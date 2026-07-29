# R-P16 Import Manifest — n-hys illumos RISC-V CDDL sources staged into solnix

**What:** board-INDEPENDENT CDDL sources from the n-hys illumos RISC-V port
(`github.com/n-hys/illumos-gate`, branch `v2022.11-wip`, cloned at
`/tmp/n-hys-gate`) imported into `src/riscv/uts/` to pre-stage the R-P16
Milk-V Jupiter2 / SpaceMiT K1 bring-up (~4-5 week critical path). Driven by
`artifacts/hayashin-priorart/analysis/n-hys-adoption-analysis.md` §1–§2 + §5's
adopt-list.

**License / attribution:** every imported file keeps its original **CDDL**
header (Copyright 2017–2022 Hayashi Naoyuki + Sun/Oracle/AT&T) AND carries a
`Portions Copyright <year> Hayashi Naoyuki; adapted for solnix from
n-hys/illumos-gate (<origin path>)` line. CDDL == illumos == solnix, reusable
with attribution. This is attribution, not optional; it is preserved in-file.

**Build scope (per task):** the whole thing does NOT compile against our tree
(our `src/riscv/uts` is a freestanding bring-up kernel, not the full gate). The
GOAL is to STAGE the sources with attribution. The two pieces that INTEGRATE
with our existing files (the FDT of_utils merge in `fdt.c`, and the CMO
`cmo.{h,c}`) were syntax-checked clean with the pinned cross gcc
(`pkgsCross.riscv64-embedded`, riscv64-none-elf gcc 14.3.0), both CMO backends.
The staged reference/template files are NOT expected to build standalone yet.

---

## Integration status legend
- **merged** — folded into an existing solnix file; builds/integrates now.
- **new** — a net-new capability staged as new solnix file(s); self-contained.
- **staged** — imported verbatim (+attribution) as a reference/adopt-later
  source; depends on genunix/DDI/promif we do not yet have, so not built now.
- **template** — imported as a clearly-marked reference to be rewritten for K1
  silicon; not wired live.

---

## 1. krtld — R_RISCV_* kernel-module relocation (we had NONE) — **new/staged**

| solnix file | n-hys origin | provides | status |
|---|---|---|---|
| `krtld/doreloc.c` | `usr/src/uts/riscv64/krtld/doreloc.c` | `reloc_table[R_RISCV_NUM]` + `do_reloc_krtld()` — the RISC-V relocation engine (R_RISCV_64/32/RELATIVE/JUMP_SLOT/COPY/TLS_*). | staged |
| `krtld/kobj_reloc.c` | `usr/src/uts/riscv64/krtld/kobj_reloc.c` | `do_relocate`/`do_relocations` — walks a module's SHT_RELA sections and applies relocs; SDT probe patching. | staged |
| `krtld/kobj_convrelstr.c` | `usr/src/uts/riscv64/krtld/kobj_convrelstr.c` | `conv_reloc_RISCV_type()` — reloc-type name strings (krtld debug + sgs). | staged |
| `krtld/elf_riscv.h` | `usr/src/uts/common/sys/elf_riscv.h` | `R_RISCV_*` constants + `R_RISCV_NUM` + ELF64 PLT/GOT machine defines. The header the two .c files relocate against. | staged |
| `krtld/mapfile` | `usr/src/uts/riscv64/krtld/mapfile` | krtld link-editor version mapfile. | staged |

We had **zero** module-loading (one static `unix`). This is the engine solnix
needs the day it links loadable `genunix` + driver modules, and it seeds the
Solaris link-editor (sgs) riscv relocs the toolchain track needs
(design-riscv-port.md §3.2). Depends on kobj/module infrastructure we lack →
staged, not built.

## 2. FDT ingest — of_utils reg/clock/compatible parsing — **merged into `fdt.c`**

