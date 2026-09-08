# Nixifying the COSMIC desktop on x86_64-illumos

How COSMIC apps become **real Nix derivations** instead of `cargo` output in a
`/root` checkout, what each illumos fix is for, and what is still ad-hoc.

Status of this document: the pattern is proven end to end through compilation of
the full ~860-crate COSMIC/iced/winit/wayland graph, with a passing negative
control. One dependency (`libxkbcommon`) does not yet build on the node because
of a *tooling* bug unrelated to COSMIC; that blocker is named precisely in
"Where it stops" below. Read that section before believing anything else here.

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
| Vendor FOD builds, is content-addressed, has a real deriver | **VERIFIED** -- `/nix/store/dwaq7qxcc1ya7srvrqib21c1vhsy5l32-cosmic-term-vendor-1.5.0`, 861 entries, 1.34 GB |
| No hardcoded `/root/...` or `/nix/cosmic/...` path anywhere in the derivation | **VERIFIED** |
| The ~860-crate graph compiles (libcosmic, iced, winit, wayland, softbuffer, alacritty_terminal) | **VERIFIED** through the point described below |
| Negative control flips the check to FAIL | **VERIFIED** |
| Final `cosmic-term` binary produced | **NOT REACHED** -- see below |
| Binary is `ELFOSABI_SOLARIS` / `EM_AMD64` | **NOT VERIFIED** (no binary yet) |
| Binary runs / paints under smallvil | **NOT VERIFIED** (no binary yet) |

Do not report the last three as done. They are not.

## Where it stops, exactly

The remaining blocker is **not** in COSMIC and not in Rust. It is the bootstrap
Nix on the node:

```
Assertion failed: false, file src/libstore/build/derivation-goal.cc, line 306,
function outputsSubstitutionTried
```

Reproduced **6/6** attempts, deterministically, whenever the build needs a large
set of substituted paths -- which `libxkbcommon` triggers because it is a meson
package and pulls python3 (`mpdecimal`, `sqlite`, `libxml2`, `bzip2`, `xz`,
`libtool`). Characterisation done:

* It fires only in the **derivation** goal path. Realising bare store paths with
  `nix-store -r <path>` does not hit it, which is how the rust seed and the
  nixpkgs fork were staged successfully.
* It is not a signature problem. Adding `require-sigs = false` does not change
  it.
* The abort correlates with paths reported as `don't know how to build`
  (neither substitutable nor buildable), all of them python3 closure members.
* The obvious fix -- use the from-source `nix-2.24.15`, which has the relevant
  fixes -- **does not work on this AMI**: its RUNPATH wants
  `libcrypto.so.1.1` / `libssl.so.1.1`, and the AMI ships only openssl 1.0 and
  3. Rewriting the RUNPATH with `elfedit` gets `nix --version` to run but leaves
  those two sonames unresolved.

So the precise next step for whoever picks this up is: **get a working nix on
the node** (either build `nix-2.24.15` against the AMI's openssl 3, or bank a
tarball whose RUNPATH matches), then build `libxkbcommon`, then re-run
`nix-build -A cosmic-term`. No COSMIC-side work is known to remain before the
binary appears; every COSMIC-side error encountered so far has been fixed and
cleared.

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
