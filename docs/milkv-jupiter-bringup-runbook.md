# Milk-V Jupiter (SpaceMiT K1) bring-up runbook

**Audience:** the maintainer, with the board on the desk, wanting real progress in
one sitting.

**Target:** the FIRST checkpoint from `docs/milkv-cosmic-plan.md` — **"it prints"**:
a solnix console banner on real silicon. Not a shell, not pixels, not an installed
system.

**Status of everything below.** Nothing in this project has ever executed a single
instruction on a K1. Every claim is tagged:

* **[VERIFIED-locally]** — measured on the dev box (cross-build, QEMU, `dtc`).
* **[UNVERIFIED-until-hardware]** — reasoned from vendor/mainline sources, not
  observed. Several of these will be wrong. That is the point of the sitting.

> **Do not expect this to boot.** A first bring-up that prints nothing is the
> normal outcome, and section 7 is written for that case. The deliverable of the
> sitting is *console text*, whatever it says.

> **See also `docs/milkv-jupiter-first-boot.md`** for the microSD image recipe,
> the `dd` command, the derived-vs-assumed address table, a three-way
> expectation table, and the adapter-vs-dead-kernel negative control. It also
> records a bug found in this code path after this runbook was written: the
> kernel bound its console MMIO base to a **compile-time qemu address**, which
> on the K1 is DRAM, so console input was dead and `uart_putc` would spin
> forever. Fixed. That is why section 7.4's "only ever arithmetically verified"
> note below is now out of date in one direction: the UART base is DTB-derived,
> and `src/riscv/uts/console-bind-check.py` checks that precondition in both
> directions with a working negative control.

---

## 0. What is NOT on the table

Stated up front so no time is lost looking for it. An installable solnix/COSMIC
image is **months** away, for measured reasons, not pessimism:

| Blocker | Evidence |
|---|---|
| `elf.c` loads **static `ET_EXEC` only** — no `ld.so.1`, no `dlopen` | `src/riscv/uts/elf.c`, 175 lines; COSMIC is ~860 dynamic Rust crates |
| `rootfs.c` is an **in-memory READ-ONLY** filesystem | "no write/create/unlink" |
| no ZFS, no socket layer beyond AF_UNIX | `vionet.c` sends one hand-built ARP frame |
| no SMF, no nix on riscv64 | — |

So: this runbook produces a **console banner**, and the microSD path below is
chosen specifically so the board's own working vendor OS stays intact.

---

## 1. The serial console, FIRST. Non-negotiable.

`docs/milkv-cosmic-plan.md` calls this non-negotiable, and the reason is
empirical: **every aarch64 advance this project ever made came from reading a
console.** Without it a failure is indistinguishable from a brick. Do not put a
card in the board until the console is proven.

### 1.1 What the repo knows about the UART, and what it does not

**[VERIFIED-locally]** — from `src/riscv/uts/k1.dts` and cross-checked against
mainline U-Boot 2026.04 `arch/riscv/dts/k1.dtsi`:

| Fact | Value | Source |
|---|---|---|
| Console UART | `uart0` @ `0xd4017000` | `k1.dts`, mainline `k1.dtsi` agree |
| Baud / framing | **115200 8N1** | `k1.dts` `chosen/stdout-path = "serial0:115200n8"` |
| Register layout | 16550-family, `reg-shift=2`, `reg-io-width=4` | both DTs agree |
| Clock | 14857000 Hz | both DTs agree |
| SoC pad mux | pads **68** and **69**, function **2** | mainline `k1-pinctrl.dtsi` `uart0_2_cfg` |

### 1.2 The pinout is NOT knowable from this repo — do not guess

The repo knows the **SoC pad numbers** (68/69). It does **not** know which
physical header pins those pads are routed to on the Jupiter PCB, and a wrong
guess here costs hours or a damaged pin. **Look at the board and the vendor
documentation, not at this file.**

What to look for, in order of likelihood:

1. A dedicated **3-pin debug header**, usually silkscreened `UART`, `DEBUG`,
   `CONSOLE`, or `GND/TX/RX`. This is the one you want.
