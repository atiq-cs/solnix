# Nixifying the COSMIC desktop on x86_64-illumos

How COSMIC apps become **real Nix derivations** instead of `cargo` output in a
`/root` checkout, what each illumos fix is for, and what is still ad-hoc.

Status of this document: the pattern is proven end to end through compilation of
the full ~860-crate COSMIC/iced/winit/wayland graph, with a passing negative
control, and the vendor FOD has been independently reproduced on a second clean
node. **No binary has been produced yet.** The `derivation-goal.cc:306`
assertion that was believed to be the blocker is now solved (one flag -- see
"Where it stops"); what remains is a dependency-porting problem (`cmake-minimal`
via doxygen), not a Nix problem. Read "Where it stops" before believing anything
else here.

## Why this was needed

`docs/registry/arch-manifest.tsv` has 13,559 rows and **zero** COSMIC
derivations (the one `cosmic` grep hit is `py39-cosmic-ray`, an unrelated Python
mutation tester). No `.nix` file in either repo defined a `cosmic*` or
`libcosmic` package. What existed instead:

* `scripts/solnix-cosmic-session.sh` exec'ing prebuilt binaries from hardcoded
  paths -- `/root/cosmic-gcroots/waveB2-bin/smallvil` and
  `/nix/cosmic/cosmic-apps/cosmic-term/target/x86_64-unknown-illumos/release/cosmic-term`.
* `docs/COSMIC-APPS-STATUS.md` documenting a per-app recipe that is
  `cd /root/cosmic-apps/<app> && cargo build --release`, with a `[patch]` block
  appended to each `Cargo.toml` pointing at `/root/libcosmic`.

So ~25-36 apps "compiled and ran" as artifacts on one node, unreproducible from
a clean checkout. Additional evidence that this mattered, found while doing the
work: **a hand-run `cargo build` cannot even link on a fresh base AMI.** The AMI
has no gcc binary at all (`/usr/gcc/10` and `/usr/gcc/14` contain only `lib/`),
`pkg install developer/gcc-14` is rejected by the 2025
`userland-incorporation`, and even with the nix stdenv cc supplied by hand the
link fails:

```
ld: fatal: library -lposix4: not found
ld: fatal: library -lumem: not found
ld: fatal: library -lsendfile: not found
ld: fatal: library -llgrp: not found
```

Those libs live in the base-platform `/lib/amd64`, and `rust-overlay.nix` is
what stages them behind a store `-L` for every `buildRustPackage`. The nix path
is not bureaucracy here; it is the only path that links.

## The correction that shaped the design

The obvious plan is "package `libcosmic`, then package apps against it." **That
is wrong for this stack**, and the evidence is in the app's own lockfile.
`cosmic-term`'s `Cargo.lock` resolves `libcosmic`, `iced`, `cosmic-config` and
`cosmic-theme` as **cargo git dependencies at one rev**:

```
name = "libcosmic"   version = "1.0.0"
source = "git+https://github.com/pop-os/libcosmic.git#0ca1b784c931c946517379795ce87328c6a902b8"
```

cargo resolves those from the lockfile, not from the Nix store. A standalone
`libcosmic` store path would be built and then never consumed. The reusable
shared unit is therefore **the vendored dependency set**, expressed as a
fixed-output derivation (FOD). That FOD *contains* libcosmic, iced, winit,
softbuffer and 857 other crates, pinned by the lockfile.

## Shape of the derivation

`pkgs/os-specific/illumos/cosmic/cosmic-term.nix` is two derivations:

1. **`cosmic-term.vendor`** -- an FOD that runs the seed `cargo vendor --locked`
   and captures the result. Network is reachable (this build world is
   `sandbox = false`) and the output is hash-pinned, so it is hermetic by hash,
   the same contract `fetchCargoVendor` offers.
2. **`cosmic-term`** -- an ordinary `rustPlatform.buildRustPackage` consuming it
   via `cargoVendorDir = "vendor"`.

`fetchCargoVendor` and `importCargoLock` **cannot** be used on illumos:
the former drags a python3 `requests` / `nix-prefetch-git` chain that fails
here, and the latter breaks because the fork's eval-time `fetchurl-shim` makes
`fetchCrate` return a bare string rather than an attrset with `.outputHash`.
This is a pre-existing, documented constraint (`artifacts/rust-wave1-report.md`),
not something new.

Two details of the FOD are load-bearing:

