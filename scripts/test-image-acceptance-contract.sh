#!/usr/bin/env bash
# test-image-acceptance-contract.sh -- per-defect negative controls for closure_contract_checks: start from a GOOD closure root, break ONE thing, require
# exactly the matching check to FAIL. Sources the real functions out of the acceptance script.
set -u
S=${1:-$(dirname "$0")/image-acceptance-test.sh}
W=$(mktemp -d /tmp/acc.XXXXXX); trap 'find "$W" -mindepth 1 -delete; rmdir "$W"' EXIT
eval "$(awk '/^_rl\(\) \{/,/^\}/' "$S")"; eval "$(awk '/^closure_contract_checks\(\) \{/,/^\}$/' "$S")"
PASS=0 FAIL=0 SKIP=0; _ok() { echo "ok: $*"; }; _fail() { echo "FAIL: $*"; }; _skip() { echo "skip: $*"; }
good() { local G=$1 TL=/nix/store/00000000000000000000000000000000-solnix-system-x
  mkdir -p "$G$TL/bin" "$G/nix/store/11111111111111111111111111111111-w/bin" "$G/run" "$G/nix/var/nix/profiles" "$G/usr" "$G/etc/nix" "$G/nix/var/nix/db" "$G/lib"
  echo 'install-be' > "$G$TL/bin/solnix-install"; : > "$G$TL/bin/install-be"; : > "$G/nix/var/nix/db/db.sqlite"
  ln -s "$TL" "$G/run/current-system"; ln -s "$TL" "$G/nix/var/nix/profiles/system-1-link"; ln -s system-1-link "$G/nix/var/nix/profiles/system"
  ln -s /nix/store/11111111111111111111111111111111-w/bin "$G/usr/bin"; ln -s /nix/store/11111111111111111111111111111111-w/bin "$G/usr/sbin"
  printf 'substituters = https://cache.solnix.io https://cache.nixos.org\ntrusted-public-keys = cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n' > "$G/etc/nix/nix.conf"
  echo 'root:x:0:0::/root:/bin/sh' > "$G/etc/passwd"; }
TL=/nix/store/00000000000000000000000000000000-solnix-system-x
tot=0; bad=0
while IFS='|' read -r name break want; do
  G="$W/$name"; good "$G"; ( cd "$G" && eval "$break" )
  out=$(closure_contract_checks "$G" 2>&1 | grep '^FAIL:' | grep -v 'store DB')
  tot=$((tot+1))
  # the guard for THIS defect must be the FIRST failure (later ones may be its cascade)
  if echo "$out" | head -1 | grep -qE "$want"; then echo "PASS  $name -> $(echo "$out" | head -1 | cut -c1-100) [+$(($(echo "$out" | grep -c .)-1)) cascade]"
  else echo "MISS  $name: want /$want/ alone, got: $(echo "$out" | tr '\n' ';' | cut -c1-200)"; bad=$((bad+1)); fi
done <<'CASES'
no-current-system|rm run/current-system|not a solnix toplevel
current-not-in-store|find nix/store/00000000000000000000000000000000-solnix-system-x -delete|not in the media's store
profile-wrong|rm nix/var/nix/profiles/system-1-link; ln -s /nix/store/x nix/var/nix/profiles/system-1-link|system profile
usr-bin-real|rm usr/bin; mkdir usr/bin|/usr/bin is a real directory
host-elf|mkdir -p lib; printf '\177ELF\002' > lib/libc.so.1|ELF files outside the store
installer-copies-root|echo 'SELF_INSTALL=1' >> nix/store/00000000000000000000000000000000-solnix-system-x/bin/solnix-install|live-root copy step
retired-key|sed -i 's/8UNrVAOSOrI9PGHc8\/pD2Yqp265ZeYb3OId+gv4+wm8=/5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=/' etc/nix/nix.conf|does not trust cache.solnix.io-1:8UNr
extra-key|sed -i 's/^trusted-public-keys = /trusted-public-keys = evil-1:AAAA= /' etc/nix/nix.conf|trusts keys other than
no-solnix-subst|sed -i 's,https://cache.solnix.io ,,' etc/nix/nix.conf|no https://cache.solnix.io substituter
personal-user|echo 'jdoe:x:1000:10::/home/jdoe:/bin/sh' >> etc/passwd|personal account
baked-key|mkdir -p root/.ssh; echo ssh-ed25519 AAAA > root/.ssh/authorized_keys|authorized_keys file is baked
CASES
g="$W/good"; good "$g"; gout=$(closure_contract_checks "$g" 2>&1 | grep '^FAIL:' | grep -v 'store DB')
[ -z "$gout" ] && echo "PASS  good root: no FAIL" || { echo "MISS  good root fails: $gout"; bad=$((bad+1)); }
echo "== $((tot-bad+1))/$((tot+1)) controls behave"; [ "$bad" = 0 ]
