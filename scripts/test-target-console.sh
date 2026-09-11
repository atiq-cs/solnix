#!/usr/bin/env bash
# test-target-console.sh -- self-check for SOLNIX_TARGET_CONSOLE in solnix-install.
# The installed-system console is unrecoverable-if-wrong on a machine with no
# keyboard, so the rendering of both config files gets a check that can fail.
# The heredocs are extracted VERBATIM from the script so they cannot drift.
set -u
SCRIPT="${1:-/home/gburd/ws/solnix/scripts/solnix-install}"
W=$(mktemp -d /tmp/tcchk.XXXXXX)
trap 'find "$W" -mindepth 1 -delete 2>/dev/null; rmdir "$W" 2>/dev/null' EXIT

echo "=== default must still be ttya (every existing install test captures serial) ==="
grep -q '^TARGET_CONSOLE="${SOLNIX_TARGET_CONSOLE:-ttya}"$' "$SCRIPT" \
  && echo "PASS  default is ttya" || { echo "FAIL  default changed"; exit 1; }

# the writer block: from the log line through the gate.
awk '/^log "installed-system console=/,/installed-console gate OK/' "$SCRIPT" > "$W/block.sh"
grep -q 'setprop console' "$W/block.sh" || { echo "FAIL  extract: anchors moved"; exit 1; }
bash -n "$W/block.sh" || { echo "FAIL  extracted block is not valid shell"; exit 1; }

FAILED=
check() { # check <TARGET_CONSOLE>
  local TC="$1" R="$W/r.$1" out rc
  mkdir -p "$R"
  ( set -u
    ALTROOT="$R"; TARGET_CONSOLE="$TC"
    SOLNIX_EDITION=test; TOPLEVEL=""; TARGET=cXtYdZ; POOL=rpool; BEDS=rpool/ROOT/x
    die() { echo "DIE: $*"; exit 1; }
    log() { :; }
    . "$W/block.sh"
  ) > "$R/out" 2>&1; rc=$?
  local lc="$R/boot/loader.conf" bc="$R/boot/solaris/bootenv.rc"
  local ok=1
  [ "$rc" = 0 ] || ok=0
  grep -q "^console=\"$TC\"\$"        "$lc" 2>/dev/null || ok=0
  grep -q "^os_console=\"$TC\"\$"     "$lc" 2>/dev/null || ok=0
  grep -q "^setprop console $TC\$"    "$bc" 2>/dev/null || ok=0
  grep -q "^setprop os_console $TC\$" "$bc" 2>/dev/null || ok=0
  # the ttya-* props must survive for BOTH values (brief: keep them)
  grep -q '^setprop ttya-mode 115200,8,n,1,-$' "$bc" 2>/dev/null || ok=0
  grep -q '^setprop ttya-ignore-cd true$'      "$bc" 2>/dev/null || ok=0
  grep -q '^setprop ttya-rts-dtr-off false$'   "$bc" 2>/dev/null || ok=0
  # nothing may ship an unexpanded variable
  grep -q 'TARGET_CONSOLE' "$lc" "$bc" 2>/dev/null && ok=0
  if [ "$ok" = 1 ]; then echo "PASS  TARGET_CONSOLE=$TC -> $(head -1 "$lc") / $(head -1 "$bc")"
  else echo "FAIL  TARGET_CONSOLE=$TC (rc=$rc)"; sed 's/^/      | /' "$R/out"; FAILED=1; fi
}

echo "=== rendering both values ==="
check ttya
check text

echo "=== NEGATIVE CONTROL: sabotage the rendering (quoted heredoc -> the literal"
echo "    string \$TARGET_CONSOLE ships). The gate MUST die. ==="
sed "s/<<EOF/<<'EOF'/g" "$W/block.sh" > "$W/sab.sh"
R="$W/r.sab"; mkdir -p "$R"
( set -u; ALTROOT="$R"; TARGET_CONSOLE=text; SOLNIX_EDITION=test; TOPLEVEL=""
  TARGET=cXtYdZ; POOL=rpool; BEDS=rpool/ROOT/x
  die() { echo "DIE: $*"; exit 1; }; log() { :; }
  . "$W/sab.sh" ) > "$R/out" 2>&1
if grep -q '^DIE:' "$R/out"; then echo "PASS  gate fired: $(grep -m1 '^DIE:' "$R/out")"
else echo "FAIL  sabotaged rendering was ACCEPTED -- the gate proves nothing"; sed 's/^/      | /' "$R/out"; FAILED=1; fi

echo "=== the auto-install path must pass text, not the ttya default ==="
LIVECD="${2:-/home/gburd/ws/solnix/scripts/oi-make-livecd.sh}"
# count only real assignments in a command position, not the comments explaining them
n=$(grep -c '^ *SOLNIX_POOL=rpool .*SOLNIX_TARGET_CONSOLE=text' "$LIVECD")
[ "$n" = 2 ] && echo "PASS  both auto-install call sites pass SOLNIX_TARGET_CONSOLE=text" \
  || { echo "FAIL  expected 2 call sites passing text, found $n"; FAILED=1; }
# no BARE invocation may remain: every `solnix-install "$_tgt"` must be a line
# continuation of a command that set the override.
if [ "$(grep -c 'solnix-install "\$_tgt"' "$LIVECD")" = "$(grep -B1 'solnix-install "\$_tgt"' "$LIVECD" | grep -c 'SOLNIX_TARGET_CONSOLE=text')" ]; then
  echo "PASS  no bare solnix-install invocation in the auto-install path"
else
  echo "FAIL  an auto-install invocation lacks the console override"; FAILED=1
fi

[ -z "$FAILED" ] && echo "ALL TARGET-CONSOLE CHECKS PASS" || { echo "TARGET-CONSOLE CHECKS FAILED"; exit 1; }