2. Console pins on the **40-pin GPIO header**. If the vendor docs give a pin
   number, use it; do not infer one from a Raspberry Pi layout.
3. Some K1 boards expose the debug console over a **USB-C** port via an on-board
   USB-serial bridge. If plugging USB-C into your workstation makes a
   `/dev/ttyUSB*` or `/dev/ttyACM*` appear, you already have your console and
   need no adapter.

**Confirm before trusting:** write down the pin you chose, then verify it in
section 2 by seeing the *vendor* firmware print. Never debug our kernel on an
unproven console — you cannot tell "our kernel is silent" from "the wires are
wrong".

### 1.3 Wiring, if it is a pin header

Three wires, and only three:

| Adapter | Board |
|---|---|
| GND | GND — **connect this first** |
| RX | board **TX** |
| TX | board **RX** |

**Do NOT connect the adapter's VCC/3V3.** The board has its own supply;
back-feeding it is how boards die. TX/RX cross over — adapter RX to board TX. If
you see nothing, swapping exactly these two is the first thing to try (section
7.1). Use a **3.3 V** adapter (CP2102, CH340, FT232 in 3V3 mode); a 5 V adapter
can damage the SoC pads.

### 1.4 Open the console

Find the device: `ls /dev/ttyUSB* /dev/ttyACM*`. Then, pick one:

```sh
# picocom — recommended: clean exit with C-a C-x, no stale-session trap
picocom -b 115200 /dev/ttyUSB0

# screen — also fine; detach C-a d, quit C-a k
screen /dev/ttyUSB0 115200

# minicom — note the -D, and turn hardware flow control OFF in setup
minicom -D /dev/ttyUSB0 -b 115200
```

**Always log the session to a file.** The console text *is* the deliverable, and
the interesting part is usually the part that scrolled past:

```sh
mkdir -p ~/k1-logs
picocom -b 115200 --logfile ~/k1-logs/$(date +%Y%m%d-%H%M)-stock.log /dev/ttyUSB0
```

If `picocom` is older than 2.0 and lacks `--logfile`, use
`script -c 'picocom -b 115200 /dev/ttyUSB0' ~/k1-logs/session.log`.

**Permissions:** if the device opens but is silent and you got no error, check
you are in the `dialout`/`uucp` group. **Flow control must be OFF** (picocom's
default). Hardware flow control on a 3-wire cable produces exactly the "opens
fine, prints nothing" symptom.

---

## 2. Boot the STOCK VENDOR IMAGE first — and record two facts

This step is not optional and not a formality. It establishes that the board,
its firmware, and **your console wiring** all work, before our code is in the
picture. Skipping it makes every later failure ambiguous.

If the board shipped with the vendor OS on eMMC, just power it on. Otherwise
write the vendor image (Bianbu) to a microSD per Milk-V's instructions and boot
that.

### 2.1 Fact A — are U-Boot and OpenSBI healthy?

Watch for the chain. **[UNVERIFIED-until-hardware]**, but the mainline U-Boot
K1 documentation (`doc/board/spacemit/bananapi-f3.rst`) records this shape on a
BPI-F3, which is the same SoC:

```
try sd...
bm:3
j...

U-Boot SPL 2022.10spacemit-dirty (...)
[   0.279] DDR type LPDDR4X
[   0.292] lpddr4_silicon_init consume 13ms
...
U-Boot 2024.10-... (...)

DRAM:  4 GiB
Core:  19 devices, ...
In:    serial@d4017000
Out:   serial@d4017000
Err:   serial@d4017000
=>
```

**Record, verbatim:** the SPL line, the DRAM size, the `In/Out/Err` device, and
the U-Boot version. Save the whole log. Two things matter later:

* `DRAM: N GiB` — tells us the real memory size. Our DTB currently models 2 GiB
  and the kernel reads the live `/memory` node, so a mismatch is informational,
  not fatal.
* Getting to a `=>` prompt at all means **you have an interactive bootloader**,
  which is what makes section 4 safe: you can load and run our kernel *without
  flashing anything*.

**Interrupt autoboot** by hitting a key (often any key, sometimes `s` or Esc)
during the countdown, to reach `=>`.

