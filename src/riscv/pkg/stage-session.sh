#!/usr/bin/env bash
# stage-session.sh <stage-dir> -- ONE session root with all six packages + a terminfo dir.
# No /sbin/init: the kernel falls back to its embedded uts init (gates, then the /etc/passwd
# login on the console, which execs root's shell /bin/dash). sbase's applets are HARD LINKS to
# one sbase-box (ustar '1' entries; argv[0] picks the applet), as an installed sbase would be.
set -euo pipefail
S="$1"; OUT="${OUT:-$HOME/scratch/rvsh/out}"
mkdir -p "$S/bin" "$S/etc" "$S/tmp" "$S/usr/share/terminfo"
cp "$OUT/sbase-box" "$OUT/dash" "$OUT/less" "$OUT/minigzip" "$OUT/curstest" "$S/bin/"
for a in $("$HOME/scratch/rvsh/hostsb-bin/sbase-box" 2>&1 | tr ' ' '\n' | grep -v '^\[$\|^sbase-box\|^$\|^\['); do
	[ -e "$S/bin/$a" ] || ln "$S/bin/sbase-box" "$S/bin/$a"
done
ln -s dash "$S/bin/sh" 2>/dev/null || true; rm -f "$S/bin/sh"	# no symlinks in the kernel's ustar reader
printf '%s\n' 'root:x:0:0:Super-User:/:/bin/dash' > "$S/etc/passwd"
printf '%s\n' cherry banana apple date banana elderberry fig grape bandana > "$S/etc/words"
tic -x -o "$S/usr/share/terminfo" <(infocmp vt100) >/dev/null 2>&1
tic -x -o "$S/usr/share/terminfo" <(infocmp xterm) >/dev/null 2>&1
echo "session: $(find "$S" -mindepth 1 | wc -l) names, $(du -sb "$S" | cut -f1) bytes apparent"
