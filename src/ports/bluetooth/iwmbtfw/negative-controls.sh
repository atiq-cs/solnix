#!/bin/sh
# Negative controls for btintelfw -t: break one mechanism at a time and require
# the self-test to FAIL. A sabotage counts only if its target text was found
# (the file changed) AND the sabotaged tree BUILT; a build failure proves nothing.
# Run from this directory after a good build (Makefile.illumos `check`).
set -u
here=$(pwd)
work=$(mktemp -d /tmp/btintelfw-neg.XXXXXX) || exit 1
trap 'find "$work" -depth -delete' EXIT
caught=0; total=0; bad=0

sab() {	# file, sed expression, label
	total=$((total + 1))
	d="$work/$total"; mkdir -p "$d"
	cp -R "$here/." "$d/"
	find "$d" -name '*.o' -type f -delete; find "$d" -name btintelfw -type f -delete
	chmod -R u+w "$d"
	sed "$2" "$d/$1" > "$d/$1.new" && mv "$d/$1.new" "$d/$1"
	if cmp -s "$here/$1" "$d/$1"; then
		echo "NEG $total ($3): target text not found -- PROBLEM"; bad=1; return
	fi
	if ! (cd "$d" && gmake -f Makefile.illumos PROTOINC="${PROTOINC:-/usr/include}" btintelfw >build.log 2>&1); then
		echo "NEG $total ($3): sabotaged tree did not build -- PROBLEM"; bad=1; return
	fi
	if (cd "$d" && ./btintelfw -t >run.log 2>&1); then
		echo "NEG $total ($3): NOT caught -- PROBLEM"; bad=1
	else
		echo "NEG $total ($3): caught ($(grep -c 'selftest FAIL' "$d/run.log") checks failed)"
		caught=$((caught + 1))
	fi
}

sab ugen_evq.c 's/elen = 2 + (size_t)q->buf\[1\];/elen = q->len;/' "event framing ignores HCI length"
sab ugen_usb.c 's/buf\[6\] = len . 0xff;/buf[6] = 0;/' "control setup wLength zeroed"
sab ugen_usb.c 's/buf\[0\] = rt;/buf[0] = rt | 0x80;/' "control setup direction bit"
sab btintelfw.c 's/memcpy(out9, ev->data, 9);/memcpy(out9, ev->data + 1, 9);/' "Read_Local_Version return params"
sab ugen_usb.c 's/!ugen_noclear \&\&/0 \&\&/' "interrupt-IN toggle reset at open removed"
sab compat/sys/endian.h 's/((uint32_t)p\[1\] << 8)/((uint32_t)p[1] << 0)/' "le32dec byte order"

echo "negative controls: $caught/$total caught"
[ "$bad" -eq 0 ] && [ "$caught" -eq "$total" ]
