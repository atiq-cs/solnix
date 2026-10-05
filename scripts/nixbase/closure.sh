#!/bin/sh
# closure.sh <proto> <bin>... : DT_NEEDED closure resolved inside the proto (ABI by elfdump -e class)
P=$1; shift
q=""; for b in "$@"; do q="$q $b"; done; seen=" "
while [ -n "$(echo $q)" ]; do
  set -- $q; f=$1; shift; q="$*"
  case "$seen" in *" $f "*) continue;; esac; seen="$seen$f "
  echo "$f"
  cls=$(elfdump -e "$P/$f" 2>/dev/null | awk '/ei_class/{print $4; exit}')
  if [ "$cls" = ELFCLASS64 ]; then dirs="lib/amd64 usr/lib/amd64"; else dirs="lib usr/lib"; fi
  for so in $(elfdump -d "$P/$f" 2>/dev/null | awk '$2=="NEEDED"{print $NF}'); do
    r=""; for d in $dirs; do [ -e "$P/$d/$so" ] && { r="$d/$so"; break; }; done
    [ -n "$r" ] && q="$q $r" || echo "UNRESOLVED $so (from $f)"
  done
done
