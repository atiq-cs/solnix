#!/bin/sh
# slice-negative-control.sh -- prove that slice-exec-test.sh CAN report failure.
#
# ⚠️ WHY THIS FILE EXISTS. In this project a guard that could not fail has manufactured
# false confidence SEVEN times: sg-guard.sh reported CLEAN while auditing nothing
# because every AWS call failed into `|| true`; a `stat -c %s` size gate was always
# false because illumos has no stat(1); an ELF check passed on Linux and failed on
# illumos because od zero-pads. And slice-exec-test.sh ITSELF did it once, on its first
# run: it wrapped every binary in `timeout 5`, illumos HAS NO timeout(1), every exec
# returned rc=127, 127 is not an ld.so.1 abort, and it reported EXEC-OK 68 of 68 while
# executing NOTHING.
#
# So: hide a library the slice genuinely needs, re-run the exec test, and require it to
# FAIL. If it still passes, the test is measuring nothing and no result from it counts.
#
#   sh slice-negative-control.sh <slice-store-path> [soname]
# ⚠️ WHY SABOTAGING A COPY DOES NOT WORK, MEASURED. The obvious control -- copy the
# slice to scratch, delete a library from the COPY, re-run the test -- was tried FIRST
# and reported zero failures. That was not a test bug; it is how the RUNPATH works.
# mk-proto-slice bakes ABSOLUTE $out paths into every binary:
#     $ORIGIN:/nix/store/<hash>-illumos-core-utils/lib-32:.../lib-64
# so a copy at /var/tmp/negctl/slice still resolves its libraries out of the ORIGINAL
# store path. `ldd` on the sabotaged copy proved it -- byte-identical resolution to the
# intact slice, every soname pointing back into /nix/store. The sabotage was invisible
# because it was never consulted.
#
# THE WORKING CONTROL therefore attacks the RESOLUTION, not the file: rewrite the
# copy's RUNPATH to point at the copy's own (broken) lib dirs, so the missing library
# is actually looked for where it is missing. That is a real unsatisfiable NEEDED,
# which is exactly the failure mode this exists to detect.
#
# The general lesson, and the reason this comment is long: A CONTROL CAN BE
# STRUCTURALLY INCAPABLE OF WORKING, and it looks identical to a passing test. The only
# way to tell was to observe the mechanism -- run ldd on the sabotaged copy and see
# where it actually resolved -- rather than trusting that removing a file must have an
# effect.
set -u
S="${1:?usage: slice-negative-control.sh <slice-store-path> [soname]}"
SO="${2:-libcmdutils.so.1}"

echo "=== NEGATIVE CONTROL on $S"
echo "=== hiding $SO, which the slice's own computed closure says it needs"

# The store is read-only, and making it writable to sabotage it would be both rude and
# a mutation of a shared store. Instead copy the slice to a scratch tree, break the
# COPY, and point the test at that. The copy must preserve symlinks (-a, not -aL):
# the per-ABI flat lib dirs ARE symlinks, and dereferencing them would hide the very
# structure under test.
W=/var/tmp/negctl
[ -d "$W" ] && find "$W" -mindepth 1 -delete 2>/dev/null
mkdir -p "$W"
cp -a "$S/." "$W/slice/"
chmod -R u+w "$W/slice"

# Confirm the library is actually part of this slice's closure before hiding it --
# otherwise the "control" would hide something irrelevant and prove nothing.
if ! grep -q "$SO" "$W/slice/.slice/closure-libs.txt"; then
  echo "FATAL: $SO is not in this slice's computed closure -- pick one that is:"
  head -5 "$W/slice/.slice/closure-libs.txt"
  exit 1
fi
echo "confirmed: $SO appears in the derivation's own closure-libs.txt"

# Hide every copy, in the real lib dirs AND in the flat dirs the RUNPATH points at.
n=0
for f in $(find "$W/slice" -name "$SO" 2>/dev/null); do
  mv "$f" "$f.HIDDEN"
  n=$((n + 1))
done
echo "hid $n cop(ies) of $SO"
[ "$n" -gt 0 ] || { echo "FATAL: hid nothing -- the control cannot work"; exit 1; }

# --- THE STEP THAT MAKES THE SABOTAGE VISIBLE (see the header). Repoint every ELF's
# RUNPATH from the original store path to THIS COPY's lib dirs. Without this the
# binaries resolve out of the pristine store path and the control is a no-op.
echo "=== repointing the copy's RUNPATH at its own (sabotaged) lib dirs ==="
NRP="\$ORIGIN:$W/slice/lib-32:$W/slice/lib-64"
nrel=0
for f in $(find "$W/slice" -type f 2>/dev/null); do
  /usr/bin/elfdump -d "$f" 2>/dev/null | grep -Eq 'SONAME|NEEDED|RUNPATH|RPATH' || continue
  chmod u+w "$f" 2>/dev/null
  /usr/bin/elfedit -e "dyn:runpath $NRP" "$f" >/dev/null 2>&1 && nrel=$((nrel + 1))
done
echo "repointed $nrel object(s) at $NRP"
# Prove the repoint took, by checking that resolution now happens in the COPY. If this
# still shows the original store path, the control is again a no-op and must not be
# reported as a pass.
echo "=== resolution check: df's libc must now come from $W ==="
ldd "$W/slice/usr/sbin/df" 2>&1 | head -3
if ldd "$W/slice/usr/sbin/df" 2>&1 | grep -q "$S/lib"; then
  echo "FATAL: the copy STILL resolves out of the original store path -- the sabotage"
  echo "       is invisible and this control would prove nothing. Aborting rather than"
  echo "       reporting a meaningless pass."
  exit 1
fi

echo "=== re-running the exec test against the SABOTAGED copy ==="
sh /root/slice-exec-test.sh "$W/slice" > /var/tmp/negctl.out 2>&1
rc=$?
tail -12 /var/tmp/negctl.out

echo "-------------------------------------------------------------"
nf=$(awk -F: '/^FAILED:/{print $2}' /var/tmp/negctl.out | awk '{print $1}')
if [ "${nf:-0}" -gt 0 ]; then
  echo "NEGATIVE CONTROL PASSED: hiding $SO made the exec test report $nf failure(s)."
  echo "  -> the test CAN fail, so its PASS on the intact slice means something."
  echo "  failures it caught:"
  head -8 /tmp/exec-fail.txt | sed 's,^,    ,'
  exit 0
else
  echo "NEGATIVE CONTROL FAILED: the exec test still reported ZERO failures with a"
  echo "  required library removed. THE TEST IS MEASURING NOTHING. Do not trust any"
  echo "  PASS from it until this is fixed."
  exit 1
fi
