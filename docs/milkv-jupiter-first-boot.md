# Milk-V Jupiter (SpacemiT K1) — first boot attempt

**What this is:** a microSD card and a U-Boot procedure for attempting the first
execution of solnix code on a K1 SoC. Nothing in this project has ever run an
instruction on this silicon.

**What this is NOT:** an operating system you can install. The riscv64 registry
has **zero** derivations, `elf.c` loads static `ET_EXEC` only, `rootfs.c` is a
read-only in-memory filesystem, and there is no ZFS. This is a kernel that may
print to a UART. The success condition is *console text*, nothing more.

This document is the flashing/booting companion to
`docs/milkv-jupiter-bringup-runbook.md` (which covers the serial console and the
stock-vendor-boot prerequisites, and should be read first).

---

## 0. The honest answer on the missing UART adapter

**Read this before flashing anything.**

The debug UART is the **only** observation channel this kernel has. It has no
network stack that could phone home, no framebuffer output on the boot path, no
LED it toggles, and no persistent log — it prints to a serial console and that is
the entire instrument. Every single row of the expectation table in section 4 is
read off that console.

So: **without a USB-to-UART adapter, attempting this boot produces no
information at all.** It is not merely degraded, it is null. A board that boots
our kernel perfectly and a board that faults at instruction three look
*identical* from the outside: an HDMI monitor stays dark in both cases (we never
touch the display), the Ethernet LEDs behave identically (we never bring up the
MAC), and the eMMC is untouched in both (by design). There is no side channel.

**Recommendation: wait for the adapter.** Section 8 lists the few things worth
doing without one — all of them preparation, none of them a boot attempt. The
card is harmless to write now; it is the *attempt* that is worthless unobserved,
because a silent console is indistinguishable from a hang (section 5).

That is a refutation of the "attempt the boot" framing, and it is deliberate.
Flashing something unobservable burns an attempt and teaches nothing.

---

## 1. The image

### 1.1 Build the kernel (reproducible; the artifact is gitignored on purpose)

`unix-k1.Image` is **not committed**, deliberately: a stale flashable image is
worse than none. The recipe is the artifact.

```sh
cd /home/gburd/ws/solnix/src/riscv/uts
nix shell 'nixpkgs#pkgsCross.riscv64-embedded.buildPackages.gcc14' \
          'nixpkgs#pkgsCross.riscv64-embedded.buildPackages.binutils' \
          'nixpkgs#dtc' \
  -c bash ./build-k1-payload.sh
```

Lands at, and self-checks:

| Artifact | Bytes | What |
|---|---|---|
| `src/riscv/uts/unix-k1.Image` | 624408 | the kernel, linked at `0x02000000`, with the RISC-V Image header — **this is what `booti` loads** |
| `src/riscv/uts/k1.dtb` | 4962 | our K1 devicetree |
| `src/riscv/uts/unix-k1.elf` | — | same kernel as ELF, for `addr2line` when reading a fault. **Never flash this** |

Verified by the build (**[VERIFIED-locally]**): Image magic `0x05435352` at
offset `0x38`, `text_offset == KBASE`, byte 0 disassembles to `j _start`, and
`k1.dtb` still decompiles to the K1 topology (PLIC not AIA, `ndev=159`, 8 harts,
`spacemit,k1-x-sdhci`, `reg-shift=2`, GPU disabled). Both header checks are
negative-controlled — sabotaging the magic or the offset flips them to FAIL.

### 1.2 Build the card image

```sh
cd /home/gburd/ws/solnix/src/riscv/uts
nix shell 'nixpkgs#util-linux' 'nixpkgs#dosfstools' 'nixpkgs#mtools' \
  -c bash ./mk-k1-sdcard.sh
```

Produces `src/riscv/uts/solnix-k1-sd.img` (65 MiB): MBR, one FAT32 partition
(type `0c`) at LBA 2048, label `SOLNIX`, containing exactly `unix-k1.Image` and
`k1.dtb`.

The script refuses to build from a missing kernel, and refuses one whose magic at
`0x38` is not `0x05435352` — both refusals tested (feeding it `unix-k1.elf`
produces `magic@0x38=00400003` and no image file).

### 1.3 The card has NO first-stage loader, on purpose

There is no FSBL and no FIP on this card. That is the safety property, not an
omission:

