# COSMIC build readiness — re-checked at HEAD `828b883`, 2026-10-12

> **Update 2026-10-12 (Rust 1.99 landed):** the Rust wall below has MOVED but not
> vanished. Re-measured at HEAD `828b883`:
>
> | wall (from the ba1b4e4 measurement) | status at 828b883 | evidence |
> |---|---|---|
> | 1. Rust unavailable (seed payload 404) | **LIFTED (toolchain)** | `docs/rust-illumos-bootstrap.md`: native `x86_64-unknown-illumos` **rustc/cargo 1.99.0** built FROM SOURCE and banked (`rust-1.99.0-stage` → `/nix/store/xp2sv9n9…`, NarHash `sha256-JH3xRNk/…`; wrapper `rust-illumos-1.99.0` → `/nix/store/mxn53s79…`). recipes.tsv carries the rows (committed `828b883`). Verified general-purpose: `cargo new`+build+run → native illumos ELF, `cargo add serde --features derive` (crates.io + a proc-macro) builds. **No longer seed-404-blocked.** |
> | 2. COSMIC app derivations not committed | **STILL OPEN** | `git ls-files \| grep -i cosmic` at `828b883` = only `modules/config/cosmic-desktop.nix`. `git log --all -- '**/cosmic-term.nix'` is **empty** — the app `.nix` were NEVER committed (not lost to a rewrite; never in git). `docs/cosmic-nixification.md`'s "build from the committed derivations" line is **stale/wrong** at this HEAD. |
> | 3. C deps not reachable from `mkPkgs` | **STILL OPEN** | `libxkbcommon` is defined in `pkgs/illumos/phase3/tranche-entry-224.nix:732` but that file is **not wired into** `pkgs/illumos/default.nix` or `lib/mkPkgs` — grep for `tranche-entry-224`/`phase3` in those finds nothing. So `mkPkgs.libxkbcommon`/`mesa`/`wayland` are still unreachable from a clean toplevel. |
> | 4. rust-overlay wiring (`rustPlatform` → the 1.99 wrapper) | **NOT in git** | `git grep -l rust-overlay -- '*.nix'` = none; the wrapper/overlay `.nix` live on build nodes (`docs/rust-illumos-bootstrap.md` §"Banking"). So even though 1.99 the *toolchain* is banked, nothing in the committed tree points `rustPlatform` at it. |
>
> **Honest verdict for "are the COSMIC apps buildable now against 1.99?":** the
> **toolchain** gate is cleared — Rust 1.99 builds general Rust (serde + proc-macros)
> on illumos today. But the apps are **NOT buildable from the committed tree** because
> the app derivations, the C-dep overlay wiring, and the rust-overlay are all
> uncommitted — the exact source-incompleteness the ba1b4e4 measurement named, and it
> has not been fixed. These are **missing-commit / wiring gaps, not capability gaps**:
> nothing illumos- or Rust-blocks them. The not-Rust-gated steps (1,2 below:
> re-commit the app `.nix`, wire the C deps into `mkPkgs`) could be done today and are
> now the *only* thing between a banked 1.99 and a `cosmic-term` build.
>
> **What a COSMIC-app build needs, in order, now that 1.99 is banked:**
> 1. Re-commit `pkgs/os-specific/illumos/cosmic/{cosmic-term,cosmic-files,cosmic-edit,cosmic-illumos-common,default}.nix` from the build nodes / `docs/cosmic-nixification.md` (not Rust-gated).
> 2. Wire the C deps (`libxkbcommon`, `wayland`, Mesa software stack incl. the new
>    `mesa-lavapipe-illumos` for wgpu-GL) into `mkPkgs` (not Rust-gated).
> 3. Point `rustPlatform` at the banked `rust-illumos-1.99.0` wrapper in a committed overlay.
> 4. Build `cosmic-term.vendor` (cargo) → `cosmic-term` (rustc) — now unblocked by (1-3).
>
> This stream (software-Vulkan) does NOT re-commit the COSMIC derivations (out of
> scope — a desktop-stream task), but it RECORDS that the single remaining COSMIC
> wall at this HEAD is committing what already builds on nodes, no longer the Rust seed.
> The claim surface stays exactly as `docs/graphics-claims-audit.md` requires: COSMIC
> *apps* under a software compositor over VNC; no hardware accel; the shell does not composite.

