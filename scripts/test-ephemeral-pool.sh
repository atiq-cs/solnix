#!/usr/bin/env bash
# test-ephemeral-pool.sh -- solnix-ephemeral-pool.sh decides create / import / refuse / nothing
# from the disks alone. zpool/zdb/dd are faked on PATH; each case says what the disks hold.
set -u
S=${1:-$(dirname "$0")/solnix-ephemeral-pool.sh}
W=$(mktemp -d /tmp/ep.XXXXXX); trap 'find "$W" -mindepth 1 -delete; rmdir "$W"' EXIT
mkdir -p "$W/bin" "$W/dev"; : > "$W/ds"
# fake disk state: $W/state/<disk> = blank | ours | gpt | other ; $W/imported = pool is imported
cat > "$W/bin/zpool" <<'EOF'
#!/bin/sh
case $1 in list) [ -e "$EPW/imported" ];; *) echo "zpool $*" >> "$EPW/calls";; esac
EOF
cat > "$W/bin/zdb" <<'EOF'
#!/bin/sh
d=$(basename "$2"); d=${d%s0}; d=${d%p0}; s=$(cat "$EPW/state/$d")
case "$s:$2" in ours:*s0) echo "    name: 'data'";; other:*s0) echo "    name: 'other'";; ours:*p0|other:*p0) ;; *) exit 2;; esac
EOF
cat > "$W/bin/dd" <<'EOF'
#!/bin/sh
# the GPT probe is `dd if=<disk> | dd bs=8 count=1`: the first dd emits, the second passes it on.
d=""; for a; do case $a in if=*) d=$(basename "${a#if=}"); d=${d%p0};; esac; done
if [ -z "$d" ]; then cat; elif [ "$(cat "$EPW/state/$d")" = gpt ]; then printf 'EFI PART'; fi
EOF
chmod +x "$W/bin/"*
bad=0
t() { # t <want-rc> <want-call-regex|-> <imported 0/1> <state of c2> <state of c3>
  find "$W" -maxdepth 1 \( -name calls -o -name imported \) -delete; mkdir -p "$W/state"
  echo "$4" > "$W/state/c2t1d0"; echo "$5" > "$W/state/c3t1d0"; [ "$3" = 1 ] && : > "$W/imported"
  out=$(EPW=$W PATH="$W/bin:$PATH" POOL=data DISKS="c2t1d0 c3t1d0" SOLNIX_EP_DATASETS="$W/ds" \
        DEVR="$W/dev" bash -c "sed 's,^PATH=.*,,; s,\[ -c \"\$r\" \],true,' '$S' | sh" 2>&1); rc=$?
  calls=$(cat "$W/calls" 2>/dev/null | tr '\n' ';')
  if [ $rc = "$1" ] && { [ "$2" = - ] && [ -z "$calls" ] || echo "$calls" | grep -qE "$2"; }; then echo "ok: $4/$5 imported=$3 -> rc $rc ${calls:-no zpool call}"
  else echo "FAIL: $4/$5 imported=$3: want rc $1 /$2/, got rc $rc '$calls' ($out)"; bad=1; fi
}
t 0 '^zpool create .*cachefile=none.* data c2t1d0 c3t1d0;$' 0 blank blank
t 0 '^zpool import -o cachefile=none -d /tmp/solnix-ep\.[0-9]+ data;$' 0 ours ours
t 0 - 1 blank blank
t 1 - 0 blank gpt
t 1 - 0 ours blank
t 1 - 0 other other
exit $bad