### 2.2 Fact B — does U-Boot leave a live framebuffer?

This is the single most valuable measurement of the sitting. Per
`docs/milkv-cosmic-plan.md` it decides **3–5 days versus 2–3 weeks** for "pixels
on HDMI": if U-Boot has already initialized the display, we can inherit its
framebuffer; if not, someone ports the custom SpaceMiT DPU.

Plug in an HDMI monitor **before powering on**, then at the `=>` prompt:

```
=> bdinfo
=> echo $stdout
=> lcdputs hello           # errors out if there is no video subsystem
=> video list              # or: vidconsole
=> dm tree
```

**How to read the result:**

| Observation | Conclusion |
|---|---|
| Monitor shows **U-Boot text or a vendor splash/logo** | **Live framebuffer.** The 3–5 day path. Record it. |
| `dm tree` lists a `video` / `vidconsole` / `dpu` device | Display driver present — capture the full `dm tree` |
| `bdinfo` reports an `fb` base, or `$stdout` contains `vidconsole` | Framebuffer address known — capture the exact value |
| Monitor stays dark, `lcdputs` says "Unknown command", `dm tree` has no video node | **No framebuffer from U-Boot.** The 2–3 week DPU path. |

**[VERIFIED-locally]** — a useful prior, but only a prior: **mainline** U-Boot's
K1 support has *no* display driver at all (`configs/bananapi-f3_defconfig` sets
no `CONFIG_*VIDEO*`, and mainline `k1.dtsi` has zero display/DPU/HDMI nodes). So
if the board is running **mainline** U-Boot, expect no framebuffer. The **vendor
(Bianbu)** U-Boot is a different build and is the one that might show a splash —
which is exactly why this must be measured on the board you have rather than
inferred.

**Capture `dm tree` in full either way.** It is the device inventory of the live
firmware and it answers questions we have not thought to ask yet.

---

## 3. Build the payload

On the dev box:

```sh
cd src/riscv/uts
./build-k1-payload.sh
```

**[VERIFIED-locally]** it produces, and self-checks:

| Artifact | What |
|---|---|
| `unix-k1.Image` | the kernel, relinked into K1 DRAM, with the Linux RISC-V Image header — **this is what you copy to the card** |
| `k1.dtb` | our K1 devicetree |
| `unix-k1.elf` | the same kernel as an ELF, for `objdump`/`addr2line` when reading a fault |
| `fw_payload.bin/.elf` | OpenSBI with the kernel embedded — **not for the first attempt**, see 4.4 |

The script fails rather than shipping something malformed: it checks the Image
magic (`0x05435352` at offset `0x38`), that `text_offset` equals the link
address, that byte 0 disassembles to `j _start`, and that `k1.dtb` still
decompiles to the K1 topology (PLIC not AIA, `ndev=159`, 8 harts,
`spacemit,k1-x-sdhci`, `reg-shift=2`, GPU disabled). Both header checks are
negative-controlled — sabotaging the magic or the offset flips them to FAIL.

`fw_payload.bin` additionally **boots to a login prompt under QEMU**
**[VERIFIED-locally]**.

> **What that QEMU pass does and does not prove.** It proves the *wrapping* is
> well-formed and that our kernel survives being an OpenSBI payload. It is **not
> evidence the K1 boots.** `-machine virt` is a different platform: different
> DRAM base (`0x80000000` vs `0x0`), a different UART (`ns16550a` @ `0x10000000`
> vs a SpaceMiT 32-bit-register UART @ `0xd4017000`), QEMU's OpenSBI instead of
> the vendor's, and no FSBL or DDR training at all. Treat the QEMU result as
> "the file is not obviously broken", nothing more.

### 3.1 The load address is a knob

`unix-k1.Image` is linked at **`KBASE=0x02000000`** (32 MiB). Chosen
**[VERIFIED-locally]** from mainline `configs/bananapi-f3_defconfig` to clear
everything U-Boot puts in low DRAM: vendor OpenSBI at `0x0`, U-Boot itself at
`0x00200000`, the SPL stack at `0x01000000` plus a 16 MiB malloc arena.