* `cargo vendor` prints the source-replacement config on **stdout** and does not
  write it into the vendor directory. This lockfile has six git sources, and the
  nixpkgs default config only replaces `crates-io`, so without capturing that
  output cargo tries to reach the network for every git dep. The FOD captures it
  as `$out/.cargo/config.toml`, exactly where `cargoSetupPostUnpackHook` looks.
* The captured config contains the absolute build directory, so the FOD rewrites
  it to the hook's `@vendor@` placeholder. Without that the FOD only works in
  the directory that produced it. A guard fails the build if the placeholder is
  missing.

## The illumos fixes, and what each is for

Every one below was applied in response to an **observed** compiler or linker
error, quoted in the derivation next to the fix. None were added speculatively.

| # | Fix | Observed failure it clears |
|---|-----|---------------------------|
| 1 | softbuffer shm name gains a leading `/`; `Mode::RWXU` -> `RUSR\|WUSR` | illumos `shm_open(3C)` requires a leading `/` and returns EINVAL otherwise -- every COSMIC app panicked on its first frame in `softbuffer/src/wayland/buffer.rs` |
| 2 | Re-stamp `.cargo-checksum.json` for each edited vendored file | `error: the listed checksum of ... has changed` -- cargo refuses to build an edited directory source |
| 3 | Remove `kms` from softbuffer's default feature list | `E0432 unresolved imports rustix::ioctl::{NoneOpcode,ReadOpcode,ReadWriteOpcode,WriteOpcode}` in `drm-ffi/src/ioctl.rs` (those opcodes are gated linux/bsd) |
| 4 | Add `illumos`/`solaris` to the epoll cfg gates in wayland-backend `server_impl/common_poll.rs` + `handle.rs` | `E0425 cannot find value poll_fd`, `E0425 cannot find value ret`, `E0599 no method dispatch_all_clients` |
| 5 | Add `illumos`/`solaris` to the macos/redox side of the wayland-backend `socket.rs` split | `E0599 no associated function CMSG_CLOEXEC for RecvFlags` -- illumos rustix has no `CMSG_CLOEXEC`, so it takes the `DONTWAIT` + explicit `fcntl(FD_CLOEXEC)` path |
| 6 | Add `illumos`/`solaris` to winit's existing netbsd `is_main_thread` arm | `E0425 cannot find function is_main_thread` -- winit has no illumos arm, so the call site had no definition |
| 7 | `--no-default-features --features wayland,dbus-config` | drops `wgpu`, whose `Instance::new` **panics** (rather than returning `Err`) on illumos, so iced's tiny-skia fallback never fires |
| 8 | `CARGO_TARGET_X86_64_UNKNOWN_ILLUMOS_LINKER = stdenv.cc/bin/cc` | the seed cargo wrapper hardcodes `PATH=/usr/gcc/14/bin`, which does not exist on the AMI |

Fixes 4-6 are re-expressed as version-independent `cfg` rewrites rather than
literal patch files, because the committed
`rust-patches/wayland-backend-0.3.17-illumos.patch` targets a crate version this
lockfile does not use (it pins **0.3.16**).

### One fix that was wrong, and how it was caught

An earlier iteration turned smithay-client-toolkit's default `xkbcommon` feature
**off** (via `cosmic-client-toolkit`, the only consumer that does not already set
`default-features = false`), to avoid pulling `libxkbcommon` -- a meson package,
so it drags python3 in. That does clear the `pkg-config` panic, and then
`iced_winit` fails with **eleven** errors, because `sctk::seat::keyboard` only
*exists* under that feature:

```
E0432 unresolved import `cctk::sctk::seat::keyboard`   (x7)
E0433 cannot find `keyboard` in `seat`                 (x4)
```

So the feature is load-bearing for any COSMIC/iced app and `libxkbcommon` is a
genuine dependency. The derivation carries a comment saying so, so the next
person does not re-derive it the expensive way.

## Verification, including the negative control

An A/B control pair was built from the same derivation with the same dependency
set, differing only in whether the softbuffer guard looks for a string that
exists:

* **negative** (`grep` target sabotaged to a nonexistent string) -- build
  **FAILS** in `patchPhase`, exit 1:

  ```
  FATAL: softbuffer shm-name string not found in vendor/softbuffer/src/wayland/buffer.rs;
         the illumos POSIX-shm fix would silently no-op
  ```

