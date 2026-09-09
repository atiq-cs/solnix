# Nixifying the COSMIC desktop on x86_64-illumos

How COSMIC apps become **real Nix derivations** instead of `cargo` output in a
`/root` checkout, what each illumos fix is for, and what is still ad-hoc.

Status of this document: **`cosmic-term`, `cosmic-files` and `cosmic-edit` now
build from the committed derivations on a clean node, and the binaries are
genuine `ELFOSABI_SOLARIS` / `EM_AMD64` ELFs.** `cosmic-term` runs far enough to
print its own `--help`/`--version` text. Two blockers had to be cleared to get
there, neither of them in the COSMIC derivations and neither the one previously
named here -- see "What actually blocked the binary". Read "Verified vs not
verified" before believing anything else; in particular no app has yet been shown
to paint a window.

The previously-recorded blocker (`cmake-minimal` via doxygen) turned out **not to
be in this closure at all** -- see the correction below.

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
| Vendor FOD builds, is content-addressed, has a real deriver | **VERIFIED** -- `/nix/store/dwaq7qxcc1ya7srvrqib21c1vhsy5l32-cosmic-term-vendor-1.5.0`, 861 entries. Reproduced to the identical path on a **third** independent clean node |
| No hardcoded `/root/...` or `/nix/cosmic/...` path anywhere in the derivation | **VERIFIED** |
| The ~860-crate graph compiles | **VERIFIED** |
| Negative control flips the check to FAIL | **VERIFIED** |
| Final `cosmic-term` binary produced | **VERIFIED** -- `/nix/store/vn76gvljxp2hg8jh2pgp2sh1ljk3x508-cosmic-term-1.5.0`, `bin/.cosmic-term-wrapped` 130,943,216 bytes, `nix-build` rc 0 with substituters off. Deriver `sqx9fykqv41bjrbx61f36bb3vr5h5yw0-cosmic-term-1.5.0.drv` resolves |
| Binary is `ELFOSABI_SOLARIS` / `EM_AMD64` | **VERIFIED** -- see the ELF evidence below |
| `cosmic-term` starts and runs | **VERIFIED, NARROWLY** -- `--help` prints its real help text and `--version` prints `cosmic-term 1.5.0`, 8/8 runs from `env -i`. That is CLI-level only |
| `cosmic-files` / `cosmic-edit` binaries produced | **VERIFIED** -- `71arxr76hc50b9hssllrasr7vsdilrhx-cosmic-files-1.5.0`, `qawkccvvjw8wbnim7hl4vqvz0vy5k41d-cosmic-edit-1.5.0`, both rc 0, both `ELFOSABI_SOLARIS`/`EM_AMD64`/`ET_EXEC` |
| `cosmic-files` / `cosmic-edit` "run" | **WEAKER CLAIM** -- they exit rc 0 but print NOTHING: they do not implement `--version`/`--help`. "Starts and exits cleanly", not "prints its version". Do not upgrade this claim without evidence |
| Any app paints a window / talks to a compositor | **NOT VERIFIED** -- not attempted. No compositor was run on this node |
| The wayland-client / calloop runtime fixes work | **NOT VERIFIED** -- the bounded-poll edit is applied and guarded, but nothing exercised it |
| The `derivation-goal.cc:306` assertion is avoidable | **VERIFIED** -- `--option substitute false` |
| The assertion is fixed by a newer nix | **REFUTED** -- 2.24.15 (the aborting version) *contains* it |
| `cmake`/`doxygen` is what blocks the binary | **REFUTED** -- neither is in the closure at all. See below |

### The ELF evidence, verbatim

```
$ elfdump -e /nix/store/vn76gvljxp2hg8jh2pgp2sh1ljk3x508-cosmic-term-1.5.0/bin/.cosmic-term-wrapped
ELF Header
  ei_magic:   { 0x7f, E, L, F }
  ei_class:   ELFCLASS64          ei_data:       ELFDATA2LSB
  ei_osabi:   ELFOSABI_SOLARIS    ei_abiversion: EAV_SUNW_CURRENT
  e_machine:  EM_AMD64            e_version:     EV_CURRENT
  e_type:     ET_EXEC
```

