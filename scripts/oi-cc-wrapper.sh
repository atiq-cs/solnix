#!/usr/bin/env bash
# oi-cc-wrapper.sh — emit cc-wrapper-style scripts so a package build can pick
# GCC-14 OR Clang-21 (the sliced store toolchains) against the sliced libc +
# headers + Solaris ld, with the /nix/store RUNPATH baked and the host
# /usr/gcc/14/lib leak scrubbed. This is the "wire both into a usable form"
# deliverable for docs/design-toolchains.md — the foundation the package-batch
# work drives.
#
#   ./oi-cc-wrapper.sh <outdir> <gcc14-store> <clang-store> <libc-store> [ld-store]
#
# Produces in <outdir>:  solnix-gcc  solnix-g++  solnix-clang  solnix-clang++
# Each is a self-contained wrapper: a package build sets CC=<outdir>/solnix-gcc
# (or solnix-clang) and CXX accordingly, and gets store-clean binaries.
#
# WHY a wrapper and not raw flags: gcc's DRIVER bakes an absolute host
# -R /usr/gcc/14/lib/amd64 into every C++ link (configured --with-rpath), which
# ld.so.1 resolves from the HOST before the store copy -> a leak. clang is
# cleaner (its -R follows --gcc-toolchain, which we point at the store) but we
# scrub uniformly so BOTH emit store-only RUNPATHs. The scrub is an elfedit pass
# that drops any leading host /usr/gcc path from the output binary's RUNPATH.
set -euo pipefail

OUT="${1:?usage: oi-cc-wrapper.sh <outdir> <gcc14> <clang> <libc> [ld]}"
GCC14="${2:?need gcc14 store path}"
CLANG="${3:?need clang store path}"
LIBC="${4:?need libc store path}"
LDSLICE="${5:-}"   # optional: store illumos-ld slice; if given, drive the store Solaris ld

mkdir -p "$OUT"

LIBDIR="$LIBC/lib/amd64"
USRLIB="$LIBC/usr/lib/amd64"
INC="$LIBC/usr/include"
GCCRT="$GCC14/usr/gcc/14/lib/amd64"
# gcc's OWN freestanding/intrinsic headers (stdatomic.h, stddef.h, *mmintrin.h,
# stdarg.h, ...). -nostdinc drops these, so add the gcc-internal include dir
# back FIRST (before the sliced libc headers). Without it any code using
# stdatomic.h or SSE intrinsics fails to compile (openssl, zstd, ...).
GCCINC="$(ls -d "$GCC14"/usr/gcc/14/lib/gcc/*/*/include 2>/dev/null | grep -E '/[0-9]+\.[0-9]+\.[0-9]+/include$' | head -1)"
[ -n "$GCCINC" ] || GCCINC="$(ls -d "$GCC14"/usr/gcc/14/lib/gcc/*/*/include 2>/dev/null | head -1)"
# clang's OWN builtin/resource headers (stdatomic.h, intrinsics). -nostdinc drops
# the resource dir on this OI slice, so add it back explicitly for clang.
CLANGINC="$(ls -d "$CLANG"/usr/clang/21/lib/clang/*/include 2>/dev/null | head -1)"

# If an ld slice is given, put its bin first on PATH so gcc/clang drive the STORE
# Solaris ld (usr/bin/ld). Else the host /usr/bin/ld (Phase-1 host-impure) is used.
LD_PATH_PREFIX=""
[ -n "$LDSLICE" ] && LD_PATH_PREFIX="$LDSLICE/usr/bin:"

