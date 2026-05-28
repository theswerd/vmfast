// vmfast-linux — M1: boot a Linux kernel on raw Hypervisor.framework
// far enough to see it printk its banner over an emulated PL011 UART.
//
// Memory map:
//   IPA 0x08000000-0x080AFFFF  GIC MMIO (unmapped — trap+ignore)
//   IPA 0x09000000-0x09000FFF  PL011 UART (unmapped — trap+emulate)
//   IPA 0x40000000-0x4FFFFFFF  Guest RAM (256 MB)
//     0x40080000               Kernel Image (loaded from vmlinuz.bin)
//     0x44000000               DTB        (loaded from vmfast.dtb)
//
// vCPU boot state (per Documentation/arm64/booting.rst):
//   x0 = DTB IPA, x1=x2=x3=0
//   PC = kernel entry IPA
//   PSTATE = EL1h, DAIF masked, MMU off

import Foundation
import Hypervisor
import Darwin

// ─────────────── memory map constants ───────────────

let PAGE_SIZE: Int      = 16384

let RAM_IPA:    UInt64  = 0x40000000
// 1 GiB. The cpio with bundled Node.js is ~200 MB, and the kernel
// needs the initrd region plus tmpfs headroom during extraction;
// 512 MB was too tight (extraction stopped midway, /usr/local/bin
// never appeared in the guest).
let RAM_SIZE:   Int     = 1024 * 1024 * 1024

// Kernel image is ~56 MB. Place initrd above it with margin, and DTB
// above the initrd. (Previous layout overlapped: kernel at 0.5 MB ran
// past 32 MB; initrd at 32 MB clobbered the kernel and the guest
// crash-landed at PC=0x200 before earlycon could print anything.)
//
// With Node.js baked into the initramfs the cpio is ~200 MB, so DTB
// has to live near the top of RAM — otherwise the DTB load clobbers
// initramfs bytes mid-stream and the kernel extracts a partially
// corrupted rootfs (bash starts, then readline files are missing, no
// `[?2004h` sentinel ever fires, snapshot never triggers).
let KERNEL_OFFSET: UInt64 = 0x80000          // 0.5 MB into RAM
let INITRD_OFFSET: UInt64 = 0x10000000       // 256 MB into RAM — leaves
                                             // 240+ MB of headroom for the
                                             // initramfs cpio
let DTB_OFFSET:    UInt64 = 0x3FF00000       // 1023 MB into RAM (1 MB
                                             // before end of 1 GB RAM)

let KERNEL_IPA: UInt64  = RAM_IPA + KERNEL_OFFSET      // 0x40080000
let INITRD_IPA: UInt64  = RAM_IPA + INITRD_OFFSET      // 0x50000000
let DTB_IPA:    UInt64  = RAM_IPA + DTB_OFFSET         // 0x58000000

let UART_IPA:   UInt64  = 0x09000000
let GIC_IPA:    UInt64  = 0x08000000

// All file artefacts live in the same directory as this binary
// (project's `artifacts/` dir). Compute that path at startup so the
// binary is runnable from anywhere, not just the project root.
func executableDirectory() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buf, &size)
    let raw = String(cString: buf)
    if let r = realpath(raw, nil) {
        let s = String(cString: r); free(r)
        return (s as NSString).deletingLastPathComponent
    }
    return (raw as NSString).deletingLastPathComponent
}
let ART = executableDirectory()
let KERNEL_FILE     = ART + "/vmlinuz.bin"
let INITRD_FILE     = ART + "/initramfs.cpio"
let DTB_FILE        = ART + "/vmfast.dtb"
let SNAP_RAM_FILE   = ART + "/snapshot.ram"
let SNAP_STATE_FILE = ART + "/snapshot.state"

// argv parsing — "restore" mode mmaps the snapshot and resumes for an
// interactive shell. "exec" mode also mmaps the snapshot, but instead of
// going interactive it runs a line-based command server on host stdio:
//   host writes one command per line → guest runs it → vmfast prints the
//   output followed by "__VMFAST_EXIT__<n>__\n" (n = $?).
// Used by external drivers (e.g. the ComputeSDK benchmark provider).
let RESTORE_MODE = CommandLine.arguments.contains("restore")
let EXEC_MODE    = CommandLine.arguments.contains("exec")
let RESTORE_OR_EXEC = RESTORE_MODE || EXEC_MODE

// System registers we save in the snapshot and reload on restore.
// Order is fixed (it's the file layout). If Hypervisor.framework
// doesn't expose one of these, build fails and we drop it.
let SAVE_SYSREGS: [hv_sys_reg_t] = [
    HV_SYS_REG_SCTLR_EL1,
    HV_SYS_REG_CPACR_EL1,
    HV_SYS_REG_TTBR0_EL1,
    HV_SYS_REG_TTBR1_EL1,
    HV_SYS_REG_TCR_EL1,
    HV_SYS_REG_MAIR_EL1,
    HV_SYS_REG_AMAIR_EL1,
    HV_SYS_REG_VBAR_EL1,
    HV_SYS_REG_TPIDR_EL0,
    HV_SYS_REG_TPIDR_EL1,
    HV_SYS_REG_TPIDRRO_EL0,
    HV_SYS_REG_CONTEXTIDR_EL1,
    HV_SYS_REG_SP_EL0,
    HV_SYS_REG_SP_EL1,
    HV_SYS_REG_ELR_EL1,
    HV_SYS_REG_SPSR_EL1,
    HV_SYS_REG_AFSR0_EL1,
    HV_SYS_REG_AFSR1_EL1,
    HV_SYS_REG_ESR_EL1,
    HV_SYS_REG_FAR_EL1,
    HV_SYS_REG_PAR_EL1,
    HV_SYS_REG_MDSCR_EL1,
    HV_SYS_REG_CNTKCTL_EL1,
    HV_SYS_REG_CNTV_CVAL_EL0,
    HV_SYS_REG_CNTV_CTL_EL0,
    // Pointer Authentication keys (ARMv8.3-PAuth). Linux signs return
    // addresses with these; if they aren't restored, the first PACIASP
    // / AUTIASP check after resume fails and the kernel oopses with
    // "FPAC". Each key is a 128-bit value split LO/HI.
    HV_SYS_REG_APIAKEYLO_EL1, HV_SYS_REG_APIAKEYHI_EL1,
    HV_SYS_REG_APIBKEYLO_EL1, HV_SYS_REG_APIBKEYHI_EL1,
    HV_SYS_REG_APDAKEYLO_EL1, HV_SYS_REG_APDAKEYHI_EL1,
    HV_SYS_REG_APDBKEYLO_EL1, HV_SYS_REG_APDBKEYHI_EL1,
    HV_SYS_REG_APGAKEYLO_EL1, HV_SYS_REG_APGAKEYHI_EL1,
]

// ─────────────── helpers ───────────────

// Process start — captured as early as possible.
let T_START = mach_absolute_time()

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
@inline(__always)
func absToMs(_ x: UInt64) -> Double {
    Double(x) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000.0
}

// Benchmark mode: silence kernel printk to stdout, only print timings.
let BENCH = ProcessInfo.processInfo.environment["BENCH"] != nil
let SILENT = ProcessInfo.processInfo.environment["SILENT"] != nil || BENCH

// Fine-grained setup profiling: VMFAST_PROFILE=1 prints ms-since-start
// at each setup checkpoint so we can see where the cold-restore budget
// goes (mmap vs hv_vm_create vs register restore vs slirp init).
let PROFILE = ProcessInfo.processInfo.environment["VMFAST_PROFILE"] != nil
@inline(__always) func tmark(_ label: String) {
    if PROFILE {
        FileHandle.standardError.write(Data(
            String(format: "[t+%6.2f ms] %@\n", absToMs(mach_absolute_time() &- T_START), label as NSString).utf8))
    }
}

// Latency checkpoints filled in as the boot progresses.
var T_VM_READY: UInt64 = 0     // after VM + vCPU + memory + regs set
var T_FIRST_UART: UInt64 = 0   // first byte written to PL011 DR
var T_ECHO_HIT: UInt64 = 0     // we matched the ECHO sentinel from /init

@inline(__always)
func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("vmfast-linux: \(msg)\n".utf8))
    exit(1)
}

@inline(__always)
func check(_ r: hv_return_t, _ what: String) {
    if r != 0 { die("\(what): 0x\(String(UInt32(bitPattern: Int32(r)), radix: 16))") }
}

// ─────────────── allocate + load guest memory ───────────────

// In cold-boot mode we allocate fresh anonymous RAM and load kernel/
// initrd/dtb into it. In restore mode we mmap(MAP_PRIVATE) the
// snapshot.ram file — kernel sets up VA→PA in O(1), pages copy-on-write
// from the file's page-cache view on first touch.
let MAP_FAILED_PTR = UnsafeMutableRawPointer(bitPattern: ~UInt(0))
let ram: UnsafeMutableRawPointer
if RESTORE_OR_EXEC {
    let fd = open(SNAP_RAM_FILE, O_RDONLY)
    if fd < 0 { die("open snapshot.ram") }
    let raw = mmap(nil, RAM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0)
    if raw == MAP_FAILED_PTR { die("mmap snapshot.ram") }
    ram = raw!
    close(fd)
    tmark("mmap snapshot.ram done")
} else {
    let raw = mmap(nil, RAM_SIZE, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON, -1, 0)
    if raw == MAP_FAILED_PTR { die("mmap anon") }
    ram = raw!
}