* **positive** (guard intact) -- clears `patchPhase`, printing
  `illumos POSIX-shm fix target: vendor/softbuffer/src/wayland/buffer.rs`, then
  proceeds into the real crate compilation.

This is the specific failure mode worth ruling out: a derivation that "succeeds"
because it silently no-op'd its patch or picked up a prebuilt artifact. Every
source edit in the derivation is guarded the same way -- if the expected string
or file is absent, the build dies instead of shipping something unpatched. That
paid off immediately: the guard caught that at the pop-os `cosmic-4.0` tag the
file is `src/wayland/buffer.rs`, **not** `src/backends/wayland/buffer.rs` as the
committed note assumes.

### Verified vs not verified -- be strict about this

| Claim | Status |
|---|---|
| `nix-instantiate` yields a real `.drv` from a clean checkout | **VERIFIED** |
| Vendor FOD builds, is content-addressed, has a real deriver | **VERIFIED** -- `/nix/store/dwaq7qxcc1ya7srvrqib21c1vhsy5l32-cosmic-term-vendor-1.5.0`, 861 entries. **Independently reproduced** from scratch on a second clean node to the identical path (measured 623 MB on disk, not 1.34 GB) |
| No hardcoded `/root/...` or `/nix/cosmic/...` path anywhere in the derivation | **VERIFIED** |
| The ~860-crate graph compiles (libcosmic, iced, winit, wayland, softbuffer, alacritty_terminal) | **VERIFIED** through the point described below |
| Negative control flips the check to FAIL | **VERIFIED** |
| Final `cosmic-term` binary produced | **NOT REACHED** -- see below |
| Binary is `ELFOSABI_SOLARIS` / `EM_AMD64` | **NOT VERIFIED** (no binary yet) |
| Binary runs / paints under smallvil | **NOT VERIFIED** (no binary yet) |
| The `derivation-goal.cc:306` assertion is avoidable | **VERIFIED** -- `--option substitute false`, 4/4 vs 4/4; see below |
| The assertion is fixed by a newer nix | **REFUTED** -- 2.24.15 (the aborting version) *contains* it, as do 2.25-2.29 |

Do not report the binary, the ELF check, or the run as done. They are not.

## Where it stops, exactly

What was recorded here as "the bootstrap Nix" is **two separate problems**, and
the fix this document previously recommended was **wrong**. Both re-measured on
a clean node.

### 1. The assertion is AVOIDABLE WITH ONE FLAG (not fixable by upgrading)

```
Assertion failed: false, file src/libstore/build/derivation-goal.cc, line 306,
function outputsSubstitutionTried
```

Measured A/B on the recorded trigger (`libxkbcommon`), 4 runs per arm, with the
existing `/nix-tools224` bootstrap nix:

| arm | invocation | result |
|---|---|---|
| A | substituters ON | **ASSERT 4/4** |
| B | `--option substitute false` | **no assert 4/4**, proceeds to build |

The earlier claim that the from-source `nix-2.24.15` "has the relevant fixes" is
**refuted: line 306 of `derivation-goal.cc` in 2.24.15 IS that assertion**, and
`/nix-tools224/bin/nix --version` reports `nix (Nix) 2.24.15` -- the aborting nix
is already that version, so "upgrade to 2.24.15" is a no-op. Version sweep:

| nix | assertion present? |
|---|---|
| 2.8.1 / 2.11.1 / 2.13.6 / 2.18.9 | **NO** -- plain `bool retrySubstitution`, no enum, no assert |
| 2.24.15 | yes, line 306 |
| 2.25.5 / 2.26.4 | yes, line 306 |
| 2.28.4 | yes, line 293 |
| 2.29.1 | yes, line 313 |

Upgrading upstream does **not** help; only <= 2.18 is structurally immune.
**Do not build a nix from source for this.**

Mechanism, traced in the 2.24.15 source rather than inferred:

* `haveDerivation()` (dg:249) creates substitution goals only
  `if (settings.useSubstitutes && parsedDrv->substitutesAllowed())`.
* `goal.cc:150-154` is the only place the counters move: `ecIncompleteClosure`
  bumps both `nrIncompleteClosure` and `nrFailed`.
* `YesNeed` is set at dg:302 only when the substitutes formed an **incomplete
  closure** (`nrIncompleteClosure > 0 && == nrFailed`).
