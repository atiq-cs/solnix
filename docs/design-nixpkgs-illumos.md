# Design: Adding `x86_64-illumos` to the nixpkgs fork

Status: design/research. No builds run. Cites concrete nixpkgs paths against the
checkout used for this analysis (a recent nixpkgs with FreeBSD stdenv support:
`lib/systems/*`, `pkgs/stdenv/freebsd`, `pkgs/os-specific/bsd`). Verify line
numbers against your pinned rev before editing; the *shape* is stable.

This document specifies exactly how to wire an illumos target into the nixpkgs
fork and bootstrap a native stdenv from a seed toolchain, mirroring how FreeBSD
(`x86_64-freebsd`) is done today. It maps directly to roadmap tasks **T1.1**
(platform tuple) and **T1.2/T1.3/T1.4** (`libc`, `ld`, `ld.so.1` derivations).

---

## 0. Key finding: nixpkgs already has partial Solaris support

Before writing anything, note that nixpkgs is **not a blank slate** for Solaris.
Legacy support exists and is load-bearing for our decision:

- `lib/systems/parse.nix` — `kernels.solaris = { execFormat = elf; families = {}; }`
  already exists (no `name` override → kernel name is `solaris`).
- `lib/systems/inspect.nix` — `isSunOS = { kernel = kernels.solaris; }`, and
  `isSunOS` is already a member of `isUnix`.
- `lib/systems/doubles.nix` — `"x86_64-solaris"` is already in the `all` list, and
  there is already an `illumos = filterDoubles predicates.isSunOS;` group.
- `lib/systems/default.nix` (`elaborate`) — `hasSharedLibraries` includes
  `isSunOS`; the `node.platform` map emits `sunos`. **But** the `uname.system`
  map has **no** solaris entry (returns `null`), and `libc`/`linker`/`useLLVM`
  have no Solaris branch (fall through to defaults).
- `pkgs/stdenv/default.nix` — `x86_64-solaris = stagesNix;` i.e. today it selects
  the *impure native* bootstrap (build on a Solaris host using host tools), not a
  pure Nix stdenv.
- `pkgs/build-support/bintools-wrapper/` — **`ld-solaris-wrapper.sh` already
  exists** and is wired in `default.nix` under
  `optionalString (targetPlatform.isSunOS && nativePrefix != "")`. It reorders
  `-L` before `-l` and injects `-z ignore`.
- `pkgs/development/compilers/gcc/common/configure-flags.nix` — an
  `isSunOS` block already sets `--with-gnu-as --without-gnu-ld` (GNU assembler +
  Solaris link-editor), `--enable-threads=posix`, `--enable-__cxa_atexit`, etc.
  `pkgs/development/compilers/gcc/default.nix` special-cases
  `x86_64-solaris` (`CC = "gcc -m64"`, `NIX_LDFLAGS = "-lm"`).

**Consequence:** most of the platform-tuple plumbing is already present under the
`solaris` kernel name. What is missing is (a) a *pure* stdenv path, (b) the
`pkgs.illumos.*` package set, (c) the runtime-linker / RUNPATH-via-`elfedit`
story, and (d) filling the `uname`/`libc`/`linker` gaps in `elaborate`.

---

## 1. Platform tuple / `lib/systems`

### 1.1 The tuple decision: reuse `solaris` kernel, expose `x86_64-solaris`

illumos identifies as SunOS 5.11, ELF, GNU triple `x86_64-pc-solaris2.11`. The
question is whether the Nix `system` should be `x86_64-solaris` (reusing the
existing `solaris` kernel) or a brand-new `x86_64-illumos` kernel.

**Recommendation: reuse the existing `solaris` kernel; the Nix double is
`x86_64-solaris`, config triple `x86_64-unknown-solaris2.11`.** Do **not** add a
new `illumos` kernel to `parse.nix`.

Justification:

1. The whole GNU/autotools/gcc/llvm world already understands `*-solaris2.11`.
   `config.guess`/`config.sub` normalize illumos to `solaris2.11`; gcc's machine
   description is `i386-pc-solaris2.11` / `x86_64-pc-solaris2.11`. A new `illumos`
   kernel string would be rejected by every upstream `configure` and force us to
   patch `config.sub` in hundreds of packages. illumos *is* SunOS 5.11 at the ABI
   and triple level.
2. nixpkgs already ships `kernels.solaris`, `isSunOS`, `x86_64-solaris`, the
   `ld-solaris-wrapper`, and gcc solaris flags. Reusing them means we *extend*
   working code instead of duplicating it.
3. The steering docs propose `x86_64-illumos` as the spelling, but
   `nix-conventions.md` explicitly says to "confirm the canonical tuple spelling
   against the nixpkgs `lib.systems` parser … decide once, in the nixpkgs fork,
   and document it here." This is that decision: **the canonical tuple is
   `x86_64-solaris`** (kernel `solaris`), because that is what the toolchain
   triple must be. We can still *brand* the distro "illumos" everywhere at the
   Nix-attribute level: the package set is `pkgs.illumos.*`, the stdenv stages
   file is `pkgs/stdenv/illumos`, and `predicates.isSunOS` is the platform test.

   If a human-facing `x86_64-illumos` alias is wanted for `nix build .#...`, add
   it as an **examples.nix entry** whose `config` is still the solaris triple (see
   1.5). That gives ergonomic naming without lying to autotools.

The `vendor` is `unknown` in nixpkgs style (`x86_64-unknown-solaris2.11`), not
`pc`. gcc accepts either; `unknown` matches nixpkgs' `mkSystemFromSkeleton`
default for non-Darwin/Windows.