if !RESTORE_OR_EXEC {
// Load kernel.
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: KERNEL_FILE))
    let dst  = ram.advanced(by: Int(KERNEL_OFFSET))
    _ = data.withUnsafeBytes { src -> Int in
        memcpy(dst, src.baseAddress!, data.count)
        return 0
    }
    if !SILENT { print("loaded kernel: \(data.count / 1024) KB at IPA 0x\(String(KERNEL_IPA, radix: 16))") }
}

// Validate ARM64 Image header magic ("ARM\x64" at offset 0x38).
let kernPtr = ram.advanced(by: Int(KERNEL_OFFSET)).assumingMemoryBound(to: UInt8.self)
let magic = String(bytes: (0..<4).map { kernPtr[0x38 + $0] }, encoding: .ascii) ?? "?"
if magic != "ARM\u{40}" {
    if !SILENT { print("warning: kernel magic at offset 0x38 is \"\(magic)\" — expected 'ARM\\x40'") }
}

// Load initrd.
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: INITRD_FILE))
    let dst  = ram.advanced(by: Int(INITRD_OFFSET))
    _ = data.withUnsafeBytes { src -> Int in
        memcpy(dst, src.baseAddress!, data.count)
        return 0
    }
    if !SILENT { print("loaded initrd: \(data.count / 1024) KB at IPA 0x\(String(INITRD_IPA, radix: 16))") }
}

// Load DTB.
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: DTB_FILE))
    let dst  = ram.advanced(by: Int(DTB_OFFSET))
    _ = data.withUnsafeBytes { src -> Int in
        memcpy(dst, src.baseAddress!, data.count)
        return 0
    }
    if !SILENT { print("loaded DTB: \(data.count) bytes at IPA 0x\(String(DTB_IPA, radix: 16))") }
}
}  // end if !RESTORE_MODE (kernel/initrd/dtb load)

// ─────────────── create VM and vCPU ───────────────

check(hv_vm_create(nil), "hv_vm_create")
tmark("hv_vm_create done")
check(hv_vm_map(ram, RAM_IPA, RAM_SIZE,
                hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)),
      "hv_vm_map")
tmark("hv_vm_map done")

var vcpu: hv_vcpu_t = 0
var exitPtr: UnsafeMutablePointer<hv_vcpu_exit_t>? = nil
check(hv_vcpu_create(&vcpu, &exitPtr, nil), "hv_vcpu_create")
tmark("hv_vcpu_create done")

// virtio device state read from the snapshot here, but applied later:
// the virtio globals it populates aren't initialized until their
// declarations execute (further down the file), which is after this
// block. We buffer the raw u64s now and replay them just before the
// run loop. See virtioLoadState / the apply site near startNetworking.
var savedVirtioState: [UInt64] = []

if RESTORE_OR_EXEC {
    // Reload all vCPU general & system registers from snapshot.state.
    guard let f = fopen(SNAP_STATE_FILE, "rb") else { die("open snapshot.state") }
    func readU64() -> UInt64 {
        var v: UInt64 = 0
        let n = fread(&v, 8, 1, f)
        if n != 1 { die("fread") }
        return v
    }
    // GPRs X0..X30, then SP, PC, CPSR.
    let GPRS: [hv_reg_t] = [
        HV_REG_X0,  HV_REG_X1,  HV_REG_X2,  HV_REG_X3,
        HV_REG_X4,  HV_REG_X5,  HV_REG_X6,  HV_REG_X7,
        HV_REG_X8,  HV_REG_X9,  HV_REG_X10, HV_REG_X11,
        HV_REG_X12, HV_REG_X13, HV_REG_X14, HV_REG_X15,
        HV_REG_X16, HV_REG_X17, HV_REG_X18, HV_REG_X19,
        HV_REG_X20, HV_REG_X21, HV_REG_X22, HV_REG_X23,
        HV_REG_X24, HV_REG_X25, HV_REG_X26, HV_REG_X27,
        HV_REG_X28, HV_REG_X29, HV_REG_X30,
    ]
    for g in GPRS { check(hv_vcpu_set_reg(vcpu, g, readU64()), "set GPR") }
    _ = readU64()                                // sp slot (unused)
    let pc   = readU64()
    let cpsr = readU64()
    check(hv_vcpu_set_reg(vcpu, HV_REG_CPSR, cpsr), "restore CPSR")
    check(hv_vcpu_set_reg(vcpu, HV_REG_PC,   pc),   "restore PC")
    // System registers — SP_EL0/SP_EL1 are in this list, so guest SP
    // is restored correctly when the kernel returns to userspace.
    for sr in SAVE_SYSREGS {
        let v = readU64()
        check(hv_vcpu_set_sys_reg(vcpu, sr, v), "restore sysreg")
    }
    // Preserve CNTVCT_EL0 across snapshot. The guest's CNTVCT_EL0 is
    // `mach_absolute_time() - vtimer_offset`; on a fresh vCPU the
    // framework sets the offset so CNTVCT starts at 0. The kernel was
    // snapshotted with its timekeeper believing CNTVCT was at some
    // large value, and with CNTV_CVAL programmed accordingly. If we
    // let CNTVCT start at 0, the kernel sees an enormous backward
    // jump, then races forward when CNTVCT eventually overtakes CVAL
    // — visible as multi-thousand-second printk timestamps and RCU
    // stall warnings, and as a ~10× regression in time-to-prompt
    // because the kernel spends the first run replaying scheduler /
    // RCU bookkeeping. Re-pin CNTVCT to its snapshot value: from
    // here, kernel time advances normally, no replay storm.
    let savedCntvct = readU64()
    let newOffset = mach_absolute_time() &- savedCntvct
    check(hv_vcpu_set_vtimer_offset(vcpu, newOffset), "restore vtimer offset")
    // virtio device state: 3 scalars + 6 fields × 2 queues = 15 u64.
    for _ in 0..<15 { savedVirtioState.append(readU64()) }
    fclose(f)
} else {
    // Linux ARM64 boot protocol register state.
    check(hv_vcpu_set_reg(vcpu, HV_REG_X0,   DTB_IPA),    "x0=DTB")
    check(hv_vcpu_set_reg(vcpu, HV_REG_X1,   0),          "x1=0")
    check(hv_vcpu_set_reg(vcpu, HV_REG_X2,   0),          "x2=0")
    check(hv_vcpu_set_reg(vcpu, HV_REG_X3,   0),          "x3=0")
    check(hv_vcpu_set_reg(vcpu, HV_REG_PC,   KERNEL_IPA), "PC=kernel")
    check(hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3C5),      "CPSR")  // EL1h, DAIF=F
}

// Snapshot helper — dump full vCPU state + RAM to disk.
func saveSnapshot() {
    let GPRS: [hv_reg_t] = [
        HV_REG_X0,  HV_REG_X1,  HV_REG_X2,  HV_REG_X3,
        HV_REG_X4,  HV_REG_X5,  HV_REG_X6,  HV_REG_X7,
        HV_REG_X8,  HV_REG_X9,  HV_REG_X10, HV_REG_X11,
        HV_REG_X12, HV_REG_X13, HV_REG_X14, HV_REG_X15,
        HV_REG_X16, HV_REG_X17, HV_REG_X18, HV_REG_X19,
        HV_REG_X20, HV_REG_X21, HV_REG_X22, HV_REG_X23,
        HV_REG_X24, HV_REG_X25, HV_REG_X26, HV_REG_X27,
        HV_REG_X28, HV_REG_X29, HV_REG_X30,
    ]
    guard let f = fopen(SNAP_STATE_FILE, "wb") else { die("open state for write") }
    func writeU64(_ v: UInt64) {
        var x = v
        let n = fwrite(&x, 8, 1, f)
        if n != 1 { die("fwrite") }
    }
    for g in GPRS {
        var v: UInt64 = 0
        hv_vcpu_get_reg(vcpu, g, &v)
        writeU64(v)
    }
    // SP is a system register on ARM64 (SP_EL0/SP_EL1) — there's no
    // HV_REG_SP. We save SP_EL0/SP_EL1 via SAVE_SYSREGS below.
    writeU64(0)   // placeholder slot (kept for file layout symmetry)
    var pc: UInt64 = 0;   hv_vcpu_get_reg(vcpu, HV_REG_PC,   &pc);   writeU64(pc)
    var cpsr: UInt64 = 0; hv_vcpu_get_reg(vcpu, HV_REG_CPSR, &cpsr); writeU64(cpsr)
    for sr in SAVE_SYSREGS {
        var v: UInt64 = 0
        hv_vcpu_get_sys_reg(vcpu, sr, &v)
        writeU64(v)
    }
    // Save CNTVCT_EL0 (= mach_absolute_time() - vtimer_offset) so the
    // restore path can re-pin the guest's virtual counter to this
    // value instead of letting it reset to 0. See the restore-side
    // comment for why this matters.
    var off: UInt64 = 0
    hv_vcpu_get_vtimer_offset(vcpu, &off)
    writeU64(mach_absolute_time() &- off)
    // Host-side virtio device state (queue addresses, negotiated
    // features, consumed indices) — not in guest RAM, so it must ride
    // along or the restored guest's NIC is dead (it won't re-probe).
    virtioSaveState(writeU64)
    fclose(f)

    // Dump guest RAM. APFS sparse-encodes the long runs of zeros so the
    // file on disk is far smaller than 256 MB.
    let rf = open(SNAP_RAM_FILE, O_CREAT | O_RDWR | O_TRUNC, 0o644)
    if rf < 0 { die("open snapshot.ram for write") }
    let n = write(rf, ram, RAM_SIZE)
    if n != RAM_SIZE { die("write ram: short") }
    close(rf)
}

