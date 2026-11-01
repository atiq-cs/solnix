#!/bin/sh
# mkbins.sh : on dixa as gburd. Prebuild the tls-repro2 programs with the NEW store gcc (5as0zr4v) against the NEW libc slice
# (m0w5yd5w), both in the aa64tls image closure, test libs found via $ORIGIN, so they run on an image with no compiler.
# Packs /var/tmp/aa64tls/tls-bins.tar (bins + run-bins.sh). Expect on the aa64tls image 6/6 PASS rc 0.
D=/var/tmp/aa64tls; W=$D/w-bins; [ -d $W ] && find $W -depth -delete; mkdir -p $W; cd $W
G=$(ls -l $D/roots/gcc | sed 's/.* -> //')/bin/gcc; GL=$(ls -l $D/roots/gcc-lib | sed 's/.* -> //')/lib; L=$(ls -l $D/roots/libc | sed 's/.* -> //')/lib
F="-O2 -mno-outline-atomics -mtls-dialect=trad -fPIC"; R="-Wl,-R,\$ORIGIN:$GL:$L"
sed -n '/^decl=/,/^\$CC \$F -o a2 /p' $D/tls-repro2.sh | grep -v '^o=' > gen-a.sh
CC=$G RT="\$ORIGIN:$GL:$L" W=$W F="$F" sh -c '. ./gen-a.sh' 2>&1 | tail -2
sed -n '/^printf .__thread long a = 11/,/^X$/p' $D/tls-repro2.sh > gen-b.sh; sh gen-b.sh
sed -n '/^# C: /,/^printf "#include <stdio.h>\\n#include <stdint.h>\\n#include <pthread.h>\\nchar/p' $D/tls-repro2.sh | grep '^printf' > gen-c.sh; sh gen-c.sh
for lm in ie gd; do lf=""; [ $lm = ie ] && lf=-ftls-model=initial-exec; mkdir -p $lm
  $G $F $lf -shared -o $lm/libA.so A.c $R && $G $F $lf -shared -o $lm/libB.so B.c $R && $G $F -o $lm/e e.c -L$lm -lA -lB -lpthread $R &&
  $G $F $lf -shared -o $lm/libC1.so C1.c $R && $G $F $lf -shared -o $lm/libC2.so C2.c $R && $G $F -o $lm/c c.c -L$lm -lC1 -lC2 -lpthread $R || exit 2
done
cat > run-bins.sh <<'X'
#!/bin/sh
# run-bins.sh : the aa64tls TLS repro, prebuilt (no compiler). rc 0 = all PASS. Each program self-checks.
cd "$(dirname "$0")"; rc=0
chk() { n="$1"; shift; o=$("$@" 2>&1); if [ $? -eq 0 ]; then echo "PASS $n:$o"; else echo "FAIL $n:$o"; rc=1; fi; }
chk "A 4 libs distinct+initialised" ./a; chk "A' reverse link order" ./a2
for lm in ie gd; do chk "B 2 libs ($lm) x 50 threads" ./$lm/e; chk "C aligned(64) ($lm) x 20 threads" ./$lm/c; done
echo "libc: $(ldd ./a | grep libc.so.1)"; echo "rtld: $(elfdump -i ./a 2>/dev/null | tail -1)"; exit $rc
X
chmod +x run-bins.sh; ls a a2 ie/e ie/c gd/e gd/c >/dev/null || exit 3
tar cf $D/tls-bins.tar a a2 libl1.so libl2.so libl3.so libl4.so ie gd run-bins.sh && digest -a sha256 $D/tls-bins.tar
./run-bins.sh; echo "local rc=$?"