The `2.11` suffix on the kernel matters: gcc/binutils use the solaris *version*
to gate features (e.g. `-z relax`, TLS, `-z type`). We encode it via the
`config` triple string (`solaris2.11`); `parse.nix` already strips the version
into `kernel.version` via `kernelName`/`removeAbiSuffix` handling, and
`tripleFromSystem` reassembles it. Verify `mkSystemFromString "x86_64-unknown-solaris2.11"`
parses to `kernel.name == "solaris"` with the version preserved — the `"3"`-part
skeleton branch already handles `cpu-vendor-os`, but **`solaris2.11` is a 4-token
string after the vendor** (`x86_64`, `unknown`, `solaris2.11`) so it hits the
3-component branch; that branch does not currently list a `hasPrefix "solaris"`
clause. See 1.3 for the required patch.

### 1.2 `parse.nix`

`kernels.solaris` already exists and is correct (ELF, empty families). **No
kernel change needed.** Optionally add a `name = "solaris"` for explicitness (it
already defaults to the attr name, so this is cosmetic).

One thing to verify/patch: `mkSkeletonFromList` (the `"3"` component branch) must
route `x86_64-unknown-solaris2.11` to `cpu-vendor-os`. Today the branch matches
`elemAt l 1 == "apple"` or a hardcoded list plus `hasPrefix "freebsd"/"netbsd"/
"openbsd"/"genode"/"wasm32"`. It does **not** list solaris. Because our middle
token is `unknown` (not `apple`) and the OS token is `solaris2.11` (not in the
list), parsing falls through to `throw "... ambiguous"`.

**Required addition** in `parse.nix`, `mkSkeletonFromList`, the 3-component
`cpu-vendor-os` predicate:

```nix
        else if
          elemAt l 1 == "apple"
          || elem (elemAt l 2) [ "redox" "mmixware" "ghcjs" "mingw32" ]
          || hasPrefix "freebsd" (elemAt l 2)
          || hasPrefix "netbsd" (elemAt l 2)
          || hasPrefix "openbsd" (elemAt l 2)
          || hasPrefix "solaris" (elemAt l 2)   # <-- ADD
          || hasPrefix "genode" (elemAt l 2)
          || hasPrefix "wasm32" (elemAt l 0)
```

And in `mkSystemFromSkeleton`, the `kernel = ...` selector already calls
`getKernel (removeAbiSuffix args.kernel)`; `removeAbiSuffix "solaris2.11"` keeps
`solaris2.11`, and `getKernel` does `kernels."solaris2.11"` → **miss**. So we
also need the kernel lookup to strip the version. The cleanest fix mirrors the
existing netbsd/darwin special-cases:

```nix
        kernel =
          if hasPrefix "darwin" args.kernel then getKernel "darwin"
          else if hasPrefix "netbsd" args.kernel then getKernel "netbsd"
          else if hasPrefix "solaris" args.kernel then getKernel "solaris"   # <-- ADD
          else getKernel (removeAbiSuffix args.kernel);
```

(Confirm whether upstream already handles `solaris2.11` via some existing path —
if `x86_64-solaris` alone parses today but `x86_64-unknown-solaris2.11` does not,
both patches above are needed. The bare `x86_64-solaris` double works because the
2-component branch sets `kernel = "solaris"` directly.)

`execFormats`, `kernelFamilies`: **no change.** illumos is ELF, and it belongs to
no shared kernel family (like `linux`, it has empty `families`). Do *not* invent a
`sysv`/`illumos` kernel family — nothing consumes it and it would be dead
flexibility.

### 1.3 `inspect.nix`

`isSunOS` already exists and is already in `isUnix`. **No change required.**

Optional ergonomic alias (only if you want `isIllumos` to read nicely in the
solnix modules): `isIllumos = isSunOS;` — but this is pure sugar; skip it unless
a caller demands it. The predicate the rest of nixpkgs keys on is `isSunOS`.

### 1.4 `default.nix` (`elaborate`) — fill the three gaps

Three attributes currently have no Solaris branch and must be filled or the
elaborated platform is subtly wrong:

**(a) `uname.system`** — currently returns `null` for solaris. Add:

```nix
        uname = {
          system = {
            linux = "Linux";
            # ... existing entries ...
            solaris = "SunOS";   # <-- ADD (uname -s on illumos is "SunOS")
          }.${final.parsed.kernel.name} or null;
          ...
        };
```

**(b) `libc`** — the big `if/else` chain has no `isSunOS` branch, so it falls to
`"native/impure"`. Add a branch naming our libc so downstream logic and the
cc-wrapper know what libc to expect:

```nix
        libc =
          # ... existing branches ...
          else if final.isSunOS then "illumos-libc"   # <-- ADD (Solaris libc, not glibc)
          else if final.isNetBSD then "nblibc"
          # ...
```

Pick the string `illumos-libc` (or `nlibc`, matching the BSD `nblibc`/`oblibc`
pattern). This string is only used as a tag; the actual libc derivation is
`pkgs.illumos.libc` wired into the stdenv (see §3). Grep for how `fblibc` is
consumed (`pkgs/os-specific/bsd/*/pkgs/libc`) and mirror.

**(c) `linker`** — currently falls to `"bfd"` for solaris. illumos uses the
Solaris link-editor, not GNU ld. Add:

```nix
        linker =
          if final.useLLVM or false then "lld"
          else if final.isDarwin then "cctools"
          else if final.isSunOS then "solaris"   # <-- ADD (Solaris ld / ld-solaris-wrapper)
          else "bfd";
```

Then the bintools-wrapper (§4) can key on `linker == "solaris"` instead of only
`isSunOS && nativePrefix != ""`.

**(d) `useLLVM`** — leave `false` for illumos. illumos-gate's primary toolchain
is **GCC** (illumos-gcc, ~gcc 10; *verify current version* per steering). Unlike
FreeBSD (`useLLVM = final.isFreeBSD || final.isOpenBSD`), we do **not** set
`useLLVM` for SunOS. Clang is only a shadow compiler upstream. This is the single
biggest divergence from the nixbsd model.

