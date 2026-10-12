# Milk-V Jupiter (SpacemiT K1) — the hardware-iteration loop

> **⚠️ The maintainer's actual board is a SpacemiT K3 Pico ITX, not a K1.** For
> that board use **`docs/k3-first-boot-runbook.md`** — it has the native-on-board
> build recipe (gcc 15.2), the correct DRAM base (`0x102000000`), 16 harts, the
> AIA interrupt path, and the safe no-reflash NOR→U-Boot→`/boot` load path. This
> K1 document is retained for the K1/Jupiter hardware and as the shared loop
> doctrine (serial console, negative controls, what to capture).

**Audience:** the maintainer with the physical Milk-V Jupiter about to go on the
desk, plus whoever drives the build box. This is the **loop**: build → flash →
wire the console → power → read serial → capture → feed back → rebuild. It is the
operational companion to the two detailed references, which it points at rather
than duplicating:

* `docs/milkv-jupiter-first-boot.md` — the microSD recipe, the derived-vs-assumed
  address table, the three-way expectation table, and the adapter-vs-dead-kernel
  negative control. **Read it before the first flash.**
* `docs/milkv-jupiter-bringup-runbook.md` — the serial console pinout, baud, the
  stock-vendor prerequisites, and what is *not* on the table.
* `docs/riscv-jupiter-driver-plan.md` — the K1 peripheral map and the driver
  priority order past "it prints".
* `src/riscv/rp61/K1-MEMORY-MAP.md` — the SoC MMIO bases + the two calibration
  knobs (UART baud divisor, SDHCI clock divider).

Everything below is tagged **[VERIFIED-locally]** (built + qemu-booted on the dev
box / an EC2 build host) or **[UNVERIFIED-until-hardware]** (reasoned from vendor
sources). Nothing in this project has executed an instruction on a K1 yet; the
deliverable of the first sitting is **console text**, whatever it says.

---

## 0. The one decision that gates everything: how the kernel gets loaded

**Decision: ship the kernel as a `booti` Image + `k1.dtb` and let the board's
VENDOR firmware load it. Ship NO OpenSBI/`fw_payload` of ours for the first boot.**

This is the resolution of the "K1 DRAM base is 0x0, not qemu-virt's 0x80000000"
blocker, and it is deliberate, not a workaround. The reasoning:

* The K1 boot chain is **BootROM → FSBL → OpenSBI (M-mode, at 0x0) → U-Boot
  (S-mode)**. The vendor FSBL already places OpenSBI; U-Boot runs in **S-mode
  under it**. `booti` hands off to the next stage **in S-mode**. So you *cannot*
  `booti` an M-mode `fw_payload` — and shipping our own `fw_payload` means
  **replacing vendor M-mode firmware in the boot chain**, the single operation
  that can leave the board unbootable. That is explicitly **not** the first-boot
  path (`milkv-jupiter-bringup-runbook.md` §4.4).
* We therefore reuse the entire vendor BootROM→FSBL→OpenSBI→U-Boot chain
  **untouched** and only hand U-Boot a kernel Image + a DTB to `booti`. Recovery
  from any failure is "pull the card and power-cycle" — nothing of ours is in the
  firmware chain, nothing is written to eMMC/NOR.
* The load address is a **knob**, not a hardcode. The kernel Image is linked at
  `KBASE=0x02000000` (chosen from mainline `bananapi-f3_defconfig` to clear
  everything U-Boot puts in low DRAM: vendor OpenSBI at `0x0`, U-Boot at
  `0x00200000`, SPL stack at `0x01000000`). U-Boot's `booti` relocates the Image
  to `gd->ram_base + text_offset`; on the K1 `gd->ram_base = 0x0`, so it lands
  right back at `0x02000000` where it was linked.
* The R-P62 fix makes this robust: the kernel **reads its actual load base from
  OpenSBI** (`boot_load_pa`, captured PC-relative in `_start`) and checks
  load==link loudly before any absolute pointer is dereferenced; everything else
  (UART/PLIC/SDHCI/memory/hart-count) is **DTB-driven**. The kernel is a non-PIE
  image, so load *must* equal link — which is why there are two build targets,
  not one binary:

| target | script | KBASE | boots |
|---|---|---|---|
| **K1** (flash this) | `build-k1-payload.sh` | `0x02000000` | the Jupiter via vendor U-Boot `booti` |
| **qemu-virt** (regression gate) | `build-unix.sh` | `0x80200000` | `qemu-system-riscv64 -machine virt` |

