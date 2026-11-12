#!/usr/bin/env bash
# test-install-be-drm-perms.sh -- self-check for install-be's lay_drm_perms: logindevperm(5) keeps only
# /dev/dri/card* for the console user (render nodes stay minor_perm's 0666), and a BE dataset's /devices
# loses the devfs shadow nodes of its DRM minors (card*, renderD*), which otherwise override minor_perm in
# every cloned BE (lixi: root:root 0600 shadows from a console logout). Extracts the REAL function from
# install-be.sh. Runs anywhere: the shadows are FIFOs (find -type p for -type c: mknod c needs root),
# and df/chown are stubs. Controls: a devfs mount, SOLNIX_LIVE, and no lay_drm_perms at all.
set -u
IBE="${1:-$(dirname "$0")/../modules/system/activation/install-be.sh}"
W=$(mktemp -d /tmp/drmchk.XXXXXX)
trap 'find "$W" ! -type d -exec rm -f {} + 2>/dev/null; find "$W" -depth -type d -exec rmdir {} + 2>/dev/null' EXIT
FAILED=

awk '/^lay_drm_perms\(\) \{/,/^\}/' "$IBE" | sed 's/-type c /-type p /' > "$W/fn.sh"
grep -q '^lay_drm_perms() ' "$W/fn.sh" && grep -q -- '-type p ' "$W/fn.sh" || { echo "FAIL  extract: lay_drm_perms not found in $IBE"; exit 1; }
grep -q '^lay_drm_perms$' "$IBE" || { echo "FAIL  install-be does not call lay_drm_perms"; exit 1; }
bash -n "$W/fn.sh" || { echo "FAIL  extracted block is not valid shell"; exit 1; }
. "$W/fn.sh"
die() { echo "die: $*" >&2; return 1; }
chown() { :; }
FSTYPE=zfs
df() { echo "$2 : $FSTYPE"; }

mkbe() {   # $1 = BE root: the stock logindevperm lines and shadow nodes as lixi's BE had them
  mkdir -p "$1/etc" "$1/devices/pci@0,0" "$1/devices/pseudo"
  printf '/dev/vt/console_user\t0600\t/dev/fbs/*\t\t# frame buffers\n/dev/vt/console_user\t0600\t/dev/dri/*\t\t# dri devices\n/dev/vt/console_user\t0600\t/dev/video[0-9]+\t# video devices\n' > "$1/etc/logindevperm"
  for n in pci@0,0/display@2:card0 pci@0,0/display@2:renderD128 pci@0,0/display@2:text-0 \
           pseudo/nvidia_drm@0:card1 pseudo/nvidia_drm@0:renderD129 pseudo/nvidia_drm@0:ctl pseudo/conskbd@0:kbd; do
    mkfifo "$1/devices/$n"
  done
}
check() {   # $1 = label, $2 = function, $3 = FSTYPE, $4 = SOLNIX_LIVE, $5 = expect pass(1)/fail(0)
  local BE="$W/be.$1"; mkbe "$BE"
  ( cd "$BE" && ROOT="$BE" FSTYPE="$3" SOLNIX_LIVE="$4" "$2" ) >/dev/null 2>&1
  local ok=1 why="" d="$BE/devices"
  grep -q $'^/dev/vt/console_user\t0600\t/dev/dri/card\\[0-9\\]+\t' "$BE/etc/logindevperm" || { ok=0; why="$why dri-line"; }
  grep -qF '/dev/dri/*' "$BE/etc/logindevperm" && { ok=0; why="$why dri-glob-left"; }
  [ "$(grep -c . "$BE/etc/logindevperm")" -eq 3 ] && grep -qF '/dev/fbs/*' "$BE/etc/logindevperm" || { ok=0; why="$why other-lines"; }
  # the rewritten pattern as logindevperm/devfsadm use it (^re$, REG_EXTENDED, per path component)
  local re; re=$(awk -F'\t' '$3 ~ "^/dev/dri/" {sub("^/dev/dri/", "", $3); print $3}' "$BE/etc/logindevperm")
  [ -n "$re" ] && echo card0 | grep -Eqx "$re" 2>/dev/null && echo card1 | grep -Eqx "$re" && ! echo renderD128 | grep -Eqx "$re" \
    || { ok=0; why="$why regex"; }
  for n in pci@0,0/display@2:card0 pci@0,0/display@2:renderD128 pseudo/nvidia_drm@0:card1 pseudo/nvidia_drm@0:renderD129; do
    [ -e "$d/$n" ] && { ok=0; why="$why kept:${n##*:}"; }
  done
  for n in pci@0,0/display@2:text-0 pseudo/nvidia_drm@0:ctl pseudo/conskbd@0:kbd; do
    [ -e "$d/$n" ] || { ok=0; why="$why removed:${n##*:}"; }
  done
  if [ "$ok" = "$5" ]; then echo "PASS  $1${why:+ (control fails:$why)}"
  else echo "FAIL  $1:${why:- expected the control to fail}"; FAILED=1; fi
}
check lay_drm_perms lay_drm_perms zfs "" 1
check control-devfs-mounted lay_drm_perms devfs "" 0
check control-live-root lay_drm_perms zfs 1 0
check control-none true zfs "" 0

[ -z "$FAILED" ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