**(e) `libDir`** — currently `null` for non-Linux. illumos convention is 64-bit
libs in `.../lib/amd64` (or `lib/64` symlink) and 32-bit in `.../lib`. Since we
are 64-bit-only (i386 removed from illumos ~2018), set nothing special here
initially; store paths carry their own layout. Revisit only if a package hunts
for `lib64`. Deferred — add a Solaris `libDir` only when a package
demonstrably needs it.

### 1.5 `examples.nix` — the ergonomic cross target

Add a cross/native example so users and cross-tests can name the platform.
Mirror the BSD block:

```nix
  # illumos (SunOS 5.11). Kernel/triple is "solaris" for autotools compatibility;
  # branded "illumos" at the Nix layer.
  x86_64-illumos = {
    config = "x86_64-unknown-solaris2.11";
    # useLLVM stays false: illumos primary toolchain is GCC.
  };
```

Naming the *attribute* `x86_64-illumos` while the `config` stays solaris gives us
the branding we want without a fake triple. `crossSystem = lib.systems.examples.x86_64-illumos`
then Just Works for cross builds from Linux (roadmap P1.6).

### 1.6 `doubles.nix` / `flake-systems.nix`

`doubles.nix` already lists `"x86_64-solaris"` and defines the `illumos` group —
**no change** unless you want additional arches now. The steering doc wants the
tuples designed multi-arch from day one; if so, add (guarded, unwired to a real
toolchain) doubles under the illumos comment:

```nix
    # illumos (SunOS)
    "x86_64-solaris"
    # future arches (no toolchain wired yet — Phase 3/4):
    # "aarch64-solaris"
    # "sparcv9-solaris"   # note: cpuTypes has sparc64, not sparcv9; use sparc64-solaris
```

Note the SPARC caveat: `parse.nix` `cpuTypes` has `sparc64` (bits 64, bigEndian,
family sparc), **not** a `sparcv9`. The steering doc's `sparcv9-illumos` spelling
must become `sparc64-solaris` in Nix terms, or add a `sparcv9` cpuType alias.
Defer — Phase 4.

`flake-systems.nix` lists the systems the flake exposes package sets for. Add
`"x86_64-solaris"` **only when** the stdenv actually builds (otherwise `nix flake
show` on the fork tries to evaluate a broken stdenv). Gate this behind the stdenv
milestone.

---

## 2. How nixbsd/FreeBSD did it (reference to mirror)

FreeBSD support in nixpkgs is the closest analog to what we need. The pieces:

### 2.1 lib.systems

- `parse.nix`: `kernels.freebsd = { execFormat = elf; families = { bsd }; name = "freebsd"; }`
  plus `mkSkeletonFromList`/`mkSystemFromSkeleton` `hasPrefix "freebsd"` clauses.
- `inspect.nix`: `isFreeBSD`, membership in `isBSD`/`isUnix`.
- `doubles.nix`: `"x86_64-freebsd"` etc. in `all`, `freebsd = filterDoubles predicates.isFreeBSD;`.
- `default.nix` (`elaborate`): `uname.system.freebsd = "FreeBSD"`, `libc = "fblibc"`,
  `useLLVM = isFreeBSD || isOpenBSD`, `hasSharedLibraries` includes `isFreeBSD`,
  `node.platform` maps freebsd.
- `examples.nix`: `x86_64-freebsd = { config = "x86_64-unknown-freebsd"; useLLVM = true; };`

We do the equivalent, but almost all of it *already exists* for solaris (§0), so
our diff is much smaller. The one structural difference: FreeBSD is a `bsd` family
and uses LLVM; illumos is family-less and uses GCC.

### 2.2 The per-OS package set — the pattern to copy as `pkgs.illumos.*`

FreeBSD's fine-grained world lives in `pkgs/os-specific/bsd/freebsd/`:

- `default.nix` — a thin wrapper that calls `makeScopeWithSplicing'` with
  `generateSplicesForMkScope [ "freebsd" ]` (so `pkgs.freebsd.*` cross-splices
  correctly: `buildFreebsd` = the build-host variant). It reads `versions.json`
  for source pins and delegates to `package-set.nix`.
- `package-set.nix` — `self:` a scope built via
  `lib.packagesFromDirectoryRecursive { callPackage = self.callPackage; directory = ./pkgs; }`
  plus explicit `callPackage` wiring for the foundational, dependency-cycle-prone
  members: `csu` (C startup objects — crt1/crti/crtn), `include` (headers),
  `libc`, `libcMinimal`, `rtld-elf` (the runtime linker), `libelf`, `install`,
  `makeMinimal`, etc. The manual `callPackage`s exist precisely because these
  form a bootstrap cycle that `packagesFromDirectoryRecursive` cannot untangle.
- `pkgs/` — one file per component (`libc/package.nix`, `csu.nix`,
  `rtld-elf.nix`, `include/package.nix`, ...). Each builds a slice of
  `freebsd-src` using the shared `mkDerivation` + `bsd/setup-hook.sh` machinery.
- `lib/` — `freebsd-lib` version helper.
- `patches/<revision>/` — carried patches per source revision.
- Top-level wiring: `all-packages.nix` has `freebsd = callPackage ../os-specific/bsd/freebsd { };`
  and `bsdSetupHook = makeSetupHook { ... } ../os-specific/bsd/setup-hook.sh;`.

The BSD `setup-hook.sh` (`pkgs/os-specific/bsd/setup-hook.sh`) drives BSD-make
builds (`addMakeFlags`, `includesPhase`, `moveUsrDir`). **illumos does not use
BSD make — it uses `dmake`/`gmake` and the illumos-gate build system, so we do
NOT reuse this hook.** We write an `illumos/setup-hook.sh` tailored to
building slices of `illumos-gate` (see §5).

### 2.3 The stdenv stages — `pkgs/stdenv/freebsd/default.nix`