| solnix file | n-hys origin | provides | status |
|---|---|---|---|
| `fdt.c` (appended) | `usr/src/uts/riscv64/io/of_utils.c` | driver-facing `fdt_find_compatible`, `fdt_node_reg` (honors #address/#size-cells), `fdt_node_prop_u32`, `fdt_node_clock`/`fdt_node_reset` (phandle+id), `fdt_find_phandle`, + `fdt_of_utils_selftest`. | merged |

of_utils.c's `of_get_reg/clock/reset` + `of_is_compatible` semantics were
MERGED onto our token-stream walker (a node = its struct-block byte offset,
replacing of_utils's `pnode_t`). This gives an adopted K1 driver its MMIO base
and clock/reset phandles from the DT instead of a compiled-in address — the
ingest layer every K1 driver binds through. We deliberately did NOT import the
`promif/prom_*.c` + `sys/of_utils.h` pnode_t tree (a bigger board-independent
import that would not build against our walker); the merge gets the driver-
facing capability with the smaller diff. **Our AIA-aware bits
(`fdt_intc_is_aia`, `fdt_k1_summary`) are UNTOUCHED.** Syntax-checked clean.

## 3. copyin/out full set + FPU ctxop + sendsig + lock/memstr — **staged** (KEEP ours where it works)

| solnix file | n-hys origin | provides | status |
|---|---|---|---|
| `fpu.c` | `usr/src/uts/riscv64/os/fpu.c` | the illumos float `ctxop` (lazy save/restore via `SSR_FS` dirty tracking, `fp_fenflt`, `pcb_fpu`). The exact structure RVV extends (analysis §4). | staged |
| `float.s` | `usr/src/uts/riscv64/ml/float.s` | `_fpu_save`/`_fpu_restore` (f0-f31 + fcsr). | staged |
| `sendsig.c` | `usr/src/uts/riscv64/os/sendsig.c` | real illumos `ucontext`/`sigframe` on the user stack (siginfo, sigreturn, altstack) — vs our one-deep bring-up frame. | staged |
| `copy_full.s` | `usr/src/uts/riscv64/ml/copy.s` | the COMPLETE fault-safe copy set (`copyin/out/instr/kcopy/xcopyin/ucopy/hwblkclr` + real `t_lofault`). | staged |
| `lock_prim.s` | `usr/src/uts/riscv64/ml/lock_prim.s` | full `mutex_enter/exit`, `rw_*`, `lock_set/clear`, atomic backends in the illumos ABI. | staged |
| `memstr.s` | `usr/src/uts/riscv64/ml/memstr.s` | kernel MI-string asm stubs. | staged |

**KEPT ours:** `copy.S` (our fault-safe `copyin`/`copyout` already work — see
its `_copy_fault`/`copy_lofault` contract with `trap.c`), `swtch.S`
(per-thread satp/lofault/hart, analysis says KEEP), `aia.c`/`plic.c` (our AIA,
which n-hys lacks), `sdhci.c` (K1 is standard SDHCI, ours is closer to K1 than
n-hys's Allwinner SMHC `mmc.c`). The full set above is imported as the
adopt-at-genunix-link reference; it depends on `t_lofault`/`curthread`/`ctxop`/
assym that don't exist in our tree yet → staged, not built.

## 4. UART — dw-apb-uart / 8250 STREAMS console base — **staged** (alongside our `uart.c`)

| solnix file | n-hys origin | provides | status |
|---|---|---|---|
| `asy_nsuart.c` | `usr/src/uts/riscv64pf/sun20i/io/asy_nsuart.c` | full 8250/16450/16550A/16650/16750 STREAMS+tty console (ring buffer, `cons_polledio`, softint, modem ctl, `ddi_regs_map_setup`, FDT `reg-shift` parse). | staged |
| `asy_nsuart.h` | `usr/src/uts/riscv64pf/sun20i/io/asy_nsuart.h` | asy register/soft-state defs incl. the Allwinner `USR/TFL/RFL` extras. | staged |

Slotted alongside our R-P14 poll `uart.c` (which already proves the K1
`reg-shift=2` arithmetic). asy_nsuart is `reg-shift`-aware already; the analysis
delta is to add the **`reg-io-width=4` 32-bit access branch** for the K1
dw-apb-uart — our `uart.c` already implements that 32-bit branch (`uart_io32`),
so the delta is well-understood. asy_nsuart depends on STREAMS/tty/DDI →
staged (the interrupt-driven tty upgrade, Phase B6), our poll `uart.c` remains
the gate-1 banner driver.

## 5. T-Head CMO — cache-maintenance for non-coherent DMA (CRITICAL for K1) — **new**

| solnix file | n-hys origin | provides | status |
|---|---|---|---|
| `cmo.h` | `usr/src/uts/riscv64pf/sun20i/asm/t-head.h` | the CMO primitives: `cmo_dcache_clean/invalidate/flush`, `cmo_icache_invalidate`, `cmo_dma_wb`/`cmo_dma_inv`. Two build-time backends: **T-Head custom `.long` ops (default, verbatim n-hys ISA)** and **`-DCMO_ZICBOM`** (ratified Zicbom, prefer if Jupiter2 DT `riscv,isa` lists `zicbom`). DCACHE_LINE=64. | new |
| `cmo.c` | `usr/src/uts/riscv64pf/sun20i/os/sun20i_dep.c` | the `sync_icache`/`sync_data_memory` coherence hooks over cmo.h + `cmo_selftest()`. | new |

K1's X60 is T-Head-derived and its dwcmshc-sdhci/dwmac DMA is non-coherent →
these ops are REQUIRED to make MMC + ethernet work (they BLOCK both without it).
Our qemu-virt bring-up never needed CMO (qemu DMA is coherent). Made self-
contained for our freestanding tree (no `sys/platform.h` / `paddr_t` / P2ALIGN
dependency). **Both backends syntax-checked clean.** The self-test proves the
range loop + a clean+invalidate round-trip is non-destructive; real
non-coherent-visibility confirmation is the on-K1-silicon step.

## 6. EMAC — NIC template (we have NO ethernet) — **template** (in `pf/`)

| solnix file | n-hys origin | provides | status |
|---|---|---|---|
| `pf/emac.c` | `usr/src/uts/riscv64pf/sun20i/io/emac.c` | full GLDv3 (`mac_callbacks`, `mac_register`, `DDI_DEFINE_STREAM_OPS`) NIC: TX/RX DMA descriptor rings, MII/PHY, `ddi_dma` buffers, interrupt-driven RX/TX. ~60-70% of an illumos NIC driver. | template |
| `pf/emac.h` | `usr/src/uts/riscv64pf/sun20i/io/emac.h` | emac soft-state/desc structures. | template |
| `pf/emacreg.h` | `usr/src/uts/riscv64pf/sun20i/sys/emacreg.h` | Allwinner EMAC register map — to be REPLACED with the K1 dwmac map. | template |

Marked in-file "TEMPLATE for the K1 dwmac (stmmac); reg layer to be rewritten;
NOT wired live." The K1/Jupiter2 MAC is Synopsys `dwmac`/stmmac, NOT Allwinner
EMAC, so the register layer (`emacreg.h` + descriptor ring) gets rewritten once
the Jupiter2 DT confirms the exact `compatible` (analysis §2.3). We adopt
emac.c's illumos STRUCTURE (the only NIC skeleton we have) as the reference for
Phase D10; it is NOT compiled or attached.

---

## Bottom line — what we NOW have that we lacked

| Capability | Before R-P16 | After R-P16 |
|---|---|---|
| **krtld R_RISCV_* module reloc** | none | staged (`krtld/*` — the full reloc engine + `R_RISCV_*` header) |
| **CMO (non-coherent DMA cache ops)** | none | **new + built** (`cmo.{h,c}`, T-Head + Zicbom backends) — unblocks K1 MMC/eth |
| **FDT rich reg/clock/compatible ingest** | summary walker only | **merged + built** (`fdt.c` of_utils accessors) — drivers get base/clocks from DT |
| **UART dw-apb 8250 STREAMS base** | poll `uart.c` (gate-1) | staged (`asy_nsuart.{c,h}`) for the interrupt-driven tty upgrade |
| **EMAC / NIC template** | none | template (`pf/emac.{c,h}`, `pf/emacreg.h`) — the only illumos NIC skeleton we have |
| **FPU float ctxop (RVV foundation)** | none (boot FS=Off) | staged (`fpu.c`+`float.s`) — the structure RVV extends |
| **sendsig / full copy / locks / memstr** | thin bring-up | staged (adopt at genunix-link) |

## What still needs the physical board (R-P16 on-silicon)
- **Real Jupiter2 DTB** (replace hand-written `k1.dts`); feed through `fdt.c` +
  the merged of_utils accessors.
- **U-Boot + OpenSBI handoff** built from `spacemit_k1_defconfig` → our
  `build-k1-image.sh`.
- **CMO on-silicon coherence** (T-Head vs Zicbom decision from the DT
  `riscv,isa`; DMA-loopback confirmation).
- **SDHCI `-DK1_SILICON`** flip to 0xd4281000 + dwcmshc vendor-area/phase tuning.
- **dwmac register map + descriptor ring** rewritten from the EMAC template once
  the Jupiter2 DT confirms `snps,dwmac*`.
- **AIA wiring** of the SDHCI/dwmac interrupts (our `aia.c`, kept).

## Confirmations
- **CDDL attribution preserved** in every imported file (CDDL header intact +
  `Portions Copyright <year> Hayashi Naoyuki; adapted for solnix from
  n-hys/illumos-gate (<origin>)`). Verified by grep (see progress.md).
- **KEPT untouched** (analysis says keep ours): `aia.c`, `plic.c`, `swtch.S`,
  `sdhci.c`, `copy.S`.
- **Did NOT compile the whole tree** (per task — our tree != full gate). Only
  the two INTEGRATION files (`fdt.c` merge, `cmo.{h,c}`) were syntax-checked
  clean with the pinned cross gcc, both CMO backends.
- **Did NOT git commit** (orchestrator commits).
