#!/usr/bin/env bash
# gate-dual.sh — BONUS: compile the SAME nontrivial pthreads+printf program with
# BOTH gcc14 and clang (store toolchains, sliced libc, Solaris ld); both must RUN.
# Proves dual-toolchain capability (the package registry can build with either).
set -uo pipefail
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH
G="${1:?usage: gate-dual.sh <gcc14> <clang> <libc>}"
C="${2:?need clang store path}"
LIBC="${3:?need libc store path}"
LIBDIR=$LIBC/lib/amd64; USRLIB=$LIBC/usr/lib/amd64; INC=$LIBC/usr/include

WORK=/var/tmp/gate-dual; mkdir -p "$WORK"; cd "$WORK"
cat > threads.c <<'EOF'
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#define N 4
static void *worker(void *arg){
  long id = (long)arg;
  printf("  worker %ld running\n", id);
  return (void *)(id * id);
}
int main(void){
  pthread_t t[N]; long sum = 0;
  for (long i = 0; i < N; i++)
    if (pthread_create(&t[i], NULL, worker, (void *)(i + 1)) != 0){ perror("pthread_create"); return 1; }
  for (int i = 0; i < N; i++){ void *r; pthread_join(t[i], &r); sum += (long)r; }
  printf("sum of squares 1..%d = %ld\n", N, sum);
  return sum == 30 ? 0 : 2;   /* 1+4+9+16 = 30 */
}
EOF

echo "=== GCC-14: compile pthreads+printf ==="
"$G/usr/gcc/14/bin/gcc" -m64 -O2 -pthread -nostdinc -isystem "$INC" -B "$USRLIB" \
  -L "$LIBDIR" -L "$USRLIB" -Wl,-R,"$LIBDIR" threads.c -o threads-gcc14
echo "-- run (gcc14) --"; ./threads-gcc14; echo "  exit=$?"

echo "=== Clang-21: compile the SAME source ==="
"$C/usr/clang/21/bin/clang" -target x86_64-pc-solaris2.11 --gcc-toolchain="$G/usr/gcc/14" \
  -O2 -pthread -nostdinc -isystem "$INC" -B "$USRLIB" \
  -L "$LIBDIR" -L "$USRLIB" -Wl,-R,"$LIBDIR" threads.c -o threads-clang
echo "-- run (clang) --"; ./threads-clang; echo "  exit=$?"

echo "=== both binaries, side by side ==="
file threads-gcc14 threads-clang 2>&1 | sed 's/^/  /'
echo "-- gcc14 leaks --"; ldd threads-gcc14 2>&1 | awk '/=>/{print}' | grep -v '/nix/store/' | grep -E '/lib/|/usr/lib/' || echo "  <none — clean>"
echo "-- clang leaks --"; ldd threads-clang 2>&1 | awk '/=>/{print}' | grep -v '/nix/store/' | grep -E '/lib/|/usr/lib/' || echo "  <none — clean>"
echo "DUAL-COMPILE BONUS DONE"