* We do not have the SpaceMiT blobs, and writing **zeroed** firmware at the
  BootROM's offsets is worse than writing none — it invites the BootROM to read
  a garbage first stage instead of falling through to eMMC.
* The eMMC vendor chain (BootROM → FSBL → OpenSBI → U-Boot) is the known-good
  boot path and the only easy way back. It stays **untouched**.

The card is somewhere for the *vendor's* U-Boot to read two files from. Pull it
out and the board behaves exactly as before.

> `build-k1-image.sh` is a different thing — a full GPT layout with FSBL/FIP
> *placeholders*, for an eventual self-booting card. **Do not use it for a first
> bring-up**; it is the one path that can leave the board not booting.

**[UNVERIFIED-until-hardware]** that the BootROM, finding no valid FSBL on this
card, falls through to eMMC rather than stopping. It is the safe direction —
nothing of ours is in the boot chain — but it has not been observed.

### 1.4 Write it

```sh
lsblk                      # IDENTIFY THE CARD. Confirm the size matches.
sudo dd if=/home/gburd/ws/solnix/src/riscv/uts/solnix-k1-sd.img \
        of=/dev/sdX bs=4M conv=fsync status=progress
```

`/dev/sdX` is the **whole card** (`sdb`, not `sdb1`). Writing to the wrong device
destroys that disk — `lsblk` first, every time.

Alternative, if a vendor microSD already exists: skip `dd` entirely and copy
`unix-k1.Image` + `k1.dtb` into that card's existing boot partition. You keep a
bootable card and gain our kernel.

---

## 2. The boot procedure

Prerequisite: the serial console is **proven** by watching the *vendor* firmware
print (runbook section 2). Never debug our kernel on an unproven console.

Insert the card, power on, interrupt autoboot to reach `=>`. Then — **nothing is
written to any storage, this is pure RAM**:

```
=> mmc list
=> mmc dev 1                      # find the microSD; try 0 and 1
=> fatls mmc 1:1                  # MUST list unix-k1.Image and k1.dtb
=> fatload mmc 1:1 0x02000000 unix-k1.Image
=> fatload mmc 1:1 0x08000000 k1.dtb
=> booti 0x02000000 - 0x08000000
```

If our DTB gets nowhere, try the firmware's own fixed-up devicetree — the vendor
DTB has the *real* memory size and the pinmux the running firmware actually
configured, whereas ours is a hand-written subset:

```
=> booti 0x02000000 - ${fdtcontroladdr}
```

**Which of the two works is itself a finding. Record it.**

### 2.1 Where every number comes from — measured vs assumed

| Number | Value | Status | Derivation |
|---|---|---|---|
| kernel load / `booti` address | `0x02000000` | **measured** | `KBASE` in `build-k1-payload.sh`; the build asserts the Image header's `text_offset` equals it. Verified this build: `text_offset=0x0000000002000000` |
| DRAM base | `0x0` | **measured (from source, not silicon)** | `k1.dts` `memory@0` `reg = <0x0 0x0 0x0 0x80000000>`; mainline U-Boot `include/configs/bananapi-f3.h` `CFG_SYS_SDRAM_BASE = 0x0` |
| why `0x02000000` specifically | — | **measured** | clears everything mainline U-Boot puts in low DRAM, per `configs/bananapi-f3_defconfig`: vendor OpenSBI at `0x0`, U-Boot at `0x00200000`, SPL stack at `0x01000000` + 16 MiB malloc |
| DTB load address | `0x08000000` | **derived, with a real constraint** | must be 8-byte aligned, clear of the kernel, and **below `0x40000000`** — `hat_riscv.c` maps one identity gigapage over the kernel, so `hat_phys_ram_limit()` is `0x40000000` and a DTB above that is unreadable after paging. `0x08000000` (128 MiB) satisfies all three with the kernel image ending at ~`0x0209...` |
| `booti`, not `bootm`/`go` | — | **measured** | U-Boot `arch/riscv/lib/bootm.c` calls `kernel(gd->arch.boot_hart, images->ft_addr)`, which is the `(a0=hartid, a1=dtb)` ABI `locore.S` expects |
| the `-` placeholder | — | **measured** | required "no initrd" argument; omit it and U-Boot reads the DTB as a ramdisk |
| relocation is a no-op | — | **measured** | `arch/riscv/lib/image.c` relocates to `gd->ram_base + text_offset`; on the K1 `gd->ram_base = 0x0`, so `0x0 + 0x02000000` sends it right back |
| `mmc dev` number | `1` (try `0` too) | **ASSUMED** | not knowable from this repo. The K1 has three SDHCI controllers (`0xd4280000` eMMC, `0xd4280800`, `0xd4281000` SD). `mmc list` on the board is the only authority |
| the vendor U-Boot's actual low-DRAM layout | — | **ASSUMED** | derived from **mainline** `bananapi-f3_defconfig`. The vendor (Bianbu) build is a different binary. If section 4's "kernel never started" row fires, this is the first suspect — rebuild with `KBASE=0x04000000 ./build-k1-payload.sh`, one variable, no code change |
| DRAM size | 2 GiB modelled | **ASSUMED** | `k1.dts` models 2 GiB; the Jupiter ships 4/8/16 GiB. Informational, not fatal: the kernel reads the live `/memory` node |

