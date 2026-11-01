#!/usr/bin/env bash
# build-newlibtest.sh -- build /bin/newlibtest, the ONE solnix riscv64 program
# linked against a REAL third-party libc (newlib 4.5.0) instead of the
# hand-written user/libc.c slice, and splice it into the COMMITTED user_elfs.h
# without touching any other program's bytes.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A SEPARATE SCRIPT AND NOT PART OF build-user.sh
# ---------------------------------------------------------------------------
# newlib is a DIFFERENT libc from user/libc.c: hard-float only, medlow only, and
# therefore linked at a different base (see the flag notes below). Keeping it in
# its own script keeps those three forced choices in one place instead of
# branching the PROGS loop. build-user.sh CHAINS this script at the end, so a
# plain `bash user/build-user.sh` is a COMPLETE regeneration -- required, because
# rootfs.c references newlibtest_elf[] and will not compile without it.
#
# HISTORY, because the splice below looks paranoid without it. Regeneration used
# to break the miniwl gate, so this script rewrote only init_elf + newlibtest_elf
# and left every other program's committed bytes untouched. That breakage is now
# FIXED, and it was never about newlib OR the compiler. The failure was:
#
#   [fork] pid 20 -> child pid 21
#     [ok] fork the client
#   [trap] exception: scause=0xf (store page fault)
#          sepc=0x8020019e stval=0xffffecb0 sstatus=0x200040020
#
# sepc 0x8020019e is `sd ra,0(sp)`, the first store in _trap_entry. The cause was
# _trap_entry leaving the interrupted sp parked in sscratch for the whole of
# trap(): its own from-U-vs-from-S discriminator is `sscratch != 0`, so any trap
# taken while trap() ran was misclassified as from-U and built its frame at that
# parked USER sp. Regeneration only shifted instruction counts, i.e. the clock's
# phase against that window -- the committed blob was a lucky phase, not a
# correct kernel. Fixed in trap.S by zeroing sscratch once it has been read;
# negative-controlled (removing just that instruction reproduces the signature
# above 4/4). See docs/riscv64-first-real-binary.md.
#
# The splice is KEPT anyway: it makes this script idempotent and re-runnable on
# its own without disturbing the other programs' bytes.
#
# ---------------------------------------------------------------------------
# WHY THE ODD BUILD FLAGS (all three are measured, not preferences)
# ---------------------------------------------------------------------------
#  1. HARD FLOAT, forced. newlib ships exactly one multilib
#     (`gcc -print-multi-lib` => ".;"), built rv64imafdc/lp64d. There is no
#     soft-float newlib, so a real-libc binary is necessarily hard-float and
#     depends on the kernel's FP context switch.
#  2. -mcmodel=medlow, forced. newlib's libc.a carries 1547 absolute
#     R_RISCV_HI20 relocations against just 3 R_RISCV_PCREL_HI20: medlow code.
#  3. Therefore link base 0x40010000, NOT the usual 0xC0010000. medlow reaches
#     only [0, 0x7FFFFFFF], so linking at 0xC0010000 fails outright with
#     "relocation truncated to fit: R_RISCV_HI20 against symbol `errno'".
#     0x40010000 is Sv39 level-2 slot 1, which hat_as_newroot() leaves free for
#     user mappings (it copies only slots 0, 2 and 256..511 into a new root).
set -euo pipefail
cd "$(dirname "$0")"

TC="${TC:-riscv64-none-elf}"
CC="${CC:-${TC}-gcc}"
LD="${LD:-${TC}-ld}"

# NEWLIB may be set to point at any newlib install; the default is the newlib
# belonging to the pinned gcc 14.3.0 cross toolchain.
NEWLIB_DIR="${NEWLIB:-}"
if [ ! -d "${NEWLIB_DIR}/riscv64-none-elf/lib" ]; then
	NEWLIB_DIR="$(ls -d /nix/store/*newlib-riscv64-none-elf-4.5.0* 2>/dev/null | head -1 || true)"
fi
if [ ! -d "${NEWLIB_DIR}/riscv64-none-elf/lib" ]; then
	echo "FATAL: no newlib found. Set NEWLIB=/path/to/newlib-riscv64-none-elf" >&2
	exit 1
