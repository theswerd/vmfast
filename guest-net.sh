# vmfast guest network bring-up — installed as /etc/profile.d/zz-vmfast-net.sh
#
# Sourced by /etc/profile when the login shell starts, which is *before*
# bash draws its first prompt — and the prompt is exactly where the host
# snapshots the VM. So eth0 ends up configured inside the snapshot, and
# every restored VM has working networking the instant it resumes (~1 ms),
# with no boot-time DHCP round trip.
#
# Static config matches the libslirp NAT the VMM runs on the host:
#   guest 10.0.2.15/24, gateway/DNS 10.0.2.2 / 10.0.2.3.
if [ -z "${VMFAST_NET_DONE:-}" ] && [ -e /sys/class/net/eth0 ]; then
    export VMFAST_NET_DONE=1
    # Loopback: the kernel leaves lo DOWN by default. Bring it up so
    # 127.0.0.1 works inside the guest — node/servers routinely bind
    # localhost, and a forwarded host port reaches the guest by its IP
    # so a localhost-only listener would otherwise be unreachable.
    /usr/bin/busybox ip link set lo up                 2>/dev/null
    /usr/bin/busybox ip link set eth0 up               2>/dev/null
    /usr/bin/busybox ip addr add 10.0.2.15/24 dev eth0 2>/dev/null
    /usr/bin/busybox ip route add default via 10.0.2.2 2>/dev/null
    echo "nameserver 10.0.2.3" > /etc/resolv.conf      2>/dev/null
fi
