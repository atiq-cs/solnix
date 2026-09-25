# Plan: two solnix installer images (TUI + GUI), NixOS-pattern, install-from-flake, uutils in the closure

**Status: PLAN FOR CONFIRMATION. No building until confirmed.**

This adapts the two-image NixOS installer model to illumos. Where a question arises, the default is **"how does
NixOS do it, adapted to illumos oddities."** solnix's purpose: make illumos feel familiar to NixOS/Linux users.

## 1. What the two NixOS images are (the pattern we follow)

NixOS ships two installer ISOs (`nixos/modules/installer/cd-dvd/`):

| | NixOS minimal | NixOS graphical |
|---|---|---|
| source | `installation-cd-minimal.nix` (21 lines) | `installation-cd-graphical-*.nix` |
| boots to | text console, root shell, `nixos-install` by hand | full desktop (GNOME/Plasma) + **Calamares GUI installer** |
| installer | CLI (`nixos-install --flake …`) | Calamares (graphical) *and* the CLI still available |
| both share | `installation-cd-base.nix` + `installation-device.nix`; `storeContents = [ toplevel ]` (closure baked in); `hardware.enableAllHardware`; passwordless live root; installs by **building the target from a config/flake**, never copying the live root |

Both install from a flake so **first boot is a fully-built, ready environment** — the whole point.

## 2. The two solnix images (the adaptation)

| | **solnix-tui** (minimal) | **solnix-gui** (graphical) |
|---|---|---|
| boots to | text console, root shell | COSMIC desktop (Wayland) |
| installer | `solnix-install` (TUI, exists) | a **graphical installer** front-end over the same `solnix-install` core |
| console | `console=text` + `os_console=text` (X1-proven; no larger built-in font — lower resolution) | COSMIC/Wayland; llvmpipe where no GPU |
| shared base | one `installation-device` module + `installation-cd-base` equivalent; the **same install core** builds the target from a `--flake` | same |

**Both** must: boot on wide hardware (whole-kernel-tree drivers, already done), auto-network (done), and
**install from a user-supplied `--flake`** so first boot into the installed OS is fully built.

⚠️ **The GUI installer is the biggest new piece.** NixOS uses Calamares (Qt/C++, Linux-centric — its partition +
bootloader modules assume GRUB/systemd/parted). We will **not** port Calamares. The illumos-faithful path is a
**thin COSMIC/Rust or GTK GUI front-end that collects the same answers `solnix-install` already prompts for**
(disk, encryption, /home layout, root pw, user, flake ref) and drives the existing `solnix-install` core. The core
logic (ZFS pool, BE, `nix build --store $ALTROOT`, activate) is shared, tested, and stays authoritative — the GUI
is just data collection. This keeps the risky OS-touching code in one place.

## 3. Install-from-flake: the core, unchanged and shared

Both images install by: collect answers → **`nix build --store $ALTROOT` the flake's toplevel INTO the target
pool** → activate. This is the store-on-pool fix already landed. First boot = fully built. The user passes ANY
`--flake` (their own `github:…#host`, or the default base). **We never pin one user's config** — this is a general
installer for many people on varied hardware.

## 4. The RAM-ramdisk problem, solved the NixOS way (for a GENERAL installer)

The live root is a ~334MB RAM ramdisk. `nix eval <user-flake>` fetches the flake + inputs into `~/.cache/nix` and
fills it. NixOS avoids this by baking its **own** closure (nixpkgs + installer) into the media store — NOT any user
config. We do the same, plus a writable partition for the rest:

* **#1 — build-time writable partition on the media** (`make-iso-usb.sh`, `xorriso -append_partition 3`): a real
  ZFS/UFS partition, mounted at boot by `setup_scratch` (no live repartition), grown to fill the stick
  (`zpool online -e`). Backs the flake fetch/eval scratch **and root's home**. Universal — every user, every
  machine. Research-confirmed: illumos has no overlayfs, but this needs none.
* **#2 — seed the SOLNIX BASE closure into a read-only media store** (lofi-mounted UFS/zpool image, added as
  `--extra-substituters file://…`). Seed the **base system's toplevel closure + the common starter set** (the
  universal solnix deps: illumos core utils, openssl, git, ncurses, **uutils** — see §6), NOT a user config. So the
  common closure is local; a user's unique flake inputs still fetch, backed by #1's scratch. Research-confirmed:
  Nix's `--extra-substituters file://` needs no union mount; it is the illumos-idiomatic fit.