This is the load-bearing reference for §3. FreeBSD ships a **3-stage** pure
bootstrap driven by a downloaded `bootstrap-tools.tar.xz` seed:

- `bootstrap-files/x86_64-unknown-freebsd.nix` — pins two fetchurl blobs:
  `bootstrapTools` (the seed tarball) and `unpack` (a self-contained NAR with the
  `ld-elf.so.1` + bash + tar + xz needed to *unpack* the seed, since we can't
  assume host tools).
- `unpack-bootstrap-files.sh` — runs the seed's own `ld-elf.so.1` as the builder
  interpreter, untars, then **patchelfs** every binary/lib to point its
  interpreter + rpath at the unpacked store path, then string-scrubs stray
  `/nix/store` paths. (This is the exact step we must reimplement with `elfedit`,
  because there is no patchelf on illumos — see §3.4.)
- `default.nix` — defines `bootstrapTools` (a big attrset of `linkBootstrap`
  derivations that expose slices of the seed: `coreutils`, `binutils-unwrapped`,
  `llvmPackages.clang-unwrapped`, `freebsd.libc`, ...), then `mkStdenv` which
  assembles a `stdenvNoCC` + `stdenv` from a `prevStage`, then a **list of
  stages**: `freebsd-boot-0` (build libc/libcxx), `freebsd-boot-1` (build tools),
  `freebsd` (final). Each stage's `overrides` decides which packages come from
  the seed vs. get rebuilt.

The mechanism to internalize: **the seed provides just enough to build the first
real libc + compiler-driver-wrapped toolchain; each subsequent stage rebuilds
more from source until nothing from the seed leaks into the final closure.**

---

## 3. Stdenv bootstrap for illumos

### 3.1 Where our path diverges from both Linux and FreeBSD

- **Not Linux:** no glibc, no GNU ld default, patchelf unavailable at runtime on
  the target.
- **Not FreeBSD:** GCC not Clang (`useLLVM = false`); Solaris link-editor not
  lld/bfd; runtime linker `ld.so.1` not `ld-elf.so.1`; RUNPATH set with `-R` and
  edited with `elfedit` not patchelf; libc is Solaris libc with heavy symbol
  versioning, split historically into `libc`/`libsocket`/`libnsl`/`libresolv`.

We follow the **FreeBSD *structure*** (seed tarball → linkBootstrap slices →
staged `mkStdenv` list) but with GCC and illumos tooling in the slices.

### 3.2 What the seed must contain (produced by Phase 0 stage0)

Phase 0 (P0.1) builds illumos-gate the normal way on an illumos host and yields a
proto area. From that proto area we assemble a **`bootstrap-tools` tarball** whose
contents are the minimum to build a first pure libc + wrapped GCC under Nix. It
must include:

Runtime + libc:
- `lib/ld.so.1` (the runtime linker; illumos path is `/lib/64/ld.so.1` for 64-bit
  — capture both the 64-bit rtld and where the loader expects it).
- `lib/libc.so.1`, and the historically-split friends actually needed to link:
  `libsocket.so.1`, `libnsl.so.1`, `libresolv.so.2`, `libm.so.2`, `libpthread`
  (now a filter into libc), `librt`, `libmd`, `libmp`, `libkstat` (as needed).
- `usr/include/**` — the full libc + system header tree.
- C startup objects (the illumos `csu`): `crt1.o`, `crti.o`, `crtn.o`, `values-*.o`,
  and the gcc `crtbegin.o`/`crtend.o`.

Toolchain:
- The illumos link-editor `ld` (from `usr/src/cmd/sgs/ld`) plus its friends:
  `ld.so.1` support, `elfedit`, `elfdump`, `mcs`, `ar`, `nm`, `strip`, `size`.
- GNU `as` (illumos gcc uses GNU assembler — see gcc `--with-gnu-as`). Ship the
  `gas` from the gate's binutils.
- `gcc` (illumos-gcc ~10; *verify*), including its `cc1`, `cc1plus`, `libgcc`,
  `libstdc++`, and the internal `crtbegin/crtend`.
- CTF tools if we intend to reproduce kernel/CTF builds early: `ctfconvert`,
  `ctfmerge` (needed for `pkgs.illumos.sys`, T1.2 — can be deferred out of the
  *stdenv* seed and shipped only in the `illumos` scope).

