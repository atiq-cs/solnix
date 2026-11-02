#!/bin/sh
# Negative controls for hcitest: break one mechanism at a time and require
# `hcitest -t` or run-fixtures.sh to FAIL. A sabotage counts only if its
# target text was found (the file changed) AND the sabotaged tree BUILT.
# Run from this directory after a good build (Makefile.illumos `check`).
set -u
here=$(cd .. && pwd)
work=$(mktemp -d /tmp/hcitest-neg.XXXXXX) || exit 1
trap 'find "$work" -depth -delete' EXIT
caught=0; total=0; bad=0

sab() {	# file (relative to netbt/), sed expression, label
	total=$((total + 1))
	d="$work/$total"; mkdir -p "$d"
	cp -R "$here/netbt" "$here/iwmbtfw" "$d/"
	find "$d" -name '*.o' -type f -delete; find "$d" -name hcitest -type f -delete
	chmod -R u+w "$d"
	f="$d/netbt/$1"
	sed "$2" "$f" > "$f.new" && mv "$f.new" "$f"
	if cmp -s "$here/netbt/$1" "$f"; then
		echo "NEG $total ($3): target text not found -- PROBLEM"; bad=1; return
	fi
	if ! (cd "$d/netbt" && gmake -f Makefile.illumos PROTOINC="${PROTOINC:-/usr/include}" hcitest >build.log 2>&1); then
		echo "NEG $total ($3): sabotaged tree did not build -- PROBLEM"; bad=1; return
	fi
	if (cd "$d/netbt" && ./hcitest -t >run.log 2>&1 && ./run-fixtures.sh >>run.log 2>&1); then
		echo "NEG $total ($3): NOT caught -- PROBLEM"; bad=1
	else
		echo "NEG $total ($3): caught ($(grep -c -E 'selftest FAIL|-- FAIL' "$d/netbt/run.log") checks failed)"
		caught=$((caught + 1))
	fi
}

sab mbuf.c 's/memcpy(p, m->m_data + off, n);/memcpy(p, m->m_data + off + (off < m->m_len - 1), n);/' "m_copydata reads one byte late"
sab mbuf_ops.c 's/mp->m_pkthdr.len -= req - len;/mp->m_pkthdr.len -= req - len + 1;/' "m_adj pkthdr.len off by one"
sab gate.c 's/return (vt.img_type == TLV_IMG_TYPE_OPERATIONAL ? 0 : ENODEV);/return (0);/' "bootloader gate always passes"
sab rec.c 's/rec_scrub_addr(e + 3 + k \* 14);/(void) k;/' "scrubber keeps inquiry addresses"
sab kshim.c 's/rv = 0;/rv = EWOULDBLOCK;/' "cv wakeup reported as a timeout"
sab core_io.c 's/m_frombuf(HCI_EVENT_PKT, buf, n)/m_frombuf(HCI_EVENT_PKT, buf, n - 1)/' "events loaded one byte short"
sab core.c 's/m_copydata(m, 1, len, buf);/m_copydata(m, 0, len, buf);/' "H4 type byte not stripped from commands"
sab xport_fixture.c 's/if (l->len != n || memcmp(l->b, p, n) != 0) {/if (0) {/' "fixture matcher accepts any command"

echo "negative controls: $caught/$total caught"
[ "$bad" -eq 0 ] && [ "$caught" -eq "$total" ]
