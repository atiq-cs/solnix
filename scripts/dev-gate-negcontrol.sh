#!/usr/bin/env bash
# dev-gate-negcontrol.sh -- NEGATIVE CONTROL for the section 5a closure gates in
# oi-make-livecd.sh. A gate that cannot fail proves nothing, so sabotage each
# mechanism against a throwaway copy of the real live root and assert the gate
# FLIPS TO FAIL. Run on the illumos build host AFTER a successful build.
#
#   dev-gate-negcontrol.sh /var/tmp/solnix-media/rd-copy
#
# The gate logic is duplicated here deliberately: this tests that the CONDITIONS
# detect sabotage. Keep in sync with section 5a if that list changes.
set -u
R="${1:?usage: dev-gate-negcontrol.sh <rdroot-copy>}"
[ -d "$R" ] || { echo "FATAL: $R is not a directory" >&2; exit 1; }
pass=0; fail=0
chk() {  # chk <name> <expect-fail-cmd...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  NEG-CONTROL FAIL: $name -- gate did NOT detect the sabotage"; fail=$((fail+1))
  else
    echo "  neg-control ok:   $name -- gate correctly detected it"; pass=$((pass+1))
  fi
}

# gate (i): a required /dev node removed must be detected
rm -f "$R/dev/zfs"
chk "/dev/zfs removed" test -L "$R/dev/zfs"
rm -f "$R/dev/sad/user"
chk "/dev/sad/user removed" test -L "$R/dev/sad/user"

# gate (ii): a driver removed must make the count differ from the host's
rm -f "$R/kernel/drv/amd64/nvme"
_h=$(ls /kernel/drv/amd64 2>/dev/null | wc -l | tr -d ' ')
_r=$(ls "$R/kernel/drv/amd64" 2>/dev/null | wc -l | tr -d ' ')
chk "one driver removed (host=$_h rd=$_r)" test "$_h" = "$_r"

# gate (iii): a console-input module removed must be detected
rm -f "$R/kernel/strmod/amd64/usbkbm"
chk "usbkbm removed" test -e "$R/kernel/strmod/amd64/usbkbm"

# gate (iv): per-machine state must be caught when NON-empty
cp /etc/path_to_inst "$R/etc/path_to_inst" 2>/dev/null || echo 'x' > "$R/etc/path_to_inst"
_sz=$(wc -c < "$R/etc/path_to_inst" | tr -d ' ')
chk "path_to_inst repopulated ($_sz bytes)" test "$_sz" = 0

# gate (v): autoinstall must be caught when present
: > "$R/etc/solnix-autoinstall"
chk "autoinstall marker created" test ! -e "$R/etc/solnix-autoinstall"

echo "negative control: $pass detected, $fail missed"
[ "$fail" = 0 ] || exit 1