`ldd` resolves 14 libraries with zero "not found". `NEEDED` is
`libxkbcommon.so.0 libsocket.so.1 librt.so.1 libpthread.so.1 libnsl.so.1
libumem.so.1 libgcc_s.so.1 libm.so.2 libc.so.1`.

**Negative control on the ELF check itself**: the same `elfdump -e` run on the
makeWrapper shell script beside it prints `invalid file type`. So the check can
report a non-match and is not vacuous.

### What actually blocked the binary (two things, neither previously named)

**1. A declared-but-unproducible `debug` output.** `tranche-entry-224.nix`'s
split-debug overlay declared a `debug` output for `ncurses` and `readline` and
hardcoded `OBJCOPY=/usr/gnu/bin/objcopy`. objcopy is **absent on a fresh base
AMI**, so the hook emitted nothing and nix failed the derivation with *failed to
produce output path for output 'debug'*. Both `-debug` paths are in
`cosmic-term`'s closure, so this blocked the entire graph for a reason unrelated
to COSMIC. Note `pkg install developer/gnu-binutils` is **rejected** on the
running BE by the 2025 `userland-incorporation`; it only installs after
`pkg update` **and a reboot into the new BE**. The fix is therefore an eval-time
gate: absent the tools, do not declare the output at all. Closure output paths
went 274 -> 272 with zero `-debug`, and `ncurses`/`readline` then built.
Requesting split-debug explicitly (`solnixRequireSplitDebug`, or
`SOLNIX_REQUIRE_SPLIT_DEBUG=1`) while the tools are missing now **throws at eval**
rather than skipping silently -- silent-skip is what caused this in the first
place.

**2. `-L/usr/lib/amd64` shadowing store libraries.** `bash-interactive` then
failed to link:

```
Undefined                       first referenced
 rl_full_quoting_desired             pcomplete.o
 rl_print_keybinding                 ./builtins/libbuiltins.a(bind.o)
 rl_macro_display_hook               bashline.o
 rl_completion_rewrite_hook          bashline.o
ld: fatal: symbol referencing errors. No output written to bash
```

Mechanism, observed: the stdenv-wide `fixAttrs` put `-L/lib/amd64
-L/usr/lib/amd64` in **`NIX_LDFLAGS`**, and the bintools setup-hook *appends*
each buildInput's `-L$dep/lib` to that same variable -- so the platform `-L` is
always **earlier** on the link line than every store dependency. ld takes the
first match, and `/usr/lib/amd64/libreadline.so.8` has **none** of those four
symbols while store `readline-8.3p3` has **all four** (`nm -g`, checked both
ways). Three-arm link control, same compiler and libraries, only `-L` order
differing:

| arm | order | result |
|---|---|---|
| A | platform `-L` first (the real build) | **rc 1**, fails on `rl_full_quoting_desired` |
| B | store `-L` first | rc 0 |
| C | platform without `/usr/lib/amd64` | rc 0 |

So the **order**, not the presence, is the cause. Fix: move that pair to
`NIX_LDFLAGS_AFTER`, which `ld-wrapper` emits strictly after both. `/usr/lib/amd64`
is **kept** -- `liblgrp` and `libz` live only there and the illumos rustc target
links `-llgrp`; of the 30 platform libs this port needs, only those two are
`/usr/lib/amd64`-only. Regression control: `cmakeMinimal` still builds rc 0, which
is the check that proves `NIX_LDFLAGS_AFTER` actually reaches ld (per
`docs/cmake-on-illumos.md`'s `nc2`, cmake *fails* `-lkstat`/`-lsendfile` without
that `-L`). About **13** libraries in `/usr/lib/amd64` are ones nix also builds
(`readline ncurses history z sqlite3 xml2 expat ffi pcre2-8 ssl crypto bz2 lzma`),
so this was a latent trap for all of them, not a COSMIC-specific bug.

### The runtime bug that made the binary abort

The first build produced a binary that **aborted immediately**:

```
memory allocation of 11 bytes failed
memory allocation of 24 bytes failed
```

