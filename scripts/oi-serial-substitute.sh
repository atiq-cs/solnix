. /etc/profile.d/nix-illumos.sh 2>/dev/null
TARGET=$1
round=0
while [ $round -lt 15 ]; do
  round=$((round+1))
  want=$(nix-store -r "$TARGET" --dry-run 2>&1 | grep '^  /nix/store/' | tr -d ' ')
  [ -z "$want" ] && break
  for sp in $want; do
    [ -d "$sp" ] && continue
    t=0
    while [ $t -lt 4 ]; do
      t=$((t+1))
      nix-store -r "$sp" --option http-connections 1 >/dev/null 2>/tmp/e.txt && break
      grep -q "Error 0" /tmp/e.txt || tail -1 /tmp/e.txt
    done
  done
done
nix-store -r "$TARGET" --option http-connections 1 2>&1 | tail -1
ls -d "$TARGET" 2>&1
