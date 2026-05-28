#!/usr/bin/env python3
# Drives ./artifacts/vmfast-linux exec and runs a battery of commands,
# printing each command's stdout + exit code. Validates node, nc, bash,
# coreutils, /proc, networking inside a restored VM.
import subprocess, sys, threading, time

BIN = sys.argv[1] if len(sys.argv) > 1 else "./artifacts/vmfast-linux"
CMDS = [
    "cat /etc/os-release | head -1",
    "uname -r",
    "node -v",
    "node -e 'console.log(2+2)'",
    "echo hi | busybox nc -h 2>&1 | head -1 || true",
    "ip addr show eth0 2>/dev/null | grep -o '10.0.2.15' || busybox ip addr show eth0 | grep -o '10.0.2.15'",
    "echo $((6*7))",
    "for i in 1 2 3; do printf '%s' $i; done; echo",
    "ls /proc | head -3",
    "free -m | head -2",
    "echo done",
]

p = subprocess.Popen([BIN, "exec"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)

ready = threading.Event()
out_lines = []
EXIT_RE = "__VMFAST_EXIT__"

def reader():
    for raw in iter(p.stdout.readline, b""):
        line = raw.decode("utf-8", "replace").rstrip("\n")
        if line == "READY":
            ready.set()
        out_lines.append(line)

t = threading.Thread(target=reader, daemon=True)
t.start()

if not ready.wait(15):
    print("TIMEOUT waiting for READY")
    print("stderr:", p.stderr.read().decode())
    p.kill(); sys.exit(1)

t_ready = time.time()
print(f"[READY in handshake]")

idx = len(out_lines)
for cmd in CMDS:
    p.stdin.write((cmd + "\n").encode())
    p.stdin.flush()
    # wait for this command's exit marker
    deadline = time.time() + 10
    while time.time() < deadline:
        if any(EXIT_RE in l for l in out_lines[idx:]):
            break
        time.sleep(0.01)
    chunk = out_lines[idx:]
    idx = len(out_lines)
    body = [l for l in chunk if EXIT_RE not in l]
    exitm = [l for l in chunk if EXIT_RE in l]
    code = exitm[0].replace("__VMFAST_EXIT__","").replace("__","") if exitm else "?"
    print(f"$ {cmd}")
    for b in body:
        print(f"    {b}")
    print(f"  [exit {code}]")

p.stdin.close()
p.wait(timeout=5)