* It is cleared **only** in `inputsRealised()` (dg:490-493).
* Re-entering `outputsSubstitutionTried()` while still `YesNeed` -- via the
  `needRestart` path (dg:316-318), armed by `addWantedOutputs()` when a second
  consumer wants more outputs of the same **multi-output** drv, without passing
  through `inputsRealised()` -- trips line 306.

Disabling substituters removes the dg:249 branch, so `nrIncompleteClosure` stays
0, `YesNeed` is never set, and 306 is unreachable. This matches
`artifacts/cosmic-nix/xkbdrv.log`, whose 12 "don't know how to build these
paths" entries are all multi-output python3-closure members.

**The working recipe is two phases**, because the flag alone forces a
from-source stdenv rebuild:

1. **Warm from cache with BARE-PATH realisation.** `nix-store --realise <path>`
   uses `PathSubstitutionGoal` only and never enters
   `DerivationGoal::outputsSubstitutionTried`, so it cannot hit the assertion.
   For every `.drv` in the closure, ask `nix-store -q --outputs` and realise
   those paths. `nix-store -qR --include-outputs <drv>` is **not** sufficient --
   it omitted `expand-response-params` in a measured run.
2. **Build with `--option substitute false`.**

(`nix-build` has no `--add-root`; use `-o`. A stale `/homeless-shelter` must be
removed before each build.)

### 2. What actually blocks the binary: cache coverage, not nix

With the assertion avoided, the build walks into an unported dependency. Of
`cosmic-term`'s 339 closure output paths, **180 are in no cache** and must be
built locally, and **60 of those are the cmake / doxygen / libxcb / xorgproto /
python3 graph**. `cmake-minimal-4.3.4` then fails:

```
ld: fatal: library -lkstat: not found
ld: fatal: library -lsendfile: not found
ld: fatal: file processing errors. No output written to cmake
error: builder for '...-cmake-minimal-4.3.4.drv' failed with exit code 9
```

cascading through zstd, libarchive, python3, doxygen, libxcb, xorgproto and
libxkbcommon. This is **pre-existing, known repo state** -- `solaris-overlay`
says outright that "cmake is blocked on illumos (H26, -lkstat/-lsendfile)" and
the `git` recipe deliberately routes around cmake for that reason.
`libxkbcommon` pulls doxygen (verified with `nix-store -q --references` on its
drv), and doxygen is what drags in cmake.

**Shortest path next, in cost order:**

1. Run on a node whose store already holds the cmake/python3/xcb graph (the
   release-lineage build AMI does), or publish those 180 paths to the cache.
   Nothing else in the derivation is known to be wrong.
2. Or cut doxygen out of the libxkbcommon graph -- docs are not the deliverable
   on a port, and that drops cmake, python3, libxcb and xorgproto at once.
3. Only then port `cmake-minimal` (wire `extraSyslibs` in as the htop entry
   does, plus the recorded `-DCMAKE_RANLIB`/`-DCMAKE_STRIP` -> `true` cracks).

### 3. Four side blockers found and fixed on the way (all real)

* **A dead GNU mirror broke EVAL**, before any derivation goal existed.
  `ftpmirror.gnu.org` (first entry of `mirror://gnu`) serves a 502 nginx page;
  `ftp.gnu.org`, nluug and kernel.org all serve 200. `builtins.tryEval` cannot
  catch a `builtins.fetchurl` *download* failure (only `throw`/`assert`), so the
  shim's fallback loop never ran and eval died in `hello`'s `src` and
  `cosmic-term`'s `buildInputs`. Fixed with a `deadHosts` drop-filter in
  `artifacts/fan224-stage/fetchurl-shim-qmvlnvf0.nix` -- the same crack and same
  fix as the dead gnupg.org mirror in Wave 25, which had never been baked into
  the committed shim.
* **`library/mpfr` was not installed**, so the seed gawk could not run
  `substituteAll` and the cc setup-hook shipped **unsubstituted** placeholders:
  `export: NIX_@wrapperName@_TARGET_HOST_@suffixSalt@=1: not a valid identifier`.
  `oi-fleet-bootstrap.sh` documents this dep; `nixboot-only.sh` skips the `pkg`
  step, which suffices to *run* nix but not to *build* with it.
* **`rhash`** (a cmake dep) needs the dotted triple
  `--target=x86_64-pc-solaris2.11`, else `Checking for target OS ... UNKNOWN`.
  Recorded in Wave 25, never baked in; now in the overlay and verified to build.
