# The aarch64 console costs ~13 seconds per character — and that invalidates an experiment

A quantitative finding that reframes the whole aarch64 metal-debug loop, and
retroactively explains a result we were about to misread.

## The measurement

A prior metal boot took **~2.5 hours** to get from `scsi_vhci0` to the ZFS device
scan, during which it emitted **~670 characters** of `[A6GICD:*]` marker text.
That is **~13 seconds per character**.

## The mechanism

`boot_uart_putchar()` (armv8 `boot/boot_uart.c`) did two capped FR polls per byte:

```c
/* wait for space */
for (cap = 0; (FR & TXFF) && cap < 1000000u; cap++) yield();
write(DR, c);
/* wait for the FIFO to empty  <-- the expensive one */
for (cap = 0; !(FR & TXFE) && cap < 1000000u; cap++) yield();
```

The `[A6KCON:PUT hang txfe]` diagnostic from an earlier leg already proved
**TXFE never sets on this UART** (Graviton's console PL011 does not drive the FR
flags the way SBSA implies — the same quirk that made the original unbounded poll
hang forever). A cap does not help when the condition is *never* satisfied: every
single character pays the **full** 1,000,000 iterations of `isb sy`.

The TXFF cap is fine, because TXFF only asserts when the FIFO is genuinely full —
usually never, so that loop usually costs nothing. It is the unconditional
post-write **drain** that costs the cap on every byte.

## Why the drain is unnecessary

Draining the FIFO after each byte is not required for correctness:

* Overrun is prevented by the **TXFF check before the write**, not by draining
  after it.
* The hardware drains on its own.
* A post-write TXFE wait only matters when **handing the UART to another agent** —
  a kexec-style transfer, or powering the block down. The boot console never does
  either.

So the fix is to **drop the drain entirely** rather than cap it, and lower the TXFF
cap to 10,000 (ample for a real FIFO to free one slot, cheap enough that a
stuck-full TXFF costs milliseconds per character instead of seconds).
`a6-boot-uart-drop-txfe-drain.patch`.

Effect: a ~600-character boot goes from **~2.2 hours to seconds**.

## The experiment this invalidates

The previous leg bounded three `reg_await_clear4()` MMIO spins **and** added 19
`[A6GICD:*]` markers, after which the boot got past its stall. It honestly refused
to claim the bound was the fix, because all three bounds passed with no stuck flag,
and named the separating experiment: rebuild bounds-only with markers removed.

**That experiment cannot answer the question as posed.** Removing the markers does
not just remove printf calls — at ~13 s/char it removes roughly **2.5 hours of
settle time** injected into the middle of `gicv3_init`. So "markers removed" and
"bound alone" are not the two arms of a clean A/B; the marker arm is also a
*massively delayed* arm. Whatever the result, it would have been over-interpreted.

That is the real finding: **the debug instrument was perturbing the system by hours,
so it was never a passive observer.** With the drain removed, markers cost
microseconds and the same experiment becomes meaningful — which is the right order
to do it in.

## Consequences for how to debug this platform

1. **Re-run the bound-vs-markers experiment only after the UART fix**, when marker
   cost is negligible and the two arms differ by the intended variable alone.
2. **`-B prom_debug=1` was never affordable** on this console at 13 s/char, and
   becomes affordable now. Previous advice to reach for it was wrong on cost.
3. **Beware timing-shaped conclusions from marker-instrumented boots** generally.
   If adding output changes behaviour, suspect the output's cost before believing
   the hypothesis it was added to test.
4. **A capped poll on a condition that never occurs is not "bounded", it is a fixed
   cost.** Prefer removing an unnecessary wait to capping it; where a wait is
   necessary, size the cap to the physical event, not to a round number.
