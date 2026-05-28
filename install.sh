#!/usr/bin/env bash
# install.sh — one-shot setup for vmfast-linux.
#
# Fetches:
#   - Ubuntu 24.04 ARM64 kernel
#   - Ubuntu 24.04 base rootfs (real bash, glibc, coreutils, /etc, ...)
# Installs build deps via Homebrew, then runs build.sh.
#
# Requires: macOS on Apple Silicon, Xcode Command Line Tools, Homebrew.
set -euo pipefail
cd "$(dirname "$0")"
ART="artifacts"
mkdir -p "$ART"

#─────────────── sanity ───────────────
if [[ "$(uname -s)" != "Darwin" ]] || [[ "$(uname -m)" != "arm64" ]]; then
    echo "vmfast-linux requires macOS on Apple Silicon (arm64). Got $(uname -s) $(uname -m)." >&2
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools missing. Install with: xcode-select --install" >&2
    exit 1
fi
if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew missing. Install from https://brew.sh first." >&2
    exit 1
fi

#─────────────── brew packages ───────────────
need_brew=()
command -v dtc      >/dev/null 2>&1 || need_brew+=(dtc)
command -v ld.lld   >/dev/null 2>&1 || need_brew+=(lld)
# libslirp: userspace TCP/IP NAT for the guest's virtio-net device. No
# root or kernel extension, and it stands up in-process in well under a
# millisecond (unlike vmnet's daemon/DHCP handshake), so guest networking
# fits inside the cold-start budget.
brew --prefix libslirp >/dev/null 2>&1 || need_brew+=(libslirp)
# llvm-strip is required so we can strip the aarch64 Linux Node.js
# binary we ship inside the guest (macOS `strip` doesn't grok ELF).
if [ ! -x "$(brew --prefix llvm 2>/dev/null)/bin/llvm-strip" ]; then
    need_brew+=(llvm)
fi
if [ ${#need_brew[@]} -gt 0 ]; then
    echo "→ brew install ${need_brew[*]}"
    brew install --quiet "${need_brew[@]}"
fi
LLVM_STRIP="$(brew --prefix llvm)/bin/llvm-strip"

#─────────────── Ubuntu kernel ───────────────
KERNEL_URL="https://cloud-images.ubuntu.com/releases/noble/release/unpacked/ubuntu-24.04-server-cloudimg-arm64-vmlinuz-generic"
if [ ! -f "$ART/vmlinuz.bin" ]; then
    echo "→ downloading Ubuntu 24.04 kernel (~18 MB)"
    curl -fL --progress-bar -o "$ART/vmlinuz.gz" "$KERNEL_URL"
    echo "→ decompressing kernel"
    gunzip -c "$ART/vmlinuz.gz" > "$ART/vmlinuz.bin"
    rm -f "$ART/vmlinuz.gz"
else
    echo "✓ kernel already in artifacts/"
fi

#─────────────── Ubuntu base rootfs ───────────────
BASE_VER="24.04.4"
BASE_TGZ="ubuntu-base-${BASE_VER}-base-arm64.tar.gz"
BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${BASE_VER}/release/${BASE_TGZ}"
if [ ! -d "$ART/rootfs" ] || [ -z "$(ls -A "$ART/rootfs" 2>/dev/null)" ]; then
    echo "→ downloading Ubuntu ${BASE_VER} base rootfs (~30 MB)"
    curl -fL --progress-bar -o "$ART/$BASE_TGZ" "$BASE_URL"
    echo "→ extracting rootfs into $ART/rootfs/"
    rm -rf "$ART/rootfs"
    mkdir -p "$ART/rootfs"
    # Skip dev/ — we add our own char nodes in the cpio. Don't fail on
    # the warnings macOS tar emits about unrecognised attributes.
    tar -xzf "$ART/$BASE_TGZ" -C "$ART/rootfs" --exclude='./dev/*' 2>/dev/null || true
    rm -f "$ART/$BASE_TGZ"
    # The VM has no network. Blank apt sources so `apt update` doesn't
    # hang for minutes trying to reach ports.ubuntu.com — it'll just
    # return "Done" with nothing to fetch.
    : > "$ART/rootfs/etc/apt/sources.list"
    rm -f "$ART/rootfs/etc/apt/sources.list.d/"*.sources
    rm -f "$ART/rootfs/etc/apt/sources.list.d/"*.list
    echo "✓ extracted $(find "$ART/rootfs" -type f | wc -l | tr -d ' ') files / $(find "$ART/rootfs" -type l | wc -l | tr -d ' ') symlinks ($(du -sh "$ART/rootfs" | cut -f1) on disk)"
else
    echo "✓ rootfs already in artifacts/rootfs/"
fi

#─────────────── Node.js binary (for the benchmark probe) ───────────────
# The ComputeSDK benchmark probe runs `node -v` inside the sandbox.
# Ubuntu base doesn't ship node and apt has no network, so we bake the
# official prebuilt aarch64 binary into the rootfs (and snapshot).
NODE_VER="v22.11.0"
NODE_TGZ="node-${NODE_VER}-linux-arm64.tar.xz"
NODE_URL="https://nodejs.org/dist/${NODE_VER}/${NODE_TGZ}"
NODE_DST="$ART/rootfs/usr/local/bin/node"
if [ ! -x "$NODE_DST" ]; then
    echo "→ downloading Node.js ${NODE_VER} (~28 MB)"
    curl -fL --progress-bar -o "$ART/$NODE_TGZ" "$NODE_URL"
    mkdir -p "$ART/rootfs/usr/local/bin"
    tar -xJf "$ART/$NODE_TGZ" -C "$ART" "node-${NODE_VER}-linux-arm64/bin/node"
    mv "$ART/node-${NODE_VER}-linux-arm64/bin/node" "$NODE_DST"
    rm -rf "$ART/node-${NODE_VER}-linux-arm64" "$ART/$NODE_TGZ"
    chmod 755 "$NODE_DST"
    echo "→ stripping node (~109 MB → ~50 MB)"
    "$LLVM_STRIP" --strip-all "$NODE_DST"
    echo "✓ node installed ($(du -h "$NODE_DST" | cut -f1))"
else
    echo "✓ node already in artifacts/rootfs/usr/local/bin/"
fi

#─────────────── build everything ───────────────
echo "→ building"
./build.sh

#─────────────── first-time snapshot ───────────────
# A re-snapshot is needed when init.c, vmfast.dts, or the rootfs/cpio
# changes — anything that's part of the snapshotted guest memory.
need_snapshot=0
if [ ! -f "$ART/snapshot.ram" ] || [ ! -f "$ART/snapshot.state" ]; then
    need_snapshot=1
elif [ "$ART/initramfs.cpio" -nt "$ART/snapshot.ram" ] \
  || [ "$ART/vmfast-linux"   -nt "$ART/snapshot.ram" ]; then
    echo "→ snapshot is older than the cpio / VMM — regenerating"
    rm -f "$ART/snapshot.ram" "$ART/snapshot.state"
    need_snapshot=1
fi
if [ "$need_snapshot" = 1 ]; then
    echo "→ cold-booting Ubuntu once to capture the snapshot…"
    ./artifacts/vmfast-linux >/dev/null
fi

cat <<EOF

vmfast-linux installed.
  ./artifacts/vmfast-linux restore   one VM, cold restored into a real Ubuntu bash
  ./demo-tmux.sh                     6 VMs in a tmux grid
EOF