> The K1 Image **will not** boot on `qemu-virt` (qemu's `-kernel` forces load at
> `0x80200000`, the K1 Image's absolute pointers are relocated to `0x02000000` →
> first vtable call faults). That is **expected and by design**, not a
> regression. The qemu-virt gate uses the `build-unix.sh` binary; see §4.

> **If the vendor U-Boot's low-DRAM layout differs from mainline's** (the biggest
> assumed number), rebuild with `KBASE=0x04000000 ./build-k1-payload.sh` — one
> variable, no code change. This is the first suspect if §5's "kernel never
> started" row fires.

---

## 1. Build the flashable artifact  [VERIFIED-locally]

Needs a riscv64 cross toolchain + `dtc`. On a Nix box (recommended — the build
scripts default to the `riscv64-none-elf-` prefix the embedded cross toolchain
provides):

```sh
cd src/riscv/uts
nix shell 'nixpkgs#pkgsCross.riscv64-embedded.buildPackages.gcc14' \
          'nixpkgs#pkgsCross.riscv64-embedded.buildPackages.binutils' \
          'nixpkgs#qemu' 'nixpkgs#dtc' \
  -c bash ./build-k1-payload.sh
```

> The scanout objects (`virtio_gpu.c`/`fb.c`/`fbio.h`) live in
> `src/riscv-port/rp64/kernel/`; the script finds them at `../../riscv-port/...`
> relative to `uts/`. If you unpack the tree somewhere flat, set
> `RP64=/abs/path/to/rp64/kernel` or symlink the parent so that path resolves.

Produces, and self-checks:

| Artifact | ~Bytes | What |
|---|---|---|
| `src/riscv/uts/unix-k1.Image` | ~626 K | the kernel, linked at `0x02000000`, RISC-V Image header — **this is what `booti` loads** |
| `src/riscv/uts/k1.dtb` | ~5 K | the K1 devicetree (PLIC/ndev=159/8 harts/`spacemit,k1-x-sdhci`/`spacemit,pxa-uart` reg-shift=2/GPU disabled) |
| `src/riscv/uts/unix-k1.elf` | — | the same kernel as ELF — for `addr2line` when reading a fault. **Never flash this** |

The build asserts: Image magic `05435352` at offset `0x38`, `text_offset ==
KBASE`, byte 0 disassembles to `j _start`, and the DTB round-trips through `dtc`
still describing the K1 topology — all negative-controlled. **[VERIFIED-locally
this run]** `K1 PAYLOAD BUILD PASS`, `unix-k1.Image` 625736 bytes, header + 7/7
DTB topology checks green.

### 1.1 Put it on the boot medium

**Safe path (recommended for first boot) — a data-only microSD the vendor U-Boot
reads two files off of.** No FSBL/FIP on the card, nothing in the firmware chain:

```sh
cd src/riscv/uts
nix shell 'nixpkgs#util-linux' 'nixpkgs#dosfstools' 'nixpkgs#mtools' \
  -c bash ./mk-k1-sdcard.sh          # -> solnix-k1-sd.img (MBR + one FAT32, label SOLNIX)
lsblk                                 # IDENTIFY THE CARD — confirm the size
sudo dd if=solnix-k1-sd.img of=/dev/sdX bs=4M conv=fsync status=progress
```

`/dev/sdX` is the **whole card** (`sdb`, not `sdb1`). Wrong device = destroyed
disk; `lsblk` every time. The card holds exactly `unix-k1.Image` + `k1.dtb`.

**Alternative:** copy `unix-k1.Image` + `k1.dtb` onto an *existing* vendor microSD's
boot partition — keep a bootable card, gain our kernel.

> Do **not** use `build-k1-image.sh` for a first bring-up — that lays a full GPT
> with FSBL/FIP *placeholders* and is the one path that can leave the board not
> booting. See `milkv-jupiter-first-boot.md` §1.3.

---

## 2. The serial console — the ONLY instrument  [UART facts VERIFIED-locally]

This kernel's **only** observation channel is the debug UART. No network, no
framebuffer on the boot path, no LED, no persistent log. **Without a USB-UART
adapter a boot attempt yields zero information** — a perfect boot and a fault at
instruction three look identical from the outside. Get the console first.

