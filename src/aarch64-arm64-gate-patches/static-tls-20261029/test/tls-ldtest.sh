#!/bin/sh
# tls-ldtest.sh : on dixa as gburd. The ld GD->IE gap in isolation (dixa1 tls-test.sh 'pic' case + threads).
# An exe compiled -fPIC (trad GD) uses a lib's __thread var; compare &tv in the exe with the lib's own &tv, main + 20 threads.
# Linked by the image ld (/usr/bin/ld) and by the aa64tls ld (LD_ALTEXEC), each run under the FIXED rtld+libc (t1),
# so only the link-editor differs.  Expect: old ld = FAIL (TPREL slot under GD code), new ld = PASS (DTPMOD/DTPREL pair).
D=/var/tmp/aa64tls; W=$D/w-ld; [ -d $W ] && find $W -depth -delete; mkdir -p $W; cd $W
CC=/nix/store/alvd5rlddwk6sp09ihg389a585g2xaa1-gcc-14.3.0/bin/gcc
RT=/nix/store/kh36iy924gk7akc2b7m1l45vaszh2lps-gcc-14.3.0-lib/lib:/nix/store/rs4hiizl9f6xmrpp4c58pjc9kl3s2lxf-libc/lib
F="-O2 -mno-outline-atomics -mtls-dialect=trad"; rc=0
# the new ld must load only t1's libs: /lib/libumem would pull a second libc (/lib) next to t1's (seen: ld rc=1, no message)
printf '#!/bin/sh\nLD_LIBRARY_PATH=%s/t1/lib exec %s/t1/usr/bin/ld "$@"\n' $D $D > $D/ld-new; chmod +x $D/ld-new
printf '__thread int tv = 42;\nint *ltv(void){ return &tv; }\n' > lib.c
printf '#include <stdio.h>\n#include <pthread.h>\nextern __thread int tv; int *ltv(void); static int bad;\nstatic void *th(void *x){ if (&tv != ltv() || tv != 42) bad++; return 0; }\nint main(void){ int m = (&tv != ltv()) || tv != 42; for (int i=0;i<20;i++){ pthread_t t; pthread_create(&t,0,th,0); pthread_join(t,0); }\n printf(" tv=%%d main=%%s threads_bad=%%d/20", tv, m?"BAD":"ok", bad); return m||bad; }\n' > main.c
$CC $F -fPIC -shared -o libt.so lib.c -Wl,-R,$RT || exit 2
RUN="env LD_LIBRARY_PATH=$D/t1/lib $D/t1/lib/ld.so.1"
for l in "old:" "new:$D/ld-new"; do n=${l%%:*}; a=${l#*:}
  env ${a:+LD_ALTEXEC=$a} $CC $F -fPIC -o m-$n main.c -L. -lt -lpthread -Wl,-R,$W:$RT || { echo "FAIL ld-$n LINK"; rc=1; continue; }
  r=$(elfdump -r m-$n 2>/dev/null | grep -o 'R_AARCH64_TLS[A-Z_]*' | sort | uniq -c | tr -s ' \n' ' ')
  o=$($RUN ./m-$n 2>&1); s=$?
  if [ $s -eq 0 ]; then echo "PASS ld-$n relocs:$r|$o"; else echo "FAIL ld-$n relocs:$r|$o rc=$s"; [ $n = new ] && rc=1; fi
done
exit $rc