fi
NLLIB="${NEWLIB_DIR}/riscv64-none-elf/lib"
NLINC="${NEWLIB_DIR}/riscv64-none-elf/include"

NL_CFLAGS="-march=rv64imafdc_zicsr -mabi=lp64d -mcmodel=medlow \
	-O2 -g -Wall -Wextra -fno-stack-protector -fno-pic \
	-ffile-prefix-map=$(cd ../../../.. && pwd)=."
LIBGCC="$("$CC" -march=rv64imafdc_zicsr -mabi=lp64d -print-libgcc-file-name)"

echo "== build /bin/newlibtest against REAL newlib libc.a =="
echo "   toolchain: $("$CC" -dumpversion)  (the pin; do not change)"
echo "   newlib:    $NLLIB"

"$CC" $NL_CFLAGS -isystem "$NLINC" -c newlibtest.c  -o newlibtest.o
"$CC" $NL_CFLAGS -isystem "$NLINC" -c newlib_glue.c -o newlib_glue.o
"$LD" -T newlib.ld -Map=newlibtest.map -o newlibtest.elf \
	"$NLLIB/crt0.o" newlibtest.o newlib_glue.o \
	-L"$NLLIB" -lc -lm "$LIBGCC"

# ---------------------------------------------------------------------------
# PROVENANCE ASSERTIONS. The entire value of this binary is that it is NOT the
# toy libc, so that is verified from the link map rather than assumed. A build
# that silently re-linked user/libc.c would make a trivial result look like a
# breakthrough, so these are hard failures.
# ---------------------------------------------------------------------------
nlmembers=$(grep -oE "libc\.a\(libc_a-[^)]*\)" newlibtest.map | sort -u | wc -l)
if [ "$nlmembers" -lt 20 ]; then
	echo "FATAL: only $nlmembers newlib archive members linked (expected >=20)." >&2
	echo "       Refusing to ship a binary that may be the toy libc." >&2
	exit 1
fi
if grep -q "libc-riscv\.a" newlibtest.map; then
	echo "FATAL: the TOY libc (libc-riscv.a) got linked in." >&2
	exit 1
fi
# Must be fully self-contained: a static ET_EXEC with nothing left undefined.
if "${TC}-nm" --undefined-only newlibtest.elf | grep -q .; then
	echo "FATAL: unresolved symbols remain:" >&2
	"${TC}-nm" --undefined-only newlibtest.elf >&2
	exit 1
fi
echo "  provenance OK: $nlmembers real newlib members, 0 toy-libc members,"
echo "                 0 undefined symbols"
echo "  newlibtest.elf: $(wc -c < newlibtest.elf) bytes @ 0x40010000 (lp64d)"

# ---------------------------------------------------------------------------
# Splice the array into user_elfs.h, replacing any previous newlibtest block so
# the script is idempotent. Every other program's bytes are left untouched.
# ---------------------------------------------------------------------------
# init must also be rebuilt, because the gate call lives in init.c. It is built
# with the STOCK soft-float flags and the stock init.ld, exactly as build-user.sh
# builds it, so the only difference from the committed init is the added
# newlib_gate() call.
echo "== rebuild init.elf (adds the newlib_gate call) =="
STOCK_CFLAGS="-march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany \
	-ffreestanding -nostdlib -fno-stack-protector -fno-pic -Wall -Wextra -Os -g \
	-ffile-prefix-map=$(cd ../../../.. && pwd)=."
"$CC" $STOCK_CFLAGS -c init.c -o init.o
"$LD" -T init.ld -o init.elf init.o libc-riscv.a
echo "  init.elf: $(wc -c < init.elf) bytes"

HDR=../user_elfs.h
echo "== splice newlibtest_elf[] + init_elf[] into $HDR =="
# Replace ONLY these two arrays. Every other program's bytes stay byte-identical,
# which is the whole point: a full regeneration breaks the miniwl gate (see the
# banner), so the diff to user_elfs.h must be surgical and reviewable.
python3 - "$HDR" newlibtest.elf init.elf <<'PYEOF'
import re, sys

hdr, nl_elf, init_elf = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(hdr).read()


