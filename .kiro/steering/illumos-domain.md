# illumos Domain Knowledge

Required reading before touching build/toolchain/boot/service code. These are the
illumos facts that shape every design decision and the places solnix diverges
from both NixOS and nixbsd.

## Build system (illumos-gate)

- Source = the **ON consolidation** ("OS/Networking"), `illumos-gate`, code under
  `usr/src`.
- Driver: **`nightly.sh`** (unattended full build) configured by an env file
  (copy of `usr/src/tools/env/illumos.sh`). **`bldenv`** = interactive shell with
  the same env for incremental `dmake` builds.
- Uses **`dmake`** (Sun distributed make) + illumos-native bootstrap tools:
  `ctfconvert`/`ctfmerge` (CTF debug data — mandatory, coupled to object format),
  the **Solaris link-editor**, `elfsign`, `pkgmogrify`, `install`, mapfile tools.
- Output: a **proto area** (`$ROOT`, a staged `/`), then IPS packages.
- **Fully buildable from source today** — the old OpenSolaris "closed binaries"
  tarball is gone. No proprietary blob dependency remains. (Big win for Nix.)

## Toolchain

- Primary compiler is **GCC** (illumos ships a patched **illumos-gcc**; currently
  ~gcc 10 primary, gcc 7 legacy/shadow — **verify current version**).
- **Shadow compiler**: build compiles each object with the primary compiler and
  optionally a second (shadow) compiler purely to cross-check diagnostics.
  Mismatched warnings fail the build. Clang is usable only as shadow; a pure-clang
  gate build is not supported.
- **CTF** generation is mandatory build machinery — must reproduce under Nix.

## The hard blocker: bootstrap must happen ON illumos

- illumos-gate assumes an **illumos host**: `dmake`, CTF tools, Solaris `ld`,
  `elfsign`, IPS tooling are all illumos-isms.
- **Cross-building the whole gate from Linux is NOT a supported path** and is not
  known to work end-to-end. Do not plan as if it does.
- Known cross work is arch-cross *within* illumos (aarch64 cross-built from amd64
  illumos), not OS-cross.
- **Consequence:** solnix needs a **stage0** that runs in an **illumos VM/zone**
  (e.g. OmniOS or OpenIndiana) to produce the seed toolchain + libc, after which
  Nix takes over. This is the illumos analog of a Nix bootstrap seed, except the
  *host OS itself* must initially be illumos. This is Phase 1's first task and its
  biggest risk.

## Packaging: IPS → what Nix replaces

- CLI `pkg`; repo `pkg.depotd`; tools `pkgrepo/pkgsend/pkgrecv/pkgmogrify/
  pkgdepend/pkglint`. Package id = **FMRI** (`pkg://publisher/name@version`).
- Packages = manifests of **actions**: `file`, `dir`, `link`, `hardlink`,
  `driver` (device drivers), `user`/`group`, `depend`, `set`, `license`, `legacy`.
- Nix replaces: the package format, dependency solver, publishers/repos, image
  construction, and IPS's special actions. Watch the non-file actions —
  **`driver`** (device driver registration), **`user`/`group`**, and **SMF
  manifest delivery + `restart_fmri`/`refresh_fmri` triggers** need explicit Nix
  module equivalents; they are not just "copy a file".
- IPS derives deps via ELF `NEEDED` (`pkgdepend`); Nix derives them via RUNPATH
  closure instead.

## SMF (Service Management Facility) — the init system

- Services named by **FMRI**: `svc:/system/foo:default` (service + instance).
- **Manifests** = XML in `/lib/svc/manifest/...` (deps, methods, properties,
  restart behavior); **method scripts** in `/lib/svc/method`.
- Daemons: **`svc.startd`** (master restarter), **`svc.configd`** (config repo
  daemon backed by **SQLite** at `/etc/svc/repository.db`).
- Tools: `svcs` (status), `svcadm` (enable/disable/restart/refresh), `svccfg`
  (import manifests, set props), `svcprop` (read).
- Milestones ≈ runlevels: `single-user`, `multi-user`, `multi-user-server`.
- **SMF is deeply wired into userland** — you cannot trivially swap it. solnix's
  init module (`smf.services.*`, analog of nixbsd's `freebsd.rc`) generates and
  imports manifests. Stub `systemd.*` in a `nixos-compat.nix`.

## libc / linker / runtime

- **libc** is illumos's own (Solaris-derived), **not glibc** — different ABI,
  SysV/Solaris conventions, symbol versioning throughout. Historically split:
  `libc`, `libsocket`, `libnsl`, `libresolv`.
- **Link-editor `ld`** = the Solaris/illumos linker, **not GNU ld**. Uses
  **mapfiles** (v2) for versioning/scoping; direct bindings by default; lazy
  loading; filters; `-z` options.
- ELF tools: **`elfdump`/`elfedit`/`elffile`** (not readelf). **`elfedit`** edits
  ELF — **GNU patchelf/readelf will not work.** Any RUNPATH manipulation in Nix
  build hooks must use illumos tooling.
- **Runtime linker `ld.so.1`**; search-path tokens `$ORIGIN`, `$ISALIST`,
  `$OSNAME`, `$PLATFORM`. RUNPATH set via `-R`. solnix bakes `/nix/store` paths
  into RUNPATH and **bypasses `crle`/`/var/ld`**.

## Boot

- **x86**: illumos **`loader`** (port of the FreeBSD loader; BIOS `gptzfsboot` +
  UEFI, Lua menu) loads kernel **`unix`** (+`genunix`) and the **`boot_archive`**
  (ramdisk with drivers to mount root). `bootadm update-archive` rebuilds it;
  `bootadm` manages menu entries. **Boot environments appear as loader entries.**
- **SPARC**: **OpenBoot PROM (OBP)** Forth firmware → `bootblk` → 2nd-level boot →
  `unix` + `boot_archive`; net boot via `wanboot`.

## ZFS root + boot environments (the generation model)

- Root FS = **ZFS** `rpool`; root datasets under `rpool/ROOT/<be-name>`.
- **Boot environments (BEs)** = ZFS snapshots/clones managed by **`beadm`**.
- IPS upgrade model: clone active BE → apply changes to the clone → mark active
  for next boot → reboot switches; failure → boot old BE (rollback). Shared
  datasets (`/var`, `/export`, home) live **outside** the BE to persist.
- **solnix mapping:** a Nix generation = a BE. `/nix/store` lives inside the BE;
  `switch-to-configuration` activates within a BE; rollback = `beadm activate`
  the previous one. This gives NixOS-style atomic switch + rollback natively.

## Forks & the "everything for illumos" scope

- **OpenIndiana** (Hipster rolling, broadest IPS set), **OmniOS** (minimal/LTS
  server), **SmartOS/illumos-joyent** (RAM-boot hypervisor host), **Tribblix**
  (retro/minimal, own `zap` tool, keeps SPARC), **DilOS** (dpkg userland, SPARC).
- Features to eventually cover, and where they live now:
  - **Zones** — core, in-gate.
  - **bhyve** — in-gate (upstreamed ~2018).
  - **LX-branded zones** (run Linux ELF binaries) — in-gate (from Joyent).
  - **KVM** — largely SmartOS-only, not mainline. **Verify** before scoping.
  - **ZFS / OpenZFS** — illumos tracks OpenZFS; feature flags shared cross-platform.

## Standing "verify" list

Re-check these before relying on them (they drift): current illumos-gcc primary
version; current gate SPARC buildability; aarch64 port merge status; whether KVM
is anywhere but SmartOS. Prefer primary sources (illumos-gate, the fork repos).
