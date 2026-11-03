#!/usr/bin/bash
# (wave6 copy of wave5 evidence/iconvtest.sh; the world-check run test for item (d): echo e-acute | iconv -f UTF-8 -t UTF-16)
# iconvtest.sh <world-out> <tag> (chef, root): does UTF-8 -> UTF-16 iconv work in a root whose /usr and /lib ARE <world-out>?
# libc opens converters by absolute path (/usr/lib/iconv/<from>%<to>.so, gate libc port/gen/iconv.c:234), so running a world's
# binary on chef would read OI's /usr/lib/iconv: invalid. Here: a chroot dir with /nix lofs-mounted read-only and usr/lib/bin symlinks
# into the world; 32-bit iconv(1), and a 64-bit iconv_open() consumer (t64, built with OI gcc, run on the world's libc).
# -> /var/tmp/wave6/iconv-<tag>.txt. The lofs mount is removed at the end (and on exit).
set -u; W=$1; T=$2; R=/var/tmp/wave6/iconvroot-$T; O=/var/tmp/wave6/iconv-$T.txt
mkdir -p $R/nix $R/tmp; for d in usr lib bin; do rm -f $R/$d; ln -s $W/$d $R/$d; done
mount | grep -q "^$R/nix " || mount -F lofs -o ro /nix $R/nix
trap 'umount $R/nix 2>/dev/null' EXIT
cat > $R/tmp/t64.c <<'EOF'
#include <iconv.h>
#include <stdio.h>
int main(void) { iconv_t c = iconv_open("UTF-16", "UTF-8"); if (c == (iconv_t)-1) { perror("iconv_open UTF-8->UTF-16"); return 1; }
  char in[] = "\xc3\xa9", out[16], *op = out; const char *ip = in; size_t il = 2, ol = sizeof out;
  if (iconv(c, &ip, &il, &op, &ol) == (size_t)-1) { perror("iconv"); return 1; }
  for (char *p = out; p < op; p++) printf("%02x ", (unsigned char)*p); printf("\n"); return 0; }
EOF
${CC64:-/usr/gcc/14/bin/gcc} -m64 -o $R/tmp/t64 $R/tmp/t64.c || { echo "FATAL: t64 did not compile" > $O; exit 1; }
{ echo "world $W"; echo "modules: $(ls $W/usr/lib/iconv 2>/dev/null | wc -l | tr -d ' ') amd64: $(ls $W/usr/lib/iconv/amd64 2>/dev/null | wc -l | tr -d ' ')"
  printf '\303\251\n' | chroot $R /usr/bin/iconv -f UTF-8 -t UTF-16 > $R/tmp/o32 2> $R/tmp/e32; rc=$?
  echo "iconv32(1): rc=$rc out:$(od -An -tx1 $R/tmp/o32 | tr -s ' ') err:$(head -1 $R/tmp/e32)"
  r=$(chroot $R /tmp/t64 2>&1); echo "iconv_open64: rc=$? out: $r"
  elfdump -e $R/tmp/t64 | grep -m1 ei_class; } > $O 2>&1
cat $O