// Enable trapping of WFE/WFI back to the host so the kernel doesn't spin
// forever on a polling timer interrupt we never deliver.
// (Hypervisor.framework default: WFI exits the vCPU, which we treat as
// "kernel waiting for IRQ"; in M1 we just resume.)

// ─────────────── small register helpers ───────────────

// Map SRT (0..30 → Xn; 31 = XZR).
func setXn(_ n: Int, _ val: UInt64) {
    if n == 31 { return }
    let table: [hv_reg_t] = [
        HV_REG_X0,  HV_REG_X1,  HV_REG_X2,  HV_REG_X3,
        HV_REG_X4,  HV_REG_X5,  HV_REG_X6,  HV_REG_X7,
        HV_REG_X8,  HV_REG_X9,  HV_REG_X10, HV_REG_X11,
        HV_REG_X12, HV_REG_X13, HV_REG_X14, HV_REG_X15,
        HV_REG_X16, HV_REG_X17, HV_REG_X18, HV_REG_X19,
        HV_REG_X20, HV_REG_X21, HV_REG_X22, HV_REG_X23,
        HV_REG_X24, HV_REG_X25, HV_REG_X26, HV_REG_X27,
        HV_REG_X28, HV_REG_X29, HV_REG_X30,
    ]
    hv_vcpu_set_reg(vcpu, table[n], val)
}
func getXn(_ n: Int) -> UInt64 {
    if n == 31 { return 0 }
    let table: [hv_reg_t] = [
        HV_REG_X0,  HV_REG_X1,  HV_REG_X2,  HV_REG_X3,
        HV_REG_X4,  HV_REG_X5,  HV_REG_X6,  HV_REG_X7,
        HV_REG_X8,  HV_REG_X9,  HV_REG_X10, HV_REG_X11,
        HV_REG_X12, HV_REG_X13, HV_REG_X14, HV_REG_X15,
        HV_REG_X16, HV_REG_X17, HV_REG_X18, HV_REG_X19,
        HV_REG_X20, HV_REG_X21, HV_REG_X22, HV_REG_X23,
        HV_REG_X24, HV_REG_X25, HV_REG_X26, HV_REG_X27,
        HV_REG_X28, HV_REG_X29, HV_REG_X30,
    ]
    var v: UInt64 = 0
    hv_vcpu_get_reg(vcpu, table[n], &v)
    return v
}
func advancePC() {
    var pc: UInt64 = 0
    hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc)
    hv_vcpu_set_reg(vcpu, HV_REG_PC, pc &+ 4)
}

// ─────────────── PL011 emulation ───────────────

let UART_DR:   UInt64 = 0x000
let UART_RSR:  UInt64 = 0x004
let UART_FR:   UInt64 = 0x018
let UART_IBRD: UInt64 = 0x024
let UART_FBRD: UInt64 = 0x028
let UART_LCRH: UInt64 = 0x02C
let UART_CR:   UInt64 = 0x030
let UART_IFLS: UInt64 = 0x034
let UART_IMSC: UInt64 = 0x038
let UART_RIS:  UInt64 = 0x03C
let UART_MIS:  UInt64 = 0x040
let UART_ICR:  UInt64 = 0x044

// PL011 flag register: TXFE | RXFE | RX always ready, TX always empty.
let UART_FR_VAL: UInt64 = 0x90

// One sentinel for both flows: the literal end-of-PS1 bytes ":/# ".
// Our init sets PS1 so the final printed characters are "<hostname>:/# "
// — i.e. the last 4 bytes are colon, slash, hash, space. Bash writes
// these only when it's about to block on input, so the match cleanly
// signals "prompt is fully drawn".
//   * cold boot: first match → snapshot bash at its initial prompt
//   * restore   : we push a "\n" to bash on resume; the next match is
//                 bash redrawing its prompt → mark shell as ready
//
// (Previously we matched bash's bracketed-paste enable sequence
// "\e[?2004h", but this build of bash/readline doesn't emit it under
// our TERM/inputrc combo — the snapshot never fired.)
let BASH_PROMPT_SENTINEL: [UInt8] = [0x3A, 0x2F, 0x23, 0x20]   // ":/# "
let SNAP_SENTINEL = BASH_PROMPT_SENTINEL
let SHELL_READY_SENTINEL = BASH_PROMPT_SENTINEL
let TAIL_LEN = 32
var uartTail = [UInt8](repeating: 0, count: TAIL_LEN)
var uartTailLen = 0

var T_SHELL_READY: UInt64 = 0     // restore-mode: prompt fully drawn

var T_RESUMED_HIT: UInt64 = 0     // restore-mode: first prompt seen
var snapshotRequested = false     // snapshot-mode: set when sentinel matches

// ─────────────── exec-mode state ───────────────

// Phases for exec mode's output state machine:
//   waitFirstPrompt   — discard everything until the post-restore prompt
//   waitHandshakeDone — discard until "__VMFAST_HANDSHAKE_DONE__" line
//                       (after which terminal echo is disabled)
//   readyForCmd       — between commands; treat next bytes as command output
//   (no "inCommand" state needed — we just keep emitting lines until the
//   "__VMFAST_EXIT__<n>__" line appears, then loop back to readyForCmd)
var execPhase = "waitFirstPrompt"
var execLineBuf = [UInt8]()
let EXEC_HANDSHAKE_TOKEN: [UInt8] = Array("__VMFAST_HANDSHAKE_DONE__".utf8)
let EXEC_EXIT_PREFIX: [UInt8]     = Array("__VMFAST_EXIT__".utf8)
// Drives bash into a command-server loop:
//   - PS1/PS2/PROMPT_COMMAND emptied so no prompt bytes appear in output
//   - stty -echo so commands we send aren't echoed back
//   - "stty -onlcr" so guest output doesn't get LF→CRLF mangled
//   - one HANDSHAKE_DONE token so the host knows the loop is live
//   - then "while read line; do eval "$line"; emit exit marker; done"
//     so subsequent commands are one line in, output + marker out, with
//     no prompt redraws between them.
//
// IMPORTANT: the bytes of HANDSHAKE_CMD are echoed back by the tty
// BEFORE bash gets a chance to run `stty -echo`. If the command's
// source text contained the literal sentinel strings, our state-machine
// would match on the echo and run ahead of the actual command. So we
// split each sentinel across a printf format + arg — the echoed source
// has them as separate fragments, but bash's printf output reassembles
// the full sentinel.
let HANDSHAKE_CMD =
    "PS1=''; PS2=''; PROMPT_COMMAND=''; " +
    "stty -echo -onlcr 2>/dev/null; " +
    "printf '__VMFAST_%s_DONE__\\n' 'HANDSHAKE'; " +
    "while IFS= read -r __vmf_cmd; do " +
        "eval \"$__vmf_cmd\" 2>&1; " +
        "printf '__VMFAST_%s__%d__\\n' 'EXIT' \"$?\"; " +
    "done\n"

@inline(__always)
func pushToGuest(_ s: String) {
    rxLock.lock()
    for b in s.utf8 { rxQueue.append(b) }
    updateRxRis()
    rxLock.unlock()
}

@inline(__always)
func lineStartsWith(_ buf: [UInt8], _ prefix: [UInt8]) -> Bool {
    if buf.count < prefix.count { return false }
    for i in 0..<prefix.count {
        if buf[i] != prefix[i] { return false }
    }
    return true
}

@inline(__always)
func lineContains(_ buf: [UInt8], _ needle: [UInt8]) -> Bool {
    if buf.count < needle.count { return false }
    let limit = buf.count - needle.count
    for i in 0...limit {
        var match = true
        for j in 0..<needle.count {
            if buf[i + j] != needle[j] { match = false; break }
        }
        if match { return true }
    }
    return false
}

// Background thread driving exec-mode: read one line of host stdin per
// command, wrap it so we can recover the guest's exit code, push to the
// guest. EOF on host stdin → exit cleanly.
func startExecStdinReader() {
    Thread.detachNewThread {
        var v = vcpu
        var lineBuf = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 {
                // Host driver closed stdin — exit. fflush stdout first so
                // any in-flight output gets to the driver.
                fflush(stdout)
                _exit(0)
            }
            for i in 0..<Int(n) {
                let b = buf[i]
                if b == 0x0A {
                    // Bash is sitting in `while read __vmf_cmd; do ... done`
                    // — send the line verbatim; the loop wraps it.
                    let cmd = String(bytes: lineBuf, encoding: .utf8) ?? ""
                    lineBuf.removeAll(keepingCapacity: true)
                    pushToGuest(cmd + "\n")
                    hv_vcpus_exit(&v, 1)
                } else {
                    lineBuf.append(b)
                }
            }
        }
    }
}

// ─────────────── PL011 RX path + virtual IRQ ───────────────

// Bytes of host stdin waiting to be read by the guest. Pushed by a
// dedicated reader thread, drained by UART_DR reads from the guest.
var rxQueue: [UInt8] = []
let rxLock = NSLock()

// PL011 interrupt state.
var uartIMSC: UInt64 = 0            // interrupts the guest has enabled
var uartRIS:  UInt64 = 0            // raw interrupt status
// Bits in IMSC / RIS:
let UART_INT_RX: UInt64 = 1 << 4    // RXIM
let UART_INT_RT: UInt64 = 1 << 6    // RTIM (receive timeout)

// Have we already fired this RX edge?
var rxIrqAsserted = false

// PL011's INTID under our DTB: SPI 1 + 32 = 33.
let PL011_INTID: UInt32 = 33

