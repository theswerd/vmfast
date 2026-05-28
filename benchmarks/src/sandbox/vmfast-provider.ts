// vmfast-linux provider for the ComputeSDK benchmark.
//
// vmfast-linux is a local Hypervisor.framework demo on Apple Silicon —
// not a hosted sandbox. This provider treats one `./artifacts/vmfast-linux
// exec` subprocess as a sandbox: the subprocess restores the VM snapshot
// (~5-10 ms cold) and then runs a "while read; do eval; done" loop in
// bash inside the guest. We talk to it line-at-a-time over stdin/stdout.
//
// Protocol with the vmfast-linux exec subprocess:
//   stdout: "READY\n" once the guest shell is ready to take commands;
//           then for each command, the guest's stdout+stderr verbatim,
//           followed by a "__VMFAST_EXIT__<n>__\n" line (n = $?).
//   stdin:  one bash command per line.

import { spawn, ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const EXIT_LINE_RE = /^__VMFAST_EXIT__(\d+)__$/;

// Default location of the vmfast-linux binary. The benchmarks tree is
// vendored inside the vmfast-linux repo, so the binary is three levels
// up from this file: benchmarks/src/sandbox/ → benchmarks/ → repo/.
const __filename = fileURLToPath(import.meta.url);
const DEFAULT_BIN =
    process.env.VMFAST_BIN
    || path.resolve(path.dirname(__filename), '../../../artifacts/vmfast-linux');

interface VmfastOptions {
  binPath?: string;
}

class VmfastSandbox {
  private proc: ChildProcessWithoutNullStreams;
  private destroyed = false;
  // Single-flight: commands are dispatched one at a time. We keep one
  // queued resolver and the buffer of stdout lines seen since the last
  // command was sent.
  private pending: {
    resolve: (r: { exitCode: number; stdout: string; stderr: string }) => void;
    reject: (e: Error) => void;
    lines: string[];
  } | null = null;
  private readyResolve: (() => void) | null = null;
  private readyPromise: Promise<void>;
  private startupErr: Buffer[] = [];

  constructor(binPath: string) {
    this.proc = spawn(binPath, ['exec'], { stdio: ['pipe', 'pipe', 'pipe'] });

    this.proc.on('error', (err) => {
      const e = new Error(`vmfast-linux failed to spawn: ${err.message}`);
      if (this.pending) this.pending.reject(e);
      if (this.readyResolve) this.readyResolve();   // unblock so create() can surface error
    });

    this.proc.stderr.on('data', (chunk: Buffer) => {
      this.startupErr.push(chunk);
    });

    this.proc.on('exit', (code, signal) => {
      this.destroyed = true;
      if (this.pending) {
        const err = new Error(
          `vmfast-linux exited (code=${code}, signal=${signal}) before command completed. stderr: ` +
          Buffer.concat(this.startupErr).toString('utf8').slice(0, 500),
        );
        this.pending.reject(err);
        this.pending = null;
      }
    });

    this.readyPromise = new Promise<void>((resolve) => {
      this.readyResolve = resolve;
    });

    const rl = createInterface({ input: this.proc.stdout });
    rl.on('line', (line) => this.handleLine(line));
  }

  private handleLine(line: string): void {
    if (this.readyResolve) {
      // Still in startup. Wait for the "READY" handshake.
      if (line === 'READY') {
        const r = this.readyResolve;
        this.readyResolve = null;
        r();
      }
      // Otherwise discard pre-READY noise (there shouldn't be any).
      return;
    }
    if (!this.pending) return;   // unsolicited output between commands — drop

    const m = EXIT_LINE_RE.exec(line);
    if (m) {
      const exitCode = parseInt(m[1], 10);
      const p = this.pending;
      this.pending = null;
      const stdout = p.lines.join('\n') + (p.lines.length ? '\n' : '');
      p.resolve({ exitCode, stdout, stderr: '' });
    } else {
      this.pending.lines.push(line);
    }
  }

  async waitReady(timeoutMs: number): Promise<void> {
    let timer: NodeJS.Timeout | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(
        () => reject(new Error(`vmfast-linux did not signal READY within ${timeoutMs}ms`)),
        timeoutMs,
      );
    });
    try {
      await Promise.race([this.readyPromise, timeout]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  async runCommand(cmd: string): Promise<{ exitCode: number; stdout: string; stderr: string }> {
    if (this.destroyed) throw new Error('vmfast sandbox already destroyed');
    if (this.pending) throw new Error('vmfast sandbox is single-flight; previous command still running');

    // The guest is sitting in `while IFS= read -r __vmf_cmd; do eval "$__vmf_cmd"; ...; done`,
    // which reads one full line per command. Newlines inside `cmd` would
    // confuse that loop, so collapse them to "; " (bash treats them the
    // same way between statements). All bench probes already arrive as
    // a single line, but be safe.
    const oneLine = cmd.replace(/\r?\n/g, '; ');

    return new Promise((resolve, reject) => {
      this.pending = { resolve, reject, lines: [] };
      this.proc.stdin.write(oneLine + '\n', (err) => {
        if (err && this.pending) {
          this.pending = null;
          reject(err);
        }
      });
    });
  }

  async destroy(): Promise<void> {
    if (this.destroyed) return;
    this.destroyed = true;
    try {
      this.proc.stdin.end();
    } catch { /* ignore */ }
    // SIGKILL after a brief grace period — we don't need a clean shutdown.
    setTimeout(() => {
      try { this.proc.kill('SIGKILL'); } catch { /* ignore */ }
    }, 200);
  }
}

/** Build a ComputeSDK-shaped `compute` object backed by vmfast-linux exec. */
export function vmfast(opts: VmfastOptions = {}): { sandbox: { create: (o?: any) => Promise<VmfastSandbox> } } {
  const binPath = opts.binPath || DEFAULT_BIN;
  return {
    sandbox: {
      create: async (_opts?: any) => {
        const sb = new VmfastSandbox(binPath);
        // Wait for the guest shell to be ready before returning. Anything
        // less and the first runCommand call would race the handshake.
        await sb.waitReady(15_000);
        return sb;
      },
    },
  };
}
