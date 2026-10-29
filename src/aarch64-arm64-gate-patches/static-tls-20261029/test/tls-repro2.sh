#!/bin/sh
# tls-repro2.sh -- (aa64tls: tls-repro.sh + RUN=<rtld prefix> + test C, an aligned(64) __thread) self-checking repro of the arm64-gate (6cd2521c1e) static-TLS aliasing. Run as any user on aarch64 illumos.
# Exit 0 = every check PASS (expected after the rtld + libc fix); exit 1 = some FAIL (expected on 6cd2521c1e).
# CC: the store gcc 14.3.0 (aa64nix) by default. Flags are the arm64-gate harness's (-mtls-dialect=trad -mno-outline-atomics).
CC=${CC:-/nix/store/alvd5rlddwk6sp09ihg389a585g2xaa1-gcc-14.3.0/bin/gcc}
# RT: gcc runtime + the store libc slice FIRST, so one libc is loaded (as in every nix process; /lib/libc.so.1 would be a second one).
RT=${RT:-/nix/store/kh36iy924gk7akc2b7m1l45vaszh2lps-gcc-14.3.0-lib/lib:/nix/store/rs4hiizl9f6xmrpp4c58pjc9kl3s2lxf-libc/lib}
F="-O2 -mno-outline-atomics -mtls-dialect=trad -fPIC"; W=${W:-/var/tmp/tls-repro.$$}; mkdir -p $W; cd $W; rc=0
pass() { echo "PASS $*"; }; fail() { echo "FAIL $*"; rc=1; }
# A: four shared libs, each one initialised __thread array; an exe with NO TLS of its own reads them via accessors.
decl=""; body=""; libs=""
for i in 1 2 3 4; do printf '__thread long v%d[%d] = { %d };\nlong *p%d(void){ return v%d; }\n' $i $((i*2)) $((i*100)) $i $i > l$i.c
  $CC $F -shared -o libl$i.so l$i.c -Wl,-R,$RT || exit 2; libs="$libs -ll$i"; decl="$decl long *p$i(void);"
  body="$body if (*p$i() != $((i*100))) bad++; for (int j=0;j<$i-1;j++) if (a[j]==p$i()) bad++; a[$i-1]=p$i(); printf(\" l$i:+%ld=%ld\", (long)((char*)p$i()-(char*)tp), *p$i());"; done
printf '#include <stdio.h>\n#include <stdint.h>\n%s\nint main(void){ uintptr_t tp; long *a[4]; int bad=0; __asm__("mrs %%0, tpidr_el0" : "=r"(tp)); %s printf(" bad=%%d\\n", bad); return bad!=0; }\n' "$decl" "$body" > a.c
$CC $F -o a a.c -L. $libs -Wl,-R,$W:$RT || exit 2
o=$($RUN ./a); [ $? -eq 0 ] && pass "A 4 libs distinct+initialised:$o" || fail "A 4 libs distinct+initialised:$o"
$CC $F -o a2 a.c -L. -ll4 -ll3 -ll2 -ll1 -Wl,-R,$W:$RT || exit 2
o=$($RUN ./a2); [ $? -eq 0 ] && pass "A' reverse link order:$o" || fail "A' reverse link order:$o"
# B: two TLS libs (one .tdata + one .tbss) used from 50 new threads; libs IE then GD (GD = libc __tls_get_addr slow path).
printf '__thread long a = 11;\nlong *pa(void){ return &a; }\n' > A.c
printf '__thread long b = 22; __thread long bz;\nlong *pb(void){ return &b; } long *pbz(void){ return &bz; }\n' > B.c
cat > e.c <<'X'
#include <stdio.h>
#include <pthread.h>
long *pa(void), *pb(void), *pbz(void); static int bad;
static int chk(void){ long *A=pa(), *B=pb(), *Z=pbz(); return A==B || A==Z || B==Z || *A!=11 || *B!=22 || *Z!=0; }
static void *th(void *x){ if (chk()) bad++; *pa()=1; *pb()=2; *pbz()=3; return 0; }
int main(void){ int m=chk(); for (int i=0;i<50;i++){ pthread_t t; pthread_create(&t,0,th,0); pthread_join(t,0); }
  printf(" main=%s threads_bad=%d/50", m?"BAD":"ok", bad); return m||bad; }
X
for lm in ie gd; do lf=""; [ $lm = ie ] && lf=-ftls-model=initial-exec
  $CC $F $lf -shared -o libA.so A.c -Wl,-R,$RT && $CC $F $lf -shared -o libB.so B.c -Wl,-R,$RT && $CC $F -o e e.c -L. -lA -lB -lpthread -Wl,-R,$W:$RT || exit 2
  o=$($RUN ./e); [ $? -eq 0 ] && pass "B 2 libs ($lm) x 50 threads:$o" || fail "B 2 libs ($lm) x 50 threads:$o"; done
# C: lib c1 (one char of TLS) then lib c2 with an aligned(64), initialised __thread array; checked in main + 20 threads.
printf "__thread char c1 = 1;\nchar *pc1(void){ return &c1; }\n" > C1.c
printf "__thread long al[3] __attribute__((aligned(64))) = { 64, 65, 66 };\nlong *pal(void){ return al; }\n" > C2.c
printf "#include <stdio.h>\n#include <stdint.h>\n#include <pthread.h>\nchar *pc1(void); long *pal(void); static int bad;\nstatic int chk(void){ long *p=pal(); return ((uintptr_t)p %% 64) || p[0]!=64 || p[2]!=66 || *pc1()!=1; }\nstatic void *th(void *x){ if (chk()) bad++; return 0; }\nint main(void){ int m=chk(); for (int i=0;i<20;i++){ pthread_t t; pthread_create(&t,0,th,0); pthread_join(t,0); }\n  printf(\" main=%%s mod64=%%ld threads_bad=%%d/20\", m?\"BAD\":\"ok\", (long)((uintptr_t)pal() %% 64), bad); return m||bad; }\n" > c.c
for lm in ie gd; do lf=""; [ $lm = ie ] && lf=-ftls-model=initial-exec
  $CC $F $lf -shared -o libC1.so C1.c -Wl,-R,$RT && $CC $F $lf -shared -o libC2.so C2.c -Wl,-R,$RT && $CC $F -o c c.c -L. -lC1 -lC2 -lpthread -Wl,-R,$W:$RT || exit 2
  o=$($RUN ./c); [ $? -eq 0 ] && pass "C aligned(64) ($lm) x 20 threads:$o" || fail "C aligned(64) ($lm) x 20 threads:$o"; done
echo "libc loaded by a: $(ldd ./a | grep -c libc.so.1)"; echo "static TLS layout (LD_DEBUG=tls, test A):"; LD_DEBUG=tls $RUN ./a 2>&1 | grep -E 'static TLS module|soff' | sed 's/^[0-9]*: 1: */  /'
exit $rc
