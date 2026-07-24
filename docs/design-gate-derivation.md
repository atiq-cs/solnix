# Design: Gate-in-a-derivation + proto slicing (T1.3–T1.7)

Status: implementation design. Nothing here has been run. Concrete, implementable
plan for the next solnix build step, ready the moment Nix realises derivations on
the illumos host (P0.2). Cites real paths in the nixpkgs fork
(`~/ws/nixpkgs-solnix`, branch `solnix-x86_64-solaris`) and the gate
(`/code/illumos-gate`, HEAD `ac45d71fc2`, proto `proto/root_i386`, 429M).

Prerequisite decisions (do not re-litigate — see `docs/design-build-strategy.md`):
**native-anchored hybrid**, gate world built natively on illumos, cross-from-Linux
ruled out. This doc is the concrete Tier-1a plan: wrap the working gate build in a
derivation, slice the proto, relocate with `elfedit`. Cites the seed method from
`docs/design-seed-extraction.md` and the platform wiring from
`docs/design-nixpkgs-illumos.md`.

TL;DR:

- `pkgs.illumos.gate` = a derivation that runs the proven `scripts/oi-gate-build.sh`
  recipe against pinned `illumos/illumos-gate` rev `ac45d71fc2`; `$out` = the proto
  area (`root_i386`). **Fixed-output derivation (FOD)** — the gate embeds
  timestamps/build-host strings, so pin the output by hash like the seed.
- Build inputs (onbld/dmake/CTF tools, JDK, gcc-10, header prereqs) come from the
  **host** initially (impure references), with a TODO to nixify. Acceptable for
  Phase 1: it is a one-time cached artifact.
- `pkgs.illumos.{libc, rtld, ld, sys, base-tools}` are small derivations that copy
  their files out of `illumos.gate`'s proto and relocate RUNPATH with `elfedit`
  (`$ORIGIN`-relative), via a shared `mkIllumosComponent` helper. **No patchelf.**
- These progressively replace the seed slices: seed builds the gate → gate proto
  supplies the real libc/ld/rtld → (later) rebuild the gate with the sliced
  toolchain for a seed-independent world.

---

## 0. Where this sits