**[UNVERIFIED-until-hardware]** that the *vendor* U-Boot uses the same layout. If
section 7 points at a load-address collision, rebuild with another
2 MiB-aligned address inside bank-0 DRAM — one variable, no code change:

```sh
KBASE=0x04000000 ./build-k1-payload.sh
```

---

## 4. Boot our kernel from microSD — eMMC untouched

**Safety ordering, and why.** We do **not** flash the on-board eMMC. The vendor
image there is your known-good fallback and your only easy way back. Everything
below either runs from a microSD card or from RAM via the U-Boot prompt, so the
worst outcome is "the board ignores the card" — pull it out and the vendor OS
boots exactly as before.

### 4.1 Put the files on a microSD

Any card the vendor U-Boot can read. A single FAT partition is simplest:

```sh
# IDENTIFY THE DEVICE FIRST. `lsblk` and confirm the size matches your card.
# Writing to the wrong device destroys your workstation's disk.
lsblk
sudo mkfs.vfat -F 32 -n SOLNIX /dev/sdX1     # <- sdX1 is YOUR CARD's partition
sudo mount /dev/sdX1 /mnt
sudo cp src/riscv/uts/unix-k1.Image src/riscv/uts/k1.dtb /mnt/
sudo umount /mnt && sync
```

If the vendor image already lives on a microSD, just copy the two files into its
**boot** partition instead — you keep a bootable card and gain our kernel.

### 4.2 Load and run from the U-Boot prompt (do this first)

Insert the card, power on, interrupt autoboot to reach `=>`. Then, **nothing is
written to any storage** — this is pure RAM:

```
=> mmc list
=> mmc dev 0                      # try 0, then 1; whichever is the microSD
=> fatls mmc 0:1                  # confirm you can SEE unix-k1.Image and k1.dtb
=> fatload mmc 0:1 0x02000000 unix-k1.Image
=> fatload mmc 0:1 0x08000000 k1.dtb
=> booti 0x02000000 - 0x08000000
```

Notes that matter:

* **`booti`, not `bootm` and not `go`.** `booti` is the command that passes the
  `(a0 = hartid, a1 = dtb)` ABI our `locore.S` expects **[VERIFIED-locally]** by
  reading U-Boot's `arch/riscv/lib/bootm.c` (`kernel(gd->arch.boot_hart,
  images->ft_addr)`).
* **Load `unix-k1.Image` at `0x02000000` — the same address it was linked at.**
  U-Boot may relocate it to `gd->ram_base + text_offset` anyway, and on the K1
  `gd->ram_base` is `0x0`, so `text_offset = 0x02000000` sends it right back
  **[VERIFIED-locally]** from `arch/riscv/lib/image.c` + `include/configs/bananapi-f3.h`.
* **The `-` is required.** It is the "no initrd" placeholder; omitting it makes
  U-Boot read the DTB argument as a ramdisk.
* `0x08000000` for the DTB is just somewhere out of the way; any free,
  8-byte-aligned DRAM address works.

**Try the vendor's own DTB too.** If `booti` with our `k1.dtb` prints nothing,
try letting U-Boot supply its own fixed-up devicetree:

```
=> booti 0x02000000 - ${fdtcontroladdr}
```

This is worth doing early: the vendor DTB has the **real** memory size and
pinmux the running firmware actually configured, whereas ours is a hand-written
subset. Which of the two works is itself a finding — record it.

### 4.3 Only if RAM-loading works: make it automatic

Do not automate a boot you have not seen succeed. Once it prints, save the
sequence into the U-Boot environment (this writes to the *environment*, not to
your rootfs):

```
=> setenv solnix 'fatload mmc 0:1 0x02000000 unix-k1.Image; fatload mmc 0:1 0x08000000 k1.dtb; booti 0x02000000 - 0x08000000'
=> saveenv
=> run solnix
```

To undo: `env default -a; saveenv`.

### 4.4 `fw_payload.bin` — the second-stage option, not the first

`fw_payload.bin` wraps our kernel inside OpenSBI as **M-mode firmware**. You
cannot `booti` it: the K1's U-Boot itself runs in **S-mode**, under the vendor
OpenSBI that the FSBL loaded at `0x0`
(`CONFIG_SPL_OPENSBI_LOAD_ADDR=0x0`) **[VERIFIED-locally]** from
`board/spacemit/bananapi-f3/Kconfig`, and S-mode code cannot launch M-mode
firmware.

Using it means **replacing vendor firmware in the boot chain** — the one
operation in this document that can leave the board not booting. Do not attempt
it in the first sitting. If it ever becomes necessary, `build-k1-payload.sh`
would need `FW_TEXT_START=0x0` and a matching `FW_PAYLOAD_OFFSET`, and the
recovery path (vendor fastboot / `bootinfo` + `FSBL.bin` reflash, per
`doc/board/spacemit/bananapi-f3.rst`) must be tested **before** overwriting
anything.

### 4.5 Getting back to a working board

* **Our kernel hangs?** Power-cycle. Nothing was written; nothing changed.
* **Card boots instead of eMMC and you want eMMC back?** Remove the card.
* **U-Boot environment confused?** `env default -a; saveenv`.
* **Nothing works at all?** The eMMC vendor image is untouched by every step
  above; remove the microSD and power-cycle.

---

## 5. What success looks like

The chain, and the exact expected text.

**Vendor firmware, then ours:**

```
U-Boot 2024.10-...  (vendor, section 2)
=> booti 0x02000000 - 0x08000000
## Flattened Device Tree blob at 08000000
   Booting using the fdt blob at 0x8000000
