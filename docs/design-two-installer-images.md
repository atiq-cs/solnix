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

## 6. uutils (Rust coreutils) in BOTH closures — with the honest prerequisite

You want the **Rust coreutils (uutils, what Ubuntu now uses)** available and **in the closure of both images**,
alongside the illumos utils.

⚠️ **Measured prerequisite: there is NO Rust toolchain on the illumos fleet today** (C/C++ gcc-14/clang-21 only;
COSMIC was cross-compiled from Linux). uutils is Rust, so it needs `rustc`/`cargo` targeting
`x86_64-unknown-illumos` (a tier-3 Rust target) first. This is a **multi-day bootstrap milestone** (`post-stable-backlog.md`
PS-2), not a package add. Plan:

1. **Bootstrap Rust for illumos** — cross-compile `rustc`+`cargo` from the x86_64-linux box to
   `x86_64-unknown-illumos`, wire as a `pkgs.illumos` derivation. (Prereq for uutils AND the wider Rust CLI
   ecosystem the project wants anyway.)
2. **Package uutils-coreutils** as a solnix derivation built with that toolchain.
3. **Both illumos utils AND uutils in the closure**: ship them side by side. Decision needed (see questions) on
   whether uutils is *additive* (both present, illumos utils are the default `PATH`) or *replaces* the GNU/illumos
   coreutils as the default — Ubuntu made uutils the default; the safe first step is additive + opt-in, matching
   "measure, don't cargo-cult."

⚠️ This makes uutils-in-the-closure **gated on the Rust bootstrap**. The images can ship WITHOUT uutils first (TUI +
GUI + install-from-flake working), then add uutils once Rust lands — or we hold the images for the bootstrap. See
the questions.

## 7. Order of work

1. **#1 writable partition** (`make-iso-usb.sh` + `setup_scratch` mount-only) — small, universal, unblocks the
   fetch on any machine. Testable first.
2. **#2 base-closure media store** (seed base toplevel closure + starter set; `file://` substituter wiring).
3. **TUI image** = base + #1 + #2, install-from-flake end to end.
4. **Rust bootstrap for illumos** (multi-day; PS-2).
5. **uutils packaged** + added to both closures.
6. **GUI image**: COSMIC + a thin GUI installer front-end over the `solnix-install` core.

TUI (1–3) is near; GUI (6) and uutils (4–5) are each real milestones.

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
