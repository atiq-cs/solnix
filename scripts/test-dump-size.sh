#!/usr/bin/env bash
# test-dump-size.sh -- solnix-dump-size.sh picks the target's dump size and never resizes a dedicated dump.
# zfs/zpool/dumpadm/prtconf are faked on PATH; each case gives RAM, pool size, zvol size, dump state.
set -u
S=${1:-$(dirname "$0")/solnix-dump-size.sh}
W=$(mktemp -d /tmp/ds.XXXXXX); trap 'find "$W" -mindepth 1 -delete; rmdir "$W"' EXIT
mkdir -p "$W/bin"; G=1073741824
cat > "$W/bin/prtconf" <<'EOF'
#!/bin/sh
echo "Memory size: $(cat $DSW/ram) Megabytes"
EOF
cat > "$W/bin/zpool" <<'EOF'
#!/bin/sh
cat $DSW/pool
EOF
cat > "$W/bin/zfs" <<'EOF'
#!/bin/sh
case $1 in list) [ -e $DSW/zvol ];; get) cat $DSW/zvol;; *) echo "zfs $*" >> $DSW/calls;; esac
EOF
cat > "$W/bin/dumpadm" <<'EOF'
#!/bin/sh
if [ $# = 0 ]; then echo "       Dump device: $(cat $DSW/dump)"; else echo "dumpadm $*" >> $DSW/calls; fi
EOF
chmod +x "$W/bin/"*
bad=0
t() { # t <ram MB> <pool GiB> <zvol GiB|none> <dump device line> <want calls>
  find "$W" -maxdepth 1 -type f -delete
  echo "$1" > "$W/ram"; echo $(( $2 * G )) > "$W/pool"; echo "$4" > "$W/dump"
  [ "$3" = none ] || echo $(( $3 * G )) > "$W/zvol"
  out=$(DSW=$W PATH="$W/bin:$PATH" SOLNIX_DUMP_POOL=spool bash -c "sed 's,^PATH=.*,,' '$S' | sh" 2>&1)
  calls=$(cat "$W/calls" 2>/dev/null | tr '\n' ';')
  if [ "$calls" = "$5" ]; then echo "ok: ram=$1 pool=$2G zvol=$3 -> '${calls:-none}'"
  else echo "FAIL: ram=$1 pool=$2G zvol=$3 dump='$4': want '$5' got '$calls' ($out)"; bad=1; fi
}
D='zfs set volsize=%sG spool/dump;dumpadm -d /dev/zvol/dsk/spool/dump;'
t 16384 32  1 'none (dumps disabled)' "$(printf "$D" 8)"   # half of RAM
t 16384 28  1 'none (dumps disabled)' "$(printf "$D" 7)"   # capped at a quarter of the pool
t 65536 100 1 'none (dumps disabled)' "$(printf "$D" 16)"  # capped at 16G
t 16384 7   1 'none (dumps disabled)' 'dumpadm -d /dev/zvol/dsk/spool/dump;'  # small pool: stays 1G
t 4096  100 8 'none (dumps disabled)' 'dumpadm -d /dev/zvol/dsk/spool/dump;'  # never shrinks
t 16384 32  1 '/dev/zvol/dsk/spool/dump (dedicated)' ''   # already the dump device: untouched
t 16384 32  1 '/dev/zvol/dsk/rpool/dump (dedicated)' ''   # operator's own dump device: untouched
t 16384 32  none 'none (dumps disabled)' ''               # no zvol
exit $bad
