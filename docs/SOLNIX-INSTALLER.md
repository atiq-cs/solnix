# solnix graphical installer

A pop!_OS-style graphical installer for solnix (the Nix distribution of illumos,
x86_64). It collects the install answer set through a COSMIC wizard, renders a
declarative Nix-flavored solnix config, and drives the existing ZFS
boot-environment backend. It does NOT reinvent the installer backend — it is a
front-end over `solnix-install` / `oi-make-declarative-be.sh`.

## Front-end approach: libcosmic (approach a)

Built as a `cosmic::Application` on **libcosmic 1.0.0** (git rev
`2ab0d4c57079f0baf91d24b08a3821984121af62`) — the same toolkit pop!_OS's own
`cosmic-installer` uses. This was chosen over the GTK4/libadwaita path because
the libcosmic stack was already proven on this builder: `cosmic-settings` (a
full libcosmic app) compiles to an `x86_64-unknown-illumos` ELF in ~5 min, and
the warm cargo git/registry cache resolves the whole 637-package graph offline.
That makes it the best "functionally-identical pop!_OS COSMIC" match with the
lowest build risk.

Rust toolchain: `rust-illumos-1.97.1`, target `x86_64-unknown-illumos`, native
gcc-14 linker, illumos udev/libinput shims on the link path (same env as the
rest of the COSMIC stack, `/root/cosmic-env.sh`).

## What it does — the wizard

A linear back/next wizard (the pop!_OS flow), one `Step` per page:

1. **Welcome** — explains solnix is declarative (writes a Nix config, realizes
   its closure into a ZFS boot environment, sets the bootloader). Shows whether
   it is running in dry-run mode.
2. **Disk select** — enumerates the real disks by parsing illumos `diskinfo`
   (`TYPE DISK VID PID SIZE RMV SSD`) into a dropdown of `cNtNdN — <model/size>`.
3. **User / locale / timezone** — hostname, username, password (secure input),
   locale (from `/usr/lib/locale/*`), timezone (validated against
   `/usr/share/lib/zoneinfo`).
4. **Summary / confirm** — shows the choices AND the generated declarative
   `config.nix` (NixOS-shape: `networking.hostName`, `time.timeZone`,
   `i18n.defaultLocale`, `users.users.<u>` — composes over
   `configurations/base.nix`). "Install" runs the backend.
5. **Progress** — shells out to the backend and streams the output.

## How it wires the backend

The confirm/progress step generates the declarative config and drives the
existing ZFS-BE backend. It never re-implements the ZFS/bootloader logic.

- **Config generation** — `render_config()` emits a Nix-flavored solnix config
  in the same shape as `configurations/base.nix` / `configurations/gburd.nix`
  (`imports = [ ./base.nix ];`, `networking.hostName`, `users.users.<u>`,
  `time.timeZone`, `i18n.defaultLocale`). Written to `SOLNIX_CONFIG_OUT`
  (default `/root/solnix-installer-config.nix`).
- **Declarative realize** — `oi-make-declarative-be.sh` builds the toplevel
  from that config and lays the declarative userland into a ZFS-BE (the
  Nix/NixOS-installer approach).
- **ZFS-BE install** — `solnix-install <target-disk> [toplevel]` (env
  `SOLNIX_POOL`, `SOLNIX_BE`, `SOLNIX_ALLOW_RPOOL`) creates the GPT label
  (ESP + ZFS), the `rpool/ROOT/<be>` boot environment, copies the closure, seeds
  SMF, and sets the loader. The disk name comes straight from the disk-select
  page (`c1t1d0`, etc.).

Backend paths are overridable by env (`SOLNIX_INSTALL_BIN`,
`SOLNIX_DECLARATIVE_BIN`) so the same binary runs against the node's `/root`
copies or an installed-media `/usr/sbin` copy.

## Dry-run (default) vs real install

The actual disk install is destructive and hardware-gated, so the installer
**defaults to dry-run** (`SOLNIX_INSTALLER_DRYRUN=1`, unset also = dry-run):

- writes the generated `config.nix`,
- prints the EXACT backend command lines it *would* run,
- re-runs `diskinfo` to prove live disk enumeration,
- touches no disk.

