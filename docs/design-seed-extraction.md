# Seed Toolchain Extraction (T0.3)

Design + script plan for extracting a self-contained "seed toolchain" from an
illumos-gate build, to bootstrap a Nix stdenv for illumos (the nixpkgs
`bootstrap-tools` analog).

**Status:** design. Nothing here has been run. Paths reflect the OpenIndiana
Hipster build host from T0.1/T0.2 (illumos-gcc 10 at `/usr/gcc/10`, onbld at
`/opt/onbld`, gate at `/code/illumos-gate`). Items marked **VERIFY** must be
confirmed on the host before relying on them.

## 0. What the seed is and is not

The seed is a single relocatable tarball containing a C/C++ compiler, the
Solaris link-editor, illumos libc + its historical siblings, the crt objects,
system headers, the runtime linker, and just enough ELF/CTF tooling to link and
introspect binaries. A Nix `stdenv` **stage0** unpacks it into `/nix/store`,
patches its runpaths to point at itself, and uses it to build everything else —
after which the seed is never referenced again.

It is **not** a distro, not IPS, not a full `/usr`. Anything Nix will build from
source later (coreutils, bash, m4, ...) does **not** belong in the seed. Keep it
minimal: compiler + linker + libc + headers + runtime + the ELF tools the build
hooks need.

Provenance decision (see §1.2): we seed the **OpenIndiana `developer/gcc-10`
compiler as-is**, not a gate-rebuilt gcc. The gate consumes gcc as an external
tool; it does not produce one. Rebuilding gcc under Nix is Phase 1 work, not
stage0.

---

## 1. Seed contents

All source paths below are on the illumos build host. "proto" = the staged root
`$ROOT`, i.e. `/code/illumos-gate/proto/root_i386` for amd64 nightly.

### 1.1 From the proto area (libc, crt, siblings, headers, runtime)

illumos libc is Solaris libc — `libc.so.1` — **not glibc**. The historically
split siblings (`libsocket`, `libnsl`, `libresolv`) are still separate shared
objects. Link against `.so.1` versioned files; the unversioned `.so` in
`usr/lib` are the link-editor symlinks.

Runtime + startup objects (64-bit primary target `x86_64-pc-solaris2.11`, so the
`amd64` subdirs are what stage0 links against; 32-bit kept only if we later want
`-m32`, otherwise skip to stay minimal):

