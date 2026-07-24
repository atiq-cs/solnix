#!/usr/bin/env bash
# oi-smf-gates.sh — build + GATE the P1.5 SMF prerequisites on the illumos host:
#   GATE 1: externalLibs slice + base-tools re-RUNPATH'd -> svc.startd (and the
#           whole SMF stack) is 100% /nix/store-clean (zero host lib leaks).
#   GATE 2: lib/smf/xml.nix generator -> real SMF manifest XML + method scripts,
#           validated with `xmllint --dtdvalid` AND `svccfg validate` on-target.
#
# Continues oi-world-slices.sh. Run ON the illumos host as root.
# Assumes: Nix 2.3.16 at /nix-tools/bin; gate proto built; the .nix files copied
# to /var/tmp/solnix-nix (incl. lib/smf/{xml,tests}.nix).
set -euo pipefail

export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
NIXDIR=/var/tmp/solnix-nix
DTD=/usr/share/lib/xml/dtd/service_bundle.dtd.1

[ -f "$NIXDIR/default.nix" ] || { echo "FATAL: copy pkgs/illumos/*.nix + lib/smf/*.nix to $NIXDIR first" >&2; exit 1; }
[ -f "$DTD" ] || { echo "FATAL: DTD not at $DTD (find / -name 'service_bundle.dtd*')" >&2; exit 1; }

# host /lib, /usr/lib, /usr/gcc leaks in an ldd (empty = clean).
ldd_leaks() { ldd "$1" 2>/dev/null | awk '/=>/{print}' | egrep -v '/nix/store/' | egrep '/lib/|/usr/lib/|/usr/gcc/' || true; }

echo "=================== externalLibs slice ==================="
EL="$(nix-build "$NIXDIR/default.nix" -A externalLibs --no-out-link)"
echo "externalLibs: $EL"
echo "-- contents (32-bit) --"; ls -1 "$EL/usr/lib" | egrep 'libxml2|libz|libicu|libstdc|libgcc'
echo "-- ldd each external lib: every dep must be /nix/store --"
for l in libxml2.so.16 libz.so.1 libicuuc.so.78 libicudata.so.78 libstdc++.so.6 libgcc_s.so.1; do
  leaks="$(ldd_leaks "$EL/usr/lib/$l")"; echo "   $l: ${leaks:-<clean>}"
done

echo "=================== GATE 1: base-tools SMF stack ldd-clean ==================="
BT="$(nix-build "$NIXDIR/default.nix" -A base-tools --no-out-link)"
echo "base-tools: $BT"
echo "-- svc.startd RUNPATH --"
elfdump -d "$BT/lib/svc/bin/svc.startd" 2>/dev/null | awk '/RUNPATH/{print $NF}'
echo "-- svc.startd ldd (the GATE: 100% /nix/store) --"
ldd "$BT/lib/svc/bin/svc.startd" 2>&1
echo "-- leak check across the SMF stack + coreutils --"
gate1_fail=0
for t in usr/bin/svcs usr/sbin/svcadm lib/svc/bin/svc.startd lib/svc/bin/svc.configd \
         sbin/init sbin/sh usr/bin/ls usr/bin/cp usr/bin/mv usr/bin/cat usr/bin/rm usr/bin/mkdir usr/bin/ln; do
  leaks="$(ldd_leaks "$BT/$t")"
  if [ -z "$leaks" ]; then echo "   CLEAN  $t"; else echo "   LEAK   $t: $leaks"; gate1_fail=1; fi
done
[ "$gate1_fail" -eq 0 ] && echo "GATE 1 PASS: every SMF-stack binary is 100% /nix/store" || { echo "GATE 1 FAIL"; exit 1; }

echo "=================== GATE 2: SMF manifest generation ==================="
cd "$NIXDIR"
echo "-- xmlEscape self-check --"
nix-instantiate --eval lib/smf/tests.nix -A _escCheck
SM="$(nix-build lib/smf/tests.nix -A sshdManifest --no-out-link)"
OM="$(nix-build lib/smf/tests.nix -A oneshotManifest --no-out-link)"
SMETH="$(nix-build lib/smf/tests.nix -A sshdStartMethod --no-out-link)"
OMETH="$(nix-build lib/smf/tests.nix -A oneshotStartMethod --no-out-link)"
echo "sshd manifest:    $SM"
echo "oneshot manifest: $OM"
echo "sshd method:      $SMETH"
echo "oneshot method:   $OMETH"
echo "-- generated sshd manifest --"; cat "$SM"
echo "-- generated oneshot manifest --"; cat "$OM"
echo "-- generated sshd start method --"; cat "$SMETH"
echo "-- xmllint --dtdvalid (the build-time gate, design 2.6) --"
gate2_fail=0
for m in "$SM" "$OM"; do
  if xmllint --noout --dtdvalid "$DTD" "$m"; then echo "   DTD-VALID  $m"; else echo "   DTD-FAIL   $m"; gate2_fail=1; fi
done
echo "-- svccfg validate (on-target authority, stronger than xmllint) --"
if [ -x /usr/sbin/svccfg ]; then
  for m in "$SM" "$OM"; do
    /usr/sbin/svccfg validate "$m" && echo "   svccfg VALID  $m" || { echo "   svccfg ISSUE  $m"; gate2_fail=1; }
  done
fi
[ "$gate2_fail" -eq 0 ] && echo "GATE 2 PASS: generated manifests are DTD-valid + svccfg-valid" || { echo "GATE 2 FAIL"; exit 1; }

echo
echo "=== NAR hashes (for capture) ==="
echo "externalLibs     NAR: $(nix-store -q --hash "$EL")"
echo "base-tools       NAR: $(nix-store -q --hash "$BT")"
echo "sshd manifest    NAR: $(nix-store -q --hash "$SM")"
echo "oneshot manifest NAR: $(nix-store -q --hash "$OM")"
echo
echo "=== store paths (for README) ==="
echo "externalLibs: $EL"
echo "base-tools:   $BT"
echo "DTD:          $DTD"
