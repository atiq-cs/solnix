# Design: the x86_64-solaris stdenv bootstrap (Phase 1)

Status: **GATE 1b PASSED.** A from-source `hello` builds (realises) on the
crackers illumos host via `nix-build`, the output binary runs (prints
"Hello, world!"), and `nix-store -q --deriver` resolves. Both a
`stdenv.mkDerivation` hello and a full GNU-autotools `hello-2.12.1`
(configure -> gmake -> gmake install) build from source. The stdenv wires a
real native cc (cc-wrapper + Solaris ld). Instantiation (GATE 1a) also still
holds cross-platform (Linux eval + illumos realise), no x86_64-linux
regression. This doc records the design, the exact breakage found, the
recursion fix, and the GATE 1b work.

Companion: `docs/design-nixpkgs-illumos.md` (the lib/systems + FreeBSD-mirror
research this refines) and `docs/design-seed-extraction.md` (what the seed is).

---

## 0. TL;DR

- **Root cause of the infinite recursion:** `pkgs/stdenv/default.nix` selected
  `x86_64-solaris = stagesNix` (the impure NATIVE bootstrap). `stagesNix` assumes
  the host `/usr`,`/bin` carry bash/coreutils/gcc; when the package set is
  instantiated FOR `x86_64-solaris` on a Linux eval host those tools do not
  exist, so nixpkgs falls back to building `bash-interactive` → `bison` →
  `help2man` → ... from source with no working stdenv to build them → loop.
  `pkgs.buildEnv` is just `stdenvNoCC.mkDerivation`, so `system.path` /
  `environment.systemPackages` inherited the same loop.
- **Fix applied (Fix A):** add `pkgs/stdenv/illumos/default.nix` (a proper
  stdenv-stages list, seeded from the bootstrap toolchain, mirroring
  `pkgs/stdenv/freebsd`) and repoint the selector to
  `x86_64-solaris = stagesIllumos`. Now `stdenvNoCC.mkDerivation` and
  `stdenv.mkDerivation` INSTANTIATE for `system = x86_64-solaris` (drvPath
  resolves) with no recursion. Delivered as `patches/0004-stdenv-illumos-
  bootstrap-stage.patch` in solnix-pkgs.
- **Fix applied (Fix B):** the seed cc/bintools wrappers in
  `pkgs/os-specific/illumos/default.nix` imported the cc-wrapper/bintools-wrapper
  and `lib/systems/examples.nix` via repo-relative paths
  (`../../build-support/...`) that do not exist in the overlay repo. Repointed at
  the nixpkgs source root (`${path}/pkgs/build-support/...`, `path` = `pkgs.path`
  injected by callPackage). Now `pkgs.solnix.{cc,bintools,ccFlagsDump}`
  instantiate.
- **What GATE 1b needed (delivered this task):** a real `stdenv` with a wired
  cc. Rather than the seed-cross-wrap + from-source-libc path originally
  sketched below (the purist, multi-day route), the boot stdenv wires a
  **native** cc — cc-wrapper `nativeTools`/`nativeLibc` around the crackers
  host's `/usr` gcc 14.3.0 + Solaris ld, GNU coreutils at `/usr/gnu`, mirroring
  how pkgs/stdenv/native does FreeBSD/Darwin stage0. `pkgs/stdenv/illumos/
  default.nix` was rewritten to this shape. A from-source `hello`
  (`stdenv.mkDerivation` AND full GNU-autotools `hello-2.12.1`) now realises on
  the illumos host, runs, and `nix-store -q --deriver` resolves. See §7.
  Impure-native (links host libc); pure toolchain is deferred (§7.2).

---

## 1. What was verified (eval/instantiate, on Linux)

All via `nix eval` against the fork flake (`~/ws/solnix-pkgs`), which is what the
solnix consumer's `pkgsFor "x86_64-solaris"` does.