// Virtual timer INTID. The DTS lists the vtimer as PPI 11
// (`interrupts = <0x1 0xb 0xf08>`), so guest sees it as INTID 27 (= 16 + 11).
// Without this, anything timer-driven inside the guest (sleep,
// nanosleep, libuv's epoll_wait timeout, V8's helper threads, glibc's
// arc4random pre-seed) wedges forever. Symptom: `node -v` is fast
// enough that V8 never spins up so it works, but `node -e ...` /
// `node` REPL / any setTimeout-using code hangs.
let VTIMER_INTID: UInt32 = 27

// Set when Hypervisor.framework reports HV_EXIT_REASON_VTIMER_ACTIVATED;
// cleared when the guest writes the vtimer INTID to ICC_EOIR1_EL1.
// While set, we inject IRQs into the guest and answer ICC_IAR1_EL1 with
// VTIMER_INTID. The framework auto-masks the vtimer on the exit, so we
// must call hv_vcpu_set_vtimer_mask(false) on EOI to re-arm it.
var vtimerPending = false

// Pending IRQ identified by the next ICC_IAR1_EL1 read.
var pendingIntId: UInt32 = 1023     // spurious

@inline(__always)
func updateRxRis() {
    // RIS is "raw" — reflects pending IRQ source state regardless of mask.
    if !rxQueue.isEmpty {
        uartRIS |= UART_INT_RX
    } else {
        uartRIS &= ~UART_INT_RX
    }
}

// Background thread: read stdin, push to rxQueue, kick the vCPU thread
// out of hv_vcpu_run so the main thread can set a pending IRQ (which
// must be done from the vCPU's owning thread per Hypervisor.framework).
func startStdinReader() {
    Thread.detachNewThread {
        var buf = [UInt8](repeating: 0, count: 1)
        var v = vcpu
        while true {
            let n = read(STDIN_FILENO, &buf, 1)
            if n <= 0 { return }
            rxLock.lock()
            rxQueue.append(buf[0])
            updateRxRis()
            rxLock.unlock()
            // Kick the vCPU thread so it exits hv_vcpu_run and gets a
            // chance to inject the IRQ before the next run.
            hv_vcpus_exit(&v, 1)
        }
    }
}

// Put the controlling terminal into raw mode so each keystroke goes
// through unbuffered (and isn't locally echoed by the kernel tty).
var savedTermios = termios()
var termiosWasSaved = false
func enableRawTTY() {
    if isatty(STDIN_FILENO) == 0 { return }
    tcgetattr(STDIN_FILENO, &savedTermios)
    termiosWasSaved = true
    var raw = savedTermios
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
}
func restoreTTY() {
    if termiosWasSaved {
        tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
    }
}

@inline(__always)
func tailEndsWith(_ pat: [UInt8]) -> Bool {
    if uartTailLen < pat.count { return false }
    let start = uartTailLen - pat.count
    for i in 0..<pat.count {
        if uartTail[start + i] != pat[i] { return false }
    }
    return true
}

func uartWrite(offset: UInt64, value: UInt64) {
    switch offset {
    case UART_DR:
        var byte = UInt8(value & 0xFF)
        if T_FIRST_UART == 0 { T_FIRST_UART = mach_absolute_time() }

        if RESTORE_MODE && T_RESUMED_HIT == 0 {
            // First guest byte after restore — banner BEFORE the byte
            // so the output reads naturally.
            T_RESUMED_HIT = mach_absolute_time()
            if BENCH { reportBenchAndExit() }
            // Defer the banner print until the shell is actually
            // drawable — checked below by SHELL_READY_SENTINEL match.
        }

        // Output routing:
        //   exec mode: drive the per-line state machine (see below).
        //   interactive restore / cold-boot: stream straight to stdout
        //   unless SILENT.
        if EXEC_MODE {
            switch execPhase {
            case "waitFirstPrompt":
                // Discard pre-handshake noise — the resume banner, the
                // initial prompt, etc.
                break
            case "waitHandshakeDone":
                execLineBuf.append(byte)
                if byte == 0x0A {
                    if lineContains(execLineBuf, EXEC_HANDSHAKE_TOKEN) {
                        execPhase = "readyForCmd"
                        // Signal the driver that we're ready to take
                        // commands. fflush so the driver gets it now.
                        FileHandle.standardOutput.write(Data("READY\n".utf8))
                        fflush(stdout)
                        startExecStdinReader()
                    }
                    execLineBuf.removeAll(keepingCapacity: true)
                }
            case "readyForCmd":
                execLineBuf.append(byte)
                if byte == 0x0A {
                    // Forward to host stdout. The exit-marker line is
                    // also passed through so the driver can read it.
                    FileHandle.standardOutput.write(Data(execLineBuf))
                    if lineStartsWith(execLineBuf, EXEC_EXIT_PREFIX) {
                        // Command finished — flush so the driver doesn't
                        // wait on pipe buffering.
                        fflush(stdout)
                    }
                    execLineBuf.removeAll(keepingCapacity: true)
                }
            default: break
            }
        } else if !SILENT {
            write(STDOUT_FILENO, &byte, 1)
        }

        if uartTailLen < uartTail.count {
            uartTail[uartTailLen] = byte
            uartTailLen += 1
        } else {
            for i in 0..<(uartTail.count - 1) { uartTail[i] = uartTail[i + 1] }
            uartTail[uartTail.count - 1] = byte
        }
        if !RESTORE_OR_EXEC && !snapshotRequested && tailEndsWith(SNAP_SENTINEL) {
            snapshotRequested = true
        }
        if EXEC_MODE && execPhase == "waitFirstPrompt" && tailEndsWith(SHELL_READY_SENTINEL) {
            // Snapshot was taken with bash sitting at its first prompt.
            // Kick it with a newline + handshake command so we can
            // (a) disable terminal echo (otherwise every command we send
            //     comes back interleaved with its own echo), and
            // (b) get a deterministic "I'm ready" signal we can wait on.
            execPhase = "waitHandshakeDone"
            pushToGuest(HANDSHAKE_CMD)
        }
        if RESTORE_MODE && T_SHELL_READY == 0 && tailEndsWith(SHELL_READY_SENTINEL) {
            T_SHELL_READY = mach_absolute_time()
            if !resumeBannerPrinted {
                resumeBannerPrinted = true
                let firstByteMs = absToMs(T_RESUMED_HIT &- T_START)
                let readyMs     = absToMs(T_SHELL_READY &- T_START)
                let colorCode   = Int(ProcessInfo.processInfo.environment["VMFAST_COLOR"] ?? "") ?? 51
                // Line 1 (pane color, bold): "Ubuntu VM resumed in X ms"
                // Line 2 (dim gray): "shell ready Y ms"
                let banner = String(format:
                    "\u{001B}[2J\u{001B}[H" +
                    "\u{001B}[1;38;5;%dmUbuntu VM resumed in %.2f ms\u{001B}[0m\r\n" +
                    "\u{001B}[38;5;244mshell ready %.2f ms\u{001B}[0m\r\n",
                    colorCode, firstByteMs, readyMs)
                FileHandle.standardOutput.write(Data(banner.utf8))
            }
        }
    case UART_IMSC:
        uartIMSC = value
        rxLock.lock(); updateRxRis(); rxLock.unlock()
    case UART_ICR:
        // Clear interrupts: bits written 1 clear corresponding RIS bits.
        uartRIS &= ~value
        rxLock.lock(); updateRxRis(); rxLock.unlock()
    default:
        // ignore: baud rate, control, line-control writes during init
        break
    }
}

func reportBenchAndExit() -> Never {
    let setupMs   = absToMs(T_VM_READY    &- T_START)
    let firstUart = absToMs(T_FIRST_UART  &- T_VM_READY)
    let endTime   = RESTORE_MODE ? T_RESUMED_HIT : T_ECHO_HIT
    let toEnd     = absToMs(endTime       &- T_FIRST_UART)
    let totalMs   = absToMs(endTime       &- T_START)
    let mode      = RESTORE_MODE ? "RESTORE" : "COLD BOOT"
    let label     = RESTORE_MODE ? "first byte → RESUMED" : "first byte → SNAPSHOT_NOW"
    let m = String(format:
        "\n[bench] mode                       : %@\n" +
        "[bench] host setup                 : %7.2f ms\n" +
        "[bench] vCPU run → first byte      : %7.2f ms\n" +
        "[bench] %-26@: %7.2f ms\n" +
        "[bench] TOTAL (start → end)        : %7.2f ms\n",
        mode as NSString, setupMs, firstUart, label as NSString, toEnd, totalMs)
    FileHandle.standardOutput.write(Data(m.utf8))
    exit(0)
}
func uartRead(offset: UInt64) -> UInt64 {
    switch offset {
    case UART_FR:
        // RX FIFO empty bit (4) clear when we have data; TX FIFO empty (7) always set.
        var v: UInt64 = 0x80              // TXFE
        rxLock.lock()
        if rxQueue.isEmpty { v |= 0x10 }  // RXFE
        rxLock.unlock()
        return v
    case UART_DR:
        rxLock.lock()
        let b: UInt64
        if rxQueue.isEmpty {
            b = 0
        } else {
            b = UInt64(rxQueue.removeFirst())
            updateRxRis()
        }
        rxLock.unlock()
        return b
    case UART_IMSC: return uartIMSC
    case UART_RIS:  return uartRIS
    case UART_MIS:  return uartRIS & uartIMSC
    // AMBA PrimeCell identity registers. The AMBA bus driver matches
    // devices by their PID (low 20 bits) and CID. Without correct
    // values the pl011 amba driver doesn't bind, ttyAMA0 doesn't
    // register, and /dev/console is unopenable.
    case 0xFE0:    return 0x11           // PIDR0
    case 0xFE4:    return 0x10           // PIDR1
    case 0xFE8:    return 0x14           // PIDR2
    case 0xFEC:    return 0x00           // PIDR3
    case 0xFF0:    return 0x0D           // CIDR0  ┐
    case 0xFF4:    return 0xF0           // CIDR1  │ AMBA primecell
    case 0xFF8:    return 0x05           // CIDR2  │ signature 0xB105F00D
    case 0xFFC:    return 0xB1           // CIDR3  ┘
    default:       return 0
    }
}

