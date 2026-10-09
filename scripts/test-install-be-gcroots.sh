#!/usr/bin/env bash
# test-install-be-gcroots.sh -- self-check for install-be's gcroots/auto cleanup.
# Extracts the REAL drop_staging_roots (and its rl helper) from install-be.sh, runs
# it against a fake gcroots dir, and runs the rule it replaced as the control.
# The rule: an auto root is dropped only when install-be reads a STAGING store root
# (SOLNIX_STORE_ROOT non-empty) and the root points into it. With the live store
# (SOLNIX_STORE_ROOT="", as switch-to-configuration boot runs it) every auto root
# belongs to a user and must survive. Runs anywhere (no illumos, no nix).
set -u
IBE="${1:-$(dirname "$0")/../modules/system/activation/install-be.sh}"
W=$(mktemp -d /tmp/gcrchk.XXXXXX)
trap 'find "$W" -mindepth 1 -delete 2>/dev/null; rmdir "$W" 2>/dev/null' EXIT
FAILED=

# --- extract ---------------------------------------------------------------
{ grep '^rl() ' "$IBE"; awk '/^drop_staging_roots\(\) \{/,/^\}/' "$IBE"; } > "$W/fn.sh"
grep -q '^rl() ' "$W/fn.sh" && grep -q '^drop_staging_roots() ' "$W/fn.sh" \
  || { echo "FAIL  extract: rl/drop_staging_roots not found in $IBE"; exit 1; }
grep -q '^drop_staging_roots "\$G" "\$R"$' "$IBE" \
  || { echo "FAIL  install-be does not call drop_staging_roots \"\$G\" \"\$R\""; exit 1; }
bash -n "$W/fn.sh" || { echo "FAIL  extracted block is not valid shell"; exit 1; }

# the rule install-be had before (drop every auto root outside /nix and /run): the control.
old_rule() {   # $1 = gcroots dir, $2 = store root (unused by the old rule)
  [ -d "$1/auto" ] || return 0
  for a in "$1"/auto/*; do
    [ -h "$a" ] || continue
    case "$(rl "$a")" in /nix/*|/run/*) : ;; *) rm -f "$a" ;; esac
  done
}

STAGE="$W/stage"   # a staging store root, as make-be / solnix-install host mode pass
mk_roots() {       # a fresh gcroots dir with one root of each kind
  G="$W/g.$1"; mkdir -p "$G/auto"
  ln -s "$STAGE/nix/var/nix/profiles/system-1-link" "$G/auto/staging"
  ln -s /home/x/.local/state/home-manager/gcroots/current-home "$G/auto/hm"
  ln -s /var/tmp/x/result "$G/auto/result"
  ln -s /nix/var/nix/profiles/system-2-link "$G/auto/profile"
  echo "$G"
}
# check <name> <impl> <store root> <expected surviving roots, sorted>
check() {
  local name=$1 impl=$2 sr=$3 want=$4 G got
  G=$(mk_roots "$name")
  ( . "$W/fn.sh"; $impl "$G" "$sr" )
  got=$(ls "$G/auto" | LC_ALL=C sort | tr '\n' ' ')
  if [ "$got" = "$want" ]; then echo "PASS  $name: $got"; return 0; fi
  echo "FAIL  $name: left [$got], expected [$want]"; return 1
}

# --- the fix -----------------------------------------------------------------
check live-store    drop_staging_roots ""       "hm profile result staging " || FAILED=1
check staging-store drop_staging_roots "$STAGE" "hm profile result " || FAILED=1

# --- negative controls: each must FAIL the check above ------------------------
# (c) the old rule with the live store drops the user's roots (hm, result).
if check control-old-rule-live old_rule "" "hm profile result staging " >/dev/null; then
  echo "FAIL  control: the check passed the old rule, so it cannot see dropped user roots"; FAILED=1
else
  echo "PASS  control: the old rule drops user roots with the live store (left: $(check x old_rule "" "" | sed -n 's/.*left \[\([^]]*\)\].*/\1/p'))"
fi
# a cleanup that never drops anything leaves the dangling staging root.
noop() { :; }
if check control-noop noop "$STAGE" "hm profile result " >/dev/null; then
  echo "FAIL  control: the check passed a no-op, so it cannot see a kept staging root"; FAILED=1
else
  echo "PASS  control: a no-op cleanup keeps the staging root"
fi

[ -z "$FAILED" ] && { echo "ALL PASS"; exit 0; }
echo "FAILED"; exit 1