Unpack helpers (mirroring FreeBSD's `unpack` NAR):
- A statically-resolvable `ld.so.1` + `bash` + `tar` + `xz` + `cp`/`mkdir`/`find`
  + **`elfedit`** so the unpack builder can run with `builder = ld.so.1` and no
  host dependency. (FreeBSD uses `patchelf` here; we substitute `elfedit`.)

Package the seed exactly like FreeBSD: two blobs.
- `bootstrap-tools.tar.xz` — the toolchain/libc tree.
- `unpack.nar.xz` — the tiny self-contained unpacker (ld.so.1 + bash + coreutils
  subset + tar + xz + elfedit).

Pin both via `import <nix/fetchurl.nix>` in
`pkgs/stdenv/illumos/bootstrap-files/x86_64-unknown-solaris2.11.nix`, byte-for-byte
mirroring `bootstrap-files/x86_64-unknown-freebsd.nix`.

### 3.3 Stage layout — `pkgs/stdenv/illumos/default.nix`

Copy `pkgs/stdenv/freebsd/default.nix` and adapt. Concretely:

1. `bootstrapFiles` default table:
   ```nix
   table = { x86_64-solaris = import ./bootstrap-files/x86_64-unknown-solaris2.11.nix; };
   ```
2. `bootstrapArchive` derivation: `builder = "${bootstrapFiles.unpack}/lib/ld.so.1";`
   (illumos rtld path), args `[ ".../bin/bash" ./unpack-bootstrap-files.sh ]`,
   `LD_LIBRARY_PATH = "${bootstrapFiles.unpack}/lib"`.
3. `linkBootstrap` — unchanged in spirit (symlink/copy slices out of the archive).
4. `bootstrapTools` attrset — replace FreeBSD slices with illumos ones. Notably:
   - Instead of `llvmPackages.clang-unwrapped`, expose `gcc-unwrapped` (the seed
     gcc: `bin/gcc`, `bin/g++`, `bin/cpp`, `libexec/gcc/**`, `lib/gcc/**`).
   - `binutils-unwrapped` → the Solaris `ld` + GNU `as` + `ar`/`nm`/`strip`/`ranlib`/
     `elfdump`/`elfedit`. (Keep the attr name `binutils-unwrapped` so the
     bintools-wrapper wiring matches, even though it is not GNU binutils.)
   - `illumos.libc` slice (analog of `freebsd.libc`): all the `lib*.so.*`, `crt*.o`,
     `usr/include`, matching the RTLD + csu list from §3.2.
   - coreutils/gnutar/gnumake/etc.: ship GNU coreutils/make/tar in the seed (the
     gate has `/usr/gnu/bin`), OR use illumos native tools. Prefer GNU coreutils in
     the seed to keep the setup.sh assumptions (GNU `install`, `readlink -f`,
     `cp --preserve`) intact — the generic stdenv setup.sh expects GNU behavior.
     This is a real fork point; ship GNU userland in the seed, revisit
     only if closure size forces native tools.
5. `mkStdenv` — same shape. Key deltas from FreeBSD:
   - Wrap **GCC** not clang: `cc = lib.makeOverridable (import ../../build-support/cc-wrapper) { ... isClang = false; cc = prevStage.gcc-unwrapped; ... }`.
   - No `compiler-rt`/`libcxx` bootstrap dance (that is LLVM-specific). Use the
     seed `libstdc++`/`libgcc`; drop `mkExtraBuildCommands`/`-resource-dir`.
   - `bintools` = `import ../../build-support/bintools-wrapper` with the Solaris
     `ld` (see §4).
   - `initialPath` — drop `patchelf`; add `elfedit`/`elfdump` (see §3.4).
   - `preHook` — set `PATH_LOCALE` if we ship illumos locales; otherwise omit.
6. Stage list — mirror `[ boot-0, boot-1, final ]`:
   - **stage0 (`illumos-boot-0`)**: everything from `bootstrapTools`. Goal: build
     the first pure `illumos.libc` and `csu` from `illumos-gate` source using the
     seed gcc + seed ld.
   - **stage1 (`illumos-boot-1`)**: rebuild the tools that get imported into the
     final stdenv (make, gcc if we rebuild it, etc.) against the stage0 libc.
   - **final (`illumos`)**: nothing from the seed leaks; `illumos.libc`, `ld`,
     `ld.so.1` all come from stage0/stage1 source builds.

7. Register in `pkgs/stdenv/default.nix`:
   ```nix
   stagesIllumos = import ./illumos args;
   ...
   x86_64-solaris = stagesIllumos;   # replaces `= stagesNix;`
   ```

### 3.4 RUNPATH without patchelf — the `elfedit` story (roadmap P0.3)

This is the single most novel piece. nixpkgs' Linux/FreeBSD bootstrap leans on
`patchelf` in two places we must replace:

1. **Seed unpack** (`unpack-bootstrap-files.sh`): FreeBSD does
   `patchelf --set-rpath --set-interpreter`. On illumos:
   - **Interpreter**: illumos binaries hardcode `/lib/ld.so.1` (or `/lib/64/ld.so.1`).
     We cannot relocate the store during unpack the way FreeBSD does with
     `--set-interpreter`, because the seed binaries were linked on a normal illumos
     with the absolute rtld path. Options:
     - (a) Rewrite the `.interp` with `elfedit -e 'dyn:runpath ...'`? No — `.interp`
       is not a dynamic entry. Use `elfedit -e 'dyn:...'` for RUNPATH but for the
       interpreter use `elfedit`'s `phdr` / `interp` command: `elfedit -e 'interp:interp /nix/store/.../lib/ld.so.1' file`.
       *Verify `elfedit` supports interp rewrite in the seed's illumos version.*
     - (b) Simpler: keep `/lib/ld.so.1` as the interpreter and provide it at that
       absolute path inside the build sandbox (bind, or a symlink farm). The pure
       stdenv can tolerate a fixed rtld path if the sandbox provides it, but this
       breaks purity guarantees. Prefer (a).
   - **RUNPATH**: `elfedit -e 'dyn:runpath /nix/store/.../lib' file` (or
     `dyn:rpath`). illumos honors both DT_RPATH and DT_RUNPATH; set DT_RUNPATH.
   - **String scrubbing** (the "scorch" loop in FreeBSD's unpack): keep as-is; it's
     plain `sed` on store paths and works regardless of ELF tooling.

2. **Fixup phase shrink-rpath** (`always-patchelf.sh` →
   `patchelf --shrink-rpath`): FreeBSD injects `always-patchelf.sh` as an
   `extraNativeBuildInputs` running `_FreeBSDPatchelfShrink`. On illumos we write
   `illumos/always-elfedit.sh` (or simply *skip shrink* — it's an optimization,
   not correctness). **Recommendation: skip rpath-shrinking initially.**
   Shrink-rpath is a closure-size optimization; add an elfedit-based
   shrinker only if RUNPATH bloat measurably hurts. The correctness-critical part
   is *setting* RUNPATH at link time (§4), not shrinking it in fixup.

3. **Standard stdenv fixup**: contrary to a common assumption, the *generic*
   `pkgs/stdenv/generic/setup.sh` does **not** call patchelf — patchelf's
   RUNPATH-shrink runs only via the setup-hook shipped by the `patchelf` package
   when it's in `nativeBuildInputs`. Since illumos stdenv won't include patchelf,
   nothing in the default fixup breaks. Good — smaller diff than feared.

The RUNPATH-at-link-time path (the one that matters) is handled in the
bintools-wrapper, §4.

### 3.5 Native vs cross

- **Native** (build on illumos host): the stage list above, selected by
  `x86_64-solaris = stagesIllumos` in `pkgs/stdenv/default.nix`.
- **Cross** (build the illumos world from a Linux builder, roadmap P1.6): uses the
  generic `pkgs/stdenv/cross/default.nix` path with `crossSystem =
  lib.systems.examples.x86_64-illumos`. This needs a **cross GCC targeting
  `x86_64-unknown-solaris2.11`** built on Linux, plus the illumos `libc`/headers/
  `csu`/`ld`/`ld.so.1` as the cross libc. Feasible because the gcc solaris config
  already exists; the sysroot is `pkgs.illumos.{libc,include}`. Do cross **after**
  native works — the seed makes native the shorter path. Note the steering doc's
  caveat: cross-*OS* building the *gate itself* is unsupported, but here we cross
  only the Nix-packaged slices with a Linux-hosted cross-gcc + illumos sysroot,
  which is a normal Nix cross scenario.

---

## 4. cc-wrapper / bintools-wrapper for the Solaris link-editor

### 4.1 What already exists

`pkgs/build-support/bintools-wrapper/default.nix` already special-cases Solaris:

```nix
      + optionalString (targetPlatform.isSunOS && nativePrefix != "") ''
        ldPath="${nativePrefix}/bin"
        exec="$ldPath/${targetPrefix}ld"
        wrap ld-solaris ${./ld-solaris-wrapper.sh}
      ''
```

and `ld-solaris-wrapper.sh` reorders `-L` before `-l` and adds `-z ignore`. This
was written for the old impure `x86_64-solaris = stagesNix` path. We extend/repair
it for the pure path.

### 4.2 The flag-syntax problem

The generic `ld-wrapper.sh` assumes GNU ld syntax:
- **RUNPATH**: it emits `-rpath <dir>` (GNU). Solaris ld uses **`-R <dir>`**
  (or `-rpath`? — modern illumos `ld` *does* accept `-rpath` as an alias for `-R`;
  **verify** against the pinned illumos-gate `usr/src/cmd/sgs/ld`). If `-rpath` is
  accepted, the generic rpath loop needs minimal change; if not, we translate.
- **Dynamic linker**: generic emits `-dynamic-linker <path>` when
  `NIX_DYNAMIC_LINKER` is set. Solaris ld has no `--dynamic-linker`; the
  interpreter is set via `-I <interp>` (`-I /nix/store/.../lib/ld.so.1`) or by
  linking against the right rtld. We must **not** emit `-dynamic-linker` for
  solaris; instead set `-I`.
- **`-z` options**: Solaris `-z` set differs (e.g. `-z ignore`, `-z lazyload`,
  `-z defs`, `-z text`, `-z now`). The existing wrapper already injects `-z ignore`.
- **Mapfiles**: versioning/scoping via `-M <mapfile>`. Not needed by the wrapper
  itself; individual `pkgs.illumos.*` derivations pass their own mapfiles.
- **`--as-needed`, `--build-id`, `--gc-sections`**: GNU-only; the wrapper's
  hardening flags (`add-hardening.sh`) must not leak GNU-only flags into solaris
  `ld`. Audit `hardeningLDFlags`.

### 4.3 Recommended approach

Two viable strategies; recommend **(A)** as the lazy-but-correct one:

**(A) Route all linking through the compiler driver (`gcc`), never invoke `ld`
directly, and let the ld-wrapper translate.** Extend the bintools-wrapper's
Solaris branch so the wrapped `ld`:
- sets the dynamic linker with `-I` not `-dynamic-linker`,
- passes RUNPATH as `-R` (translate the generic loop's `-rpath <dir>` to
  `-R <dir>` inside `ld-solaris-wrapper.sh`),
- keeps the `-z ignore` / `-L`-before-`-l` reordering already there.

Concretely, generalize `ld-solaris-wrapper.sh` to also rewrite rpath flags:

```sh
declare -a argsBefore=(-z ignore) argsAfter=()
while (( $# )); do
    case "$1" in
        -rpath)        argsAfter+=("-R" "$2"); shift ;;   # GNU -> Solaris
        --dynamic-linker) argsAfter+=("-I" "$2"); shift ;; # GNU -> Solaris
        -dynamic-linker)  argsAfter+=("-I" "$2"); shift ;;
        -L)   argsBefore+=("$1" "$2"); shift ;;
        -L?*) argsBefore+=("$1") ;;
        *)    argsAfter+=("$1") ;;
    esac
    shift
done
exec "@ld@" "${argsBefore[@]}" "${argsAfter[@]}"
```

and, in `bintools-wrapper/default.nix`, gate the Solaris ld-wrapper on
`targetPlatform.linker == "solaris"` (from the §1.4c change) rather than the
brittle `isSunOS && nativePrefix != ""`, and set:

```nix
  + optionalString targetPlatform.isSunOS ''
    # illumos: interpreter via -I, RUNPATH via -R; suppress -dynamic-linker
    touch $out/nix-support/no-dynamic-linker-flag
  ''
```

then in the wrapper's dynamic-linker section, skip writing
`nix-support/ld-set-dynamic-linker` for solaris (the interpreter is injected as
`-I` by the ld-solaris-wrapper reading `nix-support/dynamic-linker`).

**(B) A fully separate `ld-illumos-wrapper.sh`** replacing the generic
`ld-wrapper.sh` for solaris. More control, more code, more drift from upstream.
Reject unless (A)'s translation proves too leaky. Prefer (A); escalate
to (B) only if the generic ld-wrapper's rpath loop can't be made to emit
Solaris-consumable flags.

### 4.4 cc-wrapper

`pkgs/build-support/cc-wrapper/default.nix` is largely toolchain-agnostic; the
important settings for illumos:
- `isClang = false`, `isGNU = true` (drives which builtin cflags get added).
- The cc-wrapper adds `-Wl,-rpath` style flags via the bintools; ensure those
  reach `ld` as `-R` through the ld-solaris-wrapper (they route
  `-Wl,-rpath,X` → `ld -rpath X` → wrapper → `-R X`). Verify the `-Wl,` passthrough
  survives.
- Do **not** add clang `-resource-dir` / compiler-rt logic (that was FreeBSD-only).
- `add-hardening.sh` / `add-flags.sh`: audit for GNU-ld-only or clang-only flags
  that illumos gcc/ld reject (e.g. `-fno-plt`, `-z relro` is fine, `-z now` fine,
  but `-Wl,--build-id` / `-Wl,-z,noexecstack` — verify Solaris ld accepts
  `noexecstack`; it uses `-z nxstack`? *verify*). Add `NIX_HARDENING_ENABLE`
  filtering for solaris where a flag is unsupported.

### 4.5 How nixbsd handles BSD ld (for contrast)

FreeBSD/OpenBSD set `useLLVM = true` → `linker = "lld"`. lld speaks GNU-compatible
flags (`-rpath`, `--dynamic-linker`), so the *generic* `ld-wrapper.sh` works with
almost no changes; the FreeBSD stdenv just wires `bintools = llvmPackages.lld`
(or the seed `binutils-unwrapped`). NetBSD uses GNU binutils ld directly. **None
of the BSDs face our problem** because they all use GNU-flag-compatible linkers.
illumos is unique in shipping a non-GNU link-editor, which is exactly why the
`ld-solaris-wrapper.sh` already exists in-tree — we are reviving and completing
it, not inventing it.

---

## 5. Concrete file plan (ordered checklist)

Two repos: the **nixpkgs fork** (branch off a `staging`-like base since stdenv
changes force mass rebuild) and **solnix** (this repo). Ordered so each step is
testable before the next. Roadmap task tags in brackets.

### Phase 0 prerequisites (must exist before touching nixpkgs)
- [ ] **[P0.1]** illumos-gate proto area + toolchain produced on an illumos host.
- [ ] **[P0.2]** `nix` builds/runs on illumos (nix fork if needed).
- [ ] **[P0.3]** Prove `elfedit` can set DT_RUNPATH and interpreter to a
      `/nix/store` path on a test binary; `elfdump` confirms; binary runs. This
      validates §3.4 before committing to the seed design.

### nixpkgs fork — lib.systems (T1.1) — small, evaluate-only, no rebuild
- [ ] `lib/systems/parse.nix`: add `hasPrefix "solaris"` to the 3-component
      `cpu-vendor-os` branch of `mkSkeletonFromList`; add the `hasPrefix "solaris"`
      kernel selector to `mkSystemFromSkeleton`. (§1.2)
- [ ] `lib/systems/default.nix` (`elaborate`): add `solaris = "SunOS"` to
      `uname.system`; add `isSunOS` branches to `libc` (`"illumos-libc"`) and
      `linker` (`"solaris"`). Leave `useLLVM` false. (§1.4)
- [ ] `lib/systems/examples.nix`: add `x86_64-illumos = { config = "x86_64-unknown-solaris2.11"; };`. (§1.5)
- [ ] (optional) `lib/systems/doubles.nix`: keep `x86_64-solaris`; add commented
      future arches. (§1.6)
- [ ] **Test gate:** `nix-instantiate --eval -E 'with import ./lib; systems.elaborate
      systems.examples.x86_64-illumos'` resolves with `parsed.kernel.name == "solaris"`,
      correct `config`, `uname.system == "SunOS"`, `libc == "illumos-libc"`,
      `linker == "solaris"`.

### nixpkgs fork — bintools-wrapper (T1.3, Solaris ld) — mass rebuild
- [ ] `pkgs/build-support/bintools-wrapper/ld-solaris-wrapper.sh`: extend to
      translate `-rpath`→`-R` and `-dynamic-linker`/`--dynamic-linker`→`-I`. (§4.3)
- [ ] `pkgs/build-support/bintools-wrapper/default.nix`: gate the Solaris wrapper on
      `targetPlatform.linker == "solaris"`; suppress `-dynamic-linker` /
      `ld-set-dynamic-linker` for solaris. (§4.3)
- [ ] `pkgs/build-support/cc-wrapper/*`: audit `add-hardening.sh`/`add-flags.sh`
      for GNU-ld/clang-only flags unsupported by illumos gcc+ld; filter. (§4.4)

### nixpkgs fork — the seed + stdenv (T1.1 bootstrap) — mass rebuild
- [ ] `pkgs/stdenv/illumos/bootstrap-files/x86_64-unknown-solaris2.11.nix`: pin
      `bootstrapTools` + `unpack` blobs (fetchurl). (§3.2)
- [ ] `pkgs/stdenv/illumos/unpack-bootstrap-files.sh`: illumos version — builder is
      seed `ld.so.1`; use `elfedit` for interpreter + DT_RUNPATH; keep the `sed`
      store-path scrub. (§3.4)
- [ ] `pkgs/stdenv/illumos/default.nix`: copy FreeBSD's, swap clang→gcc-unwrapped,
      Solaris ld, illumos libc slices; 3-stage list. (§3.3)
- [ ] `pkgs/stdenv/illumos/setup-hook.sh` (only if slices need it — illumos-gate
      builds use `dmake`/`gmake`, not BSD make; write a minimal hook, do NOT reuse
      `os-specific/bsd/setup-hook.sh`). (§2.2)
- [ ] `pkgs/stdenv/default.nix`: `stagesIllumos = import ./illumos args;` and
      `x86_64-solaris = stagesIllumos;` (replacing `= stagesNix;`). (§3.3)
- [ ] (defer) `always-elfedit.sh` shrink — skip until closure size demands it. (§3.4)
- [ ] **Test gate:** `pkgs.stdenv` for `x86_64-solaris` builds a trivial derivation
      (hello-world C) that links against the store libc and runs on the illumos host.

### nixpkgs fork — `pkgs.illumos.*` world (T1.2/T1.4) — mass rebuild
- [ ] `pkgs/os-specific/illumos/default.nix`: `makeScopeWithSplicing'` +
      `generateSplicesForMkScope [ "illumos" ]` + `versions.json` (pin
      illumos-31d3d510d0 / OI Hipster 2025.06). Mirror `bsd/freebsd/default.nix`. (§2.2)
- [ ] `pkgs/os-specific/illumos/package-set.nix`: scope with
      `packagesFromDirectoryRecursive` + explicit `callPackage` for the cyclic
      foundational members. (§2.2)
- [ ] `pkgs/os-specific/illumos/pkgs/include/package.nix` — headers. **[T1.2]**
- [ ] `pkgs/os-specific/illumos/pkgs/csu.nix` — crt1/crti/crtn/values. **[T1.2]**
- [ ] `pkgs/os-specific/illumos/pkgs/libc/package.nix` — Solaris libc (+ split
      libsocket/libnsl/libresolv/libm). **[T1.2]**
- [ ] `pkgs/os-specific/illumos/pkgs/ld.nix` — the link-editor
      (`usr/src/cmd/sgs/ld`) + elfedit/elfdump/mcs. **[T1.3]**
- [ ] `pkgs/os-specific/illumos/pkgs/rtld.nix` — `ld.so.1`
      (`usr/src/cmd/sgs/rtld`). **[T1.4]**
- [ ] `pkgs/os-specific/illumos/pkgs/sys.nix` — kernel (`unix`+`genunix`), needs
      CTF tools in scope (`ctfconvert`/`ctfmerge`). **[T1.2]**
- [ ] `pkgs/os-specific/illumos/patches/<rev>/` — carried illumos-gate patches.
- [ ] `pkgs/top-level/all-packages.nix`: `illumos = callPackage ../os-specific/illumos { };`
      near the `freebsd = ...` line (~14388). (§2.2)
- [ ] (when stdenv is green) `lib/systems/flake-systems.nix`: add `"x86_64-solaris"`. (§1.6)
- [ ] **Test gate:** `pkgs.illumos.libc`, `.ld`, `.rtld` build from source; a
      hand-built derivation links against `pkgs.illumos.libc` with RUNPATH into the
      store and runs (roadmap Phase 0 gate, now reproduced through Nix).

### solnix repo
- [ ] `flake.nix`: input pin to the nixpkgs fork branch; overlay wiring.
- [ ] `overlays/`: expose the fork's `pkgs.illumos.*`.
- [ ] Update `nix-conventions.md` "Platform tuples" to record the decision:
      **canonical Nix system = `x86_64-solaris` (kernel `solaris`, triple
      `x86_64-unknown-solaris2.11`); `x86_64-illumos` is an `examples.nix` alias
      with the same config for ergonomics.**
- [ ] `docs/progress.md`: check off T1.1 when the lib.systems + stdenv gates pass.

---

## 6. Open questions / verify-before-relying

- **Does `x86_64-unknown-solaris2.11` parse today** without the §1.2 patches, or is
  the patch strictly required? Test with `mkSystemFromString`. (The bare
  `x86_64-solaris` double already parses via the 2-component branch.)
- **Does illumos `ld` accept `-rpath` as an alias for `-R`?** If yes, §4.3's
  translation shrinks further. Check pinned `usr/src/cmd/sgs/ld`.
- **Does the seed `elfedit` support rewriting the ELF interpreter (`.interp`)**, not
  just dynamic entries? If not, we need an alternate interpreter-relocation
  strategy in `unpack-bootstrap-files.sh` (§3.4).
- **Current illumos-gcc primary version** (steering says ~10, "verify"): pins the
  seed gcc and the `gcc-unwrapped` slice.
- **`-z nxstack` vs `-z noexecstack`** and other hardening-flag spellings for
  Solaris ld — audit before enabling hardening (§4.4).
- **GNU vs illumos coreutils in the seed**: recommended GNU for setup.sh
  compatibility; measure closure impact.
- **SPARC tuple**: Nix has `sparc64`, not `sparcv9`. `sparcv9-illumos` in the
  steering doc becomes `sparc64-solaris` (or add a `sparcv9` cpuType alias) in
  Phase 4.

---

## 7. Summary of the decision

- **Tuple:** reuse the existing `solaris` kernel; canonical Nix system
  `x86_64-solaris`, config `x86_64-unknown-solaris2.11`; brand as `illumos` at the
  Nix-attribute layer (`pkgs.illumos.*`, `examples.x86_64-illumos` alias).
- **lib.systems diff:** tiny — a `hasPrefix "solaris"` parse fix, three
  `elaborate` gap-fills (`uname`/`libc`/`linker`), one examples entry. Most Solaris
  plumbing already exists.
- **stdenv:** mirror the FreeBSD 3-stage seed bootstrap, but GCC not Clang, Solaris
  ld not lld, `ld.so.1` not `ld-elf.so.1`, `elfedit` not patchelf. `useLLVM =
  false`.
- **linker:** complete the already-present `ld-solaris-wrapper.sh`; translate
  `-rpath`→`-R` and `-dynamic-linker`→`-I`; RUNPATH is the correctness-critical
  path, shrink-rpath is deferrable.
- **package set:** `pkgs.illumos.*` copies the `pkgs/os-specific/bsd/freebsd`
  scope/splicing pattern; foundational members (`include`, `csu`, `libc`, `ld`,
  `rtld`, `sys`) get explicit `callPackage` wiring to break the bootstrap cycle.