Today (`pkgs/os-specific/illumos/default.nix`): `pkgs.illumos.{libc, cc,
gcc-unwrapped, binutils-unwrapped, bintools}` are **symlink/copy views into the
seed FOD** (`./seed/default.nix`, `illumos-seed`, gate `ac45d71fc2`). They are not
rebuilt and not relocated (the file's own comment says so). `ccFlagsDump` proves
the *flags* are correct; nothing yet builds gate source through Nix.

This design adds the first real from-proto derivations. The seed does not go away
— its role shrinks to "the compiler that builds the gate" (§3).

Task map (`.kiro/specs/solnix-foundation/tasks.md`):

| Task | This doc |
|---|---|
| T1.3 `pkgs.illumos.libc` | §2 libc slice |
| T1.4 `pkgs.illumos.ld` + `illumos.rtld` | §2 ld / rtld slices |
| T1.5 `pkgs.illumos.sys` (kernel + genunix, CTF) | §2 sys slice |
| T1.6 minimum base tools to multi-user | §2 base-tools + §4 |
| T1.7 compose into `system-path` | §4 |
| (new, blocks T1.3–T1.7) gate-in-a-derivation | §1 `pkgs.illumos.gate` |

---

## 1. `pkgs.illumos.gate` — the gate build as a derivation

### 1.1 What it is

One coarse derivation whose `$out` is the proto area
(`/code/illumos-gate/proto/root_i386` today, `$out` in the store after). It runs
the exact recipe `scripts/oi-gate-build.sh` already proved green: copy
`usr/src/tools/env/illumos.sh` → `solnix.sh`, empty the gcc-14 shadow, unset
`ON_CLOSED_BINS`, set `PERL_VERSION=5.42` / `PERL_VARIANT=-thread-multi`, install
the serial `wrapmake` (`dmake -m serial`, gcc-10 primary), `git clean -dfx`, run
`nightly solnix.sh`. IPS packaging failure is fine — we take the proto, not
packages (per `design-build-strategy.md` risk #6).

### 1.2 Normal derivation vs FOD — **decision: FOD**

The gate embeds non-deterministic strings: build timestamps, build-host name,
`uname`-derived version stamps, `bldenv` user/date. A normal derivation would
produce a different `$out` hash on every build, breaking substitution and forcing
every consumer to rebuild the 90-minute gate.

**Make `pkgs.illumos.gate` a fixed-output derivation** with a known
`outputHash`, exactly like `pkgs.illumos.seed` (`./seed/default.nix` pins
`sha256-I9jBIGrFC5v...`). Rationale:

- The seed is already an FOD for the same reason (illumos ELF, pinned bytes).
- FOD relaxes the sandbox (network + impure host refs allowed), which we *need*
  for Phase 1 because the build inputs come from the host (§1.3).
- The output *content* is what matters (a working proto), not bit-identical
  reproducibility of timestamps. Pin the bytes; upgrade to a normal derivation
  only if/when the gate build is made deterministic (a large, deferred effort —
  see risks).

Cost: the `outputHash` must be computed once from a real build
(`nix build .#illumos.gate` with a placeholder hash, read the "got:" hash, pin
it). Any change to the recipe or the pinned rev → recompute. This is the same
one-time dance the seed already does.

```
# NOTE: proto pinned by outputHash (FOD), not bit-reproducible.
#           Upgrade to a normal derivation when the gate build is made
#           deterministic (SOURCE_DATE_EPOCH + build-host scrub) — deferred.
```

### 1.3 Build inputs: host-referenced now, nixified later — **decision: host now**

The gate needs, at build time: `/opt/onbld` (nightly, dmake, ctfconvert/ctfmerge,
`bin/i386/*`), `/usr/gcc/10` (primary compiler), `/usr/java/bin/javac` (openjdk8,
build tools), and the header prereqs the recipe assumes present via `pkg install`
(idnkit/nss/nspr/cups per `design-build-strategy.md` risk #3). Nixifying these is
a multi-package project (onbld alone is a chunk of the gate).

**Phase-1 decision: reference the host-installed tools impurely.** The FOD
sandbox relaxation makes this legal. The derivation passes the host paths in as
env and asserts they exist in the builder; it does **not** try to package onbld or
gcc-10 yet. This mirrors `product.md`'s "Bootstrap exception" (host `pkg` allowed
for bootstrap-only tooling) and the seed's own reliance on host `/usr/gcc/10` and
`/usr/bin/{ld,elfdump,elfedit}` (`design-seed-extraction.md` §1.2–§1.3).

```
# NOTE: host-impure build inputs (/opt/onbld, /usr/gcc/10, JDK, IPS header
#           prereqs). FOD sandbox relaxation permits it. TODO(P2): nixify onbld
#           + gcc-10 + header prereqs so gate builds in a pure sandbox.
```

Header prereqs: the recipe today assumes `pkg install` already ran on the host
(T0.1/T0.2 host prep). Keep that assumption for Phase 1 — the derivation documents
the required IPS packages in a comment and `die`s early if a probe header is
missing, rather than installing anything (a derivation must not mutate the host).
Host prep stays a documented manual step (it already is).

### 1.4 Pinned source: `fetchFromGitHub`

The gate source is pinned reproducibly even though the *build* is impure:

```nix
src = fetchFromGitHub {
  owner = "illumos";
  repo = "illumos-gate";
  rev = "ac45d71fc2b04a5422e72a14b54dd1e746e7be07"; # == artifacts/seed/seed-manifest.txt
  # fill from: nix-prefetch-github illumos illumos-gate --rev ac45d71fc2b0...
  hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # TODO: real hash
};
```

`ac45d71fc2` is the rev we actually built and extracted the seed from
(`artifacts/seed/README.md`, `docs/progress.md:53`). The maintainer's home
reference `31d3d510d0` (`illumos-domain.md`) is *not* what we built; keep the
build pinned to what is proven green. Re-pin both seed and gate together if the
rev moves (seed↔gate drift, `design-build-strategy.md` risk #5).

> Note: `fetchFromGitHub` runs on the *build* platform. On the illumos builder it
> fetches directly; if fetched on Linux and copied, the tarball content-hash is
> platform-independent, so either works. Nothing ELF is fetched here — just source.

### 1.5 The derivation sketch

`pkgs/os-specific/illumos/pkgs/gate.nix`:

```nix
# pkgs.illumos.gate — the illumos-gate proto area as a store output.
#
# Runs the proven scripts/oi-gate-build.sh recipe against pinned illumos-gate
# ac45d71fc2 on the illumos host. $out = the proto (root_i386). FOD: the gate
# embeds timestamps/build-host strings, so pin the bytes by outputHash (like the
# seed). Build inputs come from the host (/opt/onbld, /usr/gcc/10, JDK) — Phase-1
# impure, FOD sandbox permits it. See docs/design-gate-derivation.md §1.
{ lib, stdenvNoCC, fetchFromGitHub }:

stdenvNoCC.mkDerivation {
  pname = "illumos-gate-proto";
  version = "ac45d71fc2";

  src = fetchFromGitHub {
    owner = "illumos";
    repo = "illumos-gate";
    rev = "ac45d71fc2b04a5422e72a14b54dd1e746e7be07";
    hash = "sha256-AAAA...=";              # TODO: nix-prefetch-github
  };

  # Host build tools (impure). The builder asserts these exist; it does NOT
  # install anything (a derivation must not mutate the host).
  ONBLD    = "/opt/onbld";
  GCC10    = "/usr/gcc/10";
  JAVAC    = "/usr/java/bin/javac";
  # Required host IPS prereqs (manual host prep, T0.1/T0.2):
  #   developer/java/openjdk8, header/header-* (idnkit nss nspr), print/cups (headers)
  # The builder greps for a few probe headers and die()s early if absent.

  dontConfigure = true;

  # The recipe verbatim from scripts/oi-gate-build.sh, minus the host `pkg
  # install` (host prep is a manual precondition) and using $PWD (the unpacked
  # src) instead of /code/illumos-gate.
  buildPhase = ''
    runHook preBuild
    set -eu
    GATE="$PWD"

    [ -x "$ONBLD/bin/nightly" ]      || { echo "FATAL: no $ONBLD/bin/nightly (host prep)"; exit 1; }
    [ -x "$GCC10/bin/gcc" ]          || { echo "FATAL: no $GCC10/bin/gcc"; exit 1; }
    [ -x "$JAVAC" ]                  || { echo "FATAL: no $JAVAC (pkg install developer/java/openjdk8)"; exit 1; }
    # probe a header the gate needs from IPS prereqs; add more as builds reveal them:
    [ -f /usr/include/idn/api.h ]    || echo "WARN: idnkit headers missing (packaging may skip)"

    cp usr/src/tools/env/illumos.sh solnix.sh
    sed -i '/^export SHADOW_CCS=gcc14/d; /^export SHADOW_CCCS=gcc14/d' solnix.sh
    printf 'export SHADOW_CCS=\nexport SHADOW_CCCS=\n' >> solnix.sh
    sed -i '/^export ON_CLOSED_BINS=/d' solnix.sh
    echo 'unset ON_CLOSED_BINS' >> solnix.sh
    printf 'export PERL_VERSION=5.42\nexport PERL_VARIANT=-thread-multi\n' >> solnix.sh
    # point the gate's $MAKE at a serial dmake wrapper (libc parallel-CPPFLAGS leak):
    cat > "$GATE/wrapmake" <<WRAP
    #!/bin/sh
    exec $ONBLD/bin/i386/dmake -m serial "\$@"
    WRAP
    chmod +x "$GATE/wrapmake"
    # solnix.sh must set MAKE to the wrapper (the recipe relies on this):
    echo "export MAKE=$GATE/wrapmake" >> solnix.sh

    # git clean is unnecessary — fetchFromGitHub gives a pristine tree. Skip it.
    "$ONBLD/bin/nightly" solnix.sh || true   # IPS packaging failure is expected/OK
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    [ -d proto/root_i386/lib/amd64 ] || { echo "FATAL: no proto libc — gate build failed"; exit 1; }
    [ -f proto/root_i386/lib/amd64/libc.so.1 ] || { echo "FATAL: proto libc missing"; exit 1; }
    mkdir -p "$out"
    cp -a proto/root_i386/. "$out/"
    runHook postInstall
  '';

  # illumos ELF; never let Linux fixup touch it (matches the seed FOD).
  dontStrip = true; dontPatchELF = true; dontFixup = true;

  # FOD: pin the proto bytes. Recompute after any recipe/rev change.
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash     = "sha256-BBBB...=";       # TODO: from first real build

  meta = with lib; {
    description = "illumos-gate proto area (root_i386) built via nightly on illumos";
    platforms = [ "x86_64-solaris" ];       # builds ONLY on illumos
    license = licenses.cddl;
  };
}
```

Notes:

- **`platforms = [ "x86_64-solaris" ]`** — unlike the seed FOD (unpack-only,
  `platforms.all`), the gate *builds* and only builds on illumos. Nix will refuse
  to schedule it on a Linux builder, which is correct.
- `nightly solnix.sh || true` — IPS packaging failures (Perl per-arch, msgcc) do
  not touch the proto and are out of scope (`design-build-strategy.md` risk #6).
  The `installPhase` `die`s if the proto libc is actually missing, so a real build
  failure is still caught.
- **`git clean` dropped**: `fetchFromGitHub` already yields a pristine tree, so the
  interrupted-run reset the original script needs is moot here. (The wrapmake
  recreation stays — it is untracked.)
- ~90 min serial. **One-time, cached.** After the first build every consumer
  substitutes `illumos.gate` from cache and slicing (§2) is seconds. This is the
  entire justification for the coarse-then-slice shape.

---

## 2. Proto slicing — `mkIllumosComponent`

### 2.1 The idea

Each fine-grained component is a tiny derivation that:

1. copies a named subset of files out of `illumos.gate` (`$out` from §1),
2. relocates every ELF's RUNPATH to `$ORIGIN`-relative store paths with `elfedit`
   (the T0.3-proven method, `design-seed-extraction.md` §2.3 — **no patchelf**),
3. exposes `passthru` metadata (incdir/libdir) consumers need.

The relocation runs **on illumos** (elfedit is illumos-native and edits illumos
ELF). These derivations therefore also carry `platforms = [ "x86_64-solaris" ]`.

### 2.2 The RUNPATH story (from the seed method, unchanged)

- illumos `ld.so.1` honours `$ORIGIN` in RUNPATH; `$ORIGIN` expands to the dir of
  the loading object. A lib in `.../lib/amd64` that needs a sibling uses
  `$ORIGIN`; a binary in `.../bin` needing the component's lib uses
  `$ORIGIN/../lib/amd64`. Store-path-independent, exactly as the seed does.
- Cross-component deps (a base-tool needs libc from *another* store path) cannot
  use `$ORIGIN` — they need the **absolute store path** of the dependency's
  `lib/amd64`. So `mkIllumosComponent` takes a list of dependency components and
  bakes their store `lib/amd64` into RUNPATH as literal absolute paths (the normal
  Nix way; `$ORIGIN` is only for *intra*-component sibling refs).
- `elfedit -e 'dyn:runpath <colon-list>' <file>` sets DT_RUNPATH. Chicken-and-egg
  (elfedit fixing its own runpath) does not arise here: we use the **seed's**
  elfedit (`illumos.seed`), which is already relocated, to edit the sliced files.
- **Grow-in-place risk** (`design-seed-extraction.md` §2.5, risk #2): if the
  dynamic section can't hold a longer RUNPATH, `elfedit` refuses. Verify on the
  biggest objects; fall back to relink for those. Tracked in §6.

### 2.3 The helper

`pkgs/os-specific/illumos/pkgs/mk-illumos-component.nix`:

```nix
# mkIllumosComponent — carve a set of files out of illumos.gate's proto and
# relocate their RUNPATHs into the store with elfedit ($ORIGIN for siblings,
# absolute store paths for cross-component deps). NO patchelf (illumos ELF).
# docs/design-gate-derivation.md §2; method from design-seed-extraction.md §2.3.
{ lib, stdenvNoCC, illumos }:

# name       : component name (-> illumos-<name>)
# files      : list of proto-relative paths (files or dirs) to copy from the gate
# deps       : list of other illumos.* components this one links against at runtime
#              (their $out/lib/amd64 is baked into RUNPATH as an absolute store path)
# extraRunpath: extra literal RUNPATH entries (rare)
# passthru   : merged into the derivation's passthru
{ name, files, deps ? [], extraRunpath ? [], passthru ? {}, ... }@args:

let
  elfedit = "${illumos.seed}/usr/bin/elfedit"; # relocated seed elfedit
  elfdump = "${illumos.seed}/usr/bin/elfdump";
  depRunpath = lib.concatMapStringsSep ":" (d: "${d}/lib/amd64") deps;
in
stdenvNoCC.mkDerivation ({
  pname = "illumos-${name}";
  inherit (illumos.gate) version;

  dontUnpack = true;
  dontConfigure = true; dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    # copy each requested file/dir, preserving its proto-relative layout
    for f in ${lib.escapeShellArgs files}; do
      src="${illumos.gate}/$f"
      [ -e "$src" ] || { echo "FATAL: $f not in gate proto"; exit 1; }
      mkdir -p "$out/$(dirname "$f")"
      cp -a "$src" "$out/$f"
    done

    # relocate RUNPATH on every ELF we just copied.
    # $ORIGIN-relative for siblings within this component's lib dirs, plus the
    # absolute store lib/amd64 of each declared dependency.
    RUNPATH='$ORIGIN:$ORIGIN/../lib/amd64:$ORIGIN/../../lib/amd64${
      lib.optionalString (depRunpath != "") ":${depRunpath}"
    }${lib.concatMapStrings (e: ":" + e) extraRunpath}'
    find "$out" -type f | while read -r f; do
      # only touch dynamic ELF objects
      if ${elfdump} -d "$f" >/dev/null 2>&1; then
        ${elfedit} -e "dyn:runpath $RUNPATH" "$f" 2>/dev/null || {
          echo "WARN: elfedit runpath failed (grow-in-place?): $f" >&2
        }
      fi
    done
    runHook postInstall
  '';

  dontStrip = true; dontPatchELF = true; dontFixup = true;

  passthru = passthru;

  meta = (args.meta or {}) // {
    platforms = [ "x86_64-solaris" ]; # relocation runs on illumos
  };
} // removeAttrs args [ "name" "files" "deps" "extraRunpath" "passthru" "meta" ])
```

`$ORIGIN` is written literally into the ELF (single-quoted in the shell so Nix's
`''`-string and the shell both leave it alone); `ld.so.1` expands it at load time.

### 2.4 The split — which files → which derivation

Dependency order (build/runtime): **libc first; rtld standalone; ld needs libc +
its own libs; sys standalone (kernel); base-tools need libc.** All slice from the
same `illumos.gate` proto, so there is no *build* cycle — only runtime RUNPATH
wiring via `deps`.

| Component | proto files (from `root_i386`, per `design-seed-extraction.md` §1 + Appendix) | deps | passthru |
|---|---|---|---|
| **libc** (T1.3) | `lib/amd64/libc.so.1`, siblings `lib/amd64/lib{m,socket,nsl,resolv,elf,pthread,rt,dl}.so.*`, crt `usr/lib/amd64/crt{1,i,n}.o` + `values-*.o`, `usr/include/**`, link symlinks `usr/lib/amd64/lib*.so` | — | `incdir="/usr/include"`, `libdir="/usr/lib/amd64"` |
| **rtld** (T1.4) | `lib/amd64/ld.so.1` | — | `interp="/lib/amd64/ld.so.1"` |
| **ld** (T1.4) | `usr/bin/ld`, `usr/lib/amd64/lib{ld,ldstab,lddbg}.so.*`, `usr/lib/ld/**` (mapfiles) | libc | — |
| **sys** (T1.5) | `platform/i86pc/kernel/**` (`unix`), `kernel/**` (`genunix`, drivers, modules), `usr/kernel/**` | — (kernel, no userland libc) | (CTF is baked in by the gate; nothing to relocate) |
| **base-tools** (T1.6) | `sbin/{init,sh}`, `usr/sbin/{svc.startd,svc.configd,svcadm,svccfg}`, `usr/bin/{sh,ls,cp,mv,...}` (the minimal coreutils-equiv set), plus their `usr/lib/amd64/lib*.so.*` non-libc deps (e.g. `libscf`, `libuutil`, `librestart`) | libc | — |

Notes:

- **rtld is special**: `ld.so.1` is the interpreter — it has no interpreter of its
  own and its RUNPATH is mostly irrelevant (it *is* the loader). Copy it, do not
  break if elfedit is a no-op on it. Consumers reference
  `${illumos.rtld}/lib/amd64/ld.so.1` as the `-I` interpreter (the flag the
  bintools-wrapper already translates, `design-nixpkgs-illumos.md` §4.3).
- **libc's `deps = []`**: libc's siblings are all *inside* the libc component, so
  `$ORIGIN` covers them; no cross-component absolute path needed. This is why libc
  is the root of the dependency order.
- **sys deps = []**: the kernel does not link against userland libc. CTF data is
  already merged into the objects by the gate build (`ctfmerge` in nightly);
  slicing copies it verbatim — nothing to relocate. T1.5's "reproduce CTF build"
  is satisfied by `illumos.gate` having built it; the slice just carves it out.
- **base-tools RUNPATH**: each tool gets `deps = [ libc ]` → RUNPATH includes
  `${libc}/lib/amd64`, so the tool resolves libc from the *libc store path*, not
  the host and not its own component. Sibling libs it also copies (libscf etc.)
  resolve via `$ORIGIN/../lib/amd64`.

### 2.5 Wiring in the package set

`illumos.gate` and the slices join the existing scope in
`pkgs/os-specific/illumos/default.nix`. That file currently returns a plain
`rec { ... }` of seed slices; the cleanest home for the new source-built world is
the same pattern the FreeBSD set uses — `packagesFromDirectoryRecursive` over a
`pkgs/` dir with explicit `callPackage` for the foundational members
(`design-nixpkgs-illumos.md` §2.2). But for the minimal Phase-1 diff, just add
them to the existing `rec` block:

```nix
# in pkgs/os-specific/illumos/default.nix, alongside the seed slices:
rec {
  inherit seed;
  # ... existing seed-backed libc/cc/bintools ...

  gate = callPackage ./pkgs/gate.nix { };

  mkIllumosComponent = callPackage ./pkgs/mk-illumos-component.nix {
    illumos = self;                          # pass the scope for gate/seed refs
  };

  # source-built slices (replace the seed slices once green — see §3):
  libc-gate   = mkIllumosComponent { name = "libc";  files = [ /* §2.4 */ ]; passthru = { incdir = "/usr/include"; libdir = "/usr/lib/amd64"; }; };
  rtld        = mkIllumosComponent { name = "rtld";  files = [ "lib/amd64/ld.so.1" ]; passthru = { interp = "/lib/amd64/ld.so.1"; }; };
  ld-gate     = mkIllumosComponent { name = "ld";    files = [ /* §2.4 */ ]; deps = [ libc-gate ]; };
  sys         = mkIllumosComponent { name = "sys";   files = [ /* §2.4 */ ]; };
  base-tools  = mkIllumosComponent { name = "base-tools"; files = [ /* §2.4 */ ]; deps = [ libc-gate ]; };
}
```

Name the source-built libc/ld `libc-gate`/`ld-gate` while the seed slices still
own `libc`/`binutils-unwrapped`, then flip the names in the §3 transition. (The
existing `rec` block already self-references, e.g. `bintools` uses `libc`, so
`self`/`rec` wiring is available; if `callPackage`'s scope does not expose the
recursive set as `self`, thread it explicitly as shown.)

```
# NOTE: slices added to the existing rec{} block, not a full
#           packagesFromDirectoryRecursive scope refactor. Migrate to the
#           FreeBSD-style pkgs/ dir + explicit callPackage when the set grows
#           past a handful (design-nixpkgs-illumos.md §2.2). YAGNI until then.
```

---

## 3. How these replace the seed

The seed (`illumos.seed`) plays two roles today: (a) the **compiler** that will
build the gate, and (b) **library/header slices** (`libc`, `binutils-unwrapped`,
etc.) that stand in for the real thing. Once `illumos.gate` exists, role (b) moves
to the freshly-built proto; role (a) shrinks to just the compiler.

### 3.1 The transition, in order

1. **Now (done):** seed FOD + seed slices; `ccFlagsDump` green on Linux; flags
   proven on illumos (`docs/progress.md`). Seed = compiler + fake libc/ld.
2. **Build the gate with the seed's gcc.** `illumos.gate` (§1) uses host
   `/usr/gcc/10` — the *same* gcc the seed was extracted from
   (`design-seed-extraction.md` §1.2), so seed-gcc ≡ gate-gcc for Phase 1. (Later
   purity: point the gate at the *store* seed gcc instead of host gcc.)
3. **Slice the gate proto** (§2) → real `libc`/`rtld`/`ld`/`sys`/`base-tools` from
   freshly-built illumos source, RUNPATH-relocated into the store.
4. **Flip the stdenv's libc/ld from seed slices to gate slices.** The
   cc-wrapper/bintools-wrapper wiring (`pkgs/os-specific/illumos/default.nix`) reads
   `libc`/`binutils-unwrapped` — repoint those attrs at `libc-gate`/`ld-gate`. The
   *wrapper flags do not change* (that is the whole point of §0's "wrapper wiring
   stays the same"): only the store paths behind them change from seed to gate.
   Gate: a hello.c compiled by the seed gcc but linked against the **gate** libc
   (store RUNPATH → gate libc) runs on illumos and LD_DEBUG shows gate libc, not
   seed libc.
5. **(Later, purity upgrade — deferred) Self-host rebuild.** Rebuild `illumos.gate`
   using the *sliced* toolchain (store gcc + store ld + store libc) instead of host
   tools, then re-slice. Now nothing from the host or the seed leaks into the final
   world — a seed-independent, self-hosted proto. This is the "eliminate the seed"
   milestone; **not on the Phase-1 critical path.**

### 3.2 What the seed is still needed for after §3.1 step 4

- **The compiler.** The gate build and the stdenv both still use gcc-10 (host or
  seed). Nixifying gcc-10 as `pkgs.illumos.gcc` (Phase 2, `post-stable-backlog.md`)
  is what finally retires the seed compiler. Until then the seed/host gcc stays.
- Nothing else. `libc`/`ld`/`rtld`/headers now come from the gate proto.

Phase-1 is **minimal**: seed-built gate proto is enough to boot (step 4 world runs
on illumos). The self-host rebuild (step 5) and the gcc nixify are later purity
upgrades, explicitly deferred.

```
# NOTE: Phase-1 stops at seed-built gate proto (step 4). Self-host rebuild
#           (step 5) + gcc nixify = later purity, add when seed-independence is
#           actually required (Phase 2), not before. Booting doesn't need it.
```

---

## 4. Minimal bootable set → make-be (T1.6 / T1.7)

The multi-user SMF milestone (`illumos-domain.md`: milestones ≈ runlevels,
`multi-user`/`multi-user-server`) needs, at minimum, the set below composed into a
`system-path` that feeds the make-be image builder (P1.5).

### 4.1 The minimal component set

| Component | Why it is in the minimal set |
|---|---|
| `illumos.sys` | kernel (`unix` + `genunix` + drivers) — nothing boots without it |
| `illumos.rtld` | `ld.so.1` — every dynamic binary's interpreter |
| `illumos.libc` | libc + siblings — every userland binary links it |
| `illumos.base-tools` | `init`, `svc.startd`, `svc.configd`, `svccfg`, `svcadm`, a shell, coreutils-equiv (T1.6 exact list) |
| SMF manifests | the init content — generated by `smf.nix` (T1.11, `design-smf-init.md`), not sliced from the gate |

`svc.startd` reaching `multi-user` is the T1.6 gate: it needs `svc.configd` (the
repository daemon), `svccfg`/`svcadm` (manifest import + milestone control), a
shell for method scripts, and the coreutils-equiv the methods call. All of these
live in the proto and slice into `base-tools`.

### 4.2 Composing `system-path` (T1.7)

`system-path` is the union of the component store paths into the runtime `/usr`,
`/lib`, `/sbin` layout the image expects. This is a `buildEnv` (or the solnix
`system-path` module analog) over the minimal set:

```nix
# T1.7 — compose the minimal world into a single path for the image.
illumos.systemPath = buildEnv {
  name = "illumos-system-path";
  paths = [ illumos.sys illumos.rtld illumos.libc illumos.base-tools ];
  # SMF manifests come from smf.nix (T1.11), merged by the image builder, not here.
};
```

The make-be image builder (P1.5, `make-be.nix`) consumes `illumos.systemPath` +
the generated SMF manifests (`design-smf-init.md` §: "system etc/path modules
(T1.7) symlink or bind our checkedManifests") to lay down a ZFS-root boot
environment with the illumos `loader`. That is P1.5's concern; T1.7 just has to
produce the composed path.

```
# NOTE: system-path = buildEnv union, not a bespoke merger. Add conflict
#           resolution / priority only if two components collide on a path.
```

---

## 5. File plan + ordered steps (T1.3–T1.7)

Two repos: nixpkgs fork (`~/ws/nixpkgs-solnix`) and solnix (docs/tests). Each step
has a test gate that must pass before the next. All build/relocation steps run
**on the illumos host** (P0.2 must be green first).

### Step A — `pkgs.illumos.gate` (blocks everything below)

- [ ] Add `pkgs/os-specific/illumos/pkgs/gate.nix` (§1.5).
- [ ] `nix-prefetch-github illumos illumos-gate --rev ac45d71fc2b0...` → fill `src.hash`.
- [ ] First real build with a placeholder `outputHash`; read "got:" hash; pin it.
- [ ] Wire `gate = callPackage ./pkgs/gate.nix { };` into
      `pkgs/os-specific/illumos/default.nix`.
- **Gate:** `nix build .#illumos.gate` on illumos realises; `$out/lib/amd64/libc.so.1`
  exists; `$out` size ≈ proto (429M). Second build substitutes from cache (no
  rebuild).

