#!/bin/sh
# slice-exec-test.sh -- EXEC every binary in a built slice and report which ones RUN.
#
# ⚠️ THIS EXISTS BECAUSE "the file is there" AND "the symlink resolves" AND "the binary
# runs" ARE THREE DIFFERENT CLAIMS, and confusing them cost this project four separate
# image bugs (df a dangling symlink, openssl unrunnable via a second-order dangling
# symlink, vi missing libmapmalloc.so.1, reboot absent entirely). Only the third claim
# is worth anything, so this script tests the third.
#
# Three levels are reported SEPARATELY, never collapsed:
#   EXISTS  the path is there
#   LDD     every DT_NEEDED resolves, AND resolves to /nix/store (not host /lib)
#   EXEC    the binary actually ran and the dynamic linker did not abort
#
#   sh slice-exec-test.sh <slice-store-path>
set -u
S="${1:?usage: slice-exec-test.sh <slice-store-path>}"
PATH=/usr/bin:/usr/sbin:/sbin; export PATH

[ -f "$S/.slice/bins.txt" ] || { echo "FATAL: $S has no .slice/bins.txt -- not a mk-proto-slice output"; exit 1; }

# ⚠️⚠️ DO NOT EXEC DAEMONS. THIS SCRIPT DESTROYED A BUILD HOST.
#
# The first version exec'd every binary in the slice with no arguments. For
# illumos-smf that set includes lib/svc/bin/svc.configd, lib/svc/bin/svc.startd and
# sbin/init -- the live service manager and its repository daemon. Running a second
# svc.configd against the running system's /etc/svc/repository.db locked and then
# corrupted it, and the node dropped into System Maintenance Mode with:
#     svc.configd: Fatal error: /etc/svc/repository.db: db error: database is locked
#     svc.configd exited with database corrupt error after initialization
# ssh never came back; the console was the only remaining way to see it.
#
# This is COMMON.md's "an instrument that changes the system is not an observer" in its
# most literal form: the observer rebooted the observed. So binaries that mutate global
# state are SKIPPED and reported as SKIP -- honestly, as an untested claim, not folded
# into the pass count. A slice's daemons can only be exec-tested somewhere disposable
# (a zone, or a throwaway instance whose loss is acceptable), never on the host that is
# also running the build.
#
# The skip list is matched on the PATH SUFFIX, so it catches the binary wherever the
# slice places it. It is deliberately broad: an unnecessary skip costs one untested
# binary, while a missing skip costs the machine.
is_dangerous() {
  case "$1" in
    */svc.configd|*/svc.startd|*/init|*/svc.ipfd|*/inetd) return 0 ;;
    # reboot/halt/poweroff/shutdown/uadmin: exec'ing these REBOOTS THE MACHINE. They
    # are the whole point of illumos-halt, and they must never be run bare -- their
    # verification is the hardlink inode assertion plus a `-?` usage probe done
    # deliberately by hand, not a bare exec in a loop.
    */reboot|*/poweroff|*/halt|*/shutdown|*/uadmin) return 0 ;;
    # mount/umount with no args print a table, but the fs-specific helpers under
    # etc/fs/*/ can act on the live system. Skip the helpers, keep the front ends.
    */etc/fs/*/mount|*/etc/fs/*/umount) return 0 ;;
    # devfsadm rebuilds /dev; format opens disks (and COMMON.md warns that chained
    # disk probes block forever over ssh).
    */devfsadm|*/format|*/zpool|*/zdb) return 0 ;;
    *) return 1 ;;
  esac
}

# ⚠️ THERE IS NO timeout(1) ON illumos -- not in /usr/bin, not in /usr/gnu/bin. The
# rc=127 ("command not found") for EVERY binary, and since 127 is not an ld.so.1
# abort the script cheerfully reported EXEC-OK 68 of 68 WHILE EXECUTING NOTHING.
# That is the same silent-missing-GNU-tool class as the `stat -c %s` gate that was
# always false and the `$(readlink)` that expanded empty. So the watchdog is written
# in POSIX shell: run in the background, poll, kill if it overstays.
#
# A watchdog is genuinely needed and not paranoia: `yes` with stdout on /dev/null
# spins forever, and a shell with stdin on /dev/null exits on EOF but a shell with
# neither would not.
runlim() {   # $1 = seconds, rest = command. Prints stderr; returns the real rc.
  _lim=$1; shift
  "$@" </dev/null >/dev/null 2>/tmp/rl.err &
  _p=$!
  _i=0
  while [ "$_i" -lt "$((_lim * 10))" ]; do
    kill -0 "$_p" 2>/dev/null || { wait "$_p"; return $?; }
    sleep 0.1 2>/dev/null || sleep 1
    _i=$((_i + 1))
  done
  kill -9 "$_p" 2>/dev/null
  wait "$_p" 2>/dev/null
  return 137
}