---

# COSMIC build readiness — measured at HEAD `ba1b4e4`, 2026-10-11

Can each piece of the COSMIC desktop be **built now** on a solnix host (dixi,
x86_64-illumos), and if not, exactly what blocks it? This is the honesty-bar
companion to `docs/graphics-claims-audit.md`: software-only, no hardware GPU,
no claim that COSMIC runs.

## Bottom line

**COSMIC is Rust-gated, and at this HEAD it is also source-incomplete.** Two
independent walls, measured on dixi:

1. **Rust is unavailable.** The cached seed wrapper
   `/nix/store/8daydacsqmkzi72zfa3dmi9pp98d6hmj-rust-illumos-1.97.1` realises
   (419-byte shell scripts), but its payload
   `/nix/store/q3r5dh1m5ylwkpd9w6jk6ivqd3m3ic05-rust-seed-stage` is **gone**
   (retired from cache.solnix.io). `rustc --version` and `cargo --version` both
   fail to exec:

   ```
   $ /nix/store/8daydacsqmkzi72zfa3dmi9pp98d6hmj…-rust-illumos-1.97.1/bin/rustc --version
   …/rust-illumos-1.97.1/bin/rustc[5]: exec:
     /nix/store/q3r5dh1m…-rust-seed-stage/bin/rustc: not found
   ```

   Every COSMIC application is a `rustPlatform.buildRustPackage` consuming a
   `cargo vendor` FOD (`docs/cosmic-nixification.md`), so **no COSMIC app build
   can run** until the seed payload is republished.

2. **The COSMIC app derivations are not committed at this HEAD.** The only
   git-tracked COSMIC `.nix` is `modules/config/cosmic-desktop.nix`. The
   `cosmic-term`/`cosmic-files`/`cosmic-edit` derivations described in
   `docs/cosmic-nixification.md` are **not in the tree** — they exist only on the
   build nodes that produced the binaries. Measured:
   `mkPkgs.cosmic-term` and `mkPkgs.solnix.cosmic-term` are **both absent**, so
   `solnix.desktop.cosmic.enable = true` (whose default `apps = [ pkgs.cosmic-term ]`)
   throws `attribute 'cosmic-term' missing`. The non-Rust C-library deps
   (`libxkbcommon`, `mesa`, `wayland`) are likewise **not reachable from
   `mkPkgs`** — they live in the uncommitted phase3 overlay fragments, not the
   clean package set a toplevel evaluates against.

So the only COSMIC thing buildable right now, without Rust and without a GPU, is
the **declarative module scaffolding** — and it is only a scaffold: it evaluates
cleanly but has no package set to install until (2) is fixed.

## Readiness table

| COSMIC component | needs Rust? | buildable now (no Rust, no GPU)? | blocker |
|---|---|---|---|
| `cosmic-desktop.nix` module (option surface: `enable`/`apps`/`compositor`/`waylandDisplay`) | no | **yes (evaluates)** | none for the option definitions; proven via the dixi toplevel eval, which pulls `module-list.nix`. But enabling it needs the app packages below. |
| `cosmic-desktop.nix` with `enable = true` | — | **no** | `apps` default `[ pkgs.cosmic-term ]` → `attribute 'cosmic-term' missing` (app derivations not committed; not in `mkPkgs`). |
| `cosmic-term` (derivation) | **yes** | no | Rust seed payload 404 (`rust-seed-stage` gone); AND the `.nix` is not committed at this HEAD. |
| `cosmic-files` (derivation) | **yes** | no | same as cosmic-term. |
| `cosmic-edit` (derivation) | **yes** | no | same as cosmic-term. |
| `cosmic-term.vendor` FOD (`cargo vendor --locked`) | **yes** | no | needs the seed `cargo` to vendor the ~860-crate graph; `cargo` cannot exec (payload 404). |
| libxkbcommon / libxcb / xorgproto (C deps of the apps) | no | **no (at this HEAD)** | real C derivations, but defined only in the uncommitted phase3 overlay fragments — not reachable from `mkPkgs`. Buildable in principle; not wired into the clean package set here. |
| Mesa llvmpipe/softpipe (software GL/EGL) | no | **no (at this HEAD)** | same: not in `mkPkgs`; software-only render path, no GPU needed, but not a committed derivation in this tree. |
| fonts / icons / `cosmic-icons` assets | no | **no (at this HEAD)** | not committed as derivations; the icon/asset set was hand-staged on build nodes. |
| `smallvil` (the working software compositor substrate) | yes (built with Rust) | no | prebuilt binary at `/root/cosmic-gcroots/.../smallvil`, **not packaged**; `compositor` is a string path by design. Rebuilding it needs Rust. |
| `cosmic-comp` (the real compositor) | yes | **no — does not compile on illumos at all** | hard-coupled to DRM/GBM; `rustix::ioctl::opcode` absent for `solarish` (`docs/cosmic-comp-illumos-finding.md`). Rust-gated *and* unported. |
| `cosmic-panel` (the shell panel) | yes | no | pins compositor-side `smithay 0.7.0` + a different `libcosmic` rev; `docs/cosmic-nixification.md` says STOP — the client-app recipe does not apply. Rust-gated + smithay/DRM work. |
| `rust-patches/*.patch`, `rust-targets/*.json` | n/a | **yes (committed source)** | these are Rust *source* patches / target specs, consumed by the app builds. They are in the tree now; they do not themselves build anything. |
| Running a COSMIC app against a live compositor (paint a window) | yes | **no** | no app has ever painted a window (`docs/cosmic-nixification.md`, "Verified vs not verified"); needs Rust + a compositor + a GPU-or-software render path. Out of scope here. |

