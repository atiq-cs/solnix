# First observable boot on the SpacemiT K3 Pico ITX — runbook

The maintainer now has a USB-to-UART adapter, so a boot attempt finally produces
evidence. This is the procedure, what to expect, and — most importantly — how to
tell a dead kernel from a miswired adapter, because both look like an empty
screen.

**Nothing here has executed on this SoC.** Everything below is either MEASURED
from the board's own devicetree (`/tmp/dts`, dumped from the running vendor
Linux) or CHOSEN with the reasoning stated. Each number says which it is.

---

## 0. The headline: this board does not boot from SD, and that is good news

The K1 flow shipped a flashable microSD image. **This board has no SD boot path
at all**, and the vendor devicetree says so unambiguously:

| measured fact | value | source |
|---|---|---|
| `mmc@d4280000` | `status = "disabled"` | `/tmp/dts` |
| `mmc@d4280800` | `status = "disabled"` | `/tmp/dts` |
| `mmc@d4281000` | `status = "disabled"` | `/tmp/dts` |
| boot mode | `boot_mode=nor` | `/chosen/bootargs` |
| boot chain location | `mtdparts=d420c000.spi:128K@0(bootinfo),512K@128K(fsbl),64K@640K(env),1M@704K(esos),384K@1728K(opensbi),-@2112K(uboot)` | `/chosen/bootargs` |
| root device | `ufshc@0xc0e00000` `"spacemit,k3-ufshcd"` `status = "okay"` | `/tmp/dts` |
| block devices | `sda` 119.3 G (sda2 = `/boot`, sda3 = `/`) + 7 `mtdblock` | `lsblk` |

All three SD/MMC controllers are off, the bootloader chain lives in SPI NOR, and
the disk is UFS. The six `mtdparts` partitions account for the seven `mtdblock`
devices. **An SD image would be a file that cannot boot**, and this repo's own
rule is that a stale flashable image is worse than none.

So the vehicle is different, and *safer*: copy the kernel into the `/boot`
partition the board's own Linux already mounts, interrupt U-Boot, and `booti`.

**This touches nothing in SPI NOR.** The BootROM → FSBL → OpenSBI → U-Boot chain
is untouched, so recovery from any failure is a power cycle. There is no way for
a failed attempt here to leave the board unbootable. (Note this also removes the
recoverability argument that justified SD in the first place.)

---

## 1. Build the artifacts

```sh
cd src/riscv/uts
export PATH=/nix/store/lpr142m8h1737a0h7hpm2r72bq1pbqj0-riscv64-none-elf-gcc-wrapper-14.3.0/bin:$PATH
export PATH=/nix/store/9j7l8hipdhzrfylifvhgyqdydgvwv2i6-dtc-1.7.2/bin:$PATH
bash build-k3-payload.sh
```

Expect `K3 PAYLOAD BUILD PASS` and two artifacts:

| artifact | what | size |
|---|---|---|
| `src/riscv/uts/unix-k3.Image` | kernel + Linux RISC-V Image header, linked `0x102200000` | ~625 KB |
| `src/riscv/uts/k3.dtb` | devicetree generated from the board's own dump | ~6 KB |

Named `unix-k3.*` deliberately: it is **not** interchangeable with
`unix-k1.Image`, which is linked at a different address. Both are gitignored on
purpose — the recipe is the deliverable, not the binary.

`k3.dtb` comes from `gen-k3-dts.py`, which **generates** `k3.dts` from
`/tmp/dts` rather than hand-editing `k1.dts`. It asserts on 16 contiguous sv39
harts, a memory node, an APLIC, and the console UART at `0xd4017000` with
reg-shift 2, and refuses to write a file if the dump disagrees. Re-dump the
board and regenerate any time the firmware changes:

```sh
# on the board
sudo dtc -I fs -O dts /proc/device-tree > /tmp/dts
# on the dev box
python3 gen-k3-dts.py /tmp/dts k3.dts
```

---

## 2. The two addresses