// ─────────────── virtio-net (MMIO, modern v2) ───────────────
//
// A minimal virtio-net device behind virtio-mmio. The stock Ubuntu
// kernel binds its built-in virtio_net driver to the DTB node and
// creates eth0; we move Ethernet frames between the guest's virtqueues
// and a userspace libslirp NAT (see slirpnet.c). Enough of the spec to
// carry TCP both ways — no checksum/GSO offload, no mergeable RX
// buffers, no control queue.

let VIRTIO_IPA:   UInt64 = 0x0A000000
let VIRTIO_INTID: UInt32 = 34            // SPI 2 (32 + 2), per the DTB
let VIRTQ_MAX:    UInt32 = 256
let VIRTIO_NET_HDR_LEN = 12              // struct virtio_net_hdr_v1

// Features we offer: VIRTIO_NET_F_MAC (bit 5) so the guest takes our
// MAC, and VIRTIO_F_VERSION_1 (bit 32) for the modern layout. Notably
// *not* F_STATUS (link is implicitly up) and *not* MRG_RXBUF (one
// descriptor chain per packet) to keep the device tiny.
let VIRTIO_DEV_FEATURES: UInt64 = (UInt64(1) << 5) | (UInt64(1) << 32)
let VIRTIO_MAC: [UInt8] = [0x52, 0x54, 0x00, 0x12, 0x34, 0x56]

struct VirtQueue {
    var num: UInt32 = 0
    var ready: UInt32 = 0
    var desc: UInt64 = 0       // descriptor table GPA
    var avail: UInt64 = 0      // available ring GPA (driver → device)
    var used: UInt64 = 0       // used ring GPA (device → driver)
    var lastAvail: UInt16 = 0  // next avail-ring slot we'll consume
}
let VQ_RX = 0
let VQ_TX = 1
var vq = [VirtQueue(), VirtQueue()]

var virtioStatus: UInt32 = 0
var virtioDriverFeatures: UInt64 = 0
var virtioDevFeaturesSel: UInt32 = 0
var virtioDrvFeaturesSel: UInt32 = 0
var virtioQueueSel: UInt32 = 0
var virtioInterruptStatus: UInt32 = 0

// Opaque libslirp handle (slirpnet.c). nil until the networking thread
// has finished dlopen'ing libvmfastnet.dylib and standing slirp up.
var slirpHandle: UnsafeMutableRawPointer? = nil

// libslirp (and its glib dependency) cost ~6 ms of dyld work at process
// launch — more than the entire cold-restore budget. So we don't link
// them: slirpnet.c is built into a side dylib (libvmfastnet.dylib) that
// we dlopen lazily, on a background thread, *after* the vCPU is already
// running. The guest's first packet is many milliseconds out, so slirp
// is always up by the time it matters, and the launch path stays lean.
typealias SlnetStartFn  = @convention(c) (
    (@convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void)?,
    UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
typealias SlnetHostfwdFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Int32
typealias SlnetTxFn      = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void
var slnetStartFn:   SlnetStartFn?   = nil
var slnetHostfwdFn: SlnetHostfwdFn? = nil
var slnetTxFn:      SlnetTxFn?      = nil

// Frames slirp produced for the guest, waiting to be placed into the RX
// virtqueue by the vCPU thread. The poll thread only enqueues here — all
// virtqueue manipulation stays single-threaded on the vCPU thread.
var rxFrameQueue: [[UInt8]] = []
let rxFrameLock = NSLock()

// ── guest-physical memory access (RAM is mmap'd at RAM_IPA) ──
@inline(__always) func gValid(_ gpa: UInt64, _ len: Int) -> Bool {
    len >= 0 && gpa >= RAM_IPA && gpa &+ UInt64(len) <= RAM_IPA &+ UInt64(RAM_SIZE)
}
@inline(__always) func gOff(_ gpa: UInt64) -> Int { Int(gpa &- RAM_IPA) }
@inline(__always) func gLoad16(_ gpa: UInt64) -> UInt16 {
    if !gValid(gpa, 2) { return 0 }
    var v: UInt16 = 0; memcpy(&v, ram + gOff(gpa), 2); return v
}
@inline(__always) func gLoad32(_ gpa: UInt64) -> UInt32 {
    if !gValid(gpa, 4) { return 0 }
    var v: UInt32 = 0; memcpy(&v, ram + gOff(gpa), 4); return v
}
@inline(__always) func gLoad64(_ gpa: UInt64) -> UInt64 {
    if !gValid(gpa, 8) { return 0 }
    var v: UInt64 = 0; memcpy(&v, ram + gOff(gpa), 8); return v
}
@inline(__always) func gStore16(_ gpa: UInt64, _ v: UInt16) {
    if !gValid(gpa, 2) { return }
    var x = v; memcpy(ram + gOff(gpa), &x, 2)
}
@inline(__always) func gStore32(_ gpa: UInt64, _ v: UInt32) {
    if !gValid(gpa, 4) { return }
    var x = v; memcpy(ram + gOff(gpa), &x, 4)
}
func gReadBytes(_ gpa: UInt64, _ len: Int) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: max(0, len))
    if len > 0 && gValid(gpa, len) {
        b.withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, ram + gOff(gpa), len) }
    }
    return b
}

// ── split virtqueue helpers ──
let VIRTQ_DESC_F_NEXT:  UInt16 = 1
let VIRTQ_DESC_F_WRITE: UInt16 = 2

@inline(__always)
func vqDesc(_ q: VirtQueue, _ i: UInt16) -> (addr: UInt64, len: UInt32, flags: UInt16, next: UInt16) {
    let d = q.desc &+ UInt64(i) &* 16
    return (gLoad64(d), gLoad32(d &+ 8), gLoad16(d &+ 12), gLoad16(d &+ 14))
}
@inline(__always) func vqAvailIdx(_ q: VirtQueue) -> UInt16 { gLoad16(q.avail &+ 2) }
@inline(__always) func vqAvailRing(_ q: VirtQueue, _ slot: UInt16) -> UInt16 {
    gLoad16(q.avail &+ 4 &+ UInt64(slot) &* 2)
}
func vqPushUsed(_ q: VirtQueue, _ id: UInt32, _ len: UInt32) {
    let uidx = gLoad16(q.used &+ 2)
    let slot = uidx % UInt16(q.num)
    let e = q.used &+ 4 &+ UInt64(slot) &* 8
    gStore32(e, id)
    gStore32(e &+ 4, len)
    gStore16(q.used &+ 2, uidx &+ 1)   // publish after the entry is written
}

@inline(__always) func virtioSignalUsed() {
    virtioInterruptStatus |= 1         // VIRTIO_MMIO_INT_VRING
}

