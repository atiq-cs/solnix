#!/bin/sh
# whyneeded.sh -- which of a slice's BINS is responsible for pulling a given soname
# into the closure, and by what chain. Answers "why is libxml2 in my coreutils?"
# with a PATH rather than a guess.
#
#   sh whyneeded.sh <soname> <bin> [bin ...]
P=/var/tmp/proto-unpack/wn8w5j1pkc9k3zgkq3bsqxk285dqbi7m-illumos-gate-proto
WANT="$1"; shift
elfclass() {
  m=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
  [ "$m" = "7f454c46" ] || { echo none; return; }
  c=$(od -An -tu1 -j4 -N1 "$1" 2>/dev/null | tr -d ' \n')
  if [ "$c" -eq 2 ] 2>/dev/null; then echo 64; else echo 32; fi
}
needed() { /usr/bin/elfdump -d "$1" 2>/dev/null | awk '$2=="NEEDED"{print $NF}'; }
resolve() {
  if [ "$2" = 64 ]; then dirs="lib/amd64 usr/lib/amd64 lib/fm/amd64 usr/lib/fm/amd64";
  else dirs="lib usr/lib lib/fm usr/lib/fm"; fi
  for d in $dirs; do [ -e "$P/$d/$1" ] && { echo "$d/$1"; return; }; done
  echo ""
}
# DFS from each bin, print the first chain that reaches WANT.
for b in "$@"; do
  cls=$(elfclass "$P/$b")
  [ "$cls" = none ] && continue
  # iterative BFS keeping a parent map in a temp file
  tmp=$(mktemp /tmp/wn.XXXXXX)
  echo "$b|$b" > "$tmp"
  frontier="$b"
  hit=""
  n=0
  while [ -n "$frontier" ] && [ -z "$hit" ] && [ $n -lt 30 ]; do
    n=$((n+1)); next=""
    for f in $frontier; do
      for so in $(needed "$P/$f"); do
        if [ "$so" = "$WANT" ]; then
          hit=$(grep "^$f|" "$tmp" | head -1 | cut -d'|' -f2)
          hit="$hit -> $WANT"
          break
        fi
        r=$(resolve "$so" "$cls")
        [ -z "$r" ] && continue
        grep -q "^$r|" "$tmp" && continue
        chain=$(grep "^$f|" "$tmp" | head -1 | cut -d'|' -f2)
        echo "$r|$chain -> $so" >> "$tmp"
        next="$next $r"
      done
      [ -n "$hit" ] && break
    done
    frontier="$next"
  done
  [ -n "$hit" ] && printf '%-24s %s\n' "$b" "$hit"
  rm -f "$tmp"
done