| name | value | measured or chosen |
|---|---|---|
| DRAM base | `0x102000000` | **MEASURED** — `memory@102000000`, `reg = <0x01 0x2000000 0x07 0xfe000000>` |
| DRAM size | `0x7fe000000` = 32.0 GiB, ending `0x900000000` | **MEASURED** |
| `KDRAM_BASE` | `0x102000000` | **MEASURED** (= DRAM base) |
| `KBASE` (link address) | `0x102200000` | **CHOSEN** = DRAM base + 2 MiB |
| `text_offset` in the Image header | `0x200000` | **DERIVED** = `KBASE - KDRAM_BASE` |
| timebase | 24,000,000 Hz | **MEASURED** — `/cpus/timebase-frequency = <0x16e3600>` |
| console | `serial@d4017000`, 115200 | **MEASURED** — `serial0` alias + `stdout-path` |
| harts | 16, `cpu@0`..`cpu@15`, all sv39 | **MEASURED** |
| external intc | APLIC `0xe0804000` + IMSIC `0xe0400000` | **MEASURED** |
| U-Boot version | 2022.10 | **MEASURED** — `/chosen/u-boot,version` |

### Why `KBASE = 0x102200000`

DRAM base + 2 MiB. Four reasons, in order of how much they constrain:

1. **It must be inside DRAM.** There is no memory below `0x102000000` on this
   board. Our previous link address `0x80200000` — correct for qemu-virt *and*
   for the K1 — is a hole here, so a kernel linked there loads into nothing and
   executes no instruction. Note `0x102000000` is **32 MiB above** the 4 GiB
   line, not 4 GiB exactly, so a naive "link at `0x100000000`" also lands
   outside DRAM.
2. **2 MiB of clearance for firmware.** This mirrors OpenSBI's own payload
   convention (its default payload offset is +2 MiB over the firmware base) —
   the same clearance qemu-virt and the K1 paths use.
3. **2 MiB alignment**, for the Sv39 megapage granularity and because U-Boot's
   `booti` relocation assumes the kernel is aligned.
4. It keeps the kernel inside **one** Sv39 gigapage starting at `0x100000000`,
   which is what `hat_boot_init` maps identity over the kernel.

This is a **knob, not a discovery**. If the board's U-Boot turns out to keep
something in `0x102000000..0x102200000`, raise it — stay 2 MiB aligned and
inside DRAM. That is one env var, not a code change:

```sh
KBASE=0x102400000 bash build-k3-payload.sh
```

### ⚠️ The `text_offset` bug this exposed

U-Boot's `booti_setup()` (arch/riscv/lib/image.c) relocates the image to
`gd->ram_base + text_offset`. `riscv.ld` emitted `text_offset = BASE`, i.e. the
**absolute** link address. That is correct *only* while `gd->ram_base` is 0 —
which it is on qemu-virt and on the K1, so the bug was invisible and stayed
invisible through 8/8 gate passes.

On this board `gd->ram_base` is `0x102000000`, so an absolute `text_offset` of
`0x102200000` would have relocated the image to **`0x204200000`** — about 4 GiB
past where it was linked, with every absolute address in it wrong.

Fixed: `riscv.ld` computes `TEXT_OFFSET = BASE - DRAM_BASE`, with `DRAM_BASE`
from a new `--defsym KDRAM_BASE=` that **defaults to 0**, so the qemu and K1
links are byte-identical. `build-k3-payload.sh` verifies the arithmetic U-Boot
will actually perform:

```
OK   text_offset=0x200000 == KBASE-KDRAM_BASE
OK   gd->ram_base + text_offset = 0x102200000 == KBASE
OK   KBASE 0x102200000 is inside DRAM [0x102000000, 0x900000000)
```

Worth noting how this happened: `image_header.S` **already documented** the
assumption it rested on — "text_offset must equal the address riscv.ld linked
the image at ... and K1's `gd->ram_base` is `0x0`". The comment was correct and
the code was correct, *for the K1*. The premise silently stopped holding when a
second board appeared. Same shape as `riscv.ld`'s DRAM comment, which asserted
K1 DRAM at `0x0..0x80000000` — true of the K1, false here. Both comments are now
fixed, because a stale comment asserting the opposite of measured reality is how
the next person loses a day.

---

## 3. Wire the adapter — and prove the wiring BEFORE our kernel is involved

**Do this step first. Do not skip it because it seems obvious.** An empty serial
console is indistinguishable between "adapter or wiring wrong" and "kernel
dead", and an unattributable empty console is what cost this project the
aarch64 "ZFS scan stall" investigation.

Console parameters (all MEASURED from `/chosen/stdout-path = "serial0:115200"`
and the `serial0` alias):

| setting | value |
|---|---|
| device | `/soc/serial@d4017000` |
| baud | 115200 |
| data / parity / stop | 8N1 |
| flow control | none |

