#!/usr/bin/env python3
# Build the initramfs cpio (newc) for vmfast-linux.
#
# Layout produced:
#   /                            (dir)
#   /init                        (our PID-1 binary)
#   <every file/dir/symlink in artifacts/rootfs/>      (real Ubuntu rootfs)
#   /dev/console  /dev/tty  /dev/null  /dev/zero       (char-device nodes)
#
# We skip the rootfs's /dev (we add our own nodes), and skip the
# contents of /proc, /sys, /tmp (init mounts these at boot).
import os, sys, stat

HERE = os.path.dirname(os.path.abspath(__file__))
ART  = os.path.join(HERE, "artifacts")
ROOT = os.path.join(ART, "rootfs")

S_IFDIR  = 0o040000
S_IFCHR  = 0o020000
S_IFREG  = 0o100000
S_IFLNK  = 0o120000

next_ino = 1
def fresh_ino():
    global next_ino
    n = next_ino
    next_ino += 1
    return n

def entry(name, mode, rdev_major, rdev_minor, data, ino):
    namesize = len(name) + 1
    filesize = len(data)
    hdr  = "070701"
    hdr += f"{ino:08x}{mode:08x}"
    hdr += "00000000" * 4                           # uid, gid, nlink placeholder, mtime
    hdr  = hdr[:-16] + "00000001" + "00000000"      # set nlink=1
    hdr += f"{filesize:08x}"
    hdr += "00000000" * 2                           # devmajor, devminor
    hdr += f"{rdev_major:08x}{rdev_minor:08x}{namesize:08x}00000000"
    out  = hdr.encode("ascii")
    out += name.encode("ascii") + b"\x00"
    while len(out) % 4: out += b"\x00"
    out += data
    while len(out) % 4: out += b"\x00"
    return out

SKIP_DIRS = {"dev", "proc", "sys", "tmp"}     # populated/mounted at runtime

def walk_rootfs():
    """Yield (name, mode, rdev_major, rdev_minor, data) for every entry."""
    # Top-level mount targets (we mount /proc, /sys, /tmp from init).
    for d in sorted(SKIP_DIRS):
        yield (d, S_IFDIR | 0o755, 0, 0, b"")

    for dirpath, dirnames, filenames in os.walk(ROOT, followlinks=False):
        rel = os.path.relpath(dirpath, ROOT)
        parts = [] if rel == "." else rel.split(os.sep)
        if parts and parts[0] in SKIP_DIRS:
            dirnames[:] = []
            continue
        if rel != ".":
            st = os.lstat(dirpath)
            yield (rel.replace(os.sep, "/"),
                   S_IFDIR | (st.st_mode & 0o7777), 0, 0, b"")

        # Ubuntu uses usrmerge: /bin → usr/bin, /lib → usr/lib, etc.
        # These show up in `dirnames` (because they're directory-like)
        # but os.walk won't follow them — so we must emit them as
        # symlink entries ourselves, then strip them from dirnames so
        # we don't try to recurse.
        keep_dirs = []
        for d in dirnames:
            full = os.path.join(dirpath, d)
            if os.path.islink(full):
                target = os.readlink(full).encode()
                rname  = ("" if rel == "." else rel + os.sep) + d
                yield (rname.replace(os.sep, "/"),
                       S_IFLNK | 0o777, 0, 0, target)
            else:
                keep_dirs.append(d)
        dirnames[:] = sorted(keep_dirs)

        for f in sorted(filenames):
            fp = os.path.join(dirpath, f)
            rname = ("" if rel == "." else rel + os.sep) + f
            rname = rname.replace(os.sep, "/")
            st = os.lstat(fp)
            m = st.st_mode
            if stat.S_ISLNK(m):
                yield (rname, S_IFLNK | 0o777, 0, 0, os.readlink(fp).encode())
            elif stat.S_ISREG(m):
                with open(fp, "rb") as fh:
                    data = fh.read()
                yield (rname, S_IFREG | (m & 0o7777), 0, 0, data)
            # Anything else (char/block/socket/fifo) — skip.

def main():
    if not os.path.isdir(ROOT):
        print(f"error: {ROOT} missing — run install.sh", file=sys.stderr); sys.exit(1)
    if not os.path.isfile(os.path.join(ART, "init")):
        print(f"error: {ART}/init missing — run build.sh", file=sys.stderr); sys.exit(1)

    arc  = b""
    # Root dir + our /init come first.
    arc += entry(".",        S_IFDIR | 0o755, 0, 0, b"",                                 fresh_ino())
    with open(os.path.join(ART, "init"), "rb") as f:
        arc += entry("init", S_IFREG | 0o755, 0, 0, f.read(),                            fresh_ino())
    # Everything from the Ubuntu rootfs.
    file_count = 0
    for (name, mode, rmaj, rmin, data) in walk_rootfs():
        arc += entry(name, mode, rmaj, rmin, data, fresh_ino())
        file_count += 1

    # busybox: the Ubuntu base rootfs ships no `ip`/`ifconfig`/`nc`, so
    # we bake in the static aarch64 busybox already in artifacts/. It
    # provides the applets the guest needs to configure eth0 and to act
    # as a netcat for the host<->guest networking demo. (/usr/bin is the
    # real dir under usrmerge; /bin is a symlink to it.)
    bb = os.path.join(ART, "busybox")
    if os.path.isfile(bb):
        with open(bb, "rb") as fh:
            arc += entry("usr/bin/busybox", S_IFREG | 0o755, 0, 0, fh.read(), fresh_ino())
        # Convenience applet symlinks so `nc` / `ip` work bare.
        for applet in ("nc", "ip"):
            arc += entry("usr/bin/" + applet, S_IFLNK | 0o777, 0, 0, b"busybox", fresh_ino())
    else:
        print(f"warning: {bb} missing — guest will have no busybox/networking tools", file=sys.stderr)

    # Guest network bring-up, sourced from /etc/profile at login so the
    # NIC is configured before the snapshot prompt.
    netsh = os.path.join(HERE, "guest-net.sh")
    if os.path.isfile(netsh):
        with open(netsh, "rb") as fh:
            arc += entry("etc/profile.d/zz-vmfast-net.sh", S_IFREG | 0o644, 0, 0, fh.read(), fresh_ino())

    # The /dev nodes we add ourselves.
    arc += entry("dev/console", S_IFCHR | 0o600, 5, 1, b"", fresh_ino())
    arc += entry("dev/tty",     S_IFCHR | 0o666, 5, 0, b"", fresh_ino())
    arc += entry("dev/null",    S_IFCHR | 0o666, 1, 3, b"", fresh_ino())
    arc += entry("dev/zero",    S_IFCHR | 0o666, 1, 5, b"", fresh_ino())
    # Trailer.
    arc += entry("TRAILER!!!", 0, 0, 0, b"", 0)

    out = os.path.join(ART, "initramfs.cpio")
    with open(out, "wb") as f: f.write(arc)
    print(f"wrote {out}: {len(arc):,} bytes "
          f"({len(arc)//1024//1024} MB) — {file_count} rootfs entries")

if __name__ == "__main__":
    main()