def emit(name, path):
    data = open(path, "rb").read()
    rows = ["".join("%d," % b for b in data[i:i + 16])
            for i in range(0, len(data), 16)]
    return data, ("static const unsigned char %s[] = {\n" % name
                  + "\n".join(rows)
                  + "\n};\nstatic const unsigned long %s_len = sizeof (%s);\n"
                  % (name, name))


def drop(text, name):
    return re.sub(
        r"\n?static const unsigned char %s\[\].*?"
        r"static const unsigned long %s_len = sizeof \(%s\);\n" % (name, name, name),
        "\n", text, flags=re.S)


# init_elf REPLACES the committed array in place (it must keep its position,
# since rootfs.c indexes vfiles by order); newlibtest_elf is appended.
init_data, init_block = emit("init_elf", init_elf)
if "static const unsigned char init_elf[] = {" not in text:
    sys.exit("FATAL: no init_elf array in %s" % hdr)
text = drop(text, "init_elf")
marker_init = "static const unsigned char sh_elf[] = {"
if marker_init not in text:
    sys.exit("FATAL: no sh_elf array to anchor init_elf before")
text = text.replace(marker_init, init_block + marker_init, 1)

nl_data, nl_block = emit("newlibtest_elf", nl_elf)
text = drop(text, "newlibtest_elf")
marker = "#endif /* _USER_ELFS_H */"
if marker not in text:
    sys.exit("FATAL: %s has no %s marker" % (hdr, marker))
text = text.replace(marker, nl_block + marker)

open(hdr, "w").write(text)
print("  init_elf:       %d bytes (replaced in place)" % len(init_data))
print("  newlibtest_elf: %d bytes (appended)" % len(nl_data))
PYEOF

# Also drop it into the on-disk ustar rootfs image, so /bin/newlibtest resolves
# whether it is served from the embedded vfile table or from vioblk.
#
# Use `tar -r` rather than hand-splicing 512-byte blocks. A ustar archive ends
# with two all-zero blocks, but an embedded ELF's own contents contain long zero
# runs, so scanning the raw bytes for a zero block finds a FALSE end and
# truncates the image. An earlier version of this script did exactly that and cut
# rootfs.img from 450560 to 82944 bytes, losing 13 of its 14 members. tar parses
# the member headers and knows where the archive actually ends.
if [ -f ../rootfs.img ]; then
	echo "== add /bin/newlibtest to rootfs.img =="
	IMG="$(cd .. && pwd)/rootfs.img"
	# Drop any previous copy first so re-runs do not stack duplicate members.
	if tar -tf "$IMG" 2>/dev/null | grep -qx "bin/newlibtest"; then
		tar --delete -f "$IMG" bin/newlibtest 2>/dev/null || true
	fi
	before=$(tar -tf "$IMG" 2>/dev/null | wc -l)
	STAGE="$(mktemp -d)"
	mkdir -p "$STAGE/bin"
	cp newlibtest.elf "$STAGE/bin/newlibtest"
	( cd "$STAGE" && tar --format=ustar -rf "$IMG" bin/newlibtest )
	find "$STAGE" -mindepth 1 -delete
	rmdir "$STAGE"
	# Pad back out to a whole number of 512-byte blocks for the block device.
	python3 - "$IMG" <<'PYEOF'
import sys
p = sys.argv[1]
n = len(open(p, "rb").read())
pad = (-n) % 512
if pad:
    open(p, "ab").write(b"\0" * pad)
print("  rootfs.img now %d bytes" % (n + pad))
PYEOF
	after=$(tar -tf "$IMG" 2>/dev/null | wc -l)
	echo "  members: $before -> $after"
	# A truncating bug here is silent and expensive, so assert we only GREW.
	if [ "$after" -lt "$before" ]; then
		echo "FATAL: rootfs.img lost members ($before -> $after)" >&2
		exit 1
	fi
	tar -tf "$IMG" 2>/dev/null | grep -qx "bin/newlibtest" || {
		echo "FATAL: /bin/newlibtest missing from rootfs.img" >&2
		exit 1
	}
fi

echo "== done. Rebuild the kernel to pick up the new header:"
echo "     cd .. && bash build-scanout.sh"
