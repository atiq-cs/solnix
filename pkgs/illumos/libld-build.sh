# libld-build.sh: builder of ./libld.nix. illumos libld.so.4 (amd64, DEBUG like the gate proto's) from the pinned gate source plus
# scripts/patches/0011 (output relocations sorted on the output symbol index). The make steps of usr/src/cmd/sgs/libld/amd64 by
# hand (libld1's build-libld.sh, no nightly/dmake/cw): sgsmsg, libconv.a, libld.so.4. Store tools only.
set -eu
export PATH="$tools:$worldPath"
/usr/bin/bash "$pathGate"
. "$illumosBin"
# fixed build dir: gcc records paths (mapped away below); the key is 1:1 with the drv, also under --check
W=/var/tmp/libld-$buildKey
[ -e "$W" ] && find "$W" -depth -delete
mkdir -m 700 "$W"; trap 'cd /; find "$W" -depth -delete' EXIT
S=$src/usr/src; R=$W/root
# the trees the patch touches are copied and patched; the rest is read from the source store path
for d in cmd/sgs test/elf-tests pkg/manifests; do mkdir -p "$R/usr/src/$(dirname $d)"; cp -R "$S/$d" "$R/usr/src/$d"; done
chmod -R u+w "$R"
(cd "$R" && patch -p1 --fuzz=0 < "$patch")
SGS=$R/usr/src/cmd/sgs
CC="$gcc/bin/gcc -B$binutils/bin/ -m64 -ffile-prefix-map=$W=/build -ffile-prefix-map=$src=/build/src"
WARN="-Wall -Wno-unknown-pragmas -Wno-unused -Wno-parentheses -Wno-switch -Wno-unused-value -Wno-char-subscripts -Wno-type-limits -Wno-missing-braces -Wno-sign-compare -Wno-maybe-uninitialized"
OPT="-O2 -fno-strict-aliasing -fno-unit-at-a-time -fno-optimize-sibling-calls -fno-inline-small-functions -fno-inline-functions-called-once -fno-ipa-cp -fno-ipa-icf -fno-reorder-functions -fno-reorder-blocks-and-partition -fno-aggressive-loop-optimizations -fstack-protector-strong -std=gnu99 -fpic -DPIC -D_REENTRANT"
DEFS="-DDEBUG -D_TS_ERRNO"
INC="-I. -I$SGS/include -I$SGS/include/i386 -I$S/common/elfcap"
INCCONV="$INC -I$S/lib/libc/inc -I$S/common/sgsrtcid"
INCLD="$INC -I$S/lib/libc/inc -I$S/uts/common/krtld -I$S/uts/sparc -I$S/uts/common"

B=$W/b-sgsmsg; mkdir -p $B; cd $B
for f in $SGS/common/assfail.c $SGS/common/findprime.c $SGS/common/string_table.c $S/common/avl/avl.c $S/tools/sgs/sgsmsg/sgsmsg.c; do
  $CC -O2 -std=gnu99 -DNATIVE_BUILD -I$SGS/include -I$SGS/include/i386 -I$S/common/elfcap -c $f -o $(basename $f .c).o
done
$CC -o sgsmsg *.o -Wl,-R,$gccLib/lib/amd64 -Wl,-R,$libc/lib/amd64   # a build tool: the unwrapped gcc adds no RUNPATH
SGSMSG="$B/sgsmsg -i $SGS/messages/sgs.ident"