# common tail: scrub any host /usr/gcc RUNPATH entry from the produced binary so
# libstdc++/libgcc_s resolve from the STORE, never host. Only runs when -o names
# a real ELF (skip -c / -E / -S compile-only invocations).
gen_scrub() {
cat <<'SCRUB'
# --- post-link RUNPATH scrub (drop host /usr/gcc leak) ---
outfile=""; want_o=0
for a in "$@"; do
  if [ "$want_o" = 1 ]; then outfile="$a"; want_o=0; continue; fi
  [ "$a" = "-o" ] && want_o=1
done
# only scrub a linked ELF (has a .dynamic RUNPATH); skip -c/-S/-E and missing out.
case " $* " in *" -c "*|*" -S "*|*" -E "*) outfile="";; esac
if [ -n "$outfile" ] && [ -f "$outfile" ]; then
  # compute RUNPATH without a pipefail-sensitive pipe in the if-condition.
  cur=$(/usr/bin/elfdump -d "$outfile" 2>/dev/null | awk '/RUNPATH/{print $NF; exit}') || cur=""
  if [ -n "$cur" ]; then
    new=$(printf '%s' "$cur" | tr ':' '\n' | grep -v '^/usr/gcc' | paste -sd: -) || new="$cur"
    if [ "$new" != "$cur" ]; then
      chmod u+w "$outfile" 2>/dev/null || true
      /usr/bin/elfedit -e "dyn:runpath $new" "$outfile" 2>/dev/null || true
    fi
  fi
fi
SCRUB
}

# ---- GCC-14 C wrapper ----
cat > "$OUT/solnix-gcc" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="${LD_PATH_PREFIX}/usr/gnu/bin:/usr/bin:\$PATH"
"$GCC14/usr/gcc/14/bin/gcc" -m64 \\
  -nostdinc -isystem "$GCCINC" -isystem "$INC" -B "$USRLIB" \\
  -L "$LIBDIR" -L "$USRLIB" -Wl,-R,"$LIBDIR" -Wl,-R,"$GCCRT" "\$@"
$(gen_scrub)
EOF

# ---- GCC-14 C++ wrapper (let g++ find its OWN store C++ headers; add sliced libc inc) ----
cat > "$OUT/solnix-g++" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="${LD_PATH_PREFIX}/usr/gnu/bin:/usr/bin:\$PATH"
"$GCC14/usr/gcc/14/bin/g++" -m64 \\
  -isystem "$INC" -B "$USRLIB" \\
  -L "$LIBDIR" -L "$USRLIB" -Wl,-R,"$LIBDIR" -Wl,-R,"$GCCRT" "\$@"
$(gen_scrub)
EOF

# ---- Clang-21 C wrapper (--gcc-toolchain = STORE gcc14 for crt+libgcc) ----
# clang ships its OWN freestanding headers (stdatomic.h, intrinsics) in its
# resource dir, added even under -nostdinc, so we do NOT inject gcc's internal
# headers here (that would shadow clang's builtins).
cat > "$OUT/solnix-clang" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="${LD_PATH_PREFIX}/usr/gnu/bin:/usr/bin:\$PATH"
"$CLANG/usr/clang/21/bin/clang" -target x86_64-pc-solaris2.11 \\
  --gcc-toolchain="$GCC14/usr/gcc/14" \\
  -nostdinc -isystem "$CLANGINC" -isystem "$INC" -B "$USRLIB" \\
  -L "$LIBDIR" -L "$USRLIB" -Wl,-R,"$LIBDIR" -Wl,-R,"$GCCRT" "\$@"
$(gen_scrub)
EOF

# ---- Clang-21 C++ wrapper (libstdc++ from store gcc14) ----
cat > "$OUT/solnix-clang++" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="${LD_PATH_PREFIX}/usr/gnu/bin:/usr/bin:\$PATH"
"$CLANG/usr/clang/21/bin/clang++" -target x86_64-pc-solaris2.11 \\
  --gcc-toolchain="$GCC14/usr/gcc/14" -stdlib=libstdc++ \\
  -isystem "$INC" -B "$USRLIB" \\
  -L "$LIBDIR" -L "$USRLIB" -Wl,-R,"$LIBDIR" -Wl,-R,"$GCCRT" "\$@"
$(gen_scrub)
EOF

chmod +x "$OUT"/solnix-gcc "$OUT"/solnix-g++ "$OUT"/solnix-clang "$OUT"/solnix-clang++
echo "wrappers written to $OUT:"
ls -1 "$OUT"/solnix-*