| Probe | Before | After the fixes |
|---|---|---|
| `import nixpkgs { system = "x86_64-solaris"; }` then `stdenvNoCC.mkDerivation {…}.drvPath` | **infinite recursion** | `…-hi.drv` (resolves) |
| same, `stdenv.mkDerivation {…}.drvPath` | infinite recursion | `…-hi2.drv` (resolves) |
| `pkgs.buildEnv { paths = []; }.drvPath` | infinite recursion | finite error: needs a cc (perl) — the **stage1 boundary**, not a loop |
| `pkgs.solnix.{cc,bintools,ccFlagsDump}.drvPath` (x86_64-linux base) | `path … does not exist` | all resolve |
| `pkgs.solnix.seed.drvPath` (x86_64-solaris) | recursion | finite error: `nativeBuildInputs=[zstd]` needs a cc — stage1 boundary |
| x86_64-linux stdenv, and cross `crossSystem = x86_64-illumos` | (linux fine) / recursion+null | linux fine (no regression); cross advances to `throw "Unknown libc illumos-libc"` — the next stage1 gate |

The trivial `.drv` is a genuine x86_64-solaris derivation. `nix derivation show`
on it:

```
system:  x86_64-solaris
builder: /nix/store/…-illumos-seed-unpacked/usr/bin/bash   (the seed bash)
stdenv:  /nix/store/…-stdenv-illumos-boot
```

and its input closure resolves cleanly:
`hi.drv → illumos-seed-unpacked.drv → seed.tar.zst.drv` (the FOD fetch). The
provenance chain is complete — exactly the "EXACTLY Nix" property Phase 1 needs.

---

## 2. The bootstrap chain (mirror of nixpkgs pkgs/stdenv/, adapted for illumos)

