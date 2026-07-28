# src/riscv/uts — illumos riscv64 MD kernel (R-P3: trap + Sv39 VM + timer)

**Milestone R-P3 — DONE.** The first illumos RISC-V kernel now takes S-mode
traps, runs with **Sv39 virtual memory ON**, delivers a timer interrupt, and
reaches an `mlsetup`→`main` split with VM/trap/timer online — booted in
supervisor mode under OpenSBI on `qemu-system-riscv64 -machine virt`. This
builds directly on the R-P2 S-mode/SBI-console foundation. See
`docs/design-riscv-port.md` §R-P3 and `artifacts/riscv-port/rp3/`.

(R-P2 — DONE — was the first illumos RISC-V instruction + SunOS banner; see
§R-P2.)

## Files

| File | What |
|------|------|
| `locore.S` | S-mode kernel entry from OpenSBI. Establishes the entry contract (a0=hartid, a1=dtb, load @ 0x80200000), disables interrupts, elects the boot hart (amoswap park loop), sets up a 16 KiB boot stack, clears BSS, installs a defensive `stvec`, and calls C `mlsetup` (R-P3; was `main` in R-P2). |
| `riscv_regs.h` | **(R-P3)** Priv-Spec S-mode CSR + Sv39 definitions: scause codes, satp MODE/ASID/PPN, PTE V/R/W/X/U/G/A/D, VPN() walk macros. |
| `asm_frame.h` | **(R-P3)** Trap-frame byte offsets shared by trap.S / trap.c (288 B). |
| `trap.S` | **(R-P3)** `_trap_entry` (the `stvec` target): saves 31 GPRs + sepc/sstatus/scause/stval into a frame, calls C `trap()`, restores + `sret`. |
| `trap.c` | **(R-P3)** `set_trap_vector()`, the `trap()` dispatcher (decodes/prints scause/sepc/stval), and `trap_selftest()` (deliberate load-page-fault proof, resumes by decoding instruction length). |
| `hat_riscv.c` | **(R-P3)** `hat_boot_init()`: builds the Sv39 boot page table (real 3-level `map_page` walk + gigapage leaves), `csrw satp`+`sfence.vma`, keeps executing translated, proves translation via a non-identity alias readback. First `hat_riscv`. |
| `timer.c` | **(R-P3)** One S-mode timer interrupt via the SBI TIME extension: `timer_prove_one_tick()` / `timer_intr()`. |
| `sbi.c` / `sbi.h` | SBI (Supervisor Binary Interface) layer. Console: probes **DBCN** (EID 0x4442434E), falls back to **legacy putchar** (EID 0x01). **(R-P3)** added the **TIME** extension (`sbi_set_timer`, EID 0x54494D45). |
| `main.c` | The C kernel entry. **(R-P3)** reworked into `mlsetup(hartid,dtb)` (MD bring-up: trap vector → Sv39 paging → self-test → timer → boot `cpu_t`) → `main()` (SunOS banner + VM/trap/timer-online status). |
| `riscv.ld` | Linker script: `_start` at **0x80200000** (OpenSBI's default S-mode payload jump address on qemu virt). |
| `build-unix.sh` | Freestanding build (`-ffreestanding -nostdlib -mcmodel=medany`) + boot under OpenSBI (`-bios default`), timeout-wrapped. |
| `unix` | The built S-mode `unix` ELF (riscv64). |
| `unix-qemu-boot.log` | The successful boot: OpenSBI → S-mode → SBI DBCN console → the banner. |

## Reproduce

```
nix shell nixpkgs#pkgsCross.riscv64-embedded.buildPackages.gcc \
          nixpkgs#pkgsCross.riscv64-embedded.buildPackages.binutils
cd src/riscv/uts
TC=riscv64-none-elf ./build-unix.sh
# expect (R-P3), the three gates:
#   [mlsetup] trap vector installed (stvec -> _trap_entry, Direct mode)
#   [hat] PAGING ON: Sv39 live, executing translated. satp=0x8000000000080224
#   [hat] alias readback: ... MATCH -> Sv39 translation verified
#   [trap] self-test OK: trap taken, decoded, resumed.
#   [timer] tick #1 ... (S-mode timer interrupt delivered)
#   [R-P3] VM online, trap online, timer online.
```

## S-mode entry contract (the reusable R-P2 foundation)

OpenSBI (M-mode firmware) jumps the S-mode payload with:
- **Privilege:** Supervisor. M-mode is OpenSBI's; all firmware services via SBI ecall.
- **Load/jump addr:** `0x80200000` (OpenSBI default; firmware itself at 0x80000000).
- **a0** = boot hartid, **a1** = DTB physical address.
- **satp = 0** (MMU off; VA==PA until the Sv39 HAT in R-P3).
- **sstatus.SIE** clear (S-mode interrupts off).

`main(a0, a1)` receives `(hartid, dtb)`. Confirmed against OpenSBI's own log:
`Domain0 Next Address: 0x80200000`, `Next Arg1: 0x87e00000` (the DTB) `Next Mode: S-mode`.

## What this proves (and does NOT)

PROVES, end to end: **OpenSBI → illumos S-mode entry → SBI console → banner**
(R-P2), plus (R-P3) a working **S-mode trap vector** (decoded scause/sepc/stval,
fault taken + resumed), **Sv39 virtual memory** (paging switched on and the
kernel keeps executing translated; a non-identity alias readback proves real
multi-level translation), and **one S-mode timer interrupt** delivered/handled
— reaching `locore → mlsetup → main` with VM/trap/timer online. The S-mode
entry contract, the trap contract (§R-P3.1), the Sv39 boot map (§R-P3.2), and
the timer contract (§R-P3.3) are established and reusable.

DOES NOT (yet): no SMP (secondary harts still parked in firmware), no periodic
(cyclic) clock, no PLIC/external interrupts, no full `hat_riscv` (page alloc /
hat_memload / high `KERNELBASE` split — R-P3 uses an identity boot map + one
alias), no scheduler, no genunix. **R-P4** is next (SBI-HSM SMP, cyclic clock,
PLIC, real HAT toward genunix).