| Purpose | proto path (amd64) |
|---|---|
| runtime linker | `lib/amd64/ld.so.1` (plus 32-bit `lib/ld.so.1` **VERIFY if needed**) |
| C runtime start | `usr/lib/amd64/crt1.o` |
| C runtime init/fini | `usr/lib/amd64/crti.o`, `usr/lib/amd64/crtn.o` |
| values objects | `usr/lib/amd64/values-*.o` (e.g. `values-Xa.o`, `values-Xc.o`, `values-xpg4.o`, `values-xpg6.o` — glob, don't enumerate) |
| C library | `lib/amd64/libc.so.1` (+ `usr/lib/amd64/libc.so` link) |
| threads | libpthread is folded into libc on illumos — `libpthread.so.1` is a filter/stub; include it and `librt.so.1` for `-lrt`/`-lpthread` link compat |
| math | `lib/amd64/libm.so.2` (**VERIFY soname: `libm.so.2` on illumos**) + `usr/lib/amd64/libm.so` |
| sockets | `lib/amd64/libsocket.so.1` + link |
| name services | `lib/amd64/libnsl.so.1` + link |
| resolver | `lib/amd64/libresolv.so.2` (**VERIFY soname**) + link |
| ELF access | `lib/amd64/libelf.so.1` + link (needed by ld, elfdump, ctf tools) |
| dl / misc used at link | `libdl` is folded into libc (stub `libdl.so.1`); include `libc_db`, `libnvpair`, `libavl`, `libcmdutils` only if a link fails without them — **defer, add on demand** |

Headers — the entire system include tree:

- `usr/include/**` — the complete header hierarchy (`stdio.h`, `sys/*.h`,
  `sys/isa_defs.h`, etc.). Copy the tree wholesale; picking headers individually
  is a losing game. This is Solaris/illumos headers, not glibc.

Link-editor support bits that live under proto (mapfiles, `libld`, `libldstab`):

- `usr/lib/amd64/libld.so.*`, `usr/lib/amd64/libldstab.so.*`,
  `usr/lib/amd64/liblddbg.so.*` — the linker's own shared objects
  (`/usr/bin/ld` is a thin driver over these). **VERIFY exact sonames via
  `elfdump -d /usr/bin/ld`.**
- `usr/lib/ld/**` — mapfile fragments / version scripts the linker reads
  (e.g. the standard mapfiles). **VERIFY the directory exists in proto;** on some
  layouts these are only in the installed system, in which case pull from the
  live host `/usr/lib/ld/` instead and note the divergence.

> **Key point on where to pull from.** Prefer the **proto area** for everything
> the gate builds (libc, crt, headers, ld's libraries, ld.so.1) so the seed
> matches the pinned gate commit. Pull from the **live host** (`/usr`, `/lib`,
> `/usr/gcc/10`, `/opt/onbld`) only for things the gate does *not* produce: the
> OI gcc, and any tool missing from proto. The script tags each file with its
> source so the manifest is unambiguous.

### 1.2 The compiler: OpenIndiana `developer/gcc-10`

gcc lives at `/usr/gcc/10` on the host, installed from the OI IPS package
`developer/gcc-10` — **it is not built by the gate**. Decision: **seed it as-is**
from the live host. Rebuilding gcc under Nix is deferred to Phase 1's real
stdenv; stage0 only needs a working cross-capable compiler that already targets
illumos, which this is.

Package the whole prefix:

- `/usr/gcc/10/bin/**` — `gcc`, `g++`, `cpp`, `gcc-ar`, etc.
- `/usr/gcc/10/lib/**` and `/usr/gcc/10/lib/amd64/**` — `libgcc_s.so.1`,
  `libstdc++.so.6`, `libgomp`, etc. These are **runtime deps of everything the
  seed compiler emits** and must ship.
- `/usr/gcc/10/libexec/gcc/**` — `cc1`, `cc1plus`, `collect2`, `lto-wrapper`.
- `/usr/gcc/10/lib/gcc/<triple>/10/include` and **`include-fixed`** — gcc's
  fixed headers. `include-fixed` contains headers gcc mangled from the system
  headers **at gcc-build time on the OI host**; they encode absolute assumptions
  about `/usr/include`. Ship them, but flag as a relocatability risk (§2, §5).
- `/usr/gcc/10/lib/gcc/<triple>/10/{crtbegin.o,crtend.o,crtbeginS.o,crtendS.o}`
  and the `amd64/` variants — gcc's own crt objects, **distinct** from libc's
  crt1/crti/crtn. Both sets are needed to link.

`<triple>` is **VERIFY** — likely `i386-pc-solaris2.11` or `x86_64-pc-solaris2.11`;
resolve at runtime with `$(gcc -dumpmachine)` rather than hardcoding.

**Is gcc relocatable?** gcc uses a compiled-in prefix but honors relocation when
invoked via its own `bin/gcc` and can be pointed elsewhere with `-B`,
`GCC_EXEC_PREFIX`, and `--sysroot`. The internal driver computes paths relative
to the driver binary in many configs, but OI's build may bake absolutes. **This
is the single biggest unknown** — see §2 and §5. The seed ships gcc whole and
stage0 wraps it (`-B<seed>/... --sysroot=<seed>` + `GCC_EXEC_PREFIX`) rather than
trusting gcc's built-in relocation.

### 1.3 Solaris `ld` and ELF tools

`/usr/bin/ld` on illumos **is** the Solaris/illumos link-editor (not GNU ld).
Seed the driver plus its `lib*ld*` shared objects (listed in §1.1):

- `/usr/bin/ld` — link-editor driver.
- `/usr/bin/elfdump` — the `readelf` replacement; stage0 verification depends on
  it. **Mandatory.**
- `/usr/bin/elfedit` — the runpath/ELF editor. **Mandatory** — this is how we
  make binaries relocatable (patchelf does not work on illumos, §2).
- `/usr/bin/elffile`, `/usr/bin/dump`, `/usr/bin/mcs` — helpful, low cost; keep
  `elffile` at least.
- `/usr/bin/nm`, `/usr/bin/ar`, `/usr/bin/as` — **VERIFY which assembler the gcc
  driver actually calls.** gcc may call `/usr/gcc/10/.../as` or the system
  `/usr/bin/gas`/`/usr/bin/as`. Whatever `gcc -print-prog-name=as` reports must
  be in the seed. Same for `ld`: confirm `gcc -print-prog-name=ld` — gcc might
  invoke `/usr/bin/ld` directly or a `collect2` that finds it on PATH.

These tools themselves link against libc/libelf from the system; once seeded and
relocated, they must resolve those from the seed (§2).

### 1.4 CTF tools

`ctfconvert`/`ctfmerge` live in `/opt/onbld/bin/` (also `$ROOT/opt/onbld` on some
layouts) and generate the CTF debug data the gate mandates.

**Decision: CTF is NOT needed at stage0.** stage0 only needs to compile+link+run
ordinary user binaries; CTF is a kernel/gate build concern, not a libc-link
concern. **Omit ctfconvert/ctfmerge from the initial seed.** Add them later when
Nix starts building the gate itself (Phase 1 `pkgs.illumos.sys`), at which point
they can be a normal Nix package. Ship them only if a stage0 link unexpectedly
requires CTF (it should not). See §5.

---

## 2. Relocatability / runpath

The seed lands at an arbitrary `/nix/store/<hash>-illumos-seed/` path unknown at
extraction time. Every binary and shared object in it that references another
seed library must find it there, not on the host system.

### 2.1 The illumos mechanism: `-R` runpaths + `$ORIGIN`

illumos `ld.so.1` supports the `$ORIGIN` token in RUNPATH: it expands to the
directory containing the object being loaded. A runpath of
`$ORIGIN/../lib/amd64` on a binary in `.../bin` resolves relative to wherever the
seed is unpacked — exactly the store-relocatability we need, and the same
mechanism nixpkgs uses on Linux via `$ORIGIN`. Runpaths are set at link time with
`ld -R` (or `gcc -Wl,-R`). `ld.so.1` also honors `$ISALIST`, `$OSNAME`,
`$PLATFORM`; we only need `$ORIGIN`.

**We bypass `crle`/`/var/ld` entirely** (per illumos-domain.md): no default
search-path config, everything explicit via baked runpaths.

### 2.2 The problem: seed binaries were linked against absolute host paths

The extracted `gcc`, `cc1`, `ld`, `elfdump`, `libstdc++.so.6`, etc. were linked
on the OI host with runpaths like `/usr/gcc/10/lib/amd64` and `/lib/amd64`, and
depend on host `libc.so.1`, `libelf.so.1`, `libgcc_s.so.1`. Unpacked into the
store they would still load host libraries (wrong version, defeats the purpose of
a pinned seed) or fail.

### 2.3 The fix: rewrite runpaths with `elfedit` (NOT patchelf)

**patchelf does not work on illumos** — it does not understand Solaris ELF
sections/versioning. We must use `elfedit`. After stage0 unpacks the seed, a
setup hook walks every ELF object and rewrites its RUNPATH to `$ORIGIN`-relative
seed paths:

```sh
# conceptual — real hook in the nixpkgs fork's stage0
elfedit -e 'dyn:runpath $ORIGIN/../lib/amd64:$ORIGIN/../../lib/amd64' file
```

`elfedit`'s `dyn:runpath` (and `dyn:value -s RUNPATH`) sets/replaces the RUNPATH
entry. It can also add a `NEEDED`/change soname if required. Because `$ORIGIN` is
resolved by `ld.so.1` at load time and stored literally in the ELF, the string is
store-path-independent: the same rewritten seed works at any store path. Do the
rewrite **once at stage0 unpack**, keyed off `$ORIGIN`, not off a concrete store
path — this keeps the tarball itself location-agnostic.

**Chicken-and-egg:** `elfedit` is itself in the seed and itself needs its runpath
fixed. Bootstrap by running the **host** `elfedit` (from PATH) to fix the seed's
copy first, or by setting `LD_LIBRARY_PATH=<seed>/lib/amd64` for the single
initial `elfedit` invocation so it can run before its own runpath is corrected.
The setup hook uses the just-fixed seed `elfedit` for the rest.

### 2.4 gcc's internal paths

Runpath rewriting fixes shared-object *loading*. It does **not** fix gcc's search
for `cc1`, crt objects, and headers — those are driver-computed paths, not
runpaths. Handle with a wrapper (nixpkgs `cc-wrapper` analog) passing:

- `-B<seed>/usr/gcc/10/lib/gcc/<triple>/10/` (find cc1, crt*.o)
- `--sysroot=<seed>` and `-isystem <seed>/usr/include`
- `-L<seed>/lib/amd64 -L<seed>/usr/lib/amd64` and matching `-Wl,-R,$ORIGIN/...`
- `GCC_EXEC_PREFIX=<seed>/usr/gcc/10/lib/gcc/`

`include-fixed` is the risk: if its headers embed host absolutes, regenerate them
against the seed's `usr/include` with gcc's `fixincludes` at stage0, or (lazier)
delete `include-fixed` and rely on `-isystem <seed>/usr/include` — **VERIFY a
hello-world still compiles without `include-fixed`; many targets do.**

### 2.5 Risks (relocatability)

- gcc built with a hard absolute prefix that its driver won't override → wrapper
  must fully override via `-B`/`GCC_EXEC_PREFIX`; worst case we rebuild gcc
  (Phase 1) sooner than planned.
- `include-fixed` host-absolute leakage (above).
- `elfedit` RUNPATH edit may be constrained by the existing dynamic-section size
  on some objects (can't grow the string table in place). If `elfedit` refuses to
  lengthen RUNPATH, we may need to relink rather than edit — **VERIFY on the
  largest offender (`libstdc++.so.6`, `cc1plus`).**

---

## 3. Extraction script

`scripts/oi-extract-seed.sh` — runs **on the illumos build host as root**.
Assembles the seed into `seed.tar.zst` + `seed-manifest.txt` (paths + sha256 +
provenance + versions). Defensive: every required file is checked; a missing one
aborts the whole run.

```bash
#!/usr/bin/env bash
# oi-extract-seed.sh — extract a relocatable seed toolchain from an illumos-gate
# build (T0.3). Run ON the illumos build host, as root.
#
#   Sources:
#     proto  = $ROOT (gate-built libc/crt/headers/ld-libs/ld.so.1)   -> preferred
#     host   = live / (OI developer/gcc-10, /usr/bin/ld, ELF tools)  -> only what
#              the gate does not itself produce
#
#   Output (in $OUT, default /var/tmp/solnix-seed):
#     seed/                 staging tree (mirrors the seed's on-disk layout)
#     seed-manifest.txt     src-path -> seed-path, sha256, provenance, versions
#     seed.tar.zst          the seed
#
# Defensive: any REQUIRED file missing -> abort. OPTIONAL files warn only.
set -euo pipefail

GATE="${GATE:-/code/illumos-gate}"
ROOT="${ROOT:-$GATE/proto/root_i386}"          # amd64 nightly proto area
GCC_PREFIX="${GCC_PREFIX:-/usr/gcc/10}"
OUT="${OUT:-/var/tmp/solnix-seed}"
SEED="$OUT/seed"
MANIFEST="$OUT/seed-manifest.txt"

die()  { echo "FATAL: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

# ---- sanity ---------------------------------------------------------------
[ "$(id -u)" = 0 ]        || die "run as root (need perms/symlink preservation)"
[ -d "$ROOT" ]           || die "proto area not found: $ROOT (build the gate first)"
[ -x "$GCC_PREFIX/bin/gcc" ] || die "gcc not found: $GCC_PREFIX/bin/gcc"
command -v elfdump >/dev/null || die "elfdump not on PATH"
command -v elfedit >/dev/null || die "elfedit not on PATH"
command -v zstd    >/dev/null || die "zstd not on PATH (pkg install compress/zstd)"
[ -f "$ROOT/lib/amd64/libc.so.1" ] || die "no libc in proto: $ROOT/lib/amd64/libc.so.1"

rm -rf "$OUT"; mkdir -p "$SEED"
: > "$MANIFEST"
TRIPLE="$("$GCC_PREFIX/bin/gcc" -dumpmachine)"   # e.g. i386-pc-solaris2.11
echo "gcc target triple: $TRIPLE"

# ---- copy helpers ---------------------------------------------------------
# cp_req  SRC  DESTREL  PROVENANCE   : required, abort if missing
# cp_opt  SRC  DESTREL  PROVENANCE   : optional, warn if missing
# cp_glob SRCGLOB DESTDIRREL PROVENANCE REQUIRED?  : glob copy
_record() { # abs-src  dest-rel  provenance
  local src="$1" dst="$2" prov="$3" sum
  sum="$(digest -a sha256 "$SEED/$dst" 2>/dev/null || sha256sum "$SEED/$dst" | awk '{print $1}')"
  printf '%s\t%s\t%s\t%s\n' "$prov" "$src" "$dst" "$sum" >> "$MANIFEST"
}
_cp() { # src dst-rel provenance required?
  local src="$1" dst="$2" prov="$3" req="$4"
  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    if [ "$req" = req ]; then die "missing required: $src"; else warn "missing optional: $src"; return 0; fi
  fi
  mkdir -p "$SEED/$(dirname "$dst")"
  # -R preserve symlinks; -P no-dereference; @/= ext-attr/acl if present
  cp -RP@ "$src" "$SEED/$dst" 2>/dev/null || cp -RP "$src" "$SEED/$dst"
  [ -L "$src" ] || _record "$src" "$dst" "$prov"
}
cp_req()  { _cp "$1" "$2" "$3" req; }
cp_opt()  { _cp "$1" "$2" "$3" opt; }
cp_glob() { # glob dst-dir-rel provenance required?
  local g="$1" dd="$2" prov="$3" req="$4" n=0 f
  for f in $g; do
    [ -e "$f" ] || continue
    cp_req "$f" "$dd/$(basename "$f")" "$prov"; n=$((n+1))
  done
  [ "$n" -gt 0 ] || { [ "$req" = req ] && die "glob matched nothing: $g" || warn "glob empty: $g"; }
}

echo "=== 1. proto: startup objects + libc + siblings (amd64) ==="
cp_req  "$ROOT/lib/amd64/ld.so.1"        lib/amd64/ld.so.1        proto
cp_req  "$ROOT/usr/lib/amd64/crt1.o"     usr/lib/amd64/crt1.o     proto
cp_req  "$ROOT/usr/lib/amd64/crti.o"     usr/lib/amd64/crti.o     proto
cp_req  "$ROOT/usr/lib/amd64/crtn.o"     usr/lib/amd64/crtn.o     proto
cp_glob "$ROOT/usr/lib/amd64/values-*.o" usr/lib/amd64            proto req

# libc + the historically-split siblings + link-time deps
cp_req  "$ROOT/lib/amd64/libc.so.1"      lib/amd64/libc.so.1      proto
cp_glob "$ROOT/lib/amd64/libm.so.*"      lib/amd64                proto req
cp_glob "$ROOT/lib/amd64/libsocket.so.*" lib/amd64                proto req
cp_glob "$ROOT/lib/amd64/libnsl.so.*"    lib/amd64                proto req
cp_glob "$ROOT/lib/amd64/libresolv.so.*" lib/amd64                proto req
cp_glob "$ROOT/lib/amd64/libelf.so.*"    lib/amd64                proto req
# these are filters/stubs on illumos but referenced by -lpthread/-lrt/-ldl:
cp_opt  "$ROOT/lib/amd64/libpthread.so.1" lib/amd64/libpthread.so.1 proto
cp_opt  "$ROOT/lib/amd64/librt.so.1"      lib/amd64/librt.so.1      proto
cp_opt  "$ROOT/lib/amd64/libdl.so.1"      lib/amd64/libdl.so.1      proto

# link-editor symlinks (.so -> .so.N) live under usr/lib; copy the whole set of
# unversioned link names we care about (cp -RP keeps them as symlinks)
for l in libc libm libsocket libnsl libresolv libelf libpthread librt libdl; do
  cp_opt "$ROOT/usr/lib/amd64/$l.so" "usr/lib/amd64/$l.so" proto
done

echo "=== 2. proto: system headers (whole tree) ==="
cp_req "$ROOT/usr/include" usr/include proto

echo "=== 3. proto: link-editor shared objects + mapfiles ==="
cp_glob "$ROOT/usr/lib/amd64/libld.so.*"     usr/lib/amd64 proto req
cp_glob "$ROOT/usr/lib/amd64/libldstab.so.*" usr/lib/amd64 proto req
cp_glob "$ROOT/usr/lib/amd64/liblddbg.so.*"  usr/lib/amd64 proto opt
if [ -d "$ROOT/usr/lib/ld" ]; then
  cp_req "$ROOT/usr/lib/ld" usr/lib/ld proto
else
  warn "no $ROOT/usr/lib/ld in proto; pulling from live host /usr/lib/ld"
  cp_opt /usr/lib/ld usr/lib/ld host
fi

echo "=== 4. host: Solaris ld + ELF tools ==="
cp_req /usr/bin/ld       usr/bin/ld       host
cp_req /usr/bin/elfdump  usr/bin/elfdump  host
cp_req /usr/bin/elfedit  usr/bin/elfedit  host
cp_opt /usr/bin/elffile  usr/bin/elffile  host
cp_opt /usr/bin/nm       usr/bin/nm       host
cp_opt /usr/bin/ar       usr/bin/ar       host
cp_opt /usr/bin/mcs      usr/bin/mcs      host
# whatever gcc actually calls for as/ld (may differ from the above):
AS="$("$GCC_PREFIX/bin/gcc" -print-prog-name=as)"; [ -x "$AS" ] && cp_req "$AS" "usr/bin/$(basename "$AS")" host
GLD="$("$GCC_PREFIX/bin/gcc" -print-prog-name=ld)"; [ -x "$GLD" ] && cp_opt "$GLD" "usr/bin/gld-$(basename "$GLD")" host

echo "=== 5. host: OI gcc-10 prefix (whole) ==="
cp_req "$GCC_PREFIX" "usr/gcc/10" host   # bin, lib, lib/amd64, libexec, lib/gcc/<triple>/10 incl include-fixed + crt*

# ---- versions / provenance ------------------------------------------------
echo "=== 6. capture versions ==="
{
  echo "# solnix seed manifest — generated $(date -u +%FT%TZ)"
  echo "# host uname: $(uname -a)"
  echo "# gcc triple: $TRIPLE"
  echo "# gcc version:"; "$GCC_PREFIX/bin/gcc" --version | sed 's/^/#   /'
  echo "# ld version:";  /usr/bin/ld -V 2>&1 | sed 's/^/#   /' || true
  echo "# ld.so.1 (proto) elfdump -d NEEDED/soname:"
  elfdump -d "$ROOT/lib/amd64/libc.so.1" 2>/dev/null | sed 's/^/#   /' | head -40
  if [ -d "$GATE/.git" ]; then
    echo "# gate git commit: $(cd "$GATE" && git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "# gate git describe: $(cd "$GATE" && git describe --always --dirty 2>/dev/null || echo unknown)"
  fi
  echo "# ---- provenance<TAB>src<TAB>dest<TAB>sha256 ----"
} > "$MANIFEST.hdr"
cat "$MANIFEST" >> "$MANIFEST.hdr" && mv "$MANIFEST.hdr" "$MANIFEST"

echo "=== 7. tarball ==="
( cd "$OUT" && tar -cf - seed | zstd -19 -T0 -o seed.tar.zst )
SEEDSUM="$(digest -a sha256 "$OUT/seed.tar.zst" 2>/dev/null || sha256sum "$OUT/seed.tar.zst" | awk '{print $1}')"
echo "seed.tar.zst sha256: $SEEDSUM" | tee -a "$MANIFEST"

echo
echo "DONE."
echo "  seed tree: $SEED"
echo "  manifest:  $MANIFEST"
echo "  tarball:   $OUT/seed.tar.zst  ($SEEDSUM)"
```

Notes on the script:

- **`digest -a sha256`** is the illumos-native hash tool; `sha256sum` is the
  fallback if GNU coreutils happens to be installed. **VERIFY `digest` is
  present** (it ships with libmd/`SUNWcs` on illumos).
- `cp -RP@` preserves symlinks and extended attributes; falls back to `cp -RP` if
  `@` (extattr) is unsupported. Symlinks are intentionally **not** hashed in the
  manifest (they have no stable content sum); only real files are recorded.
- The script copies the **live gcc prefix wholesale** — simplest correct thing;
  trimming it (dropping docs/man) is a later optimization, not a stage0 need.

---

## 4. Verification (outside the build host)

Goal: prove the seed compiles, links, and runs a binary that resolves libc **from
the seed**, not the system. Run on a *clean* illumos box (or a fresh zone) that
does not have gcc-10 installed, so a leak to the host is obvious.

### 4.1 Unpack + relocate

```sh
mkdir -p /tmp/S && tar -I zstd -xf seed.tar.zst -C /tmp/S
SEED=/tmp/S/seed
# fix the seed's own elfedit first (host elfedit or LD_LIBRARY_PATH), then
# walk every ELF and set $ORIGIN-relative RUNPATH (the stage0 hook does this;
# for a manual smoke test the wrapper -Wl,-R below is enough).
```

### 4.2 hello-world compile + link + run

```sh
cat > /tmp/hello.c <<'EOF'
#include <stdio.h>
int main(void){ puts("hello from solnix seed"); return 0; }
EOF

TRIPLE=$("$SEED/usr/gcc/10/bin/gcc" -dumpmachine)
"$SEED/usr/gcc/10/bin/gcc" \
  -B"$SEED/usr/gcc/10/lib/gcc/$TRIPLE/10/" \
  --sysroot="$SEED" \
  -isystem "$SEED/usr/include" \
  -L"$SEED/lib/amd64" -L"$SEED/usr/lib/amd64" \
  -Wl,-R,"$SEED/lib/amd64" -Wl,-R,"$SEED/usr/lib/amd64" \
  -m64 /tmp/hello.c -o /tmp/hello

/tmp/hello   # must print: hello from solnix seed
```

(For the *relocatable* proof, the RUNPATH baked by the stage0 hook uses
`$ORIGIN/...` rather than the absolute `-Wl,-R` above; the absolute form is fine
for a first smoke test.)

### 4.3 Confirm it resolves libc from the seed (elfdump, not readelf)

```sh
# NEEDED + RUNPATH the binary carries:
"$SEED/usr/bin/elfdump" -d /tmp/hello | egrep 'NEEDED|RUNPATH|RPATH'
#   expect: NEEDED libc.so.1   and RUNPATH containing the seed's lib/amd64

# what ld.so.1 ACTUALLY binds at runtime (the real proof):
LD_DEBUG=libs /tmp/hello 2>&1 | egrep 'libc\.so\.1|find object'
#   every path must be under $SEED, NONE under /lib or /usr/lib of the host
```

A clean run where `ldd`/`LD_DEBUG` shows `libc.so.1 => /tmp/S/seed/lib/amd64/libc.so.1`
(and nothing resolving to the host `/lib/amd64`) is the T0.3 success gate. This is
also the concrete artifact for **P0.3 (RUNPATH spike)** in the roadmap.

### 4.4 C++ check (optional but cheap)

Repeat 4.2 with `g++` and a one-line `<iostream>` program; confirm `elfdump -d`
shows `libstdc++.so.6` and `libgcc_s.so.1` resolving from the seed.

---

## 5. Open questions / risks

Ranked by how likely they are to bite stage0.

1. **gcc relocatability (highest).** Whether OI's `developer/gcc-10` honors
   `-B`/`GCC_EXEC_PREFIX`/`--sysroot` enough to fully ignore its built-in
   `/usr/gcc/10` and `/usr/include` absolutes. If not, the wrapper can't save us
   and we must rebuild gcc under Nix earlier than Phase 1 planned. **Test first**
   (§4.2 on a host with no `/usr/gcc/10`).
2. **`include-fixed` host leakage.** gcc's fixed headers may hardcode the OI
   host's `/usr/include`. Mitigation: drop `include-fixed` + `-isystem` the seed
   headers, or re-run `fixincludes` at stage0. **VERIFY hello-world + a header
   that gets fixincluded (e.g. something touching `<stdio.h>` internals).**
3. **`elfedit` RUNPATH grow-in-place.** If the existing dynamic section can't hold
   a longer RUNPATH string, `elfedit` may refuse; we'd have to relink those
   objects instead of editing. Test on `libstdc++.so.6` and `cc1plus`.
4. **Which `as`/`ld` gcc invokes.** Hardcoding `/usr/bin/ld` is wrong if gcc calls
   a `collect2`/`gld` on its own path. Script resolves via `-print-prog-name`, but
   **VERIFY the seeded set actually satisfies a link on the clean box.**
5. **Sonames / library versions (VERIFY list).** `libm.so.2`, `libresolv.so.2`,
   `libld.so.*`, `liblddbg` exact versions differ across illumos revs. Script
   globs rather than pins; the manifest records what was actually captured. Cross
   -check `elfdump -d /usr/bin/ld` and `elfdump -d libc.so.1` for the real
   NEEDED set before trusting the enumeration in §1.
6. **CTF at bootstrap.** Asserted **not needed** for stage0 (user-binary link, no
   kernel). If any stage0 link pulls CTF, revisit and seed `ctfconvert`/
   `ctfmerge` from `/opt/onbld/bin`. Low risk but unproven.
7. **Symbol versioning / mapfiles.** illumos libc is heavily version-scoped
   (SUNW_1.x, ILLUMOS_0.x). The linker needs its mapfiles (`usr/lib/ld`) and the
   versioned `.so.1` files; if `usr/lib/ld` isn't in proto we fall back to the
   live host copy (script handles this) — but a mismatch between proto libc
   versions and host-copied mapfiles is a theoretical hazard. Prefer everything
   from one source (proto) where possible.
8. **32-bit (`-m32`).** Deliberately skipped to stay minimal. If any stage0 build
   needs 32-bit, add `lib/`, `usr/lib/` (non-amd64) crt/libc/values. Add when a
   build actually demands it, not before.
9. **Proto vs host drift for gcc.** The gcc we seed (host) was built against the
   *host's* system, which may be a slightly older illumos than the *proto* libc
   (gate HEAD). Usually fine (illumos ABI is stable + versioned), but a large gap
   between the gcc-build-time headers and the proto headers could surface. Keep
   the host and the gate commit close; record both in the manifest.

---

## Appendix: source-path quick reference

| Thing | Source (host path) | Seed dest |
|---|---|---|
| proto area (amd64) | `/code/illumos-gate/proto/root_i386` | — |
| libc | `<proto>/lib/amd64/libc.so.1` | `lib/amd64/libc.so.1` |
| crt objects | `<proto>/usr/lib/amd64/crt{1,i,n}.o` | `usr/lib/amd64/` |
| values objects | `<proto>/usr/lib/amd64/values-*.o` | `usr/lib/amd64/` |
| siblings | `<proto>/lib/amd64/lib{m,socket,nsl,resolv,elf}.so.*` | `lib/amd64/` |
| headers | `<proto>/usr/include` | `usr/include` |
| runtime linker | `<proto>/lib/amd64/ld.so.1` | `lib/amd64/ld.so.1` |
| ld's libraries | `<proto>/usr/lib/amd64/lib{ld,ldstab,lddbg}.so.*` | `usr/lib/amd64/` |
| linker mapfiles | `<proto>/usr/lib/ld` (fallback: `/usr/lib/ld`) | `usr/lib/ld` |
| Solaris ld | `/usr/bin/ld` | `usr/bin/ld` |
| ELF tools | `/usr/bin/{elfdump,elfedit,elffile,nm,ar,mcs}` | `usr/bin/` |
| gcc-10 | `/usr/gcc/10` (whole prefix) | `usr/gcc/10` |
| CTF tools | `/opt/onbld/bin/{ctfconvert,ctfmerge}` | **omitted at stage0** |