### Step B — `mkIllumosComponent` + `libc` (T1.3)

- [ ] Add `pkgs/os-specific/illumos/pkgs/mk-illumos-component.nix` (§2.3).
- [ ] Add `libc-gate = mkIllumosComponent { name = "libc"; ... }` (§2.4).
- **Gate:** `nix build .#illumos.libc-gate` realises; `elfdump -d
  $out/lib/amd64/libc.so.1` shows a **store** RUNPATH (`$ORIGIN`-relative), not a
  host `/lib` path. (Mirrors the T0.3 success gate, `design-seed-extraction.md` §4.3.)

### Step C — `rtld` + `ld` (T1.4)

- [ ] Add `rtld` and `ld-gate` components (§2.4), `ld-gate` with `deps = [ libc-gate ]`.
- **Gate:** `elfdump -d ${ld-gate}/usr/bin/ld` shows RUNPATH containing
  `${libc-gate}/lib/amd64` (absolute store path). `${rtld}/lib/amd64/ld.so.1`
  exists and `file` reports it as the runtime linker.

### Step D — flip stdenv libc/ld seed→gate + prove a linked binary (T1.3/T1.4 exit)

- [ ] Repoint the `libc`/`binutils-unwrapped` attrs (consumed by the
      cc-wrapper/bintools-wrapper in `default.nix`) from seed slices to
      `libc-gate`/`ld-gate` (§3.1 step 4).
