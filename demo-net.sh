#!/usr/bin/env bash
# demo-net.sh - host<->guest networking over the virtio-net + libslirp path.
#
# Restores a VM, starts a netcat listener inside it, then connects to that
# listener from the host through the libslirp port-forward. The VM resumes
# with eth0 already configured (it's in the snapshot), so the network is
# live the instant the VM is back - no boot, no DHCP.
#
# The host-side port is a *starting* point: the VMM scans upward for the
# first free port and announces the one it bound on stderr as
#   [vmfast-net] forward 127.0.0.1:<port> -> guest 10.0.2.15:<guestport>
# so this script discovers the real port rather than assuming it. That's
# what lets you run many VMs at once (each lands on its own host port).
set -euo pipefail
cd "$(dirname "$0")"

GUEST_PORT="${1:-4444}"
MSG="hello-from-vmfast-$$"
ERRLOG="$(mktemp)"
trap 'rm -f "$ERRLOG"; kill "$VM" 2>/dev/null || true' EXIT

echo "-> restoring a VM with a netcat listener on guest port ${GUEST_PORT}"
( printf 'echo %s | busybox nc -l -s 0.0.0.0 -p %s &\n' "$MSG" "$GUEST_PORT"; sleep 6 ) \
    | VMFAST_HOSTFWD="${GUEST_PORT}:${GUEST_PORT}" ./artifacts/vmfast-linux exec >/dev/null 2>"$ERRLOG" &
VM=$!

# Discover the host port the VMM actually bound (it scans up from the
# start if the start is busy). The forward is set up on a background
# thread a few ms in, so poll the stderr log briefly.
HOST_PORT=""
for _ in $(seq 30); do
    HOST_PORT="$(grep -o '127\.0\.0\.1:[0-9]*' "$ERRLOG" | head -1 | cut -d: -f2 || true)"
    [ -n "$HOST_PORT" ] && break
    sleep 0.1
done
HOST_PORT="${HOST_PORT:-$GUEST_PORT}"

# Brief wait for bash + nc to bring up the listener inside the guest.
sleep 1

echo "-> host connecting to 127.0.0.1:${HOST_PORT} (forwarded to guest :${GUEST_PORT})"
got="$(nc -w 3 127.0.0.1 "$HOST_PORT" </dev/null || true)"
echo "   guest replied: ${got:-<nothing>}"
if [ "$got" = "$MSG" ]; then
    echo "   [OK] host<->guest round trip"
else
    echo "   [FAIL] no reply - is the VM built with networking? (./install.sh)"
fi
