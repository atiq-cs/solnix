#!/usr/bin/env bash
# stage-demo.sh <stage-dir> -- tryit1: the browser demo's root fs. dash + sbase (applets as hard links) + less +
# minigzip, the demo init (uts/user/init.c built -DSOLNIX_DEMO) as /sbin/init, /etc/{passwd,motd,release}.
# Login: root, no password (empty passwd field; shell /bin/dash).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$1"; OUT="${OUT:?}"; INIT="${INIT:?demo init ELF}"
mkdir -p "$S/bin" "$S/sbin" "$S/etc" "$S/tmp" "$S/root" "$S/usr/share/terminfo"
cp "$INIT" "$S/sbin/init"
cp "$OUT/sbase-box" "$OUT/dash" "$OUT/less" "$OUT/minigzip" "$S/bin/"
for a in $(sed -n 's/^.*{"\([^"]*\)", *[a-z_0-9]*_main},$/\1/p' "${SBASE_BOX_C:-$OUT/sbase-box.c}"); do
	case "$a" in "["|sbase-box) continue;; esac
	[ -e "$S/bin/$a" ] || ln "$S/bin/sbase-box" "$S/bin/$a"
done
ln "$S/bin/dash" "$S/bin/sh"
printf '%s\n' 'root::0:0:Super-User:/root:/bin/dash' > "$S/etc/passwd"
printf '%s\n' "${MOTD1:?}" "${MOTD2:?}" > "$S/etc/motd"
printf '%s\n' "${RELEASE:?}" > "$S/etc/release"
printf '%s\n' cherry banana apple date banana elderberry fig grape bandana > "$S/etc/words"
tic -x -o "$S/usr/share/terminfo" <(infocmp vt100) >/dev/null 2>&1
tic -x -o "$S/usr/share/terminfo" <(infocmp xterm) >/dev/null 2>&1
echo "demo root: $(find "$S" -mindepth 1 | wc -l) names, $(du -sb "$S" | cut -f1) bytes apparent"