Wiring: adapter **GND** to board GND, adapter **RX** to board **TX**, adapter
**TX** to board **RX**. Do **not** connect the adapter's VCC. TX/RX crossed is
the single most common mistake and presents as a completely silent console.

```sh
# on the dev box, adapter plugged in
ls -l /dev/ttyUSB* /dev/ttyACM*
picocom -b 115200 /dev/ttyUSB0        # or: screen /dev/ttyUSB0 115200
```

### THE INSTRUMENT NEGATIVE CONTROL

Now **power-cycle the board with the vendor firmware untouched** and watch. The
vendor chain is in SPI NOR and boots to Linux 6.18.3 on its own; you have
changed nothing yet. You should see, in order:

| what appears | what it proves |
|---|---|
| SpacemiT FSBL / DDR-training chatter | the adapter, wiring, baud and ground are all correct |
| `OpenSBI v...` banner with `Platform Name`, `Boot HART ID` | M-mode firmware is talking on this UART |
| `U-Boot 2022.10` (version MEASURED from `/chosen/u-boot,version`) | you have reached the stage that will run our `booti` |
| `Hit any key to stop autoboot:` countdown | the interrupt point exists and you know its wording |
| Linux boot messages, then a login prompt | the whole vendor chain is healthy |

**If you see NOTHING here, the problem is the instrument, not solnix.** Fix the
wiring before going further:

* swap adapter TX and RX (by far the most likely);
* confirm 115200 8N1 and no flow control;
* confirm a common ground;
* loopback-test the adapter alone — short its own TX to RX, type in the
  terminal, and confirm your keystrokes echo. If they do not, the adapter or its
  driver is at fault and the board is irrelevant.

Only once you have seen vendor output on this exact cable at this exact baud is
an empty console attributable to our kernel. **Write down what the autoboot
interrupt prompt actually says** — you need it in the next step.

---

## 4. Copy the artifacts onto the board

The board runs a healthy Linux with `/boot` already mounted (sda2, 256 MB, and
it is the partition the vendor U-Boot loads from). Copy over the network:

```sh
# from the dev box
scp src/riscv/uts/unix-k3.Image src/riscv/uts/k3.dtb gburd@milkv:/tmp/
# on the board
sudo cp /tmp/unix-k3.Image /tmp/k3.dtb /boot/
sync
ls -l /boot/unix-k3.Image /boot/k3.dtb
```

Nothing else changes. The vendor kernel, its DTB, `/boot`'s existing contents,
the U-Boot environment in NOR: all untouched. **Do not edit the U-Boot
environment**; everything below is typed at the interactive prompt so a power
cycle restores normal boot.

---

## 5. Interrupt U-Boot and boot our kernel

1. With the serial console open, power-cycle the board.
2. Watch for the autoboot countdown — the prompt you wrote down in step 3, most
   commonly `Hit any key to stop autoboot:` counting down from 1–3 seconds.
   **Press a key immediately** (spacebar is fine). The window is short; it is
   normal to miss it and need another power cycle. Holding a key down from the
   moment you power on also works.
3. You should get a `=>` prompt. Confirm U-Boot can see the partition:

```
=> ls mmc 0:2
```

⚠️ **`mmc` is very likely wrong on this board** — the SD/MMC controllers are all
disabled and the disk is UFS, so the vendor U-Boot uses some other interface for
`/boot`. Discover it rather than guessing:

```
=> printenv bootcmd
=> printenv bootargs
```

`bootcmd` is the vendor's own working recipe for loading from `/boot` — it names
the exact interface and partition, and it is the authority here. Whatever device
argument it uses (`scsi 0:2`, `ufs 0:2`, `nvme 0:2`, `mmc 0:2` …), use the same
one below. `printenv` only reads; it changes nothing.

4. Load and boot, substituting the device argument from `bootcmd`:

```
=> setenv kaddr 0x102200000
=> setenv fdtaddr 0x110000000
=> load scsi 0:2 ${kaddr} unix-k3.Image
=> load scsi 0:2 ${fdtaddr} k3.dtb
=> booti ${kaddr} - ${fdtaddr}
```

