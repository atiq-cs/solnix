#!/usr/bin/env bash
# test-install-be-boot.sh -- self-check for install-be's /boot lay: the machine inputs
# the installer wrote before install-be ran (boot/loader.conf, boot/solaris/bootenv.rc)
# survive, and everything else in the kernel slice's boot/ arrives. Extracts the REAL
# lay_boot from install-be.sh and runs it against a fake kernel slice; the whole-dir
# tar copy it replaced is the control (it replaced bootenv.rc: measured under KVM,
# solnix-install's machine-input check failed "first line now: #").
# Runs anywhere (no illumos, no nix).
set -u
IBE="${1:-$(dirname "$0")/../modules/system/activation/install-be.sh}"
W=$(mktemp -d /tmp/bootchk.XXXXXX)
trap 'find "$W" -mindepth 1 -delete 2>/dev/null; rmdir "$W" 2>/dev/null' EXIT
FAILED=

awk '/^lay_boot\(\) \{/,/^\}/' "$IBE" > "$W/fn.sh"
grep -q '^lay_boot() ' "$W/fn.sh" || { echo "FAIL  extract: lay_boot not found in $IBE"; exit 1; }
grep -q '^lay_boot$' "$IBE" || { echo "FAIL  install-be does not call lay_boot"; exit 1; }
bash -n "$W/fn.sh" || { echo "FAIL  extracted block is not valid shell"; exit 1; }

old_lay_boot() {
  for e in $(ls "$R$KERNEL/boot"); do
    case $e in solaris) mkdir -p boot/solaris; ( cd "$R$KERNEL/boot" && tar cf - solaris ) | ( cd boot && tar xf - ) ;;
               *) [ -e "boot/$e" ] || cp -R "$R$KERNEL/boot/$e" boot/ ;; esac
  done
}

# a fake kernel slice and a fake BE root holding the installer's machine inputs
R="$W/sr"; KERNEL=/nix/store/kkkk-illumos-kernel
mkslice() {
  mkdir -p "$R$KERNEL/boot/solaris/bin" "$R$KERNEL/boot/forth" "$R$KERNEL/boot/defaults"
  printf '#\n# stock bootenv.rc\nsetprop ata-dma-enabled 1\n' > "$R$KERNEL/boot/solaris/bootenv.rc"
  echo '/etc/system' > "$R$KERNEL/boot/solaris/filelist.ramdisk"
  ln -sf ../../../usr/sbin/root_archive "$R$KERNEL/boot/solaris/bin/root_archive"
  echo 'console="text"' > "$R$KERNEL/boot/loader.conf"
  : > "$R$KERNEL/boot/loader64.efi"; : > "$R$KERNEL/boot/forth/loader.4th"
}
mkbe() {   # $1 = dir
  mkdir -p "$1/boot/solaris"
  printf 'setprop console ttya\nsetprop ttya-mode 115200,8,n,1,-\n' > "$1/boot/solaris/bootenv.rc"
  printf 'console="ttya,text"\nos_console="ttya"\n' > "$1/boot/loader.conf"
}
die() { echo "die: $*" >&2; return 1; }
mkslice

check() {   # $1 = label, $2 = function, $3 = expect pass(1)/fail(0)
  local BE="$W/be.$1"; mkbe "$BE"
  ( cd "$BE" && "$2" ) >/dev/null 2>&1
  local ok=1 why=""
  head -1 "$BE/boot/solaris/bootenv.rc" | grep -q '^setprop console ttya$' || { ok=0; why="$why bootenv.rc-replaced"; }
  grep -q '^os_console="ttya"$' "$BE/boot/loader.conf" || { ok=0; why="$why loader.conf-replaced"; }
  [ -e "$BE/boot/solaris/filelist.ramdisk" ] || { ok=0; why="$why filelist.ramdisk-missing"; }
  [ -h "$BE/boot/solaris/bin/root_archive" ] || { ok=0; why="$why root_archive-not-a-link"; }
  [ -e "$BE/boot/loader64.efi" ] && [ -e "$BE/boot/forth/loader.4th" ] || { ok=0; why="$why loader-files-missing"; }
  if [ "$ok" = "$3" ]; then echo "PASS  $1${why:+ (control fails:$why)}"
  else echo "FAIL  $1:${why:- expected the control to fail}"; FAILED=1; fi
}
. "$W/fn.sh"
check lay_boot lay_boot 1
check control-old-tar old_lay_boot 0

[ -z "$FAILED" ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