- **Gate:** compile+link a hello.c on illumos through the wrapped cc; the binary's
  `elfdump -d` NEEDED=libc.so.1 with RUNPATH → **gate** libc store path;
  `LD_DEBUG=libs ./hello` binds libc from `${libc-gate}`, **not** the seed and
  **not** the host `/lib`. (This is the "a base-tool runs on illumos linked against
  the sliced libc" gate from the task.)

### Step E — `sys` (T1.5)

- [ ] Add `sys` component (§2.4).
- **Gate:** `nix build .#illumos.sys` realises; `$out/platform/i86pc/kernel/amd64/unix`
  and `$out/kernel/.../genunix` exist; `ctfdump`/`elfdump -c` on `genunix` shows CTF
  present (proves the gate's CTF merge survived slicing — T1.5's "reproduce CTF").

### Step F — `base-tools` (T1.6)

- [ ] Enumerate the exact minimal tool list (`svc.startd`, `svc.configd`, `svccfg`,
      `svcadm`, `init`, shell, coreutils-equiv) + their non-libc `lib*.so.*` deps.
- [ ] Add `base-tools` component with `deps = [ libc-gate ]`.
- **Gate:** `${base-tools}/usr/sbin/svccfg --help` (or a trivial subcommand) runs on
  illumos, links libc from the store (LD_DEBUG), exits 0.

### Step G — `system-path` (T1.7)

- [ ] Add `illumos.systemPath = buildEnv { ... }` over the minimal set (§4.2).
- **Gate:** `nix build .#illumos.systemPath` realises; `$out/usr/sbin/svc.startd`,
  `$out/lib/amd64/{libc,ld}.so*`, `$out/platform/.../unix` all resolve through the
  merged tree. Handoff to P1.5 make-be.

### solnix repo (docs/tests, non-blocking)

- [ ] `docs/progress.md`: check off T1.3–T1.7 as each gate passes.
- [ ] One smoke script per gate (the `elfdump`/`LD_DEBUG` one-liners above), kept in
      `scripts/` alongside `oi-gate-build.sh` — the runnable check the RUNPATH logic
      must not silently break.

---

## 6. Risks / open questions (verify on the host)

Ranked by likelihood of biting.

1. **elfedit RUNPATH grow-in-place** (`design-seed-extraction.md` §2.5 risk).
   Sliced libc/ld may have a dynamic section too small to hold a longer store
   RUNPATH; `elfedit` refuses rather than growing it. *Verify* on the biggest
   objects: `libc.so.1`, `/usr/bin/ld`, and any base-tool with many `lib*` deps.
   *Fallback:* relink the object (the gate can emit it with a longer `-R`) instead
   of editing. This is the single most likely slicing blocker.

2. **FOD output hash instability across gate re-runs.** Even as an FOD, if the
   proto's *content* (not just timestamps) varies run-to-run (e.g. object ordering,
   embedded build paths beyond timestamps), the pinned `outputHash` breaks and every
   build fails hash verification. *Verify:* build the gate twice, diff the proto
   (ignoring known timestamp/build-host fields); confirm the rest is stable. If not,
   scrub the varying fields in `installPhase` before `cp -a` (e.g. `mcs -d` to strip
   comment sections carrying build stamps).

