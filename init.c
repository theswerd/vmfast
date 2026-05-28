// vmfast-init — minimal PID-1 process: print banner, write the host's
// snapshot sentinel, then exec busybox as `sh`. From here on the guest
// runs a real shell with ~400 applets symlinked into /bin.

typedef long ssize_t_;

static long sys3(long nr, long a, long b, long c) {
    register long x0 asm("x0") = a;
    register long x1 asm("x1") = b;
    register long x2 asm("x2") = c;
    register long x8 asm("x8") = nr;
    asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
    return x0;
}

static long sys5(long nr, long a, long b, long c, long d, long e) {
    register long x0 asm("x0") = a;
    register long x1 asm("x1") = b;
    register long x2 asm("x2") = c;
    register long x3 asm("x3") = d;
    register long x4 asm("x4") = e;
    register long x8 asm("x8") = nr;
    asm volatile("svc #0" : "+r"(x0)
        : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x8) : "memory");
    return x0;
}

static long sys_write  (int fd, const void *buf, long n) { return sys3(64,  fd, (long)buf, n); }
static long sys_execve (const char *p, char *const a[], char *const e[]) {
    return sys3(221, (long)p, (long)a, (long)e);
}
static long sys_mkdir(const char *p, long mode) {
    // mkdirat(AT_FDCWD = -100, path, mode)
    return sys3(34, -100, (long)p, mode);
}
static long sys_mount(const char *src, const char *tgt, const char *fst,
                      unsigned long flags, const void *data) {
    return sys5(40, (long)src, (long)tgt, (long)fst, (long)flags, (long)data);
}
// One-arg syscall.
static long sys1(long nr, long a) {
    register long x0 asm("x0") = a;
    register long x8 asm("x8") = nr;
    asm volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
    return x0;
}
static long sys_setsid(void)            { return sys1(157, 0); }
static long sys_close (int fd)          { return sys1(57, fd); }
static long sys_ioctl (int fd, unsigned long req, long arg) {
    return sys3(29, fd, (long)req, arg);
}
static long sys_sethostname(const char *n, long len) {
    return sys3(161, (long)n, len, 0);
}
static void sys_exit(int code) {
    register long x0 asm("x0") = code;
    register long x8 asm("x8") = 93;
    asm volatile("svc #0" :: "r"(x0), "r"(x8));
    for (;;);
}
static int slen(const char *s) { int n = 0; while (s[n]) n++; return n; }
static void puts1(const char *s) { sys_write(1, s, slen(s)); }

void _start(void) {
    // Mount the usual pseudo-filesystems so ps/free/dmesg/etc. find
    // what they expect. Failures are ignored (e.g. mkdir EEXIST).
    sys_mkdir("/proc", 0755);
    sys_mkdir("/sys",  0755);
    sys_mkdir("/tmp",  01777);
    sys_mount("proc",     "/proc", "proc",     0, 0);
    sys_mount("sysfs",    "/sys",  "sysfs",    0, 0);
    sys_mount("tmpfs",    "/tmp",  "tmpfs",    0, 0);

    sys_sethostname("vmfast", 6);

    // New session so we can claim /dev/console as the controlling tty.
    // TIOCSCTTY = 0x540E.
    sys_setsid();
    sys_ioctl(0, 0x540E, 0);

    puts1("\n*** Ubuntu Linux on vmfast (Hypervisor.framework + mmap-COW restore) ***\n");
    puts1("\n[READY_AT_PROMPT]\n");           // host snapshots here

    static char *argv[] = { (char *)"-bash", 0 };   // leading '-' → login shell
    static char *envp[] = {
        (char *)"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        (char *)"LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu:/usr/lib:/lib",
        (char *)"HOME=/root",
        (char *)"TERM=xterm-256color",
        (char *)"USER=root",
        (char *)"LOGNAME=root",
        (char *)"SHELL=/bin/bash",
        (char *)"PS1=\\[\\e[1;32m\\]root@vmfast\\[\\e[0m\\]:\\w# ",
        (char *)"HUSHLOGIN=1",
        0
    };
    sys_execve("/bin/bash", argv, envp);

    // Fallbacks if bash is unavailable for some reason.
    puts1("\nvmfast-init: /bin/bash exec failed, trying /bin/sh\n");
    static char *sh_argv[] = { (char *)"sh", 0 };
    sys_execve("/bin/sh", sh_argv, envp);

    puts1("vmfast-init: no shell available\n");
    sys_exit(1);
}