* **`extraSyslibs` pointed at an unpublished tarball FOD**
  (`qbl2q3v2...-extra-syslibs.tar.gz`) that does not exist and cannot rebuild --
  exactly the documented `PS-FRED-STALE-EXTRASYSLIBS`. Rewritten as the
  canonical `runCommand` linking from `seedSyslibs` / `/lib/amd64` with
  loud-fail guards. **Necessary but not sufficient**: nothing wires it into
  `cmakeMinimal` (only `htop` consumes it), so the cmake link error is
  byte-identical before and after -- which is how we know it is unwired rather
  than wrong.

### 4. Independent confirmation of the vendor FOD

Rebuilt from scratch on a clean node and landed on the **identical** store path
recorded earlier,
`/nix/store/dwaq7qxcc1ya7srvrqib21c1vhsy5l32-cosmic-term-vendor-1.5.0`, 861
entries, `--check-validity` passing -- independently confirming
`vendorSha256 = sha256-xim0P0/kMCU6bLb65xmUzRMBepXdV2qyKchEb2Vfzy0=`. Measured
size on disk is **623 MB**, not the 1.34 GB claimed elsewhere in this document;
the entry count matches exactly, so the size figure is the one to distrust.

## Doing the next app (this is meant to be mechanical)

1. Pick the upstream tag. Fetch `Cargo.lock` from that tag and read the pins
   (`libcosmic` rev, `softbuffer` tag, `winit` tag, `wayland-backend` version).
   Do not assume they match `cosmic-term`'s.
2. Copy `cosmic-term.nix`, change `pname`/`version`/`tag`/`srcSha256`.
3. Set `vendorSha256 = ""`, build `-A <app>.vendor`, copy the reported hash in.
4. Build the app. For each error, add the illumos cut **with a guard** and quote
   the error next to it. The eight fixes above are likely to be a superset of
   what any single app needs; feature sets differ per app.
5. If the app's lockfile pins `wayland-backend` at a version whose file layout
   differs, the cfg rewrites in fixes 4-5 still apply -- they key on gate text,
   not line numbers.

Time cost measured for `cosmic-term`: vendoring is 33 s / 366 MB with a warm
cargo cache; the FOD is 1.34 GB in the store; a full crate compile on a 36-vCPU
`c5.9xlarge` is a few minutes.

## Honest list of what is still ad-hoc

* **Every app except `cosmic-term` is still ad-hoc.** The ~25-36 binaries in
  `docs/COSMIC-APPS-STATUS.md`, `cosmic-apps-wave*-paths.txt` and
  `cosmic-apps-waveB2-paths.txt` remain hand-run `cargo` output in `/root`
  checkouts. Nothing in this change makes them reproducible.
* **`smallvil`, the compositor substrate, is still ad-hoc** -- a prebuilt binary
  at `/root/cosmic-gcroots/waveB2-bin/smallvil`. It is the thing every app needs
  at runtime, and it is not packaged.
* **`scripts/solnix-cosmic-session.sh` still hardcodes prebuilt paths.** It
  should take store paths, but it was left alone rather than half-converted.
* **`cosmic-comp` remains out of scope** -- it is hard-coupled to DRM/GBM at
  compile time on illumos (`docs/cosmic-comp-illumos-finding.md`). Note that
  `cosmic-term` does **not** pull smithay at all (only
  `smithay-client-toolkit`), so the DRM wall is not in this app's graph.
* **Seven of the sixteen committed `rust-patches/*.patch` are prose notes, not
  appliable diffs** (zero real `@@` hunks): `softbuffer-illumos-posix-shm`,
  `calloop-wayland-source-illumos-timer-dispatch`,
  `cosmic-panel-illumos-embedded-server-timer-dispatch`,
  `smallvil-illumos-cascade-toplevels`, and all three
  `wayland-client-*-blocking-read-timeout`. The softbuffer one says so itself:
  "reconstruct the byte-exact diff ... from the node's vendored tree if a literal
  apply is needed". The knowledge is committed; the patches are not. This
  derivation re-expresses the softbuffer and wayland-backend ones as guarded
  `substituteInPlace` edits. The `wayland-client` poll-timeout and
  `calloop` timer-dispatch fixes are **not** re-expressed -- they were not needed
  to compile `cosmic-term`, and they are runtime fixes whose absence will show up
  as a hang, not a compile error. Expect to need them when the binary actually
  talks to a compositor.
* **The registry rows are not emitted** -- the app has no output path to record
  yet. The vendor FOD does, and it is listed above.