* Distinction that matters: #2 serves **store paths**. A user's `github:…` flake still fetches its **flake
  inputs**; #1's writable partition is what makes that fit. For the *base/default* install (no external flake), #2
  makes it near-instant and offline-capable — the NixOS experience.

## 5. Editions (NixOS-scale, composed)

Following the 21-line-minimal pattern: a shared `installation-device` module + `installation-cd-base` equivalent,
and two thin edition files:
* `installation-cd-tui.nix` — base + text console.
* `installation-cd-gui.nix` — base + COSMIC + the GUI installer front-end.

Both set `storeContents`/media-store to the base closure (+ COSMIC closure for GUI).

## 6. uutils (Rust coreutils) in BOTH closures — the toolchain ALREADY EXISTS

You want the **Rust coreutils (uutils, what Ubuntu now uses)** available and **in the closure of both images**,
alongside the illumos utils.

✅ **CORRECTION (verified 2026-09-19): Rust is NOT a blocker — it already WORKS on solnix.** An earlier note in
`post-stable-backlog.md` said "no rustc/cargo"; that is **stale**. `docs/rust-illumos-bootstrap.md` +
`solnix-pkgs/pkgs/os-specific/illumos/rust-illumos-seed.nix` document a WORKING, published toolchain: native
`x86_64-unknown-illumos` **rustc 1.97.1 + cargo 1.97.1** (Tier-2; stage0 from OI Hipster `developer/lang/rustc`),
proven to `cargo build` crates.io crates and compile pyo3 end-to-end. Published to the durable cache as
`rust-illumos-1.97.1` (wrapped seed) + `rust-seed-stage` (raw tree).

So uutils is **not** gated on a multi-day bootstrap. The remaining work is exactly `rust-illumos-bootstrap.md` §6.1:

1. **Expose `rustc`/`cargo`/`rustPlatform` in the solaris-overlay** so `buildRustPackage` derivations resolve. The
   seed's wrappers already give working binaries; the overlay just points `rustPlatform` at them. (De-ref the two
   absolute host paths `/usr/gcc/14` to the tranche's nixpkgs gcc-14 for a hermetic closure — §6.2, optional first.)