### 2.2 Only after it prints: make it repeatable

Do not automate a boot you have not seen succeed.

```
=> setenv solnix 'fatload mmc 1:1 0x02000000 unix-k1.Image; fatload mmc 1:1 0x08000000 k1.dtb; booti 0x02000000 - 0x08000000'
=> saveenv
=> run solnix
```

Undo with `env default -a; saveenv`. This writes the U-Boot *environment*, not
any filesystem.

---

## 3. What selects the console UART — and the x86_64 lesson, applied

The X1 Carbon's keyboard was dead through five hypotheses' worth of
investigation because the loader set `console` but not **`os_console`**. The
transferable lesson: **console input and output are configured separately, and a
silent console is indistinguishable from a hang.**

That exact bug shape was **found on this code path and fixed as part of this
work.** Here is the full answer to "what selects the console UART".

### 3.1 There are THREE console selections, not one

| # | Selector | Chosen by | Used for |
|---|---|---|---|
| 1 | vendor U-Boot's console | `stdout-path` in the *vendor* DTB + its own defconfig | U-Boot's own `=>` prompt |
| 2 | **OpenSBI's** console | the *vendor* firmware, in M-mode, before we exist | **all our kernel messages**, via SBI legacy putchar (EID `0x01`) |
| 3 | our kernel's own UART base | `fdt_k1_summary()` on the DTB in `a1` → `uart_config()` | console **input** (`read(fd=0)` → `uart_getc`) and `uart_putc` |

Every banner line comes out of **#2**, the firmware's own UART driver. So if
vendor U-Boot printed, our output path works — the console is the *least* likely
thing to fail for output. `uart.c` is not on the banner path.

Console **input** comes out of **#3**, configured completely separately. That is
the `console`/`os_console` split, reproduced exactly.

### 3.2 Is there a path where output works but input does not? YES — there was.

`startup.c` called the console self-test with a **hardcoded compile-time
address** — `UART0_BASE`, i.e. `0x10000000`, the *qemu-virt* ns16550 — on both
platforms, and `uart.c` then rebound the console back to that same constant.

On the K1, `0x10000000` is **not a UART**: bank-0 DRAM is `0x0..0x80000000`
(`k1.dts` `memory@0`) and the real console UART is at `0xd4017000` (`k1.dts`
`serial@d4017000`). So `0x10000000` is ordinary RAM. Freshly trained DRAM reads
`0x00`, so `LSR.THRE` (bit 5) never sets, and

```c
while ((uart_rd(UART_LSR) & LSR_THRE) == 0)   /* uart.c */
        __asm__ __volatile__("nop");
```

**spins forever.** Predicted symptom: the kernel prints its banner and roughly
thirty lines, then hangs at the console-bind line. Console input was dead by the
same mechanism (`uart_getc` polling bit 0 of the same DRAM byte), and
`uart_wr(THR)` also *stored* into RAM that `page_init` later manages.

Output was unaffected, because output goes through **#2**. Output fine, input
dead, configured independently — the same bug, on a different architecture, two
years later.

**Why no QEMU gate could ever have caught it:** on `-machine virt`, `0x10000000`
**is** a real ns16550. THRE is set, the self-test passes, and all seven gates go
green while proving nothing about metal. This is the **ninth** documented
QEMU-vs-hardware divergence on this project.

### 3.3 Can the kernel pick a different UART than U-Boot? Not any more.

The fix makes the base come from the **live boot DTB** the firmware hands us in
`a1`, never from a constant:

* `startup.c` passes `boot.uart_base` / `boot.uart_shift` / `boot.uart_io32`.
* `uart.c`'s self-test no longer rebinds to `UART0_BASE`, refuses to bind to
  base 0, and issues **no MMIO at all** unless the base was firmware-confirmed —
  because a TX to a non-UART is not a failed test, it is an infinite spin.
* `fdt.c` now also reads `reg-io-width` (it selects 8- vs 32-bit MMIO; the K1
  needs 32-bit on a 4-byte stride, `reg-shift=2`).

Two residual ways they can still disagree, both now **loud instead of silent**:

1. **The vendor DTB spells the UART differently** than
   `ns16550_uart_compat[]` expects (`ns16550a`, `ns16550`, `snps,dw-apb-uart`,
   `spacemit,pxa-uart`, `spacemit,k1-uart`, `intel,xscale-uart`). Then the walk
   finds no console UART and prints
   `[dw-apb-uart] boot DTB named no 16550-family console UART; console input unavailable`.
   Kernel messages keep working (path #2). Fix is one string in that table —
   send back the `k1-dtb: parsed ...` line.
2. **OpenSBI's console is a different UART than the DTB's `serial0`.** Then
   output goes to one port and input is read from another. Both would be
   physically real, so nothing hangs; symptom is "it prints but ignores typing".
   Only a board can tell us. Our `[dw-apb-uart] console bound @...` line prints
   the address we chose, so the log makes the comparison possible.

### 3.4 Reachability after paging — checked

`0xd4017000` is above the low-MMIO identity gigapage (`0x0..0x40000000`), so it
would fault after `satp` is loaded were it not explicitly mapped.
`hat_riscv.c` installs `K1_DEV_GIGA` — an identity gigapage over
`0xc0000000..0x100000000` — which covers the UART, all three SDHCI controllers,
the PLIC (`0xe0000000`) and the CLINT (`0xe4000000`). The boot log line
`k1-mmio: mapped ... readback OK` is that check.

### 3.5 The second bug, found by the negative control

Writing the precondition check (section 6) turned up a second bug of the same
family. `fdt_k1_summary()` stored a node's `reg` **only while a
compatible-based classification was already live** — it assumed `compatible`
precedes `reg`. DTB property order is not guaranteed, and the two producers
disagree:

```
our k1.dts    : compatible, reg, reg-shift, ...   (compatible FIRST)
qemu -M virt  : interrupts, ..., reg, compatible  (compatible LAST)
```

So on the **qemu-virt boot DTB** the ns16550a's `reg` arrived before its
`compatible` and was silently dropped: `uart_base` parsed as **0**. Observed
directly in the boot log, before and after:

```
before:  dw-apb-uart@0x0000000000000000  (reg-shift=0)
after:   dw-apb-uart@0x0000000010000000  (reg-shift=0)
```

Same failure as bug 1 — a value that looks present and is not. `fdt.c` now
latches `reg`/`reg-shift`/`reg-io-width` and the classification independently
and joins them at `FDT_END_NODE`, so it is order-independent by construction.

---

## 4. Expectation table

Three-way split. **The first thing that should appear** after the `booti` line is
U-Boot's own FDT acknowledgement, then our very first kernel line:

```
## Flattened Device Tree blob at 08000000
   Booting using the fdt blob at 0x8000000
Moving Image from 0x2000000 to 0x2000000, end=0x28f6080     <- may or may not appear

[mlsetup] riscv64 machine-dependent bring-up (R-P4)         <- FIRST solnix output
```

`[mlsetup] riscv64 ...` **is the win.** It means OpenSBI handed control to
`_start`, the Image header was accepted, the kernel was at the right address, and
the console works. Everything after it is bonus.

### Row A — got past the console bind (the fix working)

| Observation | Meaning |
|---|---|
| `[dw-apb-uart] bind console @0x00000000d4017000 reg-shift=2 io-width=4(32b) [from boot DTB]` | **The fix is working on silicon.** The base came from the vendor DTB and is the real K1 UART |
| `[dw-apb-uart] console TX/RX on uart (8250, reg-shift=2): LSR.THRE live @0xd4017014` | our own UART driver drove real K1 registers — first ever live drive |
| `[board] runtime detect: boot DTB IS SpaceMiT K1 -> live MMIO (physical board)` | board detection works. **Must say `IS`.** If it says `NOT K1` on the K1, the vendor DTB spells UART or MMC differently — send the `k1-dtb: parsed ...` line, fix is one string |
| `[startup] clamping managed RAM to the boot identity gigapage end 0x40000000` | **expected and benign** — the documented 1 GiB ceiling, means the guard worked |
| lines continue past `[sdhci]` | further than any prediction; capture everything |

### Row B — banner, then a stop (still a win: "it prints" achieved)

Record **exactly** where it stopped; the last line names the subsystem.

| Last line | Implicates |
|---|---|
| `[dw-apb-uart] bind console @0x0000000010000000` | **the bug this work fixed.** You are running a stale `unix-k1.Image` — rebuild (1.1). On the K1 that address is DRAM and the next instruction spins forever |
| `[mlsetup] trap vector installed` | Sv39 boot map — identity gigapages vs the K1's real layout |
| `[hat] Sv39 boot map built` | first post-paging access; a mapping is missing |
| `[smp] boot hart ... starting secondaries` | SBI HSM `hart_start` on 8 real harts (QEMU only ever ran 4) |
| `[plic] self-test` | PLIC at `0xe0000000`, `ndev=159` — first live test |
| `[clock] starting periodic clock` | timebase mismatch: K1 arch timer is **24 MHz**, QEMU's 10 MHz |
| `[startup] startup_memlist` | the `/memory` extent or the boot-allocator clamp |
| `[sdhci]` | live SDHCI MMIO at `0xd4281000` — first genuinely untested driver |
| garbage/mojibake mid-line | baud mismatch (console is 115200 8N1), or a wrong `reg-shift` |
| register dump (`sepc`/`scause`/`stval`) | **capture verbatim, all three.** `riscv64-none-elf-addr2line -e unix-k1.elf <sepc>` names the line |

### Row C — nothing at all (the row you will actually be staring at)

**Do section 5 first.** An empty console has three unrelated causes and they are
indistinguishable by looking.

| Check, in order | If it fails |
|---|---|
| Did the **vendor** firmware print in this same session? | **No → your console is wrong, not our kernel.** Section 5. Do not touch the kernel |
| Did you watch for **several minutes** with a timestamped log? | An aarch64 "stall" on this project was a reset loop with an ~8–10 minute period, recorded from a 27-second read. Four agents inherited the wrong phenomenon. State how long you watched |
| `Bad Linux RISCV Image magic!` | You loaded `unix-k1.elf` instead of `unix-k1.Image`, or the file is corrupt. `mk-k1-sdcard.sh` checks this, so a card built by it cannot have this problem |
| Did U-Boot print `Moving Image from ... to ...`, and to **where**? | A different destination means our `text_offset` assumption is wrong on the vendor build |
| Retry with `KBASE=0x04000000 ./build-k1-payload.sh` | If this fixes it, the vendor U-Boot's low-DRAM layout differs from mainline's — the biggest ASSUMED number in section 2.1 |
| Retry with `booti 0x02000000 - ${fdtcontroladdr}` | If ours dies and the vendor DTB works, our `k1.dtb` describes memory the board does not have, and early setup died before printing |
| Did you use `go` instead of `booti`? | `go` passes no `a0`/`a1`; the kernel cannot work. `booti` is required |

---

## 5. Negative control: "my adapter is wrong" vs "the kernel is dead"

Both present as an empty console. This is the most important procedure in the
document, because getting it wrong sends you debugging a kernel when the problem
is a wire.

**The control: the vendor firmware is the known-good transmitter.**

Run this in **one unbroken session**, without touching the wiring in between:

```sh
mkdir -p ~/k1-logs
picocom -b 115200 --logfile ~/k1-logs/$(date +%Y%m%d-%H%M)-control.log /dev/ttyUSB0
```

1. **Card OUT.** Power-cycle the board. Watch for the vendor chain
   (`try sd...`, `U-Boot SPL`, `DRAM: N GiB`, `In: serial@d4017000`, then `=>`).
2. Only if you saw that text, **card IN**, power-cycle, interrupt autoboot, and
   run the section 2 sequence.

| Step 1 (vendor, card out) | Step 2 (ours) | Conclusion |
|---|---|---|
| prints | prints | Everything works. Read section 4 |
| **prints** | **silent** | **The console is PROVEN and the kernel is the problem.** Row C. The same adapter, wires, baud and session just carried text |
| **silent** | silent | **Your observation channel is wrong. Learn NOTHING about the kernel from this.** Fix the console first |
| silent | prints | Impossible; suspect you swapped the steps |

The discriminating power comes entirely from **not changing anything between the
two steps.** If you re-plug, re-seat, or restart picocom between them, you have
two experiments instead of one control, and the comparison is void — that is the
"ask what a comparison actually compares" failure that made an earlier A/B on
this project meaningless (it ran different drivers).

**If step 1 is silent, in this order** (from the runbook, unchanged):

- TX/RX swapped — the single most common cause. Swap **only** those two wires.
- GND not connected. Connect it first, always.
- **Do NOT connect the adapter's VCC/3V3.** Back-feeding is how boards die.
- Wrong pin/header — the repo knows the SoC pads (68/69, function 2) but **not**
  which physical header pin the Jupiter routes them to. Read the vendor doc, not
  this file.
- Baud not 115200; **flow control not disabled.** Hardware flow control on a
  3-wire cable gives exactly "opens fine, prints nothing".
- Adapter not enumerated: `ls /dev/ttyUSB* /dev/ttyACM*`, `dmesg | tail`.
- Not in `dialout`/`uucp`.
- Use a **3.3 V** adapter (CP2102, CH340, FT232 in 3V3 mode). A 5 V one can
  damage the SoC pads.
- Try USB-C first: if plugging it into your workstation makes a `/dev/ttyUSB*`
  or `/dev/ttyACM*` appear, some K1 boards expose the console there via an
  on-board bridge and you need no adapter at all.

**A second control worth ten minutes:** loop the adapter's own TX to its own RX
(one jumper, board disconnected), open picocom, and type. Characters echo → the
adapter, cable, driver, permissions and baud are all good, so a subsequent
silence is the board or the wiring to it. Characters do not echo → the adapter
is the problem and the board was never involved. This isolates the adapter
without the board present at all.

---

## 6. What was verified locally, and what that is worth

All local, no cost, `qemu-system-riscv64` + `pkgsCross.riscv64-embedded.gcc14`.

| Check | Result |
|---|---|
| `build-k1-payload.sh` | **PASS** — magic `05435352`, `text_offset==KBASE`, `j _start`, 7/7 DTB topology checks |
| `build-scanout.sh` (full boot + framebuffer screendump) | **PASS** — no regression from the fix |
| `console-bind-check.py` | **PASS 4/4**, and **8/8 over 8 runs** |
| `console-bind-check.py --sabotage` | **FAIL 2/4 as required**, **8/8 runs**, control not vacuous |
| `mk-k1-sdcard.sh` fed `unix-k1.elf` | **refused** (`magic@0x38=00400003`), no image written |
| `mk-k1-sdcard.sh` fed a missing file | **refused** with the rebuild recipe, no image written |

`console-bind-check.py` checks the **precondition**, not the hang — the technique
this project used for hart-slot aliasing, `callout_lock` SIE and the `_CRS` scan.
The hang is **unreproducible in QEMU by construction** (there, `0x10000000` *is* a
UART), so a test that tried to trigger it would be a test that cannot fail. The
precondition is a static fact per boot: does the bound console base come from the
live DTB? Checked in **both** directions — K1 DTB must yield `0xd4017000`,
qemu-virt's own DTB must yield `0x10000000` — because a kernel that hardcodes
either address passes one direction and fails the other. That is exactly how the
original bug hid.

Both arms were run 8 times (this project's flakiness is **bursty**, so a 4-run
sample can honestly report 25% inside a burst and 100% outside). Both were
deterministic, 8/8, no clustering.

### What the QEMU passes do NOT prove

**A QEMU pass here is necessary but nowhere near sufficient.** `-machine virt` is
a different platform: DRAM at `0x80000000` not `0x0`, an `ns16550a` at
`0x10000000` not a 32-bit-register SpaceMiT UART at `0xd4017000`, QEMU's OpenSBI
instead of the vendor's, 4 harts instead of 8, a 10 MHz timebase instead of
24 MHz, and no FSBL or DDR training at all.

QEMU is **systematically more permissive** than this hardware, with **nine**
documented divergences on this project — an emulated NVMe that panics illumos
while real NVMe works; a QEMU `ttya` that made "installed disk boots alone"
meaningless on a serial-less laptop; and now the console-base bug in section 3.2,
which passed all seven gates 8/8 while being fatal on metal. That last one was
found by *reading the K1 memory map against the code*, not by any amount of
emulation.

Treat every green check above as "the file is not obviously broken." **Nothing
here is evidence the board boots.**

---

## 7. What to capture and send back

The console log **is** the artifact.

```
~/k1-logs/<date>-control.log   the section 5 control: vendor boot, card OUT
~/k1-logs/<date>-solnix.log    every attempt, successes AND silences
```

1. The complete vendor boot: `try sd...` through `=>`, with the SPL line, `DRAM:
   N GiB`, and `In:/Out:/Err:`.
2. **Every** solnix attempt verbatim, including the silent ones, **with the exact
   `fatload`/`booti` commands used.** "Nothing at all" is data only if the
   command that produced it is recorded.
3. The `[dw-apb-uart] bind console @...` line — **the single most informative
   line in this boot.** It says which UART we chose and where we got it.
4. `[board] runtime detect:` and the `k1-dtb: parsed ...` line above it.
5. Which DTB worked: ours or `${fdtcontroladdr}`.
6. Any fault text complete — `sepc`, `scause`, `stval` are the whole diagnosis; a
   paraphrase is not usable.
7. The board's DRAM size as U-Boot reported it, and `mmc list` output.
8. **How long you watched**, and whether the log was timestamped.

If a **new** blocker appears: capture its exact text and **stop**. One fix
reveals the next; a precisely-named next blocker beats a half-attempted second
repair.

---

## 8. What you can learn without the UART adapter

Honestly: **almost nothing about our kernel.** Section 0 explains why. These are
worth doing because they are preparation and they are free — none is a boot
attempt.

| Action | What it tells you | Worth it? |
|---|---|---|
| Try **USB-C** for a console: `ls /dev/ttyUSB* /dev/ttyACM*` before and after plugging in | Some K1 boards bridge the debug console to USB-C. **If a device appears, you already have a console and need no adapter** | **Do this first.** Highest value per minute in the whole document |
| Boot the **stock vendor OS** and log in over HDMI+USB keyboard, or over the network | Board health, DRAM size, `dmesg`, and the pinout via `/sys/firmware/devicetree` — reading the vendor's *own* DTB tells you exactly what U-Boot passes in `a1`, which is what section 3.3 hinges on | **High.** Answers real questions with no adapter |
| From the vendor OS, check `/proc/device-tree/chosen/stdout-path` and the `serial@d4017000` node's `compatible` | Whether the vendor spells the UART the way `ns16550_uart_compat[]` expects. This is the "boot DTB named no 16550-family UART" risk, resolvable **before** the adapter arrives | **High** |
| Plug in HDMI, boot vendor U-Boot, run `dm tree` / `bdinfo` / `video list` | Whether U-Boot leaves a live framebuffer — the single measurement that decides **3–5 days vs 2–3 weeks** for pixels on HDMI. Needs a console to *read*, but a **splash screen or U-Boot text on the monitor** is visible without one | **Medium** — the visual half works adapter-free |
| Write the card (section 1) | Nothing about the board, but it is ready and harmless | Low, do it whenever |
| **Attempt the boot** | **Nothing. Zero information.** Success and total failure are identical: dark HDMI either way (we never touch the display), identical Ethernet LEDs (we never bring up the MAC), untouched eMMC either way (by design), no LED we toggle, no network we can reach | **No. Wait for the adapter** |

Explicitly: **there is no LED, HDMI, or network signal that distinguishes a
working boot from a dead one.** Every one of those channels requires a driver
this kernel does not have on the boot path. The eMMC being untouched is a safety
property, not an observation — it is untouched whether we boot or fault.

Buy a 3.3 V USB-to-UART adapter (CP2102, CH340, or FT232 in 3V3 mode). It is the
whole instrument.

---

## 9. Getting back to a working board

* **Our kernel hangs?** Power-cycle. Nothing was written; nothing changed.
* **Card boots instead of eMMC and you want eMMC back?** Remove the card.
* **U-Boot environment confused?** `env default -a; saveenv`.
* **Nothing works at all?** The eMMC vendor image is untouched by every step in
  this document. Remove the microSD and power-cycle.

The one operation that can leave the board not booting — writing
`fw_payload.bin`, which replaces vendor M-mode firmware — is **not in this
document** and must not be attempted in a first sitting. See the runbook's
section 4.4.