on a 31 GB machine. The illumos rustc target links `-lumem`, so `libumem.so.1`
interposes malloc, and libumem's **default `sbrk` backend returns NULL** for the
first allocation in these large `ET_EXEC` Rust images; Rust converts a NULL
malloc into `rust_oom` -> `abort`. Observed with
`truss -u libumem::malloc,umem_alloc`:

```
-> libumem:malloc(0xb, ...)          # 0xb = 11 = strlen("libX11.so.6")
  -> libumem:umem_alloc(0x1b, ...)
  <- libumem:umem_alloc() = 0        # NULL
```

with **no failing syscall anywhere** in a full `truss`. The 11 bytes are just the
first `CString` tiny-xlib builds -- a red herring, not the cause. Measured, 8 runs
per arm, deterministic (no clustering to report because there is no variation):

| arm | result |
|---|---|
| default (libumem `sbrk`) | **0/8 pass** |
| `UMEM_OPTIONS=backend=mmap` | **8/8 pass** |
| explicit `UMEM_OPTIONS=backend=sbrk` | fails -- so it *is* the backend |
| `LD_PRELOAD_64=/lib/amd64/libc.so.1` | 8/8 pass -- bypasses libumem entirely |

Control that libumem is not simply broken here: `/usr/sbin/zpool` links it and
works, and `LD_PRELOAD_64=libumem.so.1` onto `/usr/bin/ls` gives rc 0. The
derivations now set `UMEM_OPTIONS=backend=mmap` via `makeWrapper --set-default`.
Verified with the control that matters, under `env -i`: **wrapped 8/8, inner
unwrapped binary 0/8**. The same control reproduces on `cosmic-files`, so this is
stack-wide.

**Honest limit:** *why* sbrk fails is **not** established. `brk(0)` returns an
address just past the 131 MB image and the subsequent `brk()` calls return
success, so a naive "brk is refused" story does **not** hold and is not asserted
here. What is established is which backend works and which does not.

### Correction: cmake/doxygen was never in this closure

This document previously said 60 of cosmic-term's 180 uncached paths "are the
cmake / doxygen / libxcb / xorgproto / python3 graph", which was then compressed
elsewhere into "cmake/doxygen blocks cosmic-term". Measured on a clean node:
cosmic-term's closure is **174 `.drv` / 274 output paths**, of which **36** are
cache-fetchable and **238** must be built locally -- and `grep -c 'cmake|doxygen'`
over the uncached list is **0**. `libxkbcommon`'s direct references are
bash/bison/libx11/libxcb/libxml2/meson/ninja/pkg-config/xkeyboard-config, with
**no doxygen**. The bulk of the uncached set is libxcb/xorgproto/python3 (python3
arrives via meson). The `cmakeMinimal`-from-source work is real and useful, but it
is **not** what unblocked this binary.

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

### 2. HISTORICAL: what was believed to block the binary (cache coverage)

**Superseded.** This section records the state before the binary existed; it is
kept because the cache-coverage point is still true and still worth acting on, but
it is **not** where the build stops any more. See "What actually blocked the
binary" above for the two real blockers (a declared-but-unproducible `debug`
output, and `-L/usr/lib/amd64` shadowing store libraries) and the ELF evidence for
the binary that now exists.

With the assertion avoided, the build walks into an unported dependency. Of
`cosmic-term`'s 339 closure output paths, **180 are in no cache** and must be
built locally, and **60 of those are the cmake / doxygen / libxcb / xorgproto /
python3 graph**. `cmake-minimal-4.3.4` then fails:

> ⚠️ **This sentence has been misread — including by a later brief of mine — as "the
> cmake/doxygen graph is the blocker."** It is not. A clean-node re-measurement
> (174 `.drv`, 274 output paths, 36 cache-fetchable, 238 local) found
> `grep -c 'cmake|doxygen'` over the uncached set = **0**: neither is in
> `cosmic-term`'s closure at all. `libxkbcommon-1.13.2`'s references are
> meson/ninja/bison/libxcb/libx11/libxml2/xkeyboard-config. So the bulk of that 60
> is **libxcb / xorgproto / python3**, and the `cmakeMinimal`-from-source win —
> though real and independently valuable — is **not** what unblocks `cosmic-term`.
> Compressing a mixed list into one component's name is how a figure becomes a
> wrong diagnosis. The actual standing blocker is **A1** below.


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