3. **Host build-input drift.** The impure `/opt/onbld`, `/usr/gcc/10`, JDK, and IPS
   header prereqs are whatever the host happens to have. A host update silently
   changes the gate output. *Verify:* record onbld + gcc + JDK versions in the
   derivation's `meta`/passthru and in `docs/progress.md`; treat a host toolchain
   bump as a reason to recompute the gate `outputHash`. (Long-term fix: nixify —
   deferred, §1.3.)

4. **sys/CTF survives slicing.** The kernel objects carry CTF merged by the gate.
   `cp -a` should preserve it, but *verify* `elfdump -c`/`ctfdump` on the sliced
   `genunix` still shows CTF and the section wasn't dropped by any fixup. (We set
   `dontStrip`/`dontFixup`, so it should be intact — confirm.)

5. **base-tools closure completeness.** The minimal svc.startd→multi-user set may
   pull `lib*.so.*` we didn't enumerate (libscf, libuutil, librestart, libnvpair,
   libcmdutils, …). *Verify:* `ldd` each base-tool on illumos; every NEEDED must
   resolve to a store path (libc component or a sibling in base-tools), none to host
   `/lib`. Add missing libs to the `files` list until `ldd` is clean.

6. **rtld relocation is a no-op / harmful.** `ld.so.1` is the loader; editing its
   RUNPATH may be meaningless or (worst case) corrupt it. *Verify:* the sliced
   `ld.so.1` still functions as an interpreter (a binary built with `-I
   ${rtld}/lib/amd64/ld.so.1` runs). If elfedit on rtld is problematic, skip
   relocation for that one file (copy verbatim).