Moving Image from 0x2000000 to 0x2000000, end=0x28f6080     <- may or may not appear
```

**Then the first solnix output.** These lines are byte-for-byte what the current
kernel prints, taken from a real boot log **[VERIFIED-locally]** — under QEMU,
not on the K1:

```
[mlsetup] riscv64 machine-dependent bring-up (R-P4)
[mlsetup] trap vector installed (stvec -> _trap_entry, Direct mode)
[hat] Sv39 boot map built:
```

**"It prints" is achieved at the very first line.** `[mlsetup] riscv64 ...` means
OpenSBI handed control to our `_start`, the Image header was accepted, the kernel
was at the right address, and the console works. Everything after it is bonus.

**The banner**, a little further in:

```
SunOS Release 5.11 Version solnix-riscv64 (first illumos on RISC-V)
Copyright (c) solnix -- the first illumos RISC-V port (R-P5 genunix bring-up)

riscv64 kernel: mlsetup complete, entering main:
  boot hart id      : 0
  devicetree        : 0x...
  console path      : SBI legacy putchar (DBCN present)
  satp (Sv39)       : 0x8000000000...
  cpus online       : 8 (1 boot + 7 secondary)      <- 8 on K1 silicon, 4 under QEMU
```

**The line that tells us the K1 detection works** — the one thing on the board
we cannot test any other way:

```
[k1] embedded K1 DTB valid (SpaceMiT/xscale uart + sdhci present)
[board] runtime detect: boot DTB IS SpaceMiT K1 -> live MMIO (physical board)
```

Under QEMU that second line says `is NOT K1 (qemu-virt) -> faithful in-kernel
SDHCI+SD model` **[VERIFIED-locally]**. **On the board it must say `IS SpaceMiT
K1`.** If it says `NOT K1` while running on the K1, the vendor DTB spells its
UART or MMC differently than `fdt.c`'s tables expect — copy the exact
`k1-dtb: parsed ...` line back; the fix is one string in
`ns16550_uart_compat[]` / `sdhci_mmc_compat[]`.

> **Why the console is the *least* likely thing to fail.** Our banner goes out
> through the **SBI console** (`console path : SBI legacy putchar`), i.e. the
> *firmware's* UART driver, which section 2 already proved works. Our own
> `uart.c` is not on the banner path. So if the vendor boot printed and ours
> prints nothing, suspect the load address or the Image header — not the serial
> setup.

**Where an early stop is still informative:** the kernel does substantial work
before the banner (trap vector, Sv39, SMP, PLIC, clock). A boot that prints
`[mlsetup]` and then stops has already told us the interesting half — see 7.4.

---

## 6. What to capture and send back

**The console log is the artifact.** Everything else is reconstructible.

```
~/k1-logs/<date>-stock.log      the whole vendor boot (section 2), including
                                `dm tree`, `bdinfo`, `echo $stdout`, `video list`