## The desktop closure, and the seam to the install media

`GRAPHICAL=1` in `scripts/oi-make-livecd.sh` layers a desktop closure onto the
live root, reading a list of store paths from `GFX_CLOSURE` (one path per line;
it `die`s if the file is absent, then tar-copies each entry into the live
`/nix/store`). That list is the seam, and it now exists for COSMIC:

```
scripts/gen-cosmic-closure.sh                 # generator
artifacts/cosmic-desktop-closure.txt          # 30 paths, all three apps

GRAPHICAL=1 GFX_CLOSURE=artifacts/cosmic-desktop-closure.txt scripts/oi-make-livecd.sh
```

Thirty paths cover all three apps (28 each -- they share nearly everything). No
`.drv` and no `-debug` entries leak in.

**Why this does not reuse `scripts/gen-gfx-closure.sh`:** that script walks the
ELF RUNPATH graph by hand because the *cross-built* store had an incomplete nix
DB `Refs` table (75 edges for 460 paths), making `nix-store -qR` useless there.
These COSMIC paths were built by nix **on** the host, so the DB reference graph is
real and `-qR` is both correct and complete. The generator still guards the
difference: if any root yields <= 1 path -- what an empty `Refs` table looks like --
it aborts rather than emitting a uselessly short list.

A sufficiency check resolved every `NEEDED` soname against **only** the listed
paths plus the base platform. With `libxkbcommon` deleted from the list as a
negative control the check reports the extra miss, so it can fail. It also
reports `libgcc_s.so.1`, which is a **limitation of the checker, not a gap**: that
library lives under `gcc-unwrapped/usr/gcc/10/lib/amd64`, which *is* a listed
path but is not one of the `lib/` or `lib/amd64/` directories the probe looks in,
and `oi-make-livecd.sh` already stages `libgcc_s`/`libstdc++` explicitly.

That check was itself nearly worthless on the first attempt: it used
`/usr/gnu/bin/awk`, which does not exist on this host, so the loop body never ran
and **both** arms reported zero missing. Same shape as the `stat -c %s` gate that
was always false. It only produced evidence after switching to `/usr/bin/nawk`.

## Selecting the desktop declaratively

`modules/config/cosmic-desktop.nix` (registered in `modules/module-list.nix`)
adds `solnix.desktop.cosmic.{enable,apps,compositor,waylandDisplay}`. Enabling it
appends the `cosmic-desktop` role, installs the app derivations, and exports
`ICED_BACKEND=tiny-skia` and `UMEM_OPTIONS=backend=mmap` session-wide (the same
two pins the wrappers set, repeated so a hand-launched binary in that session
gets them too).

`compositor` is a **string path, not a package**, deliberately: `smallvil` is
still an unpackaged prebuilt binary and `cosmic-comp` does not build on illumos
at all. Leaving it null installs the apps and warns that no session will start,
rather than implying a working desktop. **This module has never been booted.**

## Node setup this needs (all verified on a fresh `ami-014c4aaccd37b2356`)

```
nix 2.24.15 at /nix-tools224           (relocatable bootstrap tarball)
PATH=/nix-tools224/bin:/usr/gnu/bin:/usr/bin:/usr/sbin
NIX_CONF_DIR=/nix-tools224/etc/nix
LD_LIBRARY_PATH=/nix-tools224/runtime-lib     (REQUIRED)
HOME=/root
/dev/fd mounted AND in /etc/vfstab            (else every stdenv build dies on /dev/fd/63)
pkg install library/mpfr                      (else the seed gawk cannot run substituteAll)
TMPDIR on the big pool, NOT /tmp              (see below)
before each build: [ -d /homeless-shelter ] && find /homeless-shelter -delete
build with: nix-build ... --option substitute false
```

Two substrate traps measured here, both of which cost a build:

* **The root pool does not grow to match `--block-device-mappings`.** On this AMI
  the OS root is a 20 GiB `xvda` holding `rpool`; a 320 GiB volume attached as
  `/dev/sda1` arrives as a **separate, unused disk** (`c2t1d0`). `zpool online -e
  rpool` therefore does nothing, and `/nix` stays on 19 GiB. You must
  `zpool create` a pool on the extra disk and put `/nix` (and `TMPDIR`) there.
  Asking for "root >= 300 GiB" does **not** by itself give you a big `/nix`.
* **`/tmp` is a ~12.5 GB swap-backed tmpfs**, which a COSMIC Rust build tree
  exhausts (`No space left on device` writing tokio's `.rmeta`). Point `TMPDIR`
  and `--option build-dir` at a dataset on the big pool.

Also note `developer/gnu-binutils` (the source of `objcopy`) is **rejected on a
fresh AMI's running boot environment** by the 2025 `userland-incorporation`. It
only installs after `pkg update --accept` **and a reboot into the new BE**, so do
not plan work that assumes `objcopy` is one `pkg install` away -- see the
split-debug gate above, which exists exactly so this does not block the graph.

## Doing the next app (this is meant to be mechanical)

1. Pick the upstream tag. Fetch `Cargo.lock` from that tag and read the pins
   (`libcosmic` rev, `softbuffer` tag, `winit` tag, `wayland-backend` version).
   Do not assume they match `cosmic-term`'s. **If it pins `smithay` (not
   `smithay-client-toolkit`), STOP** -- that is the compositor-side crate and this
   recipe does not apply. `cosmic-panel` is in that category.
2. Add an entry to `cosmic/default.nix` calling `cosmic-illumos-common.nix` with
   `pname`/`version`/`srcSha256` and `vendorSha256 = ""`. (Copying
   `cosmic-term.nix` wholesale is no longer necessary -- it is kept as the
   documented reference, but the shared recipe is the one to extend.)
3. Build `-A <app>.vendor`; nix reports a hash mismatch against the empty hash,
   and the `got:` line is the real hash. Paste it in.
4. Build the app. For each error, add the illumos cut **with a guard** and quote
   the error next to it. The eight fixes above are likely to be a superset of
   what any single app needs; feature sets differ per app.
5. If the app's lockfile pins `wayland-backend` at a version whose file layout
   differs, the cfg rewrites in fixes 4-5 still apply -- they key on gate text,
   not line numbers. Verified across 0.3.15 and 0.3.16.

Measured doing exactly this for `cosmic-files` and `cosmic-edit`: both were pin-
for-pin identical to `cosmic-term` at `epoch-1.5.0`, so the eight cuts applied
unchanged and neither needed a new one. Two build-environment traps did bite,
both worth knowing:

* **`TMPDIR` must not be `/tmp`.** On this AMI `/tmp` is a ~12.5 GB swap-backed
  tmpfs, and `cosmic-files` died with `No space left on device` writing tokio's
  `.rmeta`. Put the build dir on the big pool (`TMPDIR=/bigtmp`,
  `--option build-dir`).
* **Do not wrap everything in `$out/bin`.** cargo installs a `<name>.d` depfile
  beside the binary, and makeWrapper dies on it: *Cannot wrap '.../cosmic-edit.d'
  because it is not an executable file*. The shared recipe now tests `-x` and
  skips `*.d` and already-wrapped files.

Time cost measured for `cosmic-term`: vendoring is 33 s / 366 MB with a warm
cargo cache; the FOD is 623 MB in the store; a full crate compile on a 36-vCPU
`c5.9xlarge` is a few minutes. On a 16-vCPU `c5.4xlarge` from a cold store the
whole first build (238 uncached closure paths from source, then the ~860 crates)
is a few hours; the second and third apps are ~15-25 minutes each once the
dependency graph is warm.

## Honest list of what is still ad-hoc