| address | value | measured or chosen |
|---|---|---|
| `kaddr` | `0x102200000` | **DERIVED** — must equal `KBASE`; `booti` relocates to `gd->ram_base + text_offset` = this |
| `fdtaddr` | `0x110000000` | **CHOSEN** — 224 MiB above the kernel: clear of the kernel's ~9.5 MB image+BSS, 2 MiB aligned, inside the 32 GiB bank |
| the `-` | required | no-initrd placeholder; `booti <kernel> - <dtb>` gives `a0=hartid, a1=dtb`, which is exactly the ABI `locore.S` expects |

`booti` will refuse an image whose magic at offset 0x38 is not `0x05435352`
("Bad Linux RISCV Image magic!"). Ours has it — `build-k3-payload.sh` verifies
that, `code0 = j _start`, and the `text_offset` arithmetic before you ever get
here.

To restore normal boot: `reset`, or just power-cycle and let autoboot run.

---

## 6. Expectation table — what should appear, and what each outcome means

The kernel's console output goes through **SBI** (`sbi_console_putchar`, DBCN
with a legacy-putchar fallback), *not* through our own UART driver. So the first
lines depend only on vendor OpenSBI being alive and our kernel executing — the
UART driver binding later is a separate, later question.

**The first thing that should appear after `booti`, in order:**

| # | expected output | what it proves |
|---|---|---|
| 1 | `Moving Image from ... to 0x102200000` (or similar U-Boot relocation line) | U-Boot accepted the Image header and is relocating to the address we linked at — `text_offset` is right |
| 2 | `## Flattened Device Tree blob at 110000000` | U-Boot found `k3.dtb` and will pass it in `a1` |
| 3 | **`[mlsetup] riscv64 machine-dependent bring-up (R-P4)`** | ⭐ **THE FIRST LINE OF OURS.** The kernel is executing at the right address, and SBI console output works. This is the single most important string to watch for. |
| 4 | `[mlsetup] trap vector installed (stvec -> _trap_entry, Direct mode)` | traps are ours |
| 5 | `[hat] Sv39 boot map built:` + identity gigapage lines | paging on, satp switched, still alive |
| 6 | `[hat] ... MATCH -> high-VA translation verified` | non-identity translation works on this silicon |
| 7 | `[smp] boot hart N starting secondaries via SBI HSM` | note the value of N — see below |
| 8 | `[smp] hart K online (secondary, ...)` × up to 15 | SBI HSM brings up the other harts |
| 9 | `[mlsetup] DTB: interrupt controller is AIA (APLIC+IMSIC) -> MSI IRQ model` | **the K3-specific path** — if this says PLIC instead, the wrong DTB got loaded |
| 10 | `[mlsetup] DTB: timebase-frequency 24000000 Hz` | ⭐ the 24 MHz fix is live. **If this says 10000000, the DTB did not reach us.** |
| 11 | `[clock] starting periodic clock: hz=100 period=240000 time-ticks (10000000 ns), timebase=24000000 Hz (from DTB)` | period 240000 = 24 MHz / 100 Hz. `(from DTB)` not `(DEFAULT ...)` |
| 12 | `[clock] N ticks, hrtime=... -> periodic clock running.` | the CLINT timer actually fires on this SoC |
| 13 | `SunOS Release 5.11 Version solnix-riscv64 (first illumos on RISC-V)` | ⭐ **the banner. illumos is running on this board.** |

### Distinguishing "never started" from "started and died"

| what you see | meaning | next step |
|---|---|---|
| Vendor output through the `=>` prompt, then **nothing at all** after `booti` | **Never started.** The kernel is not executing. Since the wiring is already proven by step 3, this is a load-address or image problem. | Check U-Boot printed a relocation line and where to. Re-check `KBASE` against `bootcmd`'s expectations; try raising `KBASE` by 2 MiB in case U-Boot has something resident at `0x102200000`. |
| `Bad Linux RISCV Image magic!` | U-Boot rejected the image. | You loaded the wrong file (the ELF instead of `unix-k3.Image`), or the copy truncated. Re-copy, check the size is ~625 KB. |
| U-Boot relocation line, then nothing | Started at the wrong address, or died before the first `puts`. | The `text_offset`/`KBASE` pair is the suspect. Compare the address U-Boot reports moving to against `0x102200000` — if they differ, that is the bug and the numbers to report. |
| **`[mlsetup] riscv64 ...` appears, then output stops** | ⭐ **Started and died.** This is a real, debuggable kernel bug and much better news than silence — it means load address, `text_offset`, DTB hand-off and SBI console are all correct. | **Record the exact last line and the total line count**, then stop. Which line it stops on names the subsystem. |
| Output stops at the `[hat]` lines | paging/Sv39 problem on real silicon | Report the last `[hat]` line verbatim. |
| Output stops in `[smp]` | hart bring-up at 16 harts | Report the boot hart id from line 7 and which harts reported in. |
| `[PANIC] boot hart N is >= MAXCPU 16` | OpenSBI booted a hart we have no slot for. | Should be impossible at 16 (`cpu@0..cpu@15`), so if you see it the hart numbering is not what the DTB claims — that is a valuable finding, report N. |
| Output stops around `[clock]` | timer/CLINT | Report whether line 10 said 24000000 or 10000000. |
| Reaches the `SunOS Release` banner | ⭐⭐ first illumos boot on this SoC | Capture the entire log. |
| Garbled/mojibake characters | baud mismatch, not a kernel fault | You would have seen this in step 3 too. Confirm 115200. |