Set `SOLNIX_INSTALLER_DRYRUN=0` for a real install (execs `solnix-install`).

## Build recipe

```sh
source /root/cosmic-env.sh
export PKG_CONFIG_PATH=/root/illumos-shims/udev
export RUSTFLAGS="-L /root/illumos-shims/udev"
export LD_LIBRARY_PATH=/root/illumos-shims/udev
export CARGO_BUILD_JOBS=6
export CARGO_TARGET_DIR=/nix/cosmic/solnix-installer/target
cd /nix/cosmic/solnix-installer
cargo build --release --target x86_64-unknown-illumos --offline
# -> target/x86_64-unknown-illumos/release/solnix-installer  (x86_64-illumos ELF)
```

Run it in a Wayland session (the `smallvil` compositor built alongside the
COSMIC stack) or its own; render check + disk enumeration proof below.

## Verification (done)

Built + launched + backend-wired on the chiuso builder (root@3.145.77.215):

- **ELF**: `target/x86_64-unknown-illumos/release/solnix-installer` — a real
  x86_64-illumos executable: `ei_osabi: ELFOSABI_SOLARIS`, `e_machine: EM_AMD64`,
  `e_type: ET_EXEC` (~81 MB, dynamically linked). Copy at
  `/root/solnix-installer-artifacts/solnix-installer`.
- **Launches + renders**: run against the session's Xvnc `:99` (1280x800) with
  the tiny-skia software renderer (no GPU on the headless VNC). Process stays
  alive and renders. Two screenshots captured with `xwd`:
  - Welcome page (`installer-shot.xwd`) — title, "Step 1 of 5", declarative
    blurb, DRY-RUN notice, COSMIC "Next" button.
  - Summary/Confirm page (`installer-shot2.xwd`, launched with
    `SOLNIX_INSTALLER_START_STEP=summary`) — settings-style summary rows
    (Disk/Hostname/User/Locale/Timezone) + the scrollable generated config.nix.
- **Enumerates disks + generates config (dry-run)**: `solnix-installer
  --dry-run-test` (headless; runs the exact code the Progress page runs):
  - 2 live disks via `diskinfo` (`c1t1d0` 60 GiB, `c2t1d0` 100 GiB),
  - 22 locales + 11 timezones from the OS,
  - wrote a declarative `config.nix` (validated: `nix-instantiate --parse` OK),
  - printed the exact backend command lines it would run:
    - `oi-make-declarative-be.sh` (build toplevel from the config, lay the BE)
    - `SOLNIX_POOL=rpool SOLNIX_ALLOW_RPOOL=1 solnix-install c1t1d0 <toplevel>`
  - touched no disk.

### Renderer note (headless)

`Settings::transparent(false)` is required on the headless Xvnc: the default
`transparent = true` makes winit-x11 pick a depth-32 visual whose pixel format
`softbuffer` rejects; opaque uses the depth-24 TrueColor visual it supports. On
real COSMIC/Wayland hardware with a GPU, re-enable the `wgpu` feature for
hardware rendering (the `wgpu -> tiny-skia` fallback chain is already in libcosmic).

## Environment overrides

| env | default | meaning |
|-----|---------|---------|
| `SOLNIX_INSTALLER_DRYRUN` | `1` (dry-run) | `0` = real destructive install |
| `SOLNIX_INSTALL_BIN` | `/root/solnix-install` | ZFS-BE installer path |
| `SOLNIX_DECLARATIVE_BIN` | `/root/oi-make-declarative-be.sh` | declarative realize path |
| `SOLNIX_CONFIG_OUT` | `/root/solnix-installer-config.nix` | generated config path |
| `SOLNIX_INSTALLER_START_STEP` | `welcome` | jump to `disk`/`user`/`summary`/`progress` (demo) |

## Source

- `src/main.rs` — the wizard (`cosmic::Application`, `Step` enum, disk/locale/tz
  enumeration, `render_config`, `run_backend`).
- `Cargo.toml` — libcosmic pinned to rev `2ab0d4c`.

Persisted in the solnix repo at `installer/`.