7. **`fetchFromGitHub` hash for a large repo.** illumos-gate is big; the source
   FOD hash is straightforward but the fetch is slow the first time. Non-blocking,
   just note the one-time cost. *Verify:* `nix-prefetch-github` completes and the
   hash matches on the illumos builder.

8. **Seed↔gate rev match.** Seed extracted from `ac45d71fc2`; the gate derivation
   pins the same rev — keep them equal. If the gate rev moves, re-extract the seed
   (or accept ABI-stable drift, `design-build-strategy.md` risk #5). *Verify:* the
   seed gcc builds the pinned gate cleanly (it did once, at `ac45d71fc2`).

---

## 7. Summary

- **`pkgs.illumos.gate`** = FOD running `oi-gate-build.sh` against pinned
  `illumos-gate ac45d71fc2`; `$out` = proto; host-impure build inputs (Phase-1);
  one-time ~90-min cached cost.
- **`mkIllumosComponent`** slices the proto into `libc`/`rtld`/`ld`/`sys`/`base-tools`,
  relocating RUNPATH with **elfedit** ($ORIGIN for siblings, absolute store paths for
  cross-component deps). No patchelf.
- **Seed transition:** seed builds gate → gate proto supplies real libc/ld/rtld →
  flip stdenv libc/ld from seed slices to gate slices (wrapper flags unchanged) →
  (later, deferred) self-host rebuild for seed-independence.
- **Minimal bootable set** (`sys` + `rtld` + `libc` + `base-tools` + generated SMF
  manifests) composes into `system-path` (buildEnv) → make-be (P1.5) →
  multi-user SMF milestone.
- **Biggest risks to verify on host:** elfedit grow-in-place on large objects, FOD
  content stability across gate re-runs, base-tools closure completeness (`ldd`
  clean, no host `/lib` leak).
