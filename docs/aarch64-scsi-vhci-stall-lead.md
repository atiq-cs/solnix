# aarch64: the post-`scsi_vhci` stall

> ## ⚠️ THE HYPOTHESIS BELOW IS REFUTED. Read this box, then skip to "The real lead".
>
> I wrote the byte-wide-GICD-write theory from the QEMU log and committed it. It is
> **wrong**, refuted statically with no hardware spend, on three independent counts
> (all re-verified by me):
>
> 1. **No byte accessor exists.** `gicthree.c` has only `gicd_write4` = `ddi_put32`
>    and `gicd_write8` = `ddi_put64`. The sweep is **already word-granular**:
>    `for (n = 32; n < gc_maxsources; n += 32) gicd_write4(gc, GICD_ICENABLERn(n>>5), 0xFFFFFFFF)`.
>    Same in `gictwo.c`.
> 2. **QEMU manufactures the bytes, not the kernel.** `hw/intc/arm_gic.c` decomposes
>    `gic_dist_writel()` -> 2x `writew` -> 4x `writeb`, so ONE 32-bit kernel store
>    produces FOUR "writeb" log lines. The log shows exactly that: runs of four
>    consecutive bytes at **word-aligned** starts (`0x1a4` is `% 4 == 0`, then
>    `1a5 1a6 1a7`, then `2a4..2a7`). I confirmed the alignment and the run length.
> 3. **"Bad offset" is QEMU's `num_irq` bound, not a granularity complaint.** Every
>    register group's first rejected offset decodes to **irq 288 = QEMU virt's
>    `NUM_IRQS`(256) + 32**: ICENABLER `0x1a4`, ICPENDR `0x2a4`, ICACTIVER `0x3a4`,
>    IPRIORITYR `0x520`, ITARGETSR `0x920` all -> 288. The kernel sweeps to
>    `GICD_TYPER_LINES` (up to 1020); QEMU virt has only 288 lines. Nothing that
>    matters is dropped, and on Graviton those lines physically exist so there is
>    nothing to reject at all.
>
> And the fatal flaw in my reasoning: the QEMU log's next node after `scsi_vhci` is
> **`gictwo0 at root`** -- QEMU virt runs the **GICv2** driver, while the metal path
> is `gicthree.c`. A different attach entirely, so that log could never have
> evidenced the metal stall. I compared two different code paths and did not check
> which driver each was using.
>
> **Lesson:** "the working boot does X right where the broken one dies" is a
> correlation, and I treated it as a mechanism. Before building on it, confirm both
> sides are running the same code -- and decode the numbers rather than
> pattern-matching them (my own ICFGR decode was also wrong: it is 2 bits per irq).
>
> ## The real lead (same class as the boot_uart FR-poll bug)
>
> `gicthree.c:303 reg_await_clear4()` is an **unbounded** `while (ddi_get32(...) & mask);`
> spin, reached from `gicd_drain_writes` (GICD_CTLR.RWP), `gicr_drain_writes`
> (GICR_CTLR.RWP) and `gicv3_awaken_cpu` (GICR_WAKER.ChildrenAsleep). **A silent hang
> with no panic is exactly an unbounded MMIO spin** -- a `VERIFY` would have printed
> something. This is the same failure shape as the Graviton boot-UART FR-poll bug,
> where a flag that never changes state on this hardware wedged an unbounded poll.

---

# Original (REFUTED) hypothesis, kept for the record


The GICv3 redistributor-count blocker is cleared on real Graviton
(`artifacts/a6gic3-metal-console-GIC-CLEARED.txt`). The boot now reaches:

```
root nexus = Amazon EC2
pseudo0 is /pseudo
scsi_vhci0 at root
scsi_vhci0 is /scsi_vhci        <-- then SILENCE on metal (status running/ok/impaired)
```

## The lead: compare against the WORKING QEMU boot

`artifacts/aarch64-a5/qemu-console-a5.log` is a *successful* aarch64 boot. What it
does immediately after that same `scsi_vhci0 is /scsi_vhci` line is striking:

```
scsi_vhci0 is /scsi_vhci
gic_dist_writeb: Bad offset 1a4
gic_dist_writeb: Bad offset 1a5
gic_dist_writeb: Bad offset 1a6
gic_dist_writeb: Bad offset 1a7
gic_dist_writeb: Bad offset 2a4
...  (continues across 1a4-1ab, 2a4-2ab, 3a4-3ab ...)
```

So the very next thing the kernel does after `scsi_vhci` is **byte-wide writes to
GIC distributor registers**, and QEMU is rejecting every one of them as a bad
offset — while tolerating it and booting on.

## Why that is very likely the metal stall

Decoding those offsets in the GICD register map:

| offset range | register | purpose |
|---|---|---|
| `0x180`-`0x1ff` | `GICD_ICENABLER` | clear-enable (disable an SPI) |
| `0x280`-`0x2ff` | `GICD_ICPENDR`  | clear-pending |
| `0x380`-`0x3ff` | `GICD_ICACTIVER` | clear-active |

`0x1a4`, `0x2a4`, `0x3a4`, `0x1a8` … are exactly those three, which is the classic
GIC-init "quiesce every SPI" sweep: disable, clear pending, clear active.

**Per the GICv3 architecture these are 32-bit registers.** Byte-granular access to
them is not architecturally guaranteed. That explains both observations at once:

* **QEMU**: implements a `writeb` path, doesn't recognise byte offsets into those
  registers, logs `Bad offset`, discards the write, and carries on. Harmless there
  — the SPIs happen to already be quiescent in an emulated GIC.
* **Real Graviton**: a byte write to a register the implementation only decodes at
  word granularity may fault, or may be dropped so the SPIs are **never actually
  disabled** — and then the first real device attach (NVMe over PCIe) delivers an
  interrupt into an unconfigured/unhandled vector and the boot dies silently.
  Silent is the expected signature either way: the console write itself is the
  thing that stops working once interrupts go wrong.

Note this also fits the fact that the GIC **count** fix did not surface it: getting
the redistributor count right is what finally let the code proceed *to* this sweep.

## What to do with it (do not assume — measure)

1. **Find the sweep** in `uts/armv8/io/gicthree.c` (or its GICD helpers) — look for
   `ddi_put8`/byte-wide accessors used against `ICENABLER`/`ICPENDR`/`ICACTIVER`,
   or a loop writing one byte per 8 interrupts instead of one word per 32.
2. **Confirm before changing**: a bounded diagnostic marker immediately before and
   after the sweep will show on real Graviton whether the boot dies *inside* it.
   Use the working `[A6KCON:*]`-style path, and remember a prior leg found ~350
   bytes overflows the PL011's 32-byte FIFO, so any diagnostic needs a bounded
   TXFF poll.
3. **The likely fix**: perform these as 32-bit writes (word-granular, one write per
   32 interrupt IDs), which is what the architecture specifies. That should be a
   small, local change.
4. **Watch for the follow-on**: even with the sweep fixed, the first NVMe/PCIe
   attach still needs **ITS/MSI** delivery working, which nothing has exercised
   yet. Expect that as the next blocker and capture its console text rather than
   chaining another fix.

## Status

This is a **hypothesis with strong supporting evidence**, not a diagnosis. It has
not been confirmed on hardware, and no fix has been written. It is recorded so the
next attempt starts here instead of rediscovering it — the previous agent was
reaching for exactly this comparison when it terminated.