B=$W/b-libconv; mkdir -p $B; cd $B
perl $SGS/tools/libconv_mk_report_bufsize.pl 8000
LC=$SGS/libconv/common
for m in $LC/*.msg; do n=$(basename $m .msg); $SGSMSG -h ${n}_msg.h -d ${n}_msg.c -n sgs_msg_libconv_$n $m; done
REV=$(perl $SGS/tools/readme_revision $SGS/tools/SUNWonld-README)
echo "libld: link-editor revision $REV" >&2
cp $LC/bld_vernote.ksh bld_vernote; chmod +x bld_vernote
MACH=i386 ksh93 ./bld_vernote -R "$REV" -r 5.11 -o vernote.s
objs=
for n in arch audit c_literal cap config corenote data deftag demangle dl dwarf dwarf_ehe dynamic elf entry globals group lddstub map phdr relocate relocate_i386 relocate_amd64 relocate_sparc sections segments strproc symbols syminfo tokens time version; do
  $CC $OPT $WARN $DEFS $INCCONV -I$LC -c $LC/$n.c -o $n.o; objs="$objs $n.o"; done
for n in cap_machelf dynamic_machelf globals_machelf sections_machelf symbols_machelf symbols_sparc_machelf; do
  $CC $OPT $WARN $DEFS $INCCONV -I$LC -c $LC/$n.c -o ${n}32.o
  $CC $OPT $WARN $DEFS $INCCONV -I$LC -D_ELF64 -c $LC/$n.c -o ${n}64.o; objs="$objs ${n}32.o ${n}64.o"; done
$CC $OPT $WARN $DEFS $INCCONV -c $S/common/elfcap/elfcap.c -o elfcap.o
for m in $LC/*.msg; do n=$(basename $m .msg); $CC $OPT $WARN $DEFS $INCCONV -c ${n}_msg.c -o ${n}_msg.o; objs="$objs ${n}_msg.o"; done
$CC $DEFS -D_ASM $INCCONV -c vernote.s -o vernote.o
"$binutils/bin/gar" crD libconv.a $objs elfcap.o vernote.o

B=$W/b-libld; mkdir -p $B; cd $B
LL=$SGS/libld/common
$SGSMSG -h msg.h -d msg.c -n libld_msg $LL/libld.msg $LL/libld.sparc.msg $LL/libld.intel.msg
F="$OPT $WARN $DEFS -DUSE_LIBLD_MALLOC $INCLD -I$LL"
objs=
c() { $CC $F "$@"; }
c -c msg.c -o msg.o; objs="$objs msg.o"
for n in debug globals util; do c -c $LL/$n.c -o $n.o; objs="$objs $n.o"; done
for n in args entry exit groups ldentry ldlibs ldmachdep ldmain libs files map map_core map_support map_v2 order outfile place relocate resolve sections sunwmove support syms update unwind version wrap; do
  c -c $LL/$n.c -o ${n}32.o; c -D_ELF64 -c $LL/$n.c -o ${n}64.o; objs="$objs ${n}32.o ${n}64.o"; done
for n in alist assfail findprime string_table strhash leb128; do c -c $SGS/common/$n.c -o $n.o; objs="$objs $n.o"; done
c -c $S/common/avl/avl.c -o avl.o; c -c $S/common/elfcap/elfcap.c -o elfcap.o; objs="$objs avl.o elfcap.o"
c -DDO_RELOC_LIBLD -c $S/uts/intel/ia32/krtld/doreloc.c -o doreloc_x86_32.o
c -D_ELF64 -DDO_RELOC_LIBLD -c $S/uts/intel/amd64/krtld/doreloc.c -o doreloc_x86_64.o
c -DDO_RELOC_LIBLD -c $S/uts/sparc/krtld/doreloc.c -o doreloc_sparc_32.o
c -D_ELF64 -DDO_RELOC_LIBLD -c $S/uts/sparc/krtld/doreloc.c -o doreloc_sparc_64.o
c -c $LL/machrel.intel.c -o machrel.intel32.o
c -D_ELF64 -c $LL/machrel.amd.c -o machrel.amd64.o
c -c $LL/machrel.sparc.c -o machrel.sparc32.o; c -D_ELF64 -c $LL/machrel.sparc.c -o machrel.sparc64.o
c -c $LL/machsym.sparc.c -o machsym.sparc32.o; c -D_ELF64 -c $LL/machsym.sparc.c -o machsym.sparc64.o
objs="$objs doreloc_x86_32.o doreloc_x86_64.o doreloc_sparc_32.o doreloc_sparc_64.o machrel.intel32.o machrel.amd64.o machrel.sparc32.o machrel.sparc64.o machsym.sparc32.o machsym.sparc64.o"
# Two links, as gcc bootstraps itself: s1 with the stock ld, then the shipped one with ld running s1, so libld.so.4's own
# .SUNW_reloc is in the new order too (the stock order of a link this size can differ between hosts).
lnk() { $CC -shared -nodefaultlibs -o libld.so.4 -Wl,-hlibld.so.4 -Wl,-ztext -Wl,-zdefs -Wl,-Bdirect \
  -Wl,-M$LL/mapfile-vers -Wl,-M$S/common/mapfiles/common/map.pagealign -Wl,-M$S/common/mapfiles/common/map.noexdata \
  -Wl,-ulink_ver_string "-Wl,-R\$ORIGIN:$ldStock/lib/amd64:$libc/lib/amd64" $objs $W/b-libconv/libconv.a \
  $gate/lib/amd64/liblddbg.so.4 -L$gate/lib/amd64 -lelf -lc; }
# a libld outside its slice: its RUNPATH ($ORIGIN) finds no liblddbg, and the host's /lib/64 one pulls a second libc (ld
# crashed in strncmp, woof). Run it with the stock slice's libs and the libc slice, as the ld slice's RUNPATH will.
LLP="$ldStock/lib/amd64:$libc/lib/amd64"
lnk; mkdir s1; mv libld.so.4 s1/
LD_LIBRARY_PATH_64=$B/s1:$LLP lnk
mkdir -p "$out/lib/amd64"; cp libld.so.4 "$out/lib/amd64/libld.so.4"
L=$out/lib/amd64/libld.so.4
"$IB/elfdump" -d "$L" | grep -E 'NEEDED|SONAME|RUNPATH' >&2
# $ORIGIN first: in the ld slice its siblings (liblddbg) win; alone (this out, its gate) it resolves in the stock slice + libc
[ "$("$IB/elfdump" -d "$L" | awk '$2 == "RUNPATH" {print $4}')" = "\$ORIGIN:$ldStock/lib/amd64:$libc/lib/amd64" ] || { echo "FATAL: libld RUNPATH" >&2; exit 1; }
LD_LIBRARY_PATH= LD_LIBRARY_PATH_64= "$IB/ldd" "$L" | awk '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//)' | grep . && { echo "FATAL: libld resolves outside the store" >&2; exit 1; }
for p in "$src" "$W" "$gcc" "$binutils"; do
  [ "$(LC_ALL=C tr '\000' '\n' < "$L" | grep -cF "$p")" = 0 ] || { echo "FATAL: libld.so.4 names $p" >&2; exit 1; }
done

# the fix works, and the check can fail: ld meets the symbols of refs1/refs2 in another order when undefs.o (references only)
# comes first. Stock ld gives two orders (negative control); this libld gives one.
T=$W/t; mkdir -p $T; cd $T; O=$R/usr/src/test/elf-tests/tests/relocs/order
for f in refs1 refs2 undefs; do "$binutils/bin/as" --64 $O/$f.s -o $f.o; done
ord() { for o in "refs1.o refs2.o undefs.o" "undefs.o refs1.o refs2.o"; do d=$1-${o%%.*}; mkdir $d
  (cd $d && env ${2:+LD_LIBRARY_PATH_64=$2:$LLP} "$ldStock/usr/bin/ld" -G -o order.so $(for x in $o; do echo ../$x; done)); done
  cmp -s $1-refs1/order.so $1-undefs/order.so; }
if ord stock ""; then echo "FATAL: negative control: stock ld gave one order (the test cannot fail)" >&2; exit 1; fi
ord new "$out/lib/amd64" || { echo "FATAL: libld 0011: the output depends on the order ld meets each symbol" >&2; exit 1; }
LD_LIBRARY_PATH_64=$out/lib/amd64:$LLP LD_DEBUG=files "$ldStock/usr/bin/ld" -V 2>&1 | grep -q "file=$out/lib/amd64/libld.so.4" \
  || { echo "FATAL: the order test did not map the new libld" >&2; exit 1; }
echo "=== libld 0011: stock ld 2 orders, this libld 1 (relocs/order) ===" >&2
