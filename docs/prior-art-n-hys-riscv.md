# Prior art: n-hys/illumos-gate — a COMPLETE illumos RISC-V port (CDDL, reusable)

## What it is
`github.com/n-hys/illumos-gate` (= gitlink.org.cn/zxs-un/illumos-port mirror;
= the old bitbucket.org/hayashin, Hayashi Naoyuki). A real, current
(branch osport/v2022.11-wip, HEAD 2022-11-17) illumos multi-arch port:
- **riscv64**: HiFive Unleashed (SiFive FU540), **Allwinner D1 Nezha (sun20i, T-Head)**,
  QEMU virt — all REAL boards, with UART/MMC/EMAC-ethernet drivers.
- **aarch64**: ODROID-C2, **Raspberry Pi 4**, QEMU AArch64.
- Alpha (EOL).
- **LICENSE: CDDL** (Copyright 2017 Hayashi Naoyuki + Sun) — same as illumos-gate.
  DIRECTLY REUSABLE with attribution. No barrier.

## Why this is huge for solnix
Our RISC-V port (R-P1..R-P15) was written FRESH under QEMU virt. n-hys has a MATURE
`uts/riscv64` MD tree + `uts/riscv64pf/{sun20i,unleashed,virt}` platform layer that
BOOTS ON REAL SILICON. The `sun20i` (Allwinner D1, T-Head C906) platform is the
closest existing analog to the SpaceMiT K1 (both Chinese RISC-V SoCs, similar
peripheral IP). Its drivers are a direct reference for the Jupiter2:
- `riscv64pf/sun20i/io/asy_nsuart.c` — 16550-family UART (cf our dw-apb-uart)
- `riscv64pf/sun20i/io/mmc.c` + `sys/smhcreg.h` — SD/MMC controller (cf our sdhci)
- `riscv64pf/sun20i/io/emac.c` + `sys/emacreg.h` — ethernet (we have NONE)
- `riscv64pf/sun20i/asm/t-head.h`, `sys/t-head.h` — T-Head core extensions
- `riscv64/ml/{copy.s,float.s,lock_prim.s,memstr.s}` — MD assembly (mature)
- `riscv64/os/{mlsetup,sundep,archdep,fpu,sendsig}.c` — MD C (mature)
- `riscv64/krtld` — RISC-V kernel relocation (R_RISCV_*) — we hadn't built this
- `riscv64/promif` + `io/of_utils.c` — FDT/OF boot interface

Full source map: artifacts/hayashin-priorart/riscv64-tree-manifest.txt

## Gaps it does NOT close (still net-new for K1/Jupiter2)
- **RVV1.0 vector state**: n-hys is float-only (D1/FU540 predate RVV1.0). The K1's
  RVV is still ours to write.
- **SpaceMiT K1-specific**: PMIC/DDR/clock (from vendor U-Boot+OpenSBI), K1 AIA
  (APLIC+IMSIC — n-hys uses PLIC), K1's exact MMC/eth IP (adapt sun20i drivers).

## STRATEGIC RECOMMENDATION (changes the plan)
Our from-scratch R-P port proved we CAN, and taught us the terrain — but n-hys is
a shortcut to REAL HARDWARE. Rather than continue re-deriving MD/driver code for
the Jupiter2, we should:
1. **Diff n-hys riscv64 MD against our src/riscv/uts/** — adopt their mature
   locore/trap/krtld/promif where better; keep our AIA (they lack it, K1 needs it).
2. **Port n-hys `sun20i` drivers (UART/MMC/EMAC) as the K1 driver base** — adapt
   register maps to K1 from its DT. This gives us ethernet + real MMC we don't have.
3. **Keep our K1 board work** (DTB, MMIO maps, image layout) + their driver bodies.
4. RVV1.0 remains a fresh solnix contribution (nobody has it).
This likely turns "months to usable K1" into "weeks to console+storage+net on
Jupiter2", and we contribute RVV + K1 + AIA back.

## For aarch64 hardware question
n-hys supports **Raspberry Pi 4** (aarch64, DT/EBBR, GICv2) — a cheap, proven
bring-up target. Reinforces the recommendation to prefer DT/EBBR boards over
ACPI/GICv3 server blades (UpTimeLab) for day-1.
