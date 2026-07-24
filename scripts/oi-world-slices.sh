#!/usr/bin/env bash
# oi-world-slices.sh — build and GATE the core illumos world slices on the
# illumos host: rtld, ld, sys, base-tools, systemPath. Continues
# oi-gate-slices.sh (gate/libc/hello) with the rest of docs/design-gate-
# derivation.md §2/§4. Run ON the illumos host as root.
#
# Assumes:
#   - Nix 2.3.16 at /nix-tools/bin (scripts/oi-nix-setup.sh)
#   - the built gate proto at /code/illumos-gate/proto/root_i386
#   - the .nix files copied to /var/tmp/solnix-nix
set -euo pipefail

export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
NIXDIR=/var/tmp/solnix-nix
CTFDUMP=/opt/onbld/bin/i386/ctfdump

[ -f "$NIXDIR/default.nix" ] || { echo "FATAL: copy pkgs/illumos/*.nix to $NIXDIR first" >&2; exit 1; }

# helper: is every NEEDED of $1 resolvable under a /nix/store RUNPATH (ldd-clean)?
# prints the ldd lines that resolve to host /lib or /usr/lib (a leak) — empty=clean.
ldd_leaks() { ldd "$1" 2>/dev/null | awk '/=>/ {print}' | egrep -v '/nix/store/' | egrep '/lib/|/usr/lib/' || true; }

echo "=================== rtld: runtime linker slice ==================="
R="$(nix-build "$NIXDIR/default.nix" -A rtld --no-out-link)"
echo "rtld store path: $R"
ls -la "$R/lib/amd64/ld.so.1"
echo "-- elfdump: is it the rtld? (SONAME /lib/amd64/ld.so.1) --"
/usr/bin/elfdump -d "$R/lib/amd64/ld.so.1" | egrep -i 'SONAME|RUNPATH' || true
file "$R/lib/amd64/ld.so.1" || true
echo "rtld: built"

echo "=================== ld: Solaris link-editor slice ==================="
LD="$(nix-build "$NIXDIR/default.nix" -A ld --no-out-link)"
echo "ld store path: $LD"
echo "-- ld RUNPATH (must contain a /nix/store libc path, NOT /usr/gcc/10) --"
/usr/bin/elfdump -d "$LD/usr/bin/ld" | egrep -i 'NEEDED|RUNPATH|RPATH'
echo "-- ldd \$out/usr/bin/ld (all libs must be /nix/store) --"
ldd "$LD/usr/bin/ld" 2>&1
echo "-- ldd leaks (host /lib or /usr/lib) --"; leaks="$(ldd_leaks "$LD/usr/bin/ld")"; echo "${leaks:-<none — clean>}"
echo "-- \$out/usr/bin/ld -V (Solaris ld version) --"
"$LD/usr/bin/ld" -V 2>&1 || echo "WARN: ld -V failed"

echo "=================== sys: kernel slice (CTF survives) ==================="
S="$(nix-build "$NIXDIR/default.nix" -A sys --no-out-link)"
echo "sys store path: $S"
ls -la "$S/platform/i86pc/kernel/amd64/unix" "$S/kernel/amd64/genunix"
echo "-- genunix has .SUNW_ctf section? --"
/usr/bin/elfdump -c "$S/kernel/amd64/genunix" 2>/dev/null | grep -i '.SUNW_ctf' || echo "FAIL: no CTF section"
echo "-- ctfdump genunix (first lines; proves CTF survived the slice) --"
if [ -x "$CTFDUMP" ]; then "$CTFDUMP" "$S/kernel/amd64/genunix" 2>&1 | head -12 || true; else echo "(ctfdump not at $CTFDUMP)"; fi

echo "=================== base-tools: minimal userland slice ==================="
BT="$(nix-build "$NIXDIR/default.nix" -A base-tools --no-out-link)"
echo "base-tools store path: $BT"
for t in usr/bin/svcs usr/bin/ls lib/svc/bin/svc.startd; do
  echo "-- $t --"
  echo "RUNPATH: $(/usr/bin/elfdump -d "$BT/$t" 2>/dev/null | awk '/RUNPATH/{print $NF}')"
  echo "ldd:"; ldd "$BT/$t" 2>&1 | sed 's/^/    /'
  leaks="$(ldd_leaks "$BT/$t")"; echo "ldd leaks: ${leaks:-<none — clean>}"
done
echo "-- run svcs (from store path) --"; "$BT/usr/bin/svcs" -a 2>&1 | head -3 || echo "(svcs needs a running repository; may exit nonzero — RUNPATH is what matters)"
echo "-- run ls (from store path) --"; "$BT/usr/bin/ls" -1 "$BT/usr/bin" 2>&1 | head -3

echo "=================== systemPath: composed world ==================="
SP="$(nix-build "$NIXDIR/default.nix" -A systemPath --no-out-link)"
echo "systemPath store path: $SP"
echo "-- tree spot-check --"
ls -la "$SP/lib/amd64/libc.so.1" "$SP/lib/amd64/ld.so.1" "$SP/usr/bin/ld" \
       "$SP/lib/svc/bin/svc.startd" "$SP/platform/i86pc/kernel/amd64/unix" \
       "$SP/kernel/amd64/genunix" 2>&1
echo "-- run a tool from the systemPath (ls) --"
"$SP/usr/bin/ls" -1 "$SP/usr/bin" 2>&1 | head -3

echo
echo "=== NAR hashes (for capture) ==="
echo "rtld        NAR: $(nix-store -q --hash "$R")"
echo "ld          NAR: $(nix-store -q --hash "$LD")"
echo "sys         NAR: $(nix-store -q --hash "$S")"
echo "base-tools  NAR: $(nix-store -q --hash "$BT")"
echo "systemPath  NAR: $(nix-store -q --hash "$SP")"
echo
echo "=== store paths (for README) ==="
echo "rtld:       $R"
echo "ld:         $LD"
echo "sys:        $S"
echo "base-tools: $BT"
echo "systemPath: $SP"
