# What the vendor DTB says — and why the payload cannot boot as built

Source: `/tmp/dts`, 9,083 lines dumped from the running vendor Linux 6.18.3 on the maintainer's board.
Every value below is **measured from the board**, not inferred.

## ✅ The console risk is CLOSED — we had it right

```
aliases { serial0 = "/soc/serial@d4017000"; }
chosen  { stdout-path = "serial0:115200"; }

serial@d4017000 {
    compatible = "spacemit,k1-uart", "intel,xscale-uart";
    reg = <0x00 0xd4017000 0x00 0x100>;
    reg-shift = <0x02>;
    reg-io-width = <0x04>;
};
```

| our assumption | measured | verdict |
|---|---|---|
| UART at `0xd4017000` | `0xd4017000` | ✅ |
| `reg-shift = 2` | `0x02` | ✅ |
| `reg-io-width = 4` (io32) | `0x04` | ✅ |
| baud 115200 | `serial0:115200` | ✅ |
| compatible in `ns16550_uart_compat[]` | `spacemit,k1-uart` **and** `intel,xscale-uart` — **both present** | ✅ |

So the console-bind fix's "UNVERIFIED-until-hardware" caveat is now **resolved**. The kernel will find this
UART. That was the single largest unknown and it landed in our favour.

## 🚫 THE BLOCKER: our kernel is linked below physical memory

```
memory@102000000 {
    reg = <0x01 0x2000000 0x07 0xfe000000>;
};
```

| | value |
|---|---|
| DRAM base | **`0x102000000`** (just above the 4 GiB line) |
| DRAM size | **`0x7fe000000` = 32.0 GiB** |
| DRAM end | `0x900000000` |
| **our link address** | **`0x80200000`** |
| inside DRAM? | **NO** |

`0x80200000` is the standard qemu-virt **and** K1 DRAM base — correct for both, and **wrong here**. On this
board there is **no memory at all below `0x102000000`**, so the kernel would be loaded into a hole and could
not execute a single instruction.

⚠️ This is why there is no image to hand over. It is also a *tenth* QEMU divergence in effect: QEMU's DRAM
starts at `0x80000000`, so every one of the 8/8 gates ran at an address this hardware does not have.

Our `k1.dts` claimed 2 GiB flat at `0x0`. Reality is 32 GiB starting above 4 GiB. Note `0x102000000` is
**not** 4 GiB exactly — it is 32 MiB past it, so a naive "link at 4 GiB" would also fail.

## Hart topology — 16 harts, two ISA variants

```
16 cpu@ nodes (cpu@0 .. cpu@15)
 8 x riscv,isa = "rv64imafdcv"
 8 x riscv,isa = "rv64imafdcvh"    <- +h, the hypervisor extension
16 x mmu-type = "riscv,sv39"
```

Better than feared. The `A100`/`X100` split differs **only** by the `h` extension; the base ISA (including
`v`) and the MMU are identical across all 16. So this is not a big.LITTLE problem for us — we use neither
`h` nor `v` — but it is still **16 harts, not 4 or 8**, and hart identity is this port's most fragile area
(bug #10 was an OpenSBI boot-hart lottery). `cpu_ncpu_online()` and the hart-slot logic need re-checking at
16.

## Interrupt controllers — APLIC, not just PLIC

```
clint@e081c000                    compatible = "riscv,clint0"
interrupt-controller@e0804000     compatible = "riscv,aplic"
```

We have a CLINT (good — timer and IPI work as expected), but the external interrupt controller is an
**APLIC**, not the `riscv,plic0` QEMU provides. Any PLIC-specific register work needs an APLIC path.

## Timebase — and a bug this exposes

```
timebase-frequency = <0x16e3600>   = 24,000,000 Hz = 24 MHz
```

⚠️ **`src/riscv/uts/timer.c:28` hardcodes QEMU's 10 MHz** ("qemu virt CLINT timebase: 10 MHz => 100 ns per
tick"). At 24 MHz every interval would be wrong by **2.4×** — the `nanosleep` measured as "169 ms for a
150 ms request" would become ~70 ms, and callouts would fire early. This must come from the DTB.

`asy_nsuart.c:599` already uses `24000000` for the UART clock, so the value was known in one file and
hardcoded wrongly in another.

## What this changes

The board is healthy, its firmware is readable, and **the hardest unknown (the UART) is confirmed correct**.
But three things must change before any boot attempt:

1. **Relink for DRAM at `0x102000000`** — a build-system change, not a guess.
2. **Read `timebase-frequency` from the DTB** instead of assuming 10 MHz.
3. **Generate `k3.dts` from this dump** rather than editing `k1.dts` by hand — 16 harts, the real memory
   map, APLIC, and the true peripheral set.

None of these needs the board. All three are verifiable in QEMU **only** for absence of regression — QEMU
cannot validate the load address, because its DRAM is at a different place. That is precisely the divergence
that has bitten nine times.