2. **Package uutils-coreutils** as a `buildRustPackage` solnix derivation.
3. **Both illumos utils AND uutils in the closure**: ship side by side, illumos utils default on `PATH` (ADDITIVE,
   per the maintainer's confirmation — measure before making uutils the default like Ubuntu did).

⚠️ The images can ship WITHOUT uutils first (TUI + GUI + install-from-flake working — the TUI image is already
built), then add uutils once the overlay exposes `rustPlatform`. This is now a **days**, not multi-day, task.

## 7. Order of work

1. **#1 writable partition + single-stick self-grow** — DONE + PROVEN on illumos (`ccb99d76`; `usb-image-20260919-tui2`).
2. **#2 base-closure media store** — DONE (verified offline on illumos).
3. **TUI image** — DONE (`usb-image-20260919-tui2`, self-grow + inode fix + media store).
4. **Rust toolchain** — ALREADY DONE (`rust-illumos-1.97.1`).
5. **uutils in both closures** — DONE (78 applets run, published, additive into base.nix; `46d53a53`).
6. **GUI image**: COSMIC + a thin GUI installer front-end over the `solnix-install` core. ← IN PROGRESS.

## 8. GUI image (#6) scope — grounded in the measured COSMIC status

MEASURED (`docs/desktop-connectable-status.md`): a Wayland compositor RUNS on x86_64-illumos (smallvil, smithay SW
compositor, Mesa softpipe/llvmpipe), VNC-verified; the full COSMIC stack is built (cosmic-term/files/settings/
launcher/session/panel + applets), and cosmic-term paints RELIABLY over time (byte-identical captures). What does
NOT yet exist: a bare-metal login-straight-to-COSMIC path (it's been VNC/software-rendered, SSH-tunnel access).

So the GUI image adapts the NixOS graphical-ISO pattern to that reality:
* boots to a **COSMIC session** (or smallvil compositor hosting the installer) on the framebuffer via llvmpipe
  where there is no GPU (the X1 is `vgatext`/llvmpipe at best — a genuine platform limit, not a shortcut).
* runs a **thin GUI installer front-end** — NOT a Calamares port. It collects the SAME answers `solnix-install`
  already prompts for (disk, encryption, /home layout, root pw, user, `--flake` ref) and drives the tested
  `solnix-install` core. The risky OS-touching code stays in the one shared, verified path.
* shares ALL of TUI's install machinery: single-stick self-grow scratch, base-closure media store,
  store-on-pool build, uutils in the closure. The GUI image just adds COSMIC + the front-end + (per the
  base+desktop seed decision) the COSMIC closure in the media store so desktop installs are fast/offline.

⚠️ HONEST RISK: the GUI installer needs a compositor to have STARTED at boot on real (or QEMU) hardware — that
login-to-desktop path has not been exercised end to end (only VNC/offscreen). The first bring-up may hit the
framebuffer/seat/session plumbing that VNC bypassed. Build the front-end + wire the session, but VERIFY it actually
reaches a visible installer on a framebuffer, and report honestly if it only reaches VNC. A GUI installer that only
works over VNC is a real partial result, not a failure to hide.

## 8. CONFIRMED (maintainer approved the full plan)

Maintainer said "yes, implement that plan" — proceeding with the recommended defaults:
1. **uutils gating**: ship TUI+GUI working WITHOUT uutils first, add uutils after the Rust bootstrap (don't hold the images for a multi-day bootstrap).
2. **uutils role**: ADDITIVE first (both illumos + uutils present, illumos utils default on PATH); measure before making uutils the default.
3. **GUI installer**: thin front-end over the existing `solnix-install` core — NO Calamares port.
4. **#2 seed scope**: base-only for the TUI image; base + COSMIC closure for the GUI image.
5. **Media size**: 1–3 GB+ media accepted (USB has room).
6. **Default flake**: no `--flake` → install the seeded base (`configurations/base.nix`).

## 9. Original questions (now answered above)

1. **uutils gating**: ship the TUI+GUI images WITHOUT uutils first (working install-from-flake now), adding uutils
   after the Rust bootstrap? Or hold both images until Rust+uutils are in? (Rust is multi-day.)
2. **uutils role**: additive (both illumos + uutils present, illumos utils default on `PATH`) — or uutils as the
   **default** coreutils like Ubuntu? Recommend additive first, flip after measurement.
3. **GUI installer front-end**: a thin COSMIC/Rust (or GTK) data-collection GUI driving the existing
   `solnix-install` core — confirm we do NOT port Calamares.
4. **#2 seed scope**: base-only, or base + COSMIC closure (so GUI installs are fast/offline too)? GUI image
   arguably wants the COSMIC closure seeded.
5. **Media size**: seeding closures makes the media 1–3 GB+ (fine on USB, longer builds, needs a hotdog build
   node). OK?
6. **Default flake**: when a user gives no `--flake`, both images install a **default solnix base** (the seeded
   base toplevel) so "just install" works offline. Confirm that default exists as `configurations/base.nix`.

## USB scratch: prep-time grow (solnix-usb-grow.sh) + the X1 enumeration wall

The .img is a hybrid ISO: p1 ISO9660 (boot, read-only) + p2 ESP + p3 scratch (4GB
sparse, type Solaris). There is NO ZFS filesystem ON the stick to "extend" -- the
live root is a UFS ramdisk and p3 is `zpool create`d FRESH at install time. So the
only growable thing is the p3 PARTITION.

`scripts/solnix-usb-grow.sh` grows p3 into the stick's free tail AFTER `dd` -- run it
on the machine you dd'd from (Linux sgdisk / illumos format), where the USB is a real
block device. This removes reliance on the boot-time `_grow_scratch_tail` and gives a
roomier install scratch.

⚠️ It does NOT unblock the X1 Carbon. Measured (diag bundle): the X1's boot stick never
enumerates as a /dev/dsk device -- `devfsadm: driver failed to attach: scsa2usb`, and
the stick is absent from the USB device tree entirely (the usb_mid/video nodes there
are the webcam). This is a DEVICE-ENUMERATION gap, not a filesystem-grow gap: illumos
can grow filesystems fine (that is what _grow_scratch_tail does); it just never sees
the stick as a disk on this hardware, so there is nothing to grow or zpool-create on.
A pre-grown p3 on the stick is still unreachable there. The X1 needs either scsa2usb
to bind (open question -- pending a cfgadm -lav / prtconf -v capture of the stick's
real state) or NVMe-scratch on the target (what the installer uses now; costs nothing
since the target is erased for the install).