// ── temporary packet tracing (VMFAST_NETLOG=1) ──
let NETLOG = ProcessInfo.processInfo.environment["VMFAST_NETLOG"] != nil
func netlog(_ tag: String, _ eth: ArraySlice<UInt8>) {
    if !NETLOG { return }
    let b = Array(eth)
    func u16(_ i: Int) -> Int { i+1 < b.count ? Int(b[i])<<8 | Int(b[i+1]) : -1 }
    var s = "\(tag) len=\(b.count)"
    if b.count >= 14 {
        let et = u16(12)
        if et == 0x0806 { s += " ARP" }
        else if et == 0x0800 && b.count >= 34 {
            let ihl = Int(b[14] & 0xF) * 4
            let proto = b[23]
            let src = "\(b[26]).\(b[27]).\(b[28]).\(b[29])"
            let dst = "\(b[30]).\(b[31]).\(b[32]).\(b[33])"
            let l4 = 14 + ihl
            if proto == 6 && l4 + 14 <= b.count {       // TCP
                let sp = u16(l4), dp = u16(l4+2)
                let flags = b[l4+13]
                var fs = ""
                if flags & 0x02 != 0 { fs += "S" }
                if flags & 0x10 != 0 { fs += "A" }
                if flags & 0x01 != 0 { fs += "F" }
                if flags & 0x04 != 0 { fs += "R" }
                if flags & 0x08 != 0 { fs += "P" }
                s += " TCP \(src):\(sp)->\(dst):\(dp) [\(fs)]"
            } else if proto == 1 { s += " ICMP \(src)->\(dst)" }
            else { s += " IPproto=\(proto) \(src)->\(dst)" }
        } else { s += String(format: " eth=0x%04x", et) }
    }
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

// Drain the guest's TX queue: gather each frame, strip the 12-byte
// virtio_net_hdr_v1, hand the Ethernet payload to slirp.
func virtioProcessTX() {
    var q = vq[VQ_TX]
    if q.ready == 0 || q.num == 0 || q.desc == 0 { return }
    let availIdx = vqAvailIdx(q)
    var did = false
    while q.lastAvail != availIdx {
        let head = vqAvailRing(q, q.lastAvail % UInt16(q.num))
        var frame = [UInt8]()
        var di = head
        var hops = 0
        while true {
            let d = vqDesc(q, di)
            if d.len > 0 { frame.append(contentsOf: gReadBytes(d.addr, Int(d.len))) }
            hops += 1
            if (d.flags & VIRTQ_DESC_F_NEXT) != 0 && hops < Int(q.num) { di = d.next } else { break }
        }
        q.lastAvail = q.lastAvail &+ 1
        if frame.count > VIRTIO_NET_HDR_LEN, let h = slirpHandle, let tx = slnetTxFn {
            if NETLOG { netlog("TX", frame[VIRTIO_NET_HDR_LEN...]) }
            frame.withUnsafeBufferPointer { buf in
                tx(h, buf.baseAddress! + VIRTIO_NET_HDR_LEN, frame.count - VIRTIO_NET_HDR_LEN)
            }
        }
        vqPushUsed(q, UInt32(head), 0)   // device wrote nothing back on TX
        did = true
    }
    vq[VQ_TX] = q
    if did { virtioSignalUsed() }
}

// Place queued inbound frames into the guest's RX buffers. Each frame
// gets a zeroed 12-byte header (num_buffers = 1) prepended. Called on
// the vCPU thread once per run-loop iteration.
func virtioDrainRX() {
    rxFrameLock.lock()
    if rxFrameQueue.isEmpty { rxFrameLock.unlock(); return }
    let frames = rxFrameQueue
    rxFrameQueue.removeAll(keepingCapacity: true)
    rxFrameLock.unlock()

    var q = vq[VQ_RX]
    if q.ready == 0 || q.num == 0 || q.desc == 0 {
        if NETLOG { FileHandle.standardError.write(Data("RX-DROP queue-not-ready (\(frames.count) frames)\n".utf8)) }
        return   // driver not up → drop
    }
    var delivered = false
    for frame in frames {
        if NETLOG { netlog("RX", frame[0...]) }
        if q.lastAvail == vqAvailIdx(q) {
            if NETLOG { FileHandle.standardError.write(Data("RX-DROP no-free-buffer\n".utf8)) }
            break             // no free buffer → drop rest
        }
        let head = vqAvailRing(q, q.lastAvail % UInt16(q.num))

        var pkt = [UInt8](repeating: 0, count: VIRTIO_NET_HDR_LEN)
        pkt[10] = 1                                           // num_buffers = 1 (LE u16)
        pkt.append(contentsOf: frame)

        var di = head
        var offset = 0
        var hops = 0
        while offset < pkt.count {
            let d = vqDesc(q, di)
            // RX descriptors must be device-writable.
            let cap = Int(d.len)
            let n = min(cap, pkt.count - offset)
            if n > 0 && gValid(d.addr, n) {
                pkt[offset..<offset + n].withUnsafeBytes { src in
                    _ = memcpy(ram + gOff(d.addr), src.baseAddress!, n)
                }
            }
            offset += n
            hops += 1
            if (d.flags & VIRTQ_DESC_F_NEXT) != 0 && hops < Int(q.num) { di = d.next } else { break }
        }
        q.lastAvail = q.lastAvail &+ 1
        vqPushUsed(q, UInt32(head), UInt32(offset))
        delivered = true
    }
    vq[VQ_RX] = q
    if delivered { virtioSignalUsed() }
}

func virtioReset() {
    vq[0] = VirtQueue()
    vq[1] = VirtQueue()
    virtioDriverFeatures = 0
    virtioInterruptStatus = 0
    virtioStatus = 0
}

func virtioRead(offset: UInt64, size: Int) -> UInt64 {
    if offset >= 0x100 {
        // Device config space: MAC bytes at 0x100..0x105.
        let c = Int(offset - 0x100)
        var val: UInt64 = 0
        for i in 0..<size {
            let idx = c + i
            let b: UInt8 = (idx >= 0 && idx < VIRTIO_MAC.count) ? VIRTIO_MAC[idx] : 0
            val |= UInt64(b) << (8 * i)
        }
        return val
    }
    let sel = Int(virtioQueueSel)
    switch offset {
    case 0x000: return 0x74726976                 // MagicValue "virt"
    case 0x004: return 2                           // Version (modern)
    case 0x008: return 1                           // DeviceID = net
    case 0x00c: return 0x554d4551                  // VendorID "QEMU"
    case 0x010:                                    // DeviceFeatures
        return (VIRTIO_DEV_FEATURES >> (virtioDevFeaturesSel == 1 ? 32 : 0)) & 0xffffffff
    case 0x034: return (sel < 2) ? UInt64(VIRTQ_MAX) : 0     // QueueNumMax
    case 0x044: return (sel < 2) ? UInt64(vq[sel].ready) : 0 // QueueReady
    case 0x060: return UInt64(virtioInterruptStatus)
    case 0x070: return UInt64(virtioStatus)
    case 0x0fc: return 0                           // ConfigGeneration
    default:    return 0
    }
}

func virtioWrite(offset: UInt64, size: Int, value: UInt64) {
    let v32 = UInt32(truncatingIfNeeded: value)
    let sel = Int(virtioQueueSel)
    switch offset {
    case 0x014: virtioDevFeaturesSel = v32
    case 0x020:                                    // DriverFeatures
        virtioDriverFeatures |= (value & 0xffffffff) << (virtioDrvFeaturesSel == 1 ? 32 : 0)
    case 0x024: virtioDrvFeaturesSel = v32
    case 0x030: virtioQueueSel = v32
    case 0x038: if sel < 2 { vq[sel].num = v32 }   // QueueNum
    case 0x044: if sel < 2 { vq[sel].ready = v32 } // QueueReady
    case 0x050:                                    // QueueNotify
        if Int(value) == VQ_TX { virtioProcessTX() }
    case 0x064: virtioInterruptStatus &= ~v32      // InterruptACK
    case 0x070:                                    // Status
        virtioStatus = v32
        if v32 == 0 { virtioReset() }
    case 0x080: if sel < 2 { vq[sel].desc  = (vq[sel].desc  & 0xffffffff_00000000) | UInt64(v32) }
    case 0x084: if sel < 2 { vq[sel].desc  = (vq[sel].desc  & 0x00000000_ffffffff) | (UInt64(v32) << 32) }
    case 0x090: if sel < 2 { vq[sel].avail = (vq[sel].avail & 0xffffffff_00000000) | UInt64(v32) }
    case 0x094: if sel < 2 { vq[sel].avail = (vq[sel].avail & 0x00000000_ffffffff) | (UInt64(v32) << 32) }
    case 0x0a0: if sel < 2 { vq[sel].used  = (vq[sel].used  & 0xffffffff_00000000) | UInt64(v32) }
    case 0x0a4: if sel < 2 { vq[sel].used  = (vq[sel].used  & 0x00000000_ffffffff) | (UInt64(v32) << 32) }
    default: break
    }
}

// Host-side device state that isn't in guest RAM, persisted in the
// snapshot so a restored VM resumes mid-stream without re-probing.
func virtioSaveState(_ w: (UInt64) -> Void) {
    w(UInt64(virtioStatus))
    w(virtioDriverFeatures)
    w(UInt64(virtioInterruptStatus))
    for q in vq {
        w(UInt64(q.num)); w(UInt64(q.ready))
        w(q.desc); w(q.avail); w(q.used)
        w(UInt64(q.lastAvail))
    }
}
func virtioLoadState(_ r: () -> UInt64) {
    virtioStatus = UInt32(truncatingIfNeeded: r())
    virtioDriverFeatures = r()
    virtioInterruptStatus = UInt32(truncatingIfNeeded: r())
    for i in 0..<2 {
        vq[i].num = UInt32(truncatingIfNeeded: r())
        vq[i].ready = UInt32(truncatingIfNeeded: r())
        vq[i].desc = r(); vq[i].avail = r(); vq[i].used = r()
        vq[i].lastAvail = UInt16(truncatingIfNeeded: r())
    }
}

// Called by slirp's poll thread when it has a frame for the guest.
let netDeliverCb: @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void = { ptr, len, _ in
    guard let ptr = ptr, len > 0 else { return }
    var frame = [UInt8](repeating: 0, count: len)
    frame.withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, ptr, len) }
    rxFrameLock.lock()
    if rxFrameQueue.count < 1024 { rxFrameQueue.append(frame) }   // bounded
    rxFrameLock.unlock()
    var v = vcpu
    hv_vcpus_exit(&v, 1)   // kick the vCPU so it drains RX promptly
}

