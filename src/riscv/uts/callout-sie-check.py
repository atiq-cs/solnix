#!/usr/bin/env python3
"""
Precondition control for the callout_lock self-deadlock.

Do NOT control on the crash: the deadlock needs a timer to land inside the hold
window, and a knowingly-broken kernel measured 4/4 "passes". Control instead on
the STATE THAT MAKES IT POSSIBLE -- is sstatus.SIE cleared before callout_lock is
acquired?

callout_lock_enter is inlined, so look at timer_intr / callout_schedule: for each
amoswap.w.aq acquire, is there a csrrc-against-sstatus in the preceding window?
"""
import subprocess, sys, re

elf  = sys.argv[1] if len(sys.argv) > 1 else "kernel.elf"
objd = sys.argv[2] if len(sys.argv) > 2 else "riscv64-none-elf-objdump"
dis = subprocess.run([objd, "-d", elf], capture_output=True, text=True).stdout
if not dis:
    print("SKIP: could not disassemble", elf); sys.exit(2)

# split into functions
funcs, cur = {}, None
for l in dis.splitlines():
    m = re.match(r'^[0-9a-f]+ <([^>]+)>:', l)
    if m:
        cur = m.group(1); funcs[cur] = []
    elif cur and re.search(r'\t', l):
        funcs[cur].append(l)

targets = [f for f in ("timer_intr", "callout_schedule") if f in funcs]
if not targets:
    print("SKIP: neither timer_intr nor callout_schedule found"); sys.exit(2)

bad = []
for f in targets:
    body = funcs[f]
    for i, l in enumerate(body):
        if "amoswap.w.aq" not in l:
            continue
        window = body[max(0, i-25):i]
        if not any(re.search(r'csrrc', w) for w in window):
            bad.append(f"{f}: acquire at line {i} has NO csrrc(sstatus) before it")

if bad:
    print("UNSAFE: callout_lock acquired with sstatus.SIE untouched:")
    for b in bad: print("   ", b)
    sys.exit(1)
print(f"CLEAN: every callout_lock acquire in {', '.join(targets)} is preceded by a csrrc(sstatus)")
sys.exit(0)