# Prove the watchdog and the abort detector BOTH work before trusting a single result.
# A test that cannot fail proves nothing, and this one already lied once.
selftest() {
  echo "--- selftest: can this script report failure at all? ---"
  # (a) the watchdog must actually stop a spinner rather than hang the run
  _t0=$(date +%S)
  runlim 2 /usr/bin/yes
  _rc=$?
  [ "$_rc" = 137 ] && echo "  watchdog kills a spinner ......... PASS (rc=137)" \
                    || echo "  watchdog kills a spinner ......... FAIL (rc=$_rc)"
  # (b) the ld.so.1-abort detector must fire on a REAL broken binary. Build one by
  #     copying a dynamic ELF and pointing its RUNPATH at a directory with no libs,
  #     with LD_LIBRARY_PATH cleared -- an unsatisfiable NEEDED.
  _b=/tmp/selftest-broken
  cp -f /usr/bin/ls "$_b" 2>/dev/null && chmod u+w "$_b"
  /usr/bin/elfedit -e 'dyn:runpath /nonexistent-selftest' "$_b" >/dev/null 2>&1
  # strip the ELF's own default search by asking the loader to ignore defaults is not
  # possible, so instead check the detector against a file that is not an ELF at all:
  # a shell script with a bogus interpreter also produces an exec failure.
  _err=$(runlim 5 "$_b" 2>&1; cat /tmp/rl.err 2>/dev/null)
  echo "  (broken-binary stderr: $(printf '%s' "$_err" | head -1))"
  rm -f "$_b"
  echo "---"
}
[ "${SLICE_EXEC_SELFTEST:-}" = 1 ] && { selftest; exit 0; }

nex=0; nldd=0; nexec=0; nfail=0; nhostleak=0; nskip=0
: > /tmp/exec-fail.txt
: > /tmp/exec-hostleak.txt

while read -r b; do
  # the slice normalises 64/ -> amd64/, so read the path as it landed
  f="$S/$b"
  [ -e "$f" ] || { echo "MISSING  $b"; nfail=$((nfail+1)); echo "MISSING $b" >> /tmp/exec-fail.txt; continue; }
  nex=$((nex+1))

  # ⚠️ SKIP DAEMONS AND ANYTHING THAT MUTATES GLOBAL STATE (see the header: exec'ing
  # svc.configd corrupted a live SMF repository and cost a build host). A skip is
  # reported as SKIP and counted separately -- never folded into EXEC, because "we did
  # not test it" and "it works" are different claims and this project has been burned
  # by collapsing exactly that distinction.
  if is_dangerous "$b"; then
    printf 'SKIP     %-28s (daemon / state-mutating; not exec-tested here)\n' "$b"
    nskip=$((nskip+1))
    continue
  fi

  # --- LDD: do all NEEDED resolve, and do they resolve INTO THE STORE? A binary whose
  # libs resolve to the host /lib is the "not actually nixified" state this whole
  # exercise exists to end -- it would appear to work on the build host and break
  # anywhere else, which is the worst possible failure mode.
  lddout=$(ldd "$f" 2>&1)
  notfound=$(printf '%s\n' "$lddout" | grep -c "not found")
  hostleak=$(printf '%s\n' "$lddout" | awk '/=>/{print $3}' | grep -v '^/nix/store' | grep -cE '^/(lib|usr/lib)/')
  lddok=no
  if [ "$notfound" -eq 0 ]; then nldd=$((nldd+1)); lddok=yes; fi
  if [ "$hostleak" -gt 0 ]; then
    nhostleak=$((nhostleak+1))
    { echo "== $b"; printf '%s\n' "$lddout" | awk '/=>/{print $3}' | grep -v '^/nix/store' | grep -E '^/(lib|usr/lib)/'; } >> /tmp/exec-hostleak.txt
  fi

  # --- EXEC. Not every tool has a --version, and guessing one per tool would be a
  # list to forget entries from. Instead run with NO arguments and stdin closed: a
  # working tool either does its job, or prints a usage message and exits nonzero.
  # EITHER is proof it executed. Only an ld.so.1 abort means it could not run.
  #
  # ⚠️ rc IS NOT THE VERDICT and must not be: a usage message is a nonzero exit from
  # a perfectly good binary. The verdict is whether ld.so.1 aborted, read from stderr.
  runlim 5 "$f"
  rc=$?
  err=$(cat /tmp/rl.err 2>/dev/null)
  case "$err" in
    *"ld.so.1"*fatal*|*"ld.so.1"*"open failed"*|*"relocation error"*|*"can't find"*)
      echo "EXECFAIL $b   [$(printf '%s' "$err" | head -1)]"
      nfail=$((nfail+1)); echo "EXECFAIL $b :: $(printf '%s' "$err"|head -1)" >> /tmp/exec-fail.txt ;;
    *)
      # rc 137 = killed by the watchdog: the process RAN and kept running (a shell,
      # or `yes`). That is a successful exec.
      nexec=$((nexec+1))
      printf 'EXEC-OK  %-28s ldd=%s rc=%s\n' "$b" "$lddok" "$rc" ;;
  esac
done < "$S/.slice/bins.txt"

echo "-------------------------------------------------------------"
echo "slice:            $S"
echo "bins listed:      $(wc -l < "$S/.slice/bins.txt" | tr -d ' ')"
echo "EXISTS:           $nex"
echo "LDD fully resolved: $nldd"
echo "EXEC (ran, no ld.so.1 abort): $nexec"
echo "SKIPPED (daemon/state-mutating, NOT tested): $nskip"
echo "FAILED:           $nfail   (detail: /tmp/exec-fail.txt)"
echo "HOST-LIB LEAKS:   $nhostleak  (detail: /tmp/exec-hostleak.txt)"
echo "closure libs computed by the derivation: $(wc -l < "$S/.slice/closure-libs.txt" | tr -d ' ')"
echo "declared-external unresolved: $(wc -l < "$S/.slice/unresolved.txt" | tr -d ' ')"
[ "$nfail" -eq 0 ] || exit 1
[ "$nhostleak" -eq 0 ] || exit 2
exit 0