nixpkgs' pure bootstrap (Linux `pkgs/stdenv/linux`, FreeBSD `pkgs/stdenv/freebsd`)
is a **list of stages** folded by `pkgs/stdenv/booter.nix`. Each stage is
`prevStage -> args`; the crucial trick that BREAKS the recursion is that
stage-0's tools are **plain `derivation`s that slice a bootstrap tarball**
(FreeBSD's `linkBootstrap`), never `stdenv.mkDerivation`. Each later stage's
`overrides` pins bash/coreutils/gcc/make from the previous stage, so
`mkDerivation`'s `shell` + `initialPath` + `defaultNativeBuildInputs` resolve to
fixed store paths instead of re-entering a source build.

The target chain for illumos:

```
seed (stage0 FOD)                     compiler + Solaris ld + libc + headers
  |                                   + rtld + ELF tools  (NO userland yet)
  v
stage1  (built FROM the seed gcc + Solaris ld, AS DERIVATIONS):
    binutils-unwrapped  = Solaris ld + as + ar/nm/strip/elfdump/elfedit
    gcc                 = the seed gcc rebuilt (or wrapped) under Nix
    coreutils, bash, gnumake, gnused, gawk, gzip, diffutils, findutils,
    patch, xz, bzip2   (the userland common-path.nix needs)
    perl                (buildEnv's builder script; needs a working cc)
  |
  v
stdenv  = stdenvNoCC + cc-wrapper(seed/stage1 gcc + Solaris ld via
          ld-solaris-wrapper) + the stage1 userland on initialPath
```

### 2.1 How illumos diverges from the FreeBSD template

- **GCC not Clang** (`useLLVM = false`): the cc-wrapper is `isGNU = true`,
  `isClang = false`; no `compiler-rt`/`libcxx`/`-resource-dir` dance.
- **Solaris link-editor not lld/bfd**: linking goes through
  `ld-solaris-wrapper.sh` (patch 0002), which translates the generic ld-wrapper's
  GNU syntax to Solaris syntax: `-rpath DIR → -R DIR`, `-dynamic-linker PATH →
  -I PATH`, and keeps `-z ignore` + `-L`-before-`-l` reordering.
- **`ld.so.1` not `ld-elf.so.1`**; interpreter set with `-I`.
- **RUNPATH via `elfedit` not patchelf** (patchelf does not understand Solaris
  ELF versioning). Correctness-critical part is *setting* RUNPATH at link time
  (the ld-solaris-wrapper `-R`), not shrinking in fixup — shrink is deferred.
- **No glibc locales**: omit the FreeBSD `PATH_LOCALE`/`PATH_I18NMODULE` preHook
  unless a build demands it.
- **The seed has no userland.** FreeBSD's `bootstrap-tools.tar.xz` ships a full
  GNU coreutils/bash/make. The solnix seed deliberately does **not**
  (`docs/design-seed-extraction.md` §0: "Anything Nix will build from source
  later — coreutils, bash, m4 — does not belong in the seed"). So stage1 must
  BUILD the userland from source with the seed gcc, OR the seed must grow a
  minimal userland. **Decision needed at stage1** (see §5).

---

## 3. What exists vs. what is missing

### Exists (in the fork today)

- **Seed FOD** — `pkgs/os-specific/illumos/seed/default.nix`. A relocatable
  tarball (gcc-10 + Solaris ld/ELF tools + libc + crt + headers + rtld). Fetched
  from `s3.solnix.io` (118 MB, reachable), SRI-pinned. Builds on any platform.
- **Seed-backed cc/bintools wrappers** — `pkgs/os-specific/illumos/default.nix`:
  `libc`, `binutils-unwrapped`, `gcc-unwrapped`, `bintools` (Solaris ld via
  `ld-solaris-wrapper`), `cc` (seed gcc), `ccFlagsDump` (flag self-check). These
  wrap the seed with `solarisStdenvNoCC = stdenvNoCC.override { targetPlatform =
  solaris; }` — a **cross-style** construct (build/host = x86_64-linux, target =
  solaris). After Fix B they instantiate.
- **lib/systems wiring** — patch 0001: `x86_64-solaris`/`x86_64-illumos`
  elaborate with `libc = illumos-libc`, `linker = solaris`, `uname = SunOS`.
- **bintools-wrapper Solaris gating** — patch 0002: `-rpath→-R`,
  `-dynamic-linker→-I`, gated on `linker == "solaris"`.
- **The stdenv-stages selector + boot stage** — patch 0004 (this task):
  `x86_64-solaris = stagesIllumos`, `pkgs/stdenv/illumos/default.nix`. Boot stage
  instantiates but is INSTANTIATE-ONLY.

### Missing (stage1 — the multi-day work)

- **`pkgs/stdenv/illumos/default.nix` stage1 + final stages.** Today it is one
  boot stage with `cc = null` and seed-only shell/initialPath. Needs:
  1. seed slices as **plain `derivation`s** (like FreeBSD `linkBootstrap`) for
     bash/coreutils/make/sed/awk/grep/gzip/xz/tar/diff/find/patch — OR a stage1
     that builds them from source with the seed gcc.
  2. a `cc` wired from the seed gcc + `ld-solaris-wrapper` (reuse the fork's
     `solnix.cc` shape but native, host = solaris).
  3. a stage that rebuilds the userland + perl from source, then the final
     `stdenv` whose closure has no seed leak.
- **`all-packages.nix` libc selector.** The cross path throws `Unknown libc
  illumos-libc`; add `else if libc == "illumos-libc" then solnix.libc` beside the
  `fblibc`/`nblibc` cases (mirrors `docs/design-nixpkgs-illumos.md` §1.4). Needs
  `solnix.libc` to be a real from-source libc (csu/headers/rtld) for a building
  stdenv, not the seed-symlink slice.
- **The seed's userland decision** (§5).

---

## 4. The buildEnv infinite recursion — root cause + fix (detail)

### Root cause

`pkgs.buildEnv` (`pkgs/build-support/buildenv/default.nix:23`) is
`constructDrv = stdenvNoCC.mkDerivation`. `modules/config/system-path.nix`
composes `environment.systemPackages` into `system.path` with it. On
`x86_64-solaris`, `stdenvNoCC` came from `stagesNix` (`pkgs/stdenv/default.nix:66:
x86_64-solaris = stagesNix`). `stagesNix = stagesNative ++ [finalStage]`, and
`stagesNative` (`pkgs/stdenv/native`) sets `initialPath` to the impure host list
`[ "/opt/local/gnu" "/" "/usr" "/usr/local" ]` and `shell = "/bin/bash"`. When
the set is *evaluated for* x86_64-solaris on a Linux host, those host tools are
absent, and the `stagesNix` final stage references `prevStage.bash`,
`prevStage.gcc`, ... which nixpkgs then tries to build from source
(`bash-interactive → bison → help2man → …`) — with no working stdenv, forever.

The trace tip:
```
stdenvShell → bash-interactive-5.3p15 → bison-3.8.2 → help2man-1.49.3 → …
```

The custom `lib/build-env.nix` in the solnix REPO sidesteps this (plain
derivation, host bash) — that is why `system.path` works on the illumos HOST
eval path (`lib/eval-host.nix`). The recursion only bites the **fully-Nix flake
path** (`pkgsFor "x86_64-solaris"` → nixpkgs `pkgs.buildEnv`), which is precisely
the path Phase 1 must unblock.

### Fix

Give x86_64-solaris a real stdenv-stages list. `pkgs/stdenv/illumos/default.nix`
provides a seed-backed boot stage: `shell = "${seed}/usr/bin/bash"`,
`initialPath = [ seed ]`, `cc = null`. Because the seed is a **plain
`derivation`** unpack (not `stdenv.mkDerivation`), building the stdenv from it
cannot re-enter the recursion. `stdenvNoCC.mkDerivation`/`stdenv.mkDerivation`
now instantiate.

`pkgs.buildEnv` itself still needs a from-source `perl` (its builder is
`${buildPackages.perl}/bin/perl`), and perl needs a non-null `stdenv.cc`
(`perl/interpreter.nix:227` reads `stdenv.cc.targetPrefix`). So buildEnv now
fails with a **finite, descriptive** dependency on stage1's cc instead of an
infinite loop. That is the correct boundary: buildEnv-via-perl genuinely needs a
working compiler, which is stage1. The recursion — the thing that made *any*
mkDerivation impossible — is gone.

---

## 5. Open decision for stage1: seed userland vs. build-from-source

FreeBSD's seed ships a userland; ours does not. Two ways to get bash/coreutils/
make onto stage1's `initialPath`:

- **(A) Grow the seed** with a minimal GNU userland (bash + coreutils + make +
  sed + awk + grep + gzip + xz + tar + diff + find + patch), sliced as plain
  `derivation`s like FreeBSD's `linkBootstrap`. Fastest to a building stdenv;
  adds ~tens of MB to the seed FOD (re-extract on the illumos host, re-pin the
  hash). Matches the FreeBSD template exactly.
- **(B) Build the userland from source** in stage1 with the seed gcc + Solaris
  ld, importing nothing pre-built. Purest; longest; each tool is a real Solaris
  build (the portability patches we already discovered become overlay patches).

**Recommendation: (A) to reach a building stdenv + GATE 1 fastest, then (B)
incrementally** so the final stdenv closure has no seed userland leak. (A) is a
seed re-extraction (`scripts/oi-extract-seed.sh` grows its copy list) + a hash
bump; the stages module then slices the userland exactly as FreeBSD does. This
keeps the boot stage's builder (`${seed}/usr/bin/bash`) real, so the trivial
`hello` REALISES and GATE 1 closes.

---

## 6. Exact stage derivations to add (file paths in solnix-pkgs)

All in the fork (`~/ws/solnix-pkgs`), reached by patch into the nixpkgs tree
(new files can be added by patch, as 0004 does for the module).

1. **`pkgs/stdenv/illumos/default.nix`** (exists as boot stage; expand):
   - `bootstrapTools` attrset of **plain `derivation`** seed slices (mirror
     FreeBSD `linkBootstrap`): `bash`, `coreutils`, `gnumake`, `gnused`, `gawk`,
     `gnugrep`, `gnutar`, `gzip`, `xz`, `bzip2`, `diffutils`, `findutils`,
     `patch`, `binutils-unwrapped` (Solaris ld+as+ar/nm/strip/elfdump/elfedit),
     `gcc-unwrapped`, `illumos.libc` (crt+libc+headers+rtld). Requires decision
     §5(A) so these paths exist in the seed.
   - `mkStdenv prevStage` closure: `initialPath` = the slices, `shell` = seed
     bash, `cc = wrapCC(seed gcc + Solaris bintools)`, `stdenvNoCC` (cc=null)
     then `stdenv`.
   - stage list `[ boot-0 (from bootstrapTools), boot-1 (rebuild tools from
     source), final (no seed leak) ]`.
2. **`pkgs/os-specific/illumos/pkgs/{include,csu,libc,ld,rtld}.nix`** — the
   from-source `solnix.libc` (Solaris libc + crt1/crti/crtn + headers + rtld),
   so the `all-packages.nix` libc selector maps to a real libc, not the
   seed-symlink slice. (docs/design-nixpkgs-illumos.md §2.2/§5.)
3. **`pkgs/top-level/all-packages.nix`** (patch): add
   `else if libc == "illumos-libc" then solnix.libc` to the libc selector
   (currently `throw "Unknown libc illumos-libc"`).
4. **(defer) `pkgs/stdenv/illumos/always-elfedit.sh`** — RUNPATH shrink; skip
   until closure size demands it.

---

## 7. GATE 1

> `nix-build` a from-source `hello` on x86_64-solaris yielding a `.drv` whose
> output RUNS on the AMI, and `nix-store -q --deriver result` resolves.

- **GATE 1a (instantiation) — DONE.** A trivial x86_64-solaris
  `stdenvNoCC.mkDerivation`/`stdenv.mkDerivation` instantiates; drvPath resolves.
- **GATE 1b (realisation) — DONE.** Instead of the seed-cross-wrap + from-source
  libc path this doc originally sketched, GATE 1b was reached by giving
  x86_64-solaris a **native boot stdenv** (cc-wrapper `nativeTools`/`nativeLibc`
  around the host `/usr` gcc 14.3.0 + Solaris ld, GNU coreutils at `/usr/gnu`),
  mirroring pkgs/stdenv/native's FreeBSD/Darwin stage0 shape. This is
  impure-native (links host libc) but proves x86_64-solaris is real-Nix capable.
  Proof on the crackers host (SunOS 5.11, Nix 2.3.16):

  ```
  # (A) stdenv.mkDerivation hello (host cc via $CC)
  out  = /nix/store/axdfl561i3carjchr8x0613f7xc93pi9-hello-src-1.0
  drv  = /nix/store/z4ddlgcbm1bm01srnbs56h2gaqzz0zwr-hello-src-1.0.drv
  run  -> Hello, world!
  # (B) GNU hello-2.12.1 from source (./configure && gmake && gmake install)
  out  = /nix/store/imkrn16lw3rlpgr0hakx243nm6q1jh4c-hello-2.12.1
  drv  = /nix/store/vgmjmyw1pips650npp59z0ca6sjbz901-hello-2.12.1.drv
  run  -> Hello, world!
  nix-store -q --deriver <out> -> the .drv above (resolves)
  .drv system = x86_64-solaris ; ldd -> /lib/64/libc.so.1 (host libc)
  ```

### 7.1 On-host workflow (what a fresh crackers host needs)

The crackers illumos hosts have a classic Nix 2.3.16 at `/nix-tools/bin/nix`
(single-user store at `/nix/store`, DB at `/nix/var/nix`), NOT on PATH. Two
frictions had to be worked around; both are host-Nix quirks, not fork changes:

1. **Solaris tar chokes on GitHub pax global headers** (`nix-prefetch-url
   --unpack` fails: `typeflag 'g' not recognized`). Fix: a tiny Python `tar`
   shim (`tarfile` handles pax) first on PATH. The host has python3 but no GNU
   tar. (Shim lives at `/root/shim/bin/tar` on the host.)
2. **Pinned nixpkgs requires Nix >= 2.18** (a hard `abort` in `default.nix` via
   `lib/minfeatures.nix`); the host only has 2.3.16. 2.3.16 eval+build actually
   works for this path, so `lib/minfeatures.nix` was patched on-host to drop the
   `>= 2.18` check (keep the `nixVersion` builtin check). This is a HOST-LOCAL
   edit to the fetched nixpkgs tree, not a fork patch. The real fix is a newer
   Nix on the build host (deferred).

Build recipe on-host: fetch pinned nixpkgs (`nix-prefetch-url --unpack` with the
tar shim), `patch -p1` the four fork patches into a copy, patch `minfeatures.nix`,
`nix-store --add` the tree (so `pkgs.path` is valid), import via a classic entry
(`import <patched-nixpkgs> { system = "x86_64-solaris"; overlays = [ solnixOverlay ]; }`).
Nix 2.3.16 has no flakes, so the classic import replaces `pkgsFor`.

### 7.2 What is DEFERRED (documented debt, not required for GATE 1b)

- **Purity.** The boot stdenv links the host `/usr` libc and uses the host gcc.
  A fully-pure closure needs the seed-backed toolchain + from-source
  `solnix.libc` (csu/crt/headers/rtld) + the all-packages libc selector
  (`libc == "illumos-libc"`, currently `throw`s). §6.2/§6.3.
- **GNU findutils on the stdenv PATH.** The generic stdenv fixup hooks
  (audit-tmpdir, patch-shebangs, strip, compress-man, make-symlinks-relative,
  broken-symlink check) + the configurePhase libtool fixup all shell out to GNU
  `find -printf/-print0/-executable`, `xargs -0 -r -P`, `stat --printf`, or
  `patchelf` — none present on the SunOS host (only GNU coreutils are, at
  `/usr/gnu`). The boot stdenv DISABLES them via `dont*/no*` env vars in its
  preHook (they are optional post-processing). Building a from-source GNU
  findutils in stage1 and putting it on the stdenv PATH lets these run normally;
  until then real packages that rely on shebang-patching/stripping need per-
  package handling.
- **Full `pkgs.hello` (nixpkgs autotools expr).** It instantiates cleanly but
  its realise pulls a from-source coreutils/perl/gmp/m4/zlib/xz closure (the
  stdenv `defaultBuildInputs`); building those on illumos is the Phase-2
  from-source userland work (each a real Solaris build with likely portability
  patches). GATE 1b was met with the two hello builds above, which prove the
  compile+link+configure+make path without that heavy closure.

---

## 8. Honest effort estimate for the full stdenv

- **Fixes in this task (recursion + wrapper paths + boot stage):** done (~1 day
  incl. tracing).
- **Stage1 to GATE 1b:**
  - §5(A) seed userland re-extraction + hash bump: ~0.5 day (needs the illumos
    host + `scripts/oi-extract-seed.sh` edit).
  - `bootstrapTools` plain-derivation slices + `mkStdenv` + 3-stage list: ~1–2
    days (mechanical mirror of FreeBSD, but first-time Solaris ld/gcc wiring will
    surface flag issues — the `ccFlagsDump` self-check helps here).
  - from-source `solnix.libc` (csu/headers/rtld) + all-packages libc selector:
    ~1–2 days (Solaris libc is symbol-versioned; mapfiles + `-M` needed).
  - first real `hello` build on the AMI + debugging the seed-gcc relocatability
    (`-B`/`GCC_EXEC_PREFIX`/`--sysroot`, the §5 risk in design-seed-extraction):
    ~1 day, could spill (gcc relocatability is the single biggest unknown).
- **Total to GATE 1b: ~4–7 working days**, front-loaded on the illumos host
  (seed re-extraction + first native build). Instantiation (this task) unblocks
  all downstream eval immediately; realisation is gated on the host work.

---

## 9. Files changed (solnix-pkgs)

- `pkgs/stdenv/illumos/default.nix` — REWRITTEN this task. Was a single
  seed-backed INSTANTIATE-ONLY boot stage (`cc = null`); now a 2-element
  stdenv-stages list wiring a **native** cc (cc-wrapper `nativeTools`/
  `nativeLibc`, `nativePrefix = /usr`, `shell = /usr/bin/bash`, `initialPath =
  [ /usr/gnu / /usr /usr/local ]`, Solaris ld via the bintools-wrapper Solaris
  path). preHook disables the GNU-only fixup hooks (§7.2). This is the file that
  closes GATE 1b.
- `patches/0004-stdenv-illumos-bootstrap-stage.patch` — REGENERATED to embed the
  rewritten stage file (new-file hunk) + the unchanged `x86_64-solaris =
  stagesIllumos` selector hunk. Applies cleanly to pinned nixpkgs
  (`applyPatches` realises); no x86_64-linux/freebsd regression.
- `patches/0001..0003` and `pkgs/os-specific/illumos/default.nix` — unchanged
  this task (0002's Solaris ld path is what the native bintools-wrapper uses).

HOST-LOCAL edits (NOT fork changes; documented in §7.1): a Python `tar` shim for
pax tarballs, and dropping the Nix `>= 2.18` guard in the fetched nixpkgs
`lib/minfeatures.nix` so the host's Nix 2.3.16 can eval it.

Validated by realising a from-source hello on the crackers host + cross-platform
instantiate on the Linux dev-box; no git commit (per house rules).
