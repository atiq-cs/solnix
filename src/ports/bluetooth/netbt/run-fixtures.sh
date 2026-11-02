#!/bin/sh
# run-fixtures.sh [transcript...]: replay each positive transcript into the
# netbt core, then five sabotaged copies of it, and require each to take the
# path written down beforehand (bt3 progress.txt step 25/26):
#   N0 Intel gate says bootloader (img 01)  -> refused, no HCI_Reset, rc 4
#   N1 a corrupted event (bad length)       -> hci_event drops it, init times out, rc 4
#   N2 inquiry Command Status failure 0x0c  -> refused, rc 6
#   N3 inquiry with no results              -> 0 devices, rc 5
#   N4 one inquiry result dropped           -> N-1 devices, rc 0
#   N5 BDADDR Command Complete opcode wrong -> init never finishes, rc 4
#   N6 transcript expects another command   -> fixture mismatch, EIO, rc 4
# Default: every fixtures/*.hcx. Run from this directory after a build.
set -u
here=$(pwd)
work=$(mktemp -d /tmp/hcitest-fx.XXXXXX) || exit 1
trap 'find "$work" -depth -delete' EXIT
bad=0; n=0

expect() {	# label, file, want rc, then grep -E patterns the output must ALL contain
	n=$((n + 1))
	xl=$1; xf=$2; want=$3; shift 3	# not f: that is the caller's loop variable
	out="$work/$n.out"
	./hcitest -F "$xf" -i > "$out" 2>&1
	rc=$?
	if [ "$rc" -ne "$want" ]; then
		echo "FX $xl: rc $rc, want $want -- FAIL"; sed 's/^/    /' "$out" | tail -8; bad=1; return
	fi
	for p in "$@"; do
		if ! grep -E -q "$p" "$out"; then
			echo "FX $xl: rc $rc but no '$p' -- FAIL"; sed 's/^/    /' "$out" | tail -8; bad=1; return
		fi
	done
	echo "FX $xl: rc $rc, $# patterns -- ok"
}

# sed on one E line, selected by its event prefix; refuse a no-op sabotage
sab() {	# src, dst, sed expression
	sed -E "$3" "$1" > "$2"
	if cmp -s "$1" "$2"; then echo "FX sabotage on $(basename "$1") changed nothing -- FAIL"; bad=1; return 1; fi
}

for f in ${*:-fixtures/*.hcx}; do
	b=$(basename "$f" .hcx)
	ndev=$(./hcitest -F "$f" -i 2>&1 | sed -n 's/^inquiry: complete, \([0-9]*\) device.*/\1/p')
	expect "$b positive" "$f" 0 "^fixture: all [0-9]+ lines consumed" \
	    "^ubt0: bdaddr ..:..:..:..:..:.. flags 0x0003 UP RUNNING$" "errors 0 gate_refused 0"
	[ -n "$ndev" ] && [ "$ndev" -ge 1 ] || { echo "FX $b: positive found no device -- FAIL"; bad=1; continue; }

	# N0: gate TLV image type 03 -> 01
	sab "$f" "$work/n0.hcx" '/^E [^ ]+ 0e....05fc00/s/1c0103/1c0101/' &&
	expect "$b N0 bootloader" "$work/n0.hcx" 4 "not operational \(img_type 0x01\)" \
	    "^SIOCSBTFLAGS up: No such device \(err 19\)" "cmds_out 0 .*gate_refused 1"
	# N1: Read_BD_ADDR Command Complete length byte one too long
	sab "$f" "$work/n1.hcx" '/^E [^ ]+ 0e0a01091000/s/0e0a01091000/0e0b01091000/' &&
	expect "$b N1 bad length" "$work/n1.hcx" 4 "\(err 11\)$" "flags 0x02e0 INIT-PENDING$" \
	    "errors 0 " "^fixture: line [0-9]+ not consumed"
	# N2: inquiry Command Status 0x0c, and nothing after it
	awk '/^C 010405/ {print; print "E +1 0f040c010104"; exit} {print}' "$f" > "$work/n2.hcx"
	expect "$b N2 cmd status" "$work/n2.hcx" 6 "^inquiry: refused \(status 0x0c\)" \
	    "CommandStatus opcode \(001\|0001\) failed \(status=0x0c\)" "errors 1 " "^fixture: all"
	# N3: inquiry results removed
	grep -v -E '^E [^ ]+ (02|22|2f)' "$f" > "$work/n3.hcx"
	expect "$b N3 no results" "$work/n3.hcx" 5 "^inquiry: complete, 0 devices, memo cache 0" "^fixture: all"
	# N4: every result for the first device removed (one response per event, as RSSI mode sends)
	awk '/^E [^ ]+ (02|22|2f)/ { a = substr($3, 7, 12); if (first == "") first = a; if (a == first) next } {print}' \
	    "$f" > "$work/n4.hcx"
	if [ "$ndev" -ge 2 ]; then
		expect "$b N4 one dropped" "$work/n4.hcx" 0 "^inquiry: complete, $((ndev - 1)) device" "^fixture: all"
	else
		expect "$b N4 one dropped" "$work/n4.hcx" 5 "^inquiry: complete, 0 devices" "^fixture: all"
	fi
	# N5: Read_BD_ADDR Command Complete answers the wrong opcode (0x100a)
	sab "$f" "$work/n5.hcx" '/^E [^ ]+ 0e0a01091000/s/0e0a01091000/0e0a010a1000/' &&
	expect "$b N5 wrong opcode" "$work/n5.hcx" 4 "bdaddr 00:00:00:00:00:00 flags 0x0020 INIT-PENDING$" \
	    "\(err 11\)$" "^fixture: line [0-9]+ not consumed"
	# N6: the transcript expects a different command (proves the matcher can fail)
	sab "$f" "$work/n6.hcx" 's/^C 051000/C 061000/' &&
	expect "$b N6 cmd mismatch" "$work/n6.hcx" 4 "^fixture: command differs from line [0-9]+" \
	    "^SIOCSBTFLAGS up: I/O error \(err 5\)"
done
echo "fixtures: $n checks, $([ $bad -eq 0 ] && echo all ok || echo FAILURES)"
[ "$bad" -eq 0 ]
