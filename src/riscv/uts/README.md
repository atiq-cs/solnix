# src/riscv/uts — illumos riscv64 MD kernel (R-P4: SMP + cyclic clock + PLIC + high-VA hat)

**Milestone R-P4 — DONE.** The first illumos RISC-V kernel now brings up
**secondary harts via SBI HSM** (SMP), runs a **periodic (cyclic) clock** at
100 Hz with a `gethrtime` wired to the `time` CSR, takes **external interrupts
through the PLIC** (claim/complete), and installs a **real high-VA kernel map**
at a canonical `KERNELBASE` (`0xffffffc000000000`) backed by a physical page
allocator — all under OpenSBI on `qemu-system-riscv64 -machine virt -smp 4`.
These are the pieces needed before genunix (R-P5). See
`docs/design-riscv-port.md` §R-P4 and `artifacts/riscv-port/rp4/`.

(R-P3 — DONE — was trap vector + Sv39 paging + one timer tick → mlsetup/main;
R-P2 — DONE — was the first illumos RISC-V instruction + SunOS banner. See
§R-P3 / §R-P2.)

## Files

| File | What |
|------|------|
| `locore.S` | S-mode kernel entry from OpenSBI (boot hart) **and** `_secondary_start` (R-P4: the SBI-HSM secondary-hart entry — adopts a per-cpu stack from a1, installs `stvec`, loads the shared `kernel_satp`, calls `secondary_main`). Boot-hart path: entry contract (a0=hartid, a1=dtb, load @ 0x80200000), boot-hart election, boot stack, BSS clear, `stvec`, `mlsetup`. Publishes `kernel_satp` + a per-secondary stack pool. |
| `riscv_regs.h` | Priv-Spec S-mode CSR + Sv39 defs. **(R-P4)** added `KERNELBASE` (canonical high Sv39 VA split) and qemu-virt MMIO bases (`CLINT`/`PLIC`/`UART0` + `UART0_IRQ`). |
| `asm_frame.h` | Trap-frame byte offsets shared by `trap.S`/`trap.c` (288 B). |
| `trap.S` | `_trap_entry` (the `stvec` target): saves 31 GPRs + 4 trap CSRs, calls C `trap()`, `sret`. |
| `trap.c` | `set_trap_vector()`, the `trap()` dispatcher (**R-P4:** timer IRQ → `timer_intr`, external IRQ → `plic_extintr`, probe fault → resume, else park), `trap_selftest()`. |
| `hat_riscv.c` | `hat_boot_init()` Sv39 boot map + publishes `kernel_satp`. **(R-P4)** `hat_phys_init()` bump page allocator, `hat_palloc()`, `hat_kmap_page()` (hat_memload-analog: 4 KiB map via the full 3-level walk + per-VA `sfence`), `hat_highva_prove()` (map a fresh page at `KERNELBASE`, write/read-back through the high VA). |
| `timer.c` | **(R-P4)** periodic clock: `clock_start()` / `clock_prove()` arm a self-rearming timer at `HZ`=100 (10 ms period), `timer_intr()` bumps the tick counter and rearms; `gethrtime()` scales the `time` CSR (10 MHz) to nanoseconds. (R-P3's one-shot is superseded.) |
| `plic.c` | **(R-P4, new)** PLIC driver: `plic_init()` (priorities/threshold for the S-mode context = 1), `plic_enable()`, `plic_claim()`/`plic_complete()`, `plic_extintr()` (claim/dispatch/complete loop, called from `trap()`), `plic_selftest()` (enables the NS16550A UART source, triggers via THRE, claims IRQ 10 — proves external-interrupt delivery without interactive input). |
| `sbi.c`/`sbi.h` | SBI layer. Console (DBCN/legacy) + TIME (`sbi_set_timer`). **(R-P4)** added the **HSM** extension (EID 0x48534D): `sbi_hart_start()` / `sbi_hart_get_status()`. |
| `main.c` | `mlsetup(hartid,dtb)` MD bring-up (trap → Sv39 → self-test → **phys alloc + high-VA hat → SMP secondaries → PLIC → periodic clock**) → `main()` (banner + R-P4 subsystem status). **(R-P4)** `secondary_main()` (secondary report-in) + `start_secondaries()` (SBI-HSM driver) + a console spinlock to serialize multi-hart output. |
| `riscv.ld` | Linker script: `_start` at **0x80200000**. |
| `build-unix.sh` | Freestanding build + boot under OpenSBI (`-smp 4`), timeout-wrapped. |
| `unix` | The built S-mode `unix` ELF (riscv64). |

## Reproduce

```
nix shell nixpkgs#pkgsCross.riscv64-embedded.buildPackages.gcc \
          nixpkgs#pkgsCross.riscv64-embedded.buildPackages.binutils
cd src/riscv/uts
TC=riscv64-none-elf SMP=4 ./build-unix.sh
# expect (R-P4), the four gates:
#   [hat] high-VA map: KERNELBASE 0xffffffc000000000 -> PA ...  MATCH
#   [smp] hart N online (secondary, satp=shared kernel PT) x3 ; started=3 online-reported=3
#   [plic] IRQ 0xa claimed ... external IRQ 0xa claimed + completed via PLIC
#   [clock] 10 ticks, hrtime=... ns (elapsed ~100 ms) -> periodic clock running
#   [R-P4] SMP + periodic clock + PLIC external IRQ + high-VA hat online.
```

## What R-P4 proves (and does NOT)

PROVES, end to end on `-smp 4`: **SMP** (3 secondary harts released via SBI HSM,
each loading the shared kernel page table + a per-cpu stack, reporting "hart N
online"); a **periodic clock** (self-rearming at 100 Hz — 10 ticks in ~100 ms —
plus `gethrtime` in ns off the `time` CSR); **PLIC external interrupts** (UART
source enabled, IRQ 10 delivered → `sip.SEIP` → trap → claim → complete); and a
**real high-VA HAT** (a fresh physical page from the bump allocator mapped at
canonical `KERNELBASE` and verified by read-back through the high VA). All on
top of the R-P3 trap/Sv39 foundation.

DOES NOT (yet): no `page_t`/`kmem`/VM heap (the allocator is a one-way bump, no
free), no full FDT parse (RAM size is a conservative constant, not DTB-probed),
no cyclic wheel / callout dispatch / TOD (just the periodic heartbeat), no
interrupt-driven console (the console is still SBI DBCN; the PLIC UART source is
quiesced after the proof), no per-cpu dispatch/idle threads (secondaries park in
`wfi`), no ASIDs/`hat_unload`, no genunix. **R-P5** is next (genunix: `page_t`/
`kmem`, the cyclic wheel, per-cpu dispatch + idle, a real PLIC-driven console).

---

## (Historical) R-P3 — trap + Sv39 VM + one timer tick

R-P3 established the S-mode trap vector (decoded `scause`/`sepc`/`stval`, fault
taken + resumed), **Sv39 virtual memory** (paging on, kernel keeps executing
translated; non-identity alias readback proved real multi-level translation),
and **one** S-mode timer interrupt — reaching `locore → mlsetup → main` with
VM/trap/timer online. R-P4 builds directly on it.