// Bring up libslirp + the guest port-forward(s) on a background thread.
// The dlopen of libvmfastnet.dylib pulls in libslirp + glib (~6 ms of
// dyld work); doing it here, off the vCPU thread, keeps it entirely out
// of the cold-restore critical path. The guest's NIC config lives in the
// snapshot and its first packet is many ms away, so slirp is always up
// before any frame needs it. Frames sent before then are dropped and the
// guest's TCP/ARP simply retransmits.
func startNetworking() {
    Thread.detachNewThread {
        // libvmfastnet.dylib sits next to the binary (built by build.sh).
        let dylib = ART + "/libvmfastnet.dylib"
        guard let lib = dlopen(dylib, RTLD_NOW | RTLD_LOCAL) else {
            let msg = String(cString: dlerror() ?? UnsafeMutablePointer(mutating: ("?" as NSString).utf8String!))
            FileHandle.standardError.write(Data("vmfast-linux: dlopen(\(dylib)) failed: \(msg); networking disabled\n".utf8))
            return
        }
        guard let pStart = dlsym(lib, "slnet_start"),
              let pFwd   = dlsym(lib, "slnet_hostfwd"),
              let pTx    = dlsym(lib, "slnet_tx") else {
            FileHandle.standardError.write(Data("vmfast-linux: slnet_* symbols missing; networking disabled\n".utf8))
            return
        }
        let startFn = unsafeBitCast(pStart, to: SlnetStartFn.self)
        let fwdFn   = unsafeBitCast(pFwd,   to: SlnetHostfwdFn.self)
        // Publish tx before the handle so the vCPU thread never sees a
        // handle with no way to send.
        slnetHostfwdFn = fwdFn
        slnetTxFn = unsafeBitCast(pTx, to: SlnetTxFn.self)

        guard let h = startFn(netDeliverCb, nil) else {
            FileHandle.standardError.write(Data("vmfast-linux: slirp init failed; networking disabled\n".utf8))
            return
        }
        // VMFAST_HOSTFWD = comma-separated host:guest TCP port pairs. The
        // host side is a *starting* port: each pair scans upward from it
        // for the first free host port and binds that. So you can launch
        // any number of VMs with the same VMFAST_HOSTFWD and they each get
        // their own host port — VM #0 gets the start, #1 gets start+1, and
        // so on — with zero coordination (the OS hands out the next free
        // one). The guest port is fixed: the guest always listens on the
        // same port; you just reach it on a per-VM host port.
        //
        // VMFAST_PORT_TRIES bounds the scan window (default 256). Set it to
        // 1 for strict "this exact port or fail" behaviour.
        let spec = ProcessInfo.processInfo.environment["VMFAST_HOSTFWD"] ?? "4444:4444"
        let tries = max(1, Int(ProcessInfo.processInfo.environment["VMFAST_PORT_TRIES"] ?? "") ?? 256)
        for pair in spec.split(separator: ",") {
            let hp = pair.split(separator: ":")
            guard hp.count == 2, let hpn = Int(hp[0]), let gpn = Int(hp[1]) else { continue }
            var bound = -1
            for off in 0..<tries {
                let host = hpn + off
                if host > 65535 { break }
                if fwdFn(h, Int32(host), Int32(gpn)) == 0 { bound = host; break }
            }
            if bound >= 0 {
                // Parseable announcement so a launcher can discover which
                // host port this VM landed on (the start port isn't
                // guaranteed under concurrency). Stable token "[vmfast-net]".
                FileHandle.standardError.write(Data(
                    "[vmfast-net] forward 127.0.0.1:\(bound) -> guest 10.0.2.15:\(gpn)\n".utf8))
            } else {
                // Every port in the window was taken — almost always many
                // leaked VMs. A silent failure here looks like "networking
                // is broken" when the ports are just exhausted.
                FileHandle.standardError.write(Data(
                    "vmfast-linux: host→guest forward for guest:\(gpn) failed — no free host port in \(hpn)..\(hpn + tries - 1) (leaked VMs holding ports?)\n".utf8))
            }
        }
        // Publish the handle last — its non-nil value is the signal to the
        // vCPU thread that TX is safe.
        slirpHandle = h
        tmark("slirp ready (bg thread)")
    }
}

// ─────────────── exception decode ───────────────

func handleDataAbort(syndrome: UInt64, ipa: UInt64) -> Bool {
    let iss = syndrome & 0x01FF_FFFF
    let isv = ((iss >> 24) & 1) == 1
    if !isv {
        FileHandle.standardError.write(Data("data-abort: ISS invalid, IPA=0x\(String(ipa, radix: 16))\n".utf8))
        return false
    }
    let srt = Int((iss >> 16) & 0x1F)
    let wnr = ((iss >>  6) & 1) == 1
    let sas = Int((iss >> 22) & 3)              // access size: 0=B,1=H,2=W,3=D
    let off = ipa & 0xFFF
    let base = ipa & ~UInt64(0xFFF)

    switch base {
    case UART_IPA:
        if wnr {
            uartWrite(offset: off, value: getXn(srt))
        } else {
            setXn(srt, uartRead(offset: off))
        }
        advancePC()
        return true

    case VIRTIO_IPA:
        // virtio-net registers + config space. Honor the access width
        // so byte/halfword config reads (e.g. the MAC) work.
        if wnr {
            virtioWrite(offset: off, size: 1 << sas, value: getXn(srt))
        } else {
            setXn(srt, virtioRead(offset: off, size: 1 << sas))
        }
        advancePC()
        return true

    case let x where x >= GIC_IPA && x < GIC_IPA + 0x120000:
        // Minimal GICv3 stub. The driver probes by reading GICD_PIDR2
        // (offset 0xFFE8) and GICR_PIDR2 (in a redistributor frame),
        // and expects bits 4-7 = 3 (GICv3). Without that, it bails
        // with "no distributor detected" and the PL011 driver can't
        // request its IRQ → ttyAMA0 never registers → /dev/console
        // is unopenable → init has no stdout.
        let off = ipa - GIC_IPA
        if wnr {
            // Ignore all writes.
        } else {
            var v: UInt64 = 0
            if off < 0x10000 {
                // GICD (distributor) — first 64 KB block.
                switch off {
                case 0xFFE8: v = 0x30           // GICD_PIDR2: ArchRev=3 (GICv3)
                case 0x0004: v = 0x0000_001F    // GICD_TYPER: 32 interrupts
                case 0x0000: v = 0              // GICD_CTLR
                default:     v = 0
                }
            } else if off >= 0xA0000 && off < 0x120000 {
                // GICR (redistributors) — at GIC_IPA + 0xA0000 per DTB.
                // Each CPU's RD has a 128 KB frame; PIDR2 lives in the
                // first 64 KB (RD_base sub-frame).
                let rdoff = (off - 0xA0000) & 0xFFFF
                switch rdoff {
                case 0xFFE8: v = 0x30           // GICR_PIDR2
                case 0x0008: v = (1 << 4)       // GICR_TYPER: LAST bit set
                case 0x0014: v = 0              // GICR_WAKER: ChildrenAsleep=0
                default:     v = 0
                }
            }
            setXn(srt, v)
        }
        advancePC()
        return true

    default:
        let m = "unhandled MMIO @0x\(String(ipa, radix: 16)) (\(wnr ? "W" : "R") x\(srt))\n"
        FileHandle.standardError.write(Data(m.utf8))
        return false
    }
}

// ─────────────── PSCI / HVC ───────────────

// PSCI v1.1 function IDs (per ARM DEN 0022).
let PSCI_VERSION:       UInt64 = 0x84000000
let PSCI_CPU_OFF:       UInt64 = 0x84000002
let PSCI_CPU_ON_64:     UInt64 = 0xC4000003
let PSCI_MIGRATE_INFO:  UInt64 = 0x84000006
let PSCI_SYSTEM_OFF:    UInt64 = 0x84000008
let PSCI_SYSTEM_RESET:  UInt64 = 0x84000009
let PSCI_FEATURES:      UInt64 = 0x8400000A
let SMCCC_VERSION:      UInt64 = 0x80000000
let SMCCC_ARCH_FEATURES:UInt64 = 0x80000001

func handleHVC() -> Bool {
    let fn = getXn(0)
    switch fn {
    case SMCCC_VERSION:
        setXn(0, 0x0001_0001)             // SMCCC 1.1 — register-only convention
    case SMCCC_ARCH_FEATURES:
        setXn(0, UInt64(bitPattern: Int64(-1)))   // NOT_SUPPORTED
    case PSCI_VERSION:
        setXn(0, 0x0001_0001)             // PSCI v1.1
    case PSCI_MIGRATE_INFO:
        setXn(0, 2)                       // Trusted OS not present
    case PSCI_FEATURES:
        // x1 holds the function ID being queried.
        let q = getXn(1) & 0xFFFFFFFF
        switch q {
        case PSCI_VERSION, PSCI_CPU_OFF, PSCI_CPU_ON_64, PSCI_MIGRATE_INFO,
             PSCI_SYSTEM_OFF, PSCI_SYSTEM_RESET, PSCI_FEATURES,
             SMCCC_VERSION:
            setXn(0, 0)                   // supported, default feature bits
        default:
            setXn(0, UInt64(bitPattern: Int64(-1)))
        }
    case PSCI_SYSTEM_OFF:
        print("\n[PSCI SYSTEM_OFF — guest shut down]")
        exit(0)
    case PSCI_SYSTEM_RESET:
        print("\n[PSCI SYSTEM_RESET]")
        exit(0)
    case PSCI_CPU_OFF:
        print("\n[PSCI CPU_OFF]")
        exit(0)
    case PSCI_CPU_ON_64:
        // Single-CPU; refuse secondary CPU starts.
        setXn(0, UInt64(bitPattern: Int64(-2)))
    default:
        if !SILENT {
            let m = "unhandled HVC/SMC fn=0x\(String(fn, radix: 16))\n"
            FileHandle.standardError.write(Data(m.utf8))
        }
        setXn(0, UInt64(bitPattern: Int64(-1)))
    }
    // NOTE: Hypervisor.framework auto-advances PC past HVC. Do NOT
    // call advancePC() here — that would skip the instruction right
    // after the HVC and the kernel would resume mid-sequence. Only
    // data aborts (which trap mid-instruction) need explicit advance.
    return true
}

// ─────────────── run loop ───────────────

// Don't announce "starting vCPU" in interactive restore / exec — keep
// host stdout clean for the restored guest output and the exec protocol.
if !SILENT && !RESTORE_OR_EXEC { print("starting vCPU…") }
fflush(stdout)
T_VM_READY = mach_absolute_time()
tmark("regs restored / VM ready")

// Replay the virtio device state captured at snapshot time (buffered
// during register restore, before the virtio globals existed).
if RESTORE_OR_EXEC && savedVirtioState.count == 15 {
    var idx = 0
    virtioLoadState { let v = savedVirtioState[idx]; idx += 1; return v }
}

