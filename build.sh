#!/usr/bin/env bash
# Build vmfast-linux from source. All outputs go into artifacts/.
# Prereqs (one-time, run install.sh): vmlinuz.bin and busybox in artifacts/.
set -euo pipefail
cd "$(dirname "$0")"
ART="artifacts"
mkdir -p "$ART"

# 1. Compile the device tree blob.
dtc -I dts -O dtb -o "$ART/vmfast.dtb" vmfast.dts

# 2. Cross-compile /init for ARM64 Linux.
clang --target=aarch64-linux-gnu -nostdlib -static -fuse-ld=lld \
      -ffreestanding -Wl,-e,_start \
      -o "$ART/init" init.c

# 3. Pack the initramfs cpio (needs $ART/init and $ART/busybox).
python3 mkcpio.py

# 4. Build the libslirp glue into a SIDE dylib (not linked into the main
#    binary). libslirp drags in glib, and linking it means dyld loads
#    glib at every process launch — ~6 ms, more than the whole cold-
#    restore budget. Instead the VMM dlopen's this dylib lazily, on a
#    background thread, after the vCPU is already running (see
#    startNetworking). libslirp is linked here with an rpath so the dylib
#    finds the Homebrew copy at runtime.
SLIRP_PREFIX="$(brew --prefix libslirp)"
clang -dynamiclib -O2 slirpnet.c \
    -I"$SLIRP_PREFIX/include/slirp" \
    -L"$SLIRP_PREFIX/lib" -lslirp \
    -Xlinker -rpath -Xlinker "$SLIRP_PREFIX/lib" \
    -install_name "@rpath/libvmfastnet.dylib" \
    -o "$ART/libvmfastnet.dylib"

# 5. Build + codesign the Swift VMM with the hypervisor entitlement.
#    No slirp/glib link here — the networking dylib is dlopen'd at
#    runtime (resolved next to the binary in artifacts/), so the launch
#    path carries only Hypervisor + Foundation + the Swift runtime.
swiftc -O -framework Hypervisor \
    vmfast-linux.swift \
    -o "$ART/vmfast-linux"
codesign --sign - --entitlements vmfast-linux.entitlements --force "$ART/vmfast-linux"

echo "built: $(pwd)/$ART/vmfast-linux"