**Before concluding "hung", check how long you watched.** An observation window
shorter than the phenomenon's period sees nothing — an aarch64 "stall" was once
recorded from a 27-second read of what was really an 8–10 minute reset loop.
Watch for **at least two minutes** after the last line, and note the elapsed
time in whatever you report.

---

## 7. What was verified, and what QEMU cannot tell us

**Verified locally** (`build-k3-payload.sh`, all negative-controlled):

* the image builds and the Image header is well-formed (magic, `code0 = j
  _start`);
* `text_offset` is `KBASE - KDRAM_BASE`, so `gd->ram_base + text_offset` lands
  exactly on the link address;
* `KBASE` is inside the DRAM the board reports;
* `k3.dtb` round-trips through `dtc` still describing 16 harts, APLIC+IMSIC,
  CLINT, a 24 MHz timebase, DRAM at `0x102000000`, and the console UART with
  reg-shift 2;
* the timebase is read from the DTB at runtime (observed in QEMU: reads and
  reports qemu's real 10 MHz, and prints `(from DTB)`);
* the seven qemu gates still pass at the default `KBASE` — the default link is
  byte-identical (`text_offset = 0x80200000`, entry `0x80200040`).

Every negative control flips to FAIL when sabotaged: the absolute-`text_offset`
bug reproduces `0x204200000`; `KBASE=0x80200000` is caught as outside DRAM; the
DTB generator refuses four different sabotaged dumps and writes no file; and
`hart-slot-check.py` at `-smp 16` reports `ALIASED=4` with
`dispatch_init_cpu(0)` reinstated versus zero on the clean tree.

**⚠️ QEMU cannot validate the two things that matter most here.** Its DRAM is at
`0x80000000` and its `gd->ram_base` is 0, so it can exercise neither a >4 GiB
link base nor a nonzero-`ram_base` `text_offset`. That is *precisely* why both
bugs survived 8/8 gate passes. QEMU is used here for **absence of regression
only**. These are the **tenth and eleventh** documented QEMU-vs-metal
divergences in this port.

**Not verified, and not verifiable without the board:** that it boots. No
instruction of ours has ever executed on this SoC.

### Known pre-existing issues, deliberately not fixed here

* `[disp] thread A/B context-switch FAILED` appears intermittently under high
  `-smp`: baseline at HEAD (`MAXCPU=8`, `-smp 8`) 5/10 runs, this tree
  (`MAXCPU=16`, `-smp 16`) 4/10. Non-fatal — the scanout gate passes in both
  cases — and no worse after these changes, so it is not a regression. Captured,
  not chained onto this work.
* `build-unix.sh` does not link at HEAD (undefined `unsock_*`, `cmo_init`,
  `virtio_gpu_init`, `fb_*`). Verified broken *before* these changes on a clean
  `git archive HEAD` tree. `build-scanout.sh` and the payload scripts are the
  working builds.

---

## 8. If it does not boot, what to send back

The precisely-named next blocker is worth more than a guess at a second fix:

1. the **exact last line** on the console, verbatim, and the total line count;
2. **how long** you watched after it stopped;
3. what U-Boot printed for the relocation (the address it moved the image to);
4. whether line 10 said `24000000` or `10000000`;
5. whether line 9 said `AIA (APLIC+IMSIC)` or `PLIC`;
6. the boot hart id from line 7;
7. `printenv bootcmd` output, so the load interface is known rather than guessed.

Items 3–6 each isolate a different subsystem, and all seven are cheap to
capture while the console is still in front of you.