| Fact | Value | Source |
|---|---|---|
| Console UART | `uart0` @ `0xd4017000` | `k1.dts`, mainline `k1.dtsi` |
| Baud / framing | **115200 8N1** | `k1.dts` `chosen/stdout-path = "serial0:115200n8"` |
| Register layout | 16550-family, `reg-shift=2`, `reg-io-width=4` (32-bit regs, 4-byte stride) | both DTs |
| SoC pad mux | pads **68** and **69**, function **2** | mainline `k1-pinctrl.dtsi` |

Connection (**[UNVERIFIED-until-hardware]** which physical header pin the Jupiter
routes the pads to — read Milk-V's board doc, not this file):

* A **3.3 V** USB-UART adapter (CP2102 / CH340 / FT232 in 3V3 mode). A 5 V one can
  damage the SoC pads.
* Adapter **GND → board GND**, adapter **RX → board TX**, adapter **TX → board
  RX**. **Do NOT connect VCC/3V3** — back-feeding kills boards.
* Read it: `picocom -b 115200 /dev/ttyUSB0` (or `screen /dev/ttyUSB0 115200`),
  8N1, **hardware flow control OFF** (on a 3-wire cable, flow control on = "opens
  fine, prints nothing").
* **Try USB-C first:** `ls /dev/ttyUSB* /dev/ttyACM*` before and after plugging
  the board's USB-C into your workstation — some K1 boards bridge the console
  there and you need no adapter at all.

**Prove the console before trusting any silence** — see §5.

---

## 3. The boot-attempt loop (pure RAM, nothing written)

Insert the card, power on, interrupt U-Boot autoboot to reach `=>`, then:

```
=> mmc list                                  # find the microSD (try dev 0 and 1)
=> mmc dev 1
=> fatls mmc 1:1                              # MUST list unix-k1.Image and k1.dtb
=> fatload mmc 1:1 0x02000000 unix-k1.Image
=> fatload mmc 1:1 0x08000000 k1.dtb
=> booti 0x02000000 - 0x08000000             # a0=hartid, a1=dtb — the ABI locore.S expects
```

* **`booti`, not `bootm`/`go`** — `booti` is the command that passes `a0`/`a1`.
* **The `-`** is the required "no initrd" placeholder; omit it and U-Boot reads
  the DTB as a ramdisk.
* **DTB load address `0x08000000`** — must be 8-byte aligned, clear of the kernel,
  and **below `0x40000000`** (the kernel maps one identity gigapage over the boot
  area, so a DTB above that is unreadable after paging).
* **Also try the vendor's own DTB:** `booti 0x02000000 - ${fdtcontroladdr}`. The
  vendor DTB has the *real* memory size and the pinmux U-Boot actually configured.
  **Which of the two works is itself a finding — record it.**

### 3.1 The FIRST thing to look for — did the load-address decision work?

After the `booti` line, the win condition, in order:

```
## Flattened Device Tree blob at 08000000
   Booting using the fdt blob at 0x8000000
Moving Image from 0x2000000 to 0x2000000, end=...        <- may or may not appear

[mlsetup] riscv64 machine-dependent bring-up (R-P4)      <- FIRST solnix output = THE WIN
```

`[mlsetup] riscv64 ...` means OpenSBI handed off, the Image header was accepted,
**the kernel was at the right address (the load-address decision worked)**, and
the console works. The single most informative line after that is:

```
[dw-apb-uart] bind console @0x00000000d4017000 reg-shift=2 io-width=4(32b) [from boot DTB]
[board] runtime detect: boot DTB IS SpaceMiT K1 -> live MMIO (physical board)
```

`bind console @0xd4017000` = the UART base came from the vendor DTB and is the
real K1 UART (the console-base bug is not present). `[board] ... IS SpaceMiT K1`
= board detection works. If it says `@0x0000000010000000` you are running a stale
Image — rebuild (§1). If `[board]` says `NOT K1` on the K1, the vendor DTB spells
the UART/MMC differently than `fdt.c`'s match tables — send back the `k1-dtb:
parsed ...` line; the fix is one string.

Full three-way expectation table (got-past-console / banner-then-stop /
nothing-at-all) with the subsystem each stop implicates:
**`milkv-jupiter-first-boot.md` §4.**

---

## 4. The regression gate (keep this green on every change)  [VERIFIED-locally]

The K1 Image can't run on qemu (§0), so the regression is the **qemu-virt** build:

```sh
cd src/riscv/uts
nix shell 'nixpkgs#pkgsCross.riscv64-embedded.buildPackages.gcc14' \
          'nixpkgs#pkgsCross.riscv64-embedded.buildPackages.binutils' \
          'nixpkgs#qemu' 'nixpkgs#dtc' -c bash ./build-unix.sh
# boots qemu-system-riscv64 -machine virt -smp 4 -bios default -kernel unix
# PASS = the "SunOS Release 5.11 ... solnix-riscv64" banner + "solnix-riscv login:"
```

**[VERIFIED-locally this run]** 142 PASS/`[ok]` lines, banner + login prompt
reached, **8/8 boots over 8 runs** (banner 8/8, login 8/8, 0 hard faults — no
bursty flake this run). The only `FAIL`-word line is the benign `fs:
open(/data/x) FAILED (no data disk?)` (no `-drive` attached; present in the
committed reference log too). The virtio-gpu scanout path now opens `/dev/fb` and
`MINIWL PASS`es — the display seam works under qemu.

**A qemu-virt pass is necessary but NOT sufficient for the K1.** `-machine virt`
is a different platform: DRAM at `0x80000000` not `0x0`, an `ns16550a` at
`0x10000000` not a 32-bit SpacemiT UART at `0xd4017000`, qemu's OpenSBI not the
vendor's, 4 harts not 8, a 10 MHz timebase not 24 MHz, no FSBL/DDR training. There
are **nine documented qemu-vs-silicon divergences** on this project. Treat green
here as "not obviously broken," never as "boots the board."

---

## 5. Negative control: "my adapter is wrong" vs "the kernel is dead"

Both present as an empty console. The control is **the vendor firmware is the
known-good transmitter** — run in ONE unbroken session, no re-wiring between:

1. **Card OUT**, power-cycle, watch for the vendor chain (`U-Boot SPL`, `DRAM: N
   GiB`, `In: serial@d4017000`, `=>`).
2. Only if you saw that, **card IN**, power-cycle, `=>`, run §3.

| vendor (card out) | ours | conclusion |
|---|---|---|
| prints | prints | everything works — read §3.1 / `first-boot.md` §4 |
| **prints** | **silent** | **console PROVEN, the kernel is the problem** — the same wires just carried text |
| **silent** | silent | **your observation channel is wrong — learn NOTHING about the kernel.** Fix the console first (TX/RX swap is the #1 cause; GND; 3.3 V; flow control off) |

Do not change anything between the two steps, or you have two experiments instead
of one control and the comparison is void. Full procedure + the adapter
loop-back self-test: `milkv-jupiter-first-boot.md` §5.

Before concluding "hung," establish **how long you watched** — an aarch64 "stall"
on this project was a reset loop on an ~8–10 minute period, mis-recorded from a
27-second read. Watch for several minutes with a timestamped log.

---

## 6. What to capture and send back (the feedback half of the loop)

The console log **is** the artifact. Capture to a timestamped file:

```sh
mkdir -p ~/k1-logs
picocom -b 115200 --logfile ~/k1-logs/$(date +%Y%m%d-%H%M)-solnix.log /dev/ttyUSB0
```

Send back:

1. The complete **vendor** boot (the §5 control), card OUT: SPL line, `DRAM: N
   GiB`, `In:/Out:/Err:`, through `=>`.
2. **Every** solnix attempt verbatim — successes AND silences — **with the exact
   `fatload`/`booti` commands used**. "Nothing at all" is data only if the command
   that produced it is recorded.
3. The `[dw-apb-uart] bind console @...` line and the `[board] runtime detect:` +
   `k1-dtb: parsed ...` lines (§3.1).
4. Which DTB worked — ours or `${fdtcontroladdr}`.
5. Any fault register dump **verbatim** — `sepc`, `scause`, `stval`. Then
   `riscv64-none-elf-addr2line -e unix-k1.elf <sepc>` names the faulting line. A
   paraphrase is not usable.
6. The board's DRAM size as U-Boot reported it, and `mmc list` output.
7. **How long you watched** and whether the log was timestamped.

If a **new** blocker appears: capture its exact text and **stop**. One fix reveals
the next; a precisely-named next blocker beats a half-attempted second repair.

---

## 7. What remains to confirm on the physical board

Everything below is software-ready and qemu-verified; only silicon can confirm
it. In dependency order:

1. **The load-address decision holds** — vendor U-Boot `booti`s the `0x02000000`
   Image and `[mlsetup]` prints. If not: retry `KBASE=0x04000000`, then the
   vendor DTB (§0, §3.1, §5).
2. **The console UART drives live** — `bind console @0xd4017000 reg-shift=2
   io-width=4` and real register TX/RX (first-ever live K1 UART drive). The two
   calibration knobs may need tuning on silicon: the **UART baud divisor** (the
   pxa-uart input clock is ~14.857 MHz per the DTS but board-specific) and later
   the **SDHCI clock divider** (`rp61/K1-MEMORY-MAP.md`).
3. **8 harts come up** via SBI HSM (qemu only ever ran 4) — `[smp]` lines.
4. **PLIC @0xe0000000, ndev=159** claims a live external IRQ — `[plic]` self-test
   (qemu PLIC is at `0x0c000000`; this is the first real-base PLIC test).
5. **The periodic clock** — the K1 arch timer is **24 MHz** vs qemu's 10 MHz; a
   timebase mismatch shows here.
6. **SDHCI @0xd4280000 live** — the first genuinely untested driver on real MMIO;
   needs the CCU clock-enable (`k1_ccu_enable`, APMU+0x054) to fire on silicon,
   and the clock-divider knob. This is the gate to reading root off real media.
7. **k1x-emac 1GbE** — needs the RGMII clock-delay calibration + the station MAC
   programmed; off the boot path, for networking.

**Reaching `/sbin/init` on the K1 needs items 1–6**; "it prints" (the first-boot
success condition) needs only 1–2.

---

## 8. Beyond "it boots init/sh": the road to Nix-managed solnix/riscv64 parity

The end goal is parity with x86_64/aarch64 — a **Nix-managed** solnix riscv64
system, not just a booting kernel. Current riscv64 reality (from
`milkv-jupiter-first-boot.md` §0) and the steps from here:

| Step | State now | What it needs |
|---|---|---|
| K1 kernel boots init/sh off SDHCI | §7 items 1–6, qemu-ready | the physical board |
| **A riscv64 illumos userland** (cross-built, like aarch64's proven cross-build) | the kernel runs UNMODIFIED coreutils + newlib on an in-tree `libc.a`; `elf.c` loads **static `ET_EXEC` only** | a dynamic-linking userland path (`ld.so.1`), a full libc, and a seed toolchain; model it on the aarch64 cross-build already proven in this repo |
| **A writable root fs + the pieces a nixos-like activation needs** | `rootfs.c` is in-memory read-only; the blockfs/SDHCI path writes single blocks | a real writable FS on SDHCI root (the blockfs write path exists; needs to grow), plus SMF (none on riscv64 yet) |
| **nixpkgs-illumos riscv64 cross** | 0 riscv64 derivations in the registry (`real-derivations-224.tsv`) | a riscv64 cross target in nixpkgs-illumos so packages build for riscv64 — the same machinery that produced 215 aarch64 + 28 sparcv9 derivations |
| **The solnix closure model on riscv64** (`storeContents=[toplevel]`, nix-managed generations) | proven on x86_64/aarch64; absent on riscv64 | the closure-model image builder re-targeted to riscv64 once the cross + a bootable userland exist |
| **A solnix-riscv image that installs/boots a Nix-managed system** | — | combine the K1 boot image (this doc) with the closure-model root; the installer path that x86_64 already has |

Phase order for the next runs: **(a)** confirm the K1 boots init/sh on silicon
(this doc's loop) → **(b)** a dynamic riscv64 userland + seed toolchain
(board-independent, can proceed in parallel) → **(c)** nixpkgs-illumos riscv64
cross so packages build → **(d)** the closure-model image on riscv64 → **(e)** an
installable Nix-managed solnix/riscv64. Steps (b)–(d) are board-independent and
can run while the hardware loop iterates.

---

## 9. Getting back to a working board

* Kernel hangs? Power-cycle — nothing was written.
* Card boots instead of eMMC and you want eMMC back? Remove the card.
* U-Boot env confused? `env default -a; saveenv`.
* The eMMC vendor image is untouched by every step here. The one operation that
  can brick — writing `fw_payload.bin` over vendor M-mode firmware — is **not in
  this document** and must not be attempted in a first sitting.