~/k1-logs/<date>-solnix.log     every attempt at section 4, successes and silences
```

Include:

1. **The complete vendor boot**, from the first `try sd...` to the `=>` prompt.
   The SPL/DRAM/`In:Out:Err` lines matter.
2. **The framebuffer answer** (2.2) with the evidence — the full `dm tree`, and
   whether the monitor showed anything. This one fact re-plans a 2-week task.
3. **Every solnix attempt verbatim**, including the ones that printed nothing —
   with the exact `fatload`/`booti` commands used. "Nothing at all" is data, but
   only if the command that produced it is recorded.
4. **The `[board] runtime detect:` line**, and the `k1-dtb: parsed ...` line
   above it.
5. **Any register dump / fault text**, complete. `sepc`, `scause`, `stval` are
   the whole diagnosis; a paraphrase is not usable.
6. **Which DTB worked**: ours (`k1.dtb`) or the vendor's (`${fdtcontroladdr}`).
7. **The board's DRAM size** as U-Boot reported it.

For a fault, `unix-k1.elf` turns an address into a line:

```sh
riscv64-none-elf-addr2line -e src/riscv/uts/unix-k1.elf 0x0203a1b4
riscv64-none-elf-objdump -d src/riscv/uts/unix-k1.elf | less   # then search the sepc
```

---

## 7. Likely early failure modes, and what each implicates

Ordered by probability. Read 7.0 first — it is the one that wastes whole
sittings.

### 7.0 Establish how long you actually watched

A 27-second console read once made an aarch64 **reset loop on an ~8–10 minute
period** get recorded as a "stall", and four subsequent agents inherited the
wrong phenomenon. **An observation window shorter than the phenomenon's period
sees nothing.** Before writing "hung", watch for **several minutes** with a
timestamped log, and say in the log how long you watched.

### 7.1 No output at all, from the vendor firmware either

**The console, not the board.** Do not touch our kernel yet.

* TX/RX swapped (the single most common cause) — swap those two wires only.
* GND not connected.
* Wrong pin / wrong header (section 1.2 — re-read the vendor doc).
* Baud not 115200; flow control not disabled.
* Adapter not enumerated: `ls /dev/ttyUSB* /dev/ttyACM*`, `dmesg | tail`.
* Not in `dialout`/`uucp`.
* Board not actually powered, or powered from a supply that cannot start it.

### 7.2 Garbage / mojibake instead of text

The line is alive and the framing is wrong. Baud mismatch — the K1 console is
**115200 8N1**. Consistent garbage with a plausible rhythm usually means a
wrong-but-related baud (57600, 921600). Garbage only at power-on that then
becomes clean text is normal: the ROM/SPL may print at a different rate.

### 7.3 Vendor firmware prints, our kernel prints nothing

Console proven, so this is about the image. In order:

1. **`booti` refused it** — if you see `Bad Linux RISCV Image magic!`, the Image
   header is wrong or you loaded the ELF (`unix-k1.elf`) instead of
   `unix-k1.Image`. **[VERIFIED-locally]** U-Boot rejects anything without
   `0x05435352` at offset `0x38`.
2. **Load-address collision** — the kernel was written over U-Boot itself or its
   stack/malloc arena. Retry with `KBASE=0x04000000` (3.1). Note whether U-Boot
   printed a `Moving Image from ... to ...` line and where to.
3. **Wrong DTB** — try `${fdtcontroladdr}` (4.2). If our `k1.dtb` describes
   memory the board does not have, early memory setup can die before printing.
4. **`booti` did not pass the ABI** — if `booti` is unavailable and you used
   `go`, the kernel got no `a0`/`a1` and cannot work. `booti` is required.

### 7.4 A banner, then a hang — the *good* failure

This means **"it prints" is achieved**. Record exactly where it stopped; the
last line names the subsystem, and the stopping point is the diagnosis:

| Last line | Implicates |
|---|---|
| `[mlsetup] trap vector installed` | Sv39 boot map — the identity gigapages do not match the K1's physical layout |
| `[hat] Sv39 boot map built` | first post-paging access; a mapping is missing |
| `[smp] boot hart ... starting secondaries` | SBI HSM `hart_start` on 8 real harts (QEMU only ever exercised 4) |
| `[plic] self-test` | PLIC at `0xe0000000` with `ndev=159` — real hardware, first live test |
| `[clock] starting periodic clock` | timebase mismatch: the K1 arch timer is **24 MHz**, QEMU's is 10 MHz |
| `[startup] startup_memlist` | the `/memory` extent, or the boot-allocator clamp |
| `[sdhci]` | live SDHCI MMIO at `0xd4281000` — the first genuinely untested driver |

**Note the two known ceilings in this area**, so a stop there is recognized
rather than re-diagnosed:

* The boot map installs **one** identity gigapage over the kernel, and the boot
  allocator plus `page_init` are **clamped** to it. On a 2/4/8 GiB K1 you will
  see `[startup] clamping managed RAM to the boot identity gigapage end ...`.
  That message is **expected and benign** — it means the guard worked. Using the
  rest of DRAM needs additional gigapage mappings, which is deliberately not
  attempted yet.
* The kernel's own K1 UART driver (`reg-shift=2`, 32-bit registers at
  `0xd4017000`) has only ever been **arithmetically** verified, never driven.
  The banner does not depend on it (it uses the SBI console), but anything that
  reads console *input* does.

  **UPDATE — a real bug was found here, and fixed.** The console MMIO base was
  not merely unverified, it was **wrong**: `startup.c` passed the hardcoded
  compile-time `UART0_BASE` (`0x10000000`, the qemu-virt ns16550) on both
  platforms, and `uart.c` rebound the console back to it after the self-test. On
  the K1 that address is DRAM (bank 0 is `0x0..0x80000000`), which reads `0x00`,
  so `LSR.THRE` never sets and `uart_putc` spins **forever** — a silent hang, not
  a dead keyboard. Output was unaffected because it goes via SBI putchar, which
  is exactly what hid it, and no QEMU gate could catch it because on `-machine
  virt` `0x10000000` *is* a real ns16550. The base now comes from the live boot
  DTB. Full write-up, and the second (property-order) bug the negative control
  turned up: `docs/milkv-jupiter-first-boot.md` section 3.

### 7.5 It prints, then resets in a loop

Re-read 7.0 — establish the period before calling it a loop. Then suspect a
watchdog the vendor firmware left running, or a fault so early that the reset
vector is reached before any output. A timestamped log makes the period obvious.

### 7.6 If a NEW blocker appears: capture it and STOP

Hard-won rule for this project: **one fix reveals the next.** Do not chain a
second repair in the same sitting. Capture the exact console text, note where it
stopped, and stop. A precisely-named next blocker is worth more than a
half-attempted second fix — and *"we got 12 lines further and here is the
verbatim text"* is a complete, valuable result.

---

## 8. After "it prints"

Per the `docs/milkv-cosmic-plan.md` checkpoint table, and only once a banner is
real:

| Checkpoint | Work | Effort |
|---|---|---|
| **"it prints"** | ← this runbook | ~1 wk |
| "it reaches a shell" | K1 clock/reset shim + wire `uts/sdhci.c` to `spacemit,k1-x-sdhci` → boot off eMMC/microSD | ~2 wk |
| "pixels on HDMI" | inherit U-Boot's framebuffer if section 2.2 said yes (3–5 d), else port the SpaceMiT DPU (2–3 wk) | 1–3 wk |

Networking (the custom `spacemit,k1x-emac`, no BSD crib) is deliberately
deferred; a USB-Ethernet dongle covers the gap.

The GPU (PowerVR BXE-2-32) is **not** being driven — no open kernel driver
exists, so `k1.dts` declares it `status = "disabled"` and the desktop composites
in software via llvmpipe. That is a deliberate, documented decision, not a gap
to fix on the board.