// Bring up the userspace NAT (libslirp) + port forwarding. This is a
// pure in-process init (no daemon/DHCP handshake), so it stays well
// inside the cold-start budget.
startNetworking()
tmark("startNetworking done")

let startTime = Date()
var exitCount: UInt64 = 0

// Interactive restore: arrange raw stdin + reader thread so the user's
// keystrokes reach the guest. SIGINT restores the terminal cleanly.
var resumeBannerPrinted = false
if RESTORE_OR_EXEC {
    // Host PL011 emulation has no view of what the kernel previously
    // wrote to UART_IMSC (we don't snapshot device-side state). Force
    // RX interrupt delivery on so the kernel hears our queued bytes.
    uartIMSC = UART_INT_RX | UART_INT_RT
    // Snapshot was taken when bash had just drawn its first prompt
    // (waiting for input). Push a newline so bash immediately processes
    // an empty command and redraws — that fresh prompt is our "shell
    // ready" event, and it's near-instant because bash is already loaded.
    rxLock.lock()
    rxQueue.append(0x0A)
    updateRxRis()
    rxLock.unlock()
    if RESTORE_MODE && !BENCH {
        enableRawTTY()
        startStdinReader()
        atexit { restoreTTY() }
        signal(SIGINT)  { _ in restoreTTY(); _exit(0) }
        signal(SIGTERM) { _ in restoreTTY(); _exit(0) }
    }
    if EXEC_MODE {
        // Exec mode reads commands from stdin line-by-line; no tty
        // mangling. Exit cleanly on signals — no terminal to restore.
        signal(SIGINT)  { _ in _exit(0) }
        signal(SIGTERM) { _ in _exit(0) }
        signal(SIGPIPE, SIG_IGN)
    }
}

while true {
    // Cold-boot mode: when /init has written the SNAPSHOT_NOW sentinel,
    // pause here, dump state, and exit. The vCPU has just finished the
    // data-abort handler for the last byte; PC is at the next kernel
    // instruction, which is exactly where we want execution to resume
    // on a future restore.
    if snapshotRequested {
        let snapStart = mach_absolute_time()
        saveSnapshot()
        let snapMs = absToMs(mach_absolute_time() &- snapStart)
        let bootMs = absToMs(snapStart &- T_START)
        if SILENT {
            let m = String(format:
                "\n[snapshot] cold boot to SNAPSHOT_NOW : %7.2f ms\n" +
                "[snapshot] state + RAM dump           : %7.2f ms\n",
                bootMs, snapMs)
            FileHandle.standardOutput.write(Data(m.utf8))
        } else {
            print(String(format: "\n[snapshot saved in %.2f ms; cold-boot to that point was %.2f ms]",
                         snapMs, bootMs))
        }
        exit(0)
    }
    // Move any inbound network frames into the guest's RX virtqueue
    // (sets virtioInterruptStatus when buffers are consumed).
    virtioDrainRX()

    // Inject a pending IRQ before the run if PL011 has RX data and the
    // kernel has unmasked RX in IMSC, the vtimer has fired and the guest
    // hasn't EOI'd it, or virtio has a used-buffer notification pending.
    // The pending bit is auto-cleared by Hypervisor.framework after each
    // run, so we set it every loop.
    do {
        rxLock.lock()
        let rxReady = !rxQueue.isEmpty && (uartIMSC & UART_INT_RX) != 0
        rxLock.unlock()
        if rxReady || vtimerPending || virtioInterruptStatus != 0 {
            hv_vcpu_set_pending_interrupt(vcpu, HV_INTERRUPT_TYPE_IRQ, true)
        }
    }
    let r = hv_vcpu_run(vcpu)
    if r != 0 { die("hv_vcpu_run returned 0x\(String(UInt32(bitPattern: Int32(r)), radix: 16))") }
    exitCount &+= 1

    let info = exitPtr!.pointee
    switch info.reason {
    case HV_EXIT_REASON_EXCEPTION:
        let syndrome = info.exception.syndrome
        let ec = (syndrome >> 26) & 0x3F
        switch ec {
        case 0x24:   // Data abort, lower EL
            if !handleDataAbort(syndrome: syndrome, ipa: info.exception.physical_address) {
                var pc: UInt64 = 0; hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc)
                die("fatal data abort @PC=0x\(String(pc, radix: 16)) IPA=0x\(String(info.exception.physical_address, radix: 16))")
            }
        case 0x16, 0x17:   // HVC / SMC (from lower EL)
            _ = handleHVC()
        case 0x1:          // Trapped WFI / WFE — pretend it returned.
            advancePC()
            // If the guest is idle waiting for input and no input is
            // queued, briefly yield to avoid pegging a P-core. When
            // the reader thread pushes a byte it will set the pending
            // IRQ and the vCPU will exit this sleep on the next run.
            if RESTORE_OR_EXEC {
                rxLock.lock()
                let uartEmpty = rxQueue.isEmpty
                rxLock.unlock()
                rxFrameLock.lock()
                let netEmpty = rxFrameQueue.isEmpty
                rxFrameLock.unlock()
                // Don't nap if console input or a network frame is
                // waiting — there's work to deliver right now.
                if uartEmpty && netEmpty && virtioInterruptStatus == 0 {
                    usleep(500)   // 0.5 ms
                }
            }
        case 0x18:         // Trapped MSR / MRS / SYS instruction
            let iss = syndrome & 0x01FFFFFF
            let dir = iss & 1                          // 1=read, 0=write
            let rt  = Int((iss >> 5) & 0x1F)
            let op0 = (iss >> 20) & 0x3
            let op2 = (iss >> 17) & 0x7
            let op1 = (iss >> 14) & 0x7
            let crn = (iss >> 10) & 0xF
            let crm = (iss >>  1) & 0xF
            // GICv3 CPU interface system registers — the kernel reads
            // ICC_IAR1_EL1 from the IRQ handler to identify which IRQ
            // fired, then writes ICC_EOIR1_EL1 to ack. Everything else
            // we stub silently.
            //   ICC_IAR1_EL1   = S3_0_C12_C12_0
            //   ICC_EOIR1_EL1  = S3_0_C12_C12_1
            if op0 == 3 && op1 == 0 && crn == 12 && crm == 12 && op2 == 0 {
                if dir == 1 {
                    // ICC_IAR1_EL1 read — kernel asks "which IRQ?".
                    // Prefer vtimer (it drives the scheduler tick;
                    // delivering it promptly keeps sleep/nanosleep/libuv
                    // honest), then virtio-net, then PL011 RX, otherwise
                    // 1023 (spurious).
                    var id: UInt64 = 1023
                    if vtimerPending {
                        id = UInt64(VTIMER_INTID)
                    } else if virtioInterruptStatus != 0 {
                        id = UInt64(VIRTIO_INTID)
                    } else {
                        rxLock.lock()
                        if !rxQueue.isEmpty { id = UInt64(PL011_INTID) }
                        rxLock.unlock()
                    }
                    setXn(rt, id)
                }
            } else if op0 == 3 && op1 == 0 && crn == 12 && crm == 12 && op2 == 1 {
                // ICC_EOIR1_EL1 write — guest is acking the IRQ whose
                // ID is in Xrt. If it's the vtimer, clear our pending
                // flag and unmask so the next expiry fires another exit.
                if dir == 0 {
                    let acked = UInt32(getXn(rt) & 0xFFFFFFFF)
                    if acked == VTIMER_INTID {
                        vtimerPending = false
                        hv_vcpu_set_vtimer_mask(vcpu, false)
                    }
                }
            } else {
                if dir == 1 { setXn(rt, 0) }
            }
            advancePC()
        case 0x20:   // Instruction abort, lower EL
            var pc: UInt64 = 0; hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc)
            die("instruction abort @PC=0x\(String(pc, radix: 16)) IPA=0x\(String(info.exception.physical_address, radix: 16))")
        default:
            var pc: UInt64 = 0; hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc)
            die("unhandled EC=0x\(String(ec, radix: 16)) syndrome=0x\(String(syndrome, radix: 16)) PC=0x\(String(pc, radix: 16))")
        }
    case HV_EXIT_REASON_VTIMER_ACTIVATED:
        // The framework already masked the vtimer for us; mark the IRQ
        // pending so the next hv_vcpu_run injects it. The guest will
        // EOI via ICC_EOIR1_EL1, which unmasks the timer.
        vtimerPending = true
        continue
    case HV_EXIT_REASON_CANCELED:
        // Interactive / exec modes kick the vCPU out via hv_vcpus_exit
        // when there's new RX input — just loop and re-run with the
        // pending IRQ set.
        if !RESTORE_OR_EXEC {
            print("\n[cancelled]")
            exit(0)
        }
    default:
        die("unknown exit reason \(info.reason.rawValue)")
    }

    // Trace + safety cap only in non-interactive modes — keep the
    // pty experience and exec protocol clean.
    if (!RESTORE_OR_EXEC) || BENCH {
        if exitCount % 20_000 == 0 && exitCount > 0 {
            var pc: UInt64 = 0; hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc)
            let info = exitPtr!.pointee
            let ec = (info.exception.syndrome >> 26) & 0x3F
            FileHandle.standardError.write(Data(
                "[trace] exits=\(exitCount) PC=0x\(String(pc, radix: 16)) lastEC=0x\(String(ec, radix: 16)) reason=\(info.reason.rawValue)\n".utf8))
        }
        if exitCount > 20_000_000 {
            let elapsed = Date().timeIntervalSince(startTime)
            FileHandle.standardError.write(Data("\n[exit cap reached after \(String(format: "%.2f", elapsed))s, \(exitCount) exits]\n".utf8))
            exit(2)
        }
    }
}
