#!/bin/sh
# slice-closure-negative-control.sh -- prove mk-proto-slice's CLOSURE GATE can fail.
#
# ⚠️ READ THIS BEFORE TRUSTING ANY SLICE. The obvious negative control -- delete a
# library from a built slice and re-run the exec test -- CANNOT WORK ON illumos, and
# discovering why is more useful than the control would have been:
#
#   illumos ld.so.1 falls back to the HOST default search path (/lib, /usr/lib) once
#   the RUNPATH is exhausted. So a library missing from the slice is silently supplied
#   by the build host, and the binary runs perfectly. Measured: hiding libcmdutils.so.1
#   from a copy of illumos-core-utils and repointing its RUNPATH still produced
#   EXEC 68/68, FAILED 0 -- while ldd showed the resolution had moved to /lib.
#
# The consequence is important beyond this script: AN EXEC TEST ON THE BUILD HOST
# CANNOT PROVE A CLOSURE IS COMPLETE. It proves the binaries run *here*, where the
# whole OS is present. The claim "this slice is self-contained" has to be enforced
# where it is actually decided -- in the derivation, at build time, by the DT_NEEDED
# resolution gate. That gate is what this script attacks.
#
# THE ATTACK: build a slice that needs a library the proto cannot supply, with nothing
# in allowUnresolved. If mk-proto-slice's gate is real, the BUILD FAILS. If the build
# succeeds, the gate is decorative and every slice built with it is unverified.
#
#   sh slice-closure-negative-control.sh
set -u
. /etc/profile.d/nix-illumos.sh
NIXDIR=/var/tmp/solnix-nix
PROTO=/var/tmp/proto-unpack/wn8w5j1pkc9k3zgkq3bsqxk285dqbi7m-illumos-gate-proto
W=/var/tmp/closure-negctl
mkdir -p "$W"

pass=0; fail=0
verdict() { # $1 = label, $2 = expected(BUILD-FAILS|BUILD-OK), $3 = actual rc
  if [ "$2" = "BUILD-FAILS" ]; then
    if [ "$3" -ne 0 ]; then echo "  $1 ... PASS (build failed as required)"; pass=$((pass+1));
    else echo "  $1 ... *** FAIL: the build SUCCEEDED, the gate is decorative ***"; fail=$((fail+1)); fi
  else
    if [ "$3" -eq 0 ]; then echo "  $1 ... PASS (build succeeded as required)"; pass=$((pass+1));
    else echo "  $1 ... *** FAIL: the build failed when it should have worked ***"; fail=$((fail+1)); fi
  fi
}

# ---------------------------------------------------------------------------
# Control 1 (THE NEGATIVE): a slice containing svccfg, which NEEDs libxml2.so.16 --
# a soname measured to exist nowhere in the proto -- with an EMPTY allowUnresolved.
# The closure gate must refuse to build this.
cat > "$W/neg1.nix" <<'NIX'
let
  gate = builtins.path { path = /var/tmp/proto-unpack/wn8w5j1pkc9k3zgkq3bsqxk285dqbi7m-illumos-gate-proto; name = "illumos-gate-proto"; };
in import /var/tmp/solnix-nix/mk-proto-slice.nix {
  inherit gate;
  name = "negctl-unresolved";
  bins = [ "usr/sbin/svccfg" ];
  allowUnresolved = [ ];   # deliberately empty: libxml2.so.16 must therefore be FATAL
}
NIX
echo "=== control 1 (NEGATIVE): unresolvable soname, allowUnresolved empty ==="
nix-build "$W/neg1.nix" --no-out-link > "$W/neg1.log" 2>&1
rc1=$?
grep "resolve nowhere" "$W/neg1.log" | head -2 | sed 's,^,      ,'
verdict "unresolvable soname is FATAL" BUILD-FAILS $rc1

# ---------------------------------------------------------------------------
# Control 2 (THE POSITIVE): the SAME slice with libxml2.so.16 declared. It must build.
# Without this, control 1 could "pass" by the derivation being broken for some
# unrelated reason -- an all-negative suite reports a clean sweep while measuring
# nothing (the exact shape of the od zero-padding bug in docs/gate-fod-findings.md §6).
sed 's,allowUnresolved = \[ \];.*,allowUnresolved = [ "libxml2.so.16" "libz.so.1" "libstdc++.so.6" "libgcc_s.so.1" ];,' "$W/neg1.nix" > "$W/pos1.nix"
echo "=== control 2 (POSITIVE): same slice, soname DECLARED external ==="
nix-build "$W/pos1.nix" --no-out-link > "$W/pos1.log" 2>&1
rc2=$?
tail -2 "$W/pos1.log" | sed 's,^,      ,'
verdict "declared-external soname builds" BUILD-OK $rc2

# ---------------------------------------------------------------------------
# Control 3 (NEGATIVE): a bins entry that is not in the proto at all. A slice must not
# silently skip a missing binary -- image l2 shipped NO reboot because its staging loop
# used `[ -e ] &&`, which skips silently. This is that class, gated.
cat > "$W/neg2.nix" <<'NIX'
let
  gate = builtins.path { path = /var/tmp/proto-unpack/wn8w5j1pkc9k3zgkq3bsqxk285dqbi7m-illumos-gate-proto; name = "illumos-gate-proto"; };
in import /var/tmp/solnix-nix/mk-proto-slice.nix {
  inherit gate;
  name = "negctl-missing-bin";
  bins = [ "usr/bin/ls" "usr/bin/this-binary-does-not-exist" ];
}
NIX
echo "=== control 3 (NEGATIVE): a bins entry absent from the proto ==="
nix-build "$W/neg2.nix" --no-out-link > "$W/neg2.log" 2>&1
rc3=$?
grep "not in proto" "$W/neg2.log" | head -1 | sed 's,^,      ,'
verdict "missing bins entry is FATAL" BUILD-FAILS $rc3

# ---------------------------------------------------------------------------
# Control 4 (NEGATIVE): a hardlink group whose head is absent. The halt/reboot/poweroff
# group is the whole reason hardlinkGroups exists; a typo in it must not pass.
cat > "$W/neg3.nix" <<'NIX'
let
  gate = builtins.path { path = /var/tmp/proto-unpack/wn8w5j1pkc9k3zgkq3bsqxk285dqbi7m-illumos-gate-proto; name = "illumos-gate-proto"; };
in import /var/tmp/solnix-nix/mk-proto-slice.nix {
  inherit gate;
  name = "negctl-bad-hardlink";
  bins = [ ];
  hardlinkGroups = [ [ "usr/sbin/nonexistent-halt" "usr/sbin/reboot" ] ];
}
NIX
echo "=== control 4 (NEGATIVE): hardlink group head absent from the proto ==="
nix-build "$W/neg3.nix" --no-out-link > "$W/neg3.log" 2>&1
rc4=$?
grep -i "hardlink group head" "$W/neg3.log" | head -1 | sed 's,^,      ,'
verdict "bad hardlink group is FATAL" BUILD-FAILS $rc4

echo "-------------------------------------------------------------"
echo "closure-gate controls: $pass passed, $fail failed"
echo "(2 negative + 1 positive + 2 negative; the POSITIVE is what proves the suite is"
echo " not passing by rejecting everything)"
[ "$fail" -eq 0 ] || exit 1
