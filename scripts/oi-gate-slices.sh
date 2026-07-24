#!/usr/bin/env bash
# oi-gate-slices.sh — reproduce GATES A/B/C of docs/design-gate-derivation.md on
# the illumos build host: ingest the gate proto as a store path (A), slice+relocate
# libc (B), compile+link+run hello against the sliced libc (C).
#
# Run ON the illumos host as root. Assumes:
#   - Nix 2.3.16 at /nix-tools/bin (scripts/oi-nix-setup.sh)
#   - the built gate proto at /code/illumos-gate/proto/root_i386
#   - the .nix files copied to /var/tmp/solnix-nix (this script scps them if run
#     from the dev box via the wrapper below; on the host they must be present)
set -euo pipefail

export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
NIXDIR=/var/tmp/solnix-nix

[ -f "$NIXDIR/default.nix" ] || { echo "FATAL: copy pkgs/illumos/*.nix to $NIXDIR first" >&2; exit 1; }

echo "=================== GATE A: gate proto as a store path ==================="
G="$(nix-build "$NIXDIR/default.nix" -A gate --no-out-link)"
echo "gate store path: $G"
ls -la "$G/lib/amd64/libc.so.1"
ls -d "$G/usr/include"
ls -la "$G/kernel/amd64/genunix"
du -sh "$G"
echo "GATE A: PASS"

echo "=================== GATE B: libc slice + RUNPATH relocate ==============="
L="$(nix-build "$NIXDIR/default.nix" -A libc --no-out-link)"
echo "libc store path: $L"
echo "-- libc.so.1 RUNPATH --"
/usr/bin/elfdump -d "$L/lib/amd64/libc.so.1" | egrep -i 'SONAME|RUNPATH'
echo "-- siblings RUNPATH --"
for so in libm.so.2 libsocket.so.1 libnsl.so.1 libresolv.so.2 libelf.so.1; do
  echo "$so: $(/usr/bin/elfdump -d "$L/lib/amd64/$so" 2>/dev/null | awk '/RUNPATH/{print $NF}')"
done
echo "GATE B: PASS"

echo "=================== GATE C: hello against the sliced libc =============="
"$NIXDIR/gate-c-hello.sh" "$L"

echo
echo "=== hashes (for capture) ==="
echo "gate NAR: $(nix-store -q --hash "$G")"
echo "libc NAR: $(nix-store -q --hash "$L")"
