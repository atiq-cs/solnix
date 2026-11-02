#!/usr/bin/env bash
# test-install-be-share.sh -- self-check for install-be's /usr/share lay. Extracts the REAL lay_usr_share (and its rl
# helper) from install-be.sh and runs it against a fake userland and system profile. Wants: /usr/share is a real dir,
# man and info name the PROFILE's share/{man,info} (illumos man(1) maps /usr/bin, which is sw/bin, to /usr/share/man
# when MANPATH is unset), every other world entry is kept (zoneinfo, terminfo, the relative terminfo link), an
# admin's real file survives, and a re-run over a previous generation relinks. The control is the rule install-be had
# before (/usr/share as one link to the userland's usr/share): it must FAIL the man check. No illumos, no nix.
set -u
IBE="${1:-$(dirname "$0")/../modules/system/activation/install-be.sh}"
W=$(mktemp -d /tmp/sharechk.XXXXXX)
trap 'find "$W" -mindepth 1 -delete 2>/dev/null; rmdir "$W" 2>/dev/null' EXIT
FAILED=

{ grep '^rl() ' "$IBE"; awk '/^lay_usr_share\(\) \{/,/^\}/' "$IBE"; } > "$W/fn.sh"
grep -q '^lay_usr_share() ' "$W/fn.sh" || { echo "FAIL  extract: lay_usr_share not found in $IBE"; exit 1; }
grep -q '^lay_usr_share "\$(attr sw)"$' "$IBE" || { echo "FAIL  install-be does not call lay_usr_share \"\$(attr sw)\""; exit 1; }
bash -n "$W/fn.sh" || { echo "FAIL  extracted block is not valid shell"; exit 1; }
grep -q 'usr/bin|usr/sbin|usr/lib|usr/kernel|usr/share) continue' "$IBE" \
  || { echo "FAIL  the /usr loop still links usr/share as one entry"; exit 1; }

old_lay() { rm -f usr/share; ln -s "$WORLD/usr/share" usr/share; }

# a fake userland (absolute store paths under R, as install-be reads them) and system profile
R="$W/sr"; WORLD=/nix/store/wwww-illumos-userland; SW=/nix/store/ssss-solnix-system-path
# the userland has no man/info today (mk-proto-world excludes usr/share/man); give it both, so a lay that links the
# world's entries over the profile's is caught
mkdir -p "$R$WORLD/usr/share/lib/zoneinfo" "$R$WORLD/usr/share/lib/terminfo/x" "$R$WORLD/usr/share/hwdata" \
  "$R$WORLD/usr/share/man/man1" "$R$WORLD/usr/share/info"
: > "$R$WORLD/usr/share/lib/zoneinfo/UTC"; ln -s ../share/lib/terminfo "$R$WORLD/usr/share/terminfo"
mkdir -p "$R$SW/share/man/man1" "$R$SW/share/info"; : > "$R$SW/share/man/man1/ls.1"; : > "$R$SW/share/info/dir"
# resolve a BE link the way the running system would: absolute /nix/store targets through R
res() { local t; t=$(rl "$1"); case $t in /nix/*) echo "$R$t";; *) echo "$(dirname "$1")/$t";; esac; }

check() {   # $1 = label, $2 = function, $3 = expect pass(1)/fail(0), $4 = pre-existing BE state (fresh|old-link|prev-gen)
  local BE="$W/be.$1"; mkdir -p "$BE/usr"
  case $4 in
    old-link) ln -s "$WORLD/usr/share" "$BE/usr/share" ;;
    prev-gen) mkdir -p "$BE/usr/share"; ln -s /nix/store/oooo-old-path/share/man "$BE/usr/share/man"
              ln -s /nix/store/oooo-old-world/usr/share/gone "$BE/usr/share/gone"; echo admin > "$BE/usr/share/local-notes" ;;
  esac
  ( cd "$BE" && "$2" "$SW" ) >/dev/null 2>&1
  local ok=1 why="" d="$BE/usr/share"
  [ -d "$d" ] && [ ! -h "$d" ] || { ok=0; why="$why share-not-a-real-dir"; }
  [ "$(rl "$d/man")" = "$SW/share/man" ] && [ -e "$(res "$d/man")/man1/ls.1" ] || { ok=0; why="$why man-not-the-profile"; }
  [ "$(rl "$d/info")" = "$SW/share/info" ] || { ok=0; why="$why info-not-the-profile"; }
  [ "$(rl "$d/lib")" = "$WORLD/usr/share/lib" ] && [ -e "$(res "$d/lib")/zoneinfo/UTC" ] || { ok=0; why="$why zoneinfo-lost"; }
  [ "$(rl "$d/terminfo")" = ../share/lib/terminfo ] || { ok=0; why="$why terminfo-link-changed"; }
  [ -h "$d/hwdata" ] || { ok=0; why="$why hwdata-lost"; }
  if [ "$4" = prev-gen ]; then
    [ -e "$d/gone" ] || [ -h "$d/gone" ] && { ok=0; why="$why stale-link-kept"; }
    [ "$(cat "$d/local-notes" 2>/dev/null)" = admin ] || { ok=0; why="$why admin-file-lost"; }
  fi
  if [ "$ok" = "$3" ]; then echo "PASS  $1${why:+ (control fails:$why)}"
  else echo "FAIL  $1:${why:- expected the control to fail}"; FAILED=1; fi
}
. "$W/fn.sh"
check fresh        lay_usr_share 1 fresh
check over-old-link lay_usr_share 1 old-link
check prev-gen     lay_usr_share 1 prev-gen
check control-one-link old_lay 0 fresh

[ -z "$FAILED" ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