* **Three apps are derivations; the other ~22-33 are still ad-hoc.**
  `cosmic-term`, `cosmic-files` and `cosmic-edit` build from the committed tree.
  The rest of the binaries in `docs/COSMIC-APPS-STATUS.md`,
  `cosmic-apps-wave*-paths.txt` and `cosmic-apps-waveB2-paths.txt` remain hand-run
  `cargo` output in `/root` checkouts. Nothing here makes those reproducible.
* **`cosmic-panel` is NOT packaged, and that is a measurement, not an oversight.**
  Its `epoch-1.5.0` `Cargo.lock` pins `smithay 0.7.0`
  (`git+https://github.com/smithay/smithay?rev=f0992e7`) -- the *compositor-side*
  crate, which is hard-coupled to DRM/GBM on illumos. It also pins a **different**
  `libcosmic` rev (`20dfd7c2` vs `0ca1b784` for term/files/edit) and
  `wayland-backend` 0.3.15, so it would not cleanly share the recipe either. Do
  not add it without doing the smithay work first.
* **No app has been shown to paint anything.** All three build and start; none
  was run against a compositor. `cosmic-term` prints `--help`/`--version`;
  `cosmic-files` and `cosmic-edit` exit 0 while printing nothing, because they do
  not implement those flags. "Starts cleanly" is the whole claim.
* **`smallvil`, the compositor substrate, is still ad-hoc** -- a prebuilt binary
  at `/root/cosmic-gcroots/waveB2-bin/smallvil`. It is the thing every app needs
  at runtime, and it is not packaged. This is why
  `modules/config/cosmic-desktop.nix`'s `compositor` option is a **string path**
  rather than a package, and why enabling that module warns instead of pretending.
* **`scripts/solnix-cosmic-session.sh` still hardcodes prebuilt paths.** It
  should take store paths, but it was left alone rather than half-converted.
* **`modules/config/cosmic-desktop.nix` has never been booted.** It evaluates the
  options and wires the closure; no installed system has run it.
* **`cosmic-comp` remains out of scope** -- it is hard-coupled to DRM/GBM at
  compile time on illumos (`docs/cosmic-comp-illumos-finding.md`). Note that
  `cosmic-term` does **not** pull smithay at all (only
  `smithay-client-toolkit`), so the DRM wall is not in this app's graph.
* **Why libumem needs `backend=mmap` is still unexplained.** The workaround is
  measured and reliable (0/8 -> 8/8) but it removes a symptom; the underlying
  reason libumem's sbrk backend fails in these images is unknown, and any
  `posix_spawn`-style second-order effect is unexplored.
* **Seven of the sixteen committed `rust-patches/*.patch` are prose notes, not
  appliable diffs** (zero real `@@` hunks): `softbuffer-illumos-posix-shm`,
  `calloop-wayland-source-illumos-timer-dispatch`,
  `cosmic-panel-illumos-embedded-server-timer-dispatch`,
  `smallvil-illumos-cascade-toplevels`, and all three
  `wayland-client-*-blocking-read-timeout`. The knowledge is committed; the
  patches are not. The derivations re-express the softbuffer and wayland-backend
  ones, plus **now** the `wayland-client` bounded-poll fix, as guarded
  `substituteInPlace` edits. That last one is worth a warning to the next
  reader: the prose note writes the call as `poll(&mut fds, -1)`, but
  wayland-client 0.31.15's `blocking_read` actually reads
  `rustix::event::poll(&mut fds, None)` -- where `None` *is* the infinite
  timeout. An edit keyed on the note's literal string matches **nothing and
  silently does nothing**, which is precisely the trap these prose "patches"
  set. The guard caught it: the first build logged no success line, and the
  corrected version now prints `illumos wayland-client bounded-poll fix applied
  to vendor/wayland-client/src/conn.rs` and compiles (rc 0). **The edit is
  applied and compiles; it has still never been exercised against a
  compositor.**
  The **`calloop` timer-dispatch fix is still NOT re-expressed**: it is a
  structural change (a new struct field plus
  register/reregister/unregister/process_events arms) that no safe
  `substituteInPlace` can express. Its absence shows up as a **hang or a black
  frame against a live compositor**, never as a build error -- so expect to need
  it the moment an app actually talks to one.
* **The registry rows are not emitted** for the three app output paths.