## What unblocks when the Rust seed returns

The infra team is republishing `rust-seed-stage` store-correct (reply pending —
see `pkgs/illumos/default.nix` note and the standing infra report). When
`/nix/store/q3r5dh1m5ylwkpd9w6jk6ivqd3m3ic05-rust-seed-stage` is back and
`rustc --version` execs, the following become possible **in this cost order**,
and only then:

1. **Re-commit the COSMIC app derivations** (`pkgs/os-specific/illumos/cosmic/`:
   `cosmic-term.nix`, `cosmic-files.nix`, `cosmic-edit.nix`, the shared
   `cosmic-illumos-common.nix`, and `default.nix`). They are not in this tree;
   they must be restored from the build nodes / `docs/cosmic-nixification.md`
   before anything can reference `pkgs.cosmic-term`. **This is prerequisite to
   everything else and is NOT Rust-gated — it is a missing-commit, and worth
   doing now regardless of the seed.**
2. **Wire the non-Rust C deps into `mkPkgs`** (libxkbcommon, libxcb, xorgproto,
   Mesa software stack, fonts) so the clean package set a toplevel evaluates
   against can resolve them. Also not Rust-gated; also doable now.
3. **Build `cosmic-term.vendor`** (needs `cargo`) → **build `cosmic-term`**
   (needs `rustc`). The eight illumos source cuts in
   `docs/cosmic-nixification.md` are already a superset of what the three apps
   need.
4. **Enable `solnix.desktop.cosmic`** in a host config with real app packages;
   build the toplevel; it installs the apps + session env (still no compositor
   from a store path — `compositor` stays a string path; `smallvil` is unpackaged).
5. Everything past that (paint a window, the shell composites, a daily-driver
   desktop) is the D1–D8 gated-task ladder in `docs/graphics-claims-audit.md` and
   needs a software or hardware compositor + render path — **out of scope for
   "buildable now"**, and the audit is the honesty bar for what "runs" may claim.

Steps 1 and 2 above are the ones that are **not** Rust-gated and could be done
today; the whole app/vendor/enable chain (3–5) is strictly blocked on the seed.

## Negative control for the Rust claim

The wrapper realises and the scripts are present and executable, so the failure
is specifically the *missing payload*, not a missing wrapper:

```
$ ls /nix/store/8daydacsqmkzi72zfa3dmi9pp98d6hmj…-rust-illumos-1.97.1/bin
cargo  rustc  rustdoc            # present, -r-xr-xr-x, 419 bytes each
$ ls /nix/store/q3r5dh1m…-rust-seed-stage
ls: … No such file or directory  # the payload the wrappers exec — gone
```

If the seed is republished, the identical `rustc --version` invocation will exec
the payload instead of printing `exec: …: not found`. That is the one check that
flips when the blocker clears.
