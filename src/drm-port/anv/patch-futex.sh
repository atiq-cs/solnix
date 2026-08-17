#!/bin/sh
# apply the illumos futex fallback to Mesa util (idempotent)
set -e
export PATH=/root/mesa-venv/bin:/usr/bin:$PATH
sd=/var/tmp/mesa-24.0.9
FXH="$sd/src/util/futex.h"
if ! grep -q '__sun' "$FXH"; then
  python3 - "$FXH" <<'PYFH'
import sys
p=sys.argv[1]; s=open(p).read()
old="#elif defined(_WIN32) && !defined(WINDOWS_NO_FUTEX)\n#define UTIL_FUTEX_SUPPORTED 1"
new=("#elif defined(__sun)\n#define UTIL_FUTEX_SUPPORTED 1\n"
     "#elif defined(_WIN32) && !defined(WINDOWS_NO_FUTEX)\n#define UTIL_FUTEX_SUPPORTED 1")
assert old in s, "futex.h anchor missing"
open(p,"w").write(s.replace(old,new,1))
print("futex.h patched")
PYFH
fi
FXC="$sd/src/util/futex.c"
if ! grep -q '__sun' "$FXC"; then
  python3 - "$FXC" <<'PYFC'
import sys
p=sys.argv[1]; s=open(p).read()
sun=("#elif defined(__sun)\n\n"
     "/* illumos has no futex(2); portable fallback: one global mutex+condvar.\n"
     " * futex: global lock, one shared condvar for all addresses -- fine here\n"
     " * (low-contention pool-grow path). Per-address hashing if it ever matters. */\n"
     "#include <pthread.h>\n#include <errno.h>\n#include <time.h>\n"
     "static pthread_mutex_t futex_mtx = PTHREAD_MUTEX_INITIALIZER;\n"
     "static pthread_cond_t  futex_cnd = PTHREAD_COND_INITIALIZER;\n\n"
     "int futex_wake(uint32_t *addr, int count)\n{\n"
     "   (void)addr; (void)count;\n"
     "   pthread_mutex_lock(&futex_mtx);\n"
     "   pthread_cond_broadcast(&futex_cnd);\n"
     "   pthread_mutex_unlock(&futex_mtx);\n   return 0;\n}\n\n"
     "int futex_wait(uint32_t *addr, int32_t value, const struct timespec *timeout)\n{\n"
     "   int ret = 0;\n"
     "   pthread_mutex_lock(&futex_mtx);\n"
     "   if (*(volatile uint32_t *)addr == (uint32_t)value) {\n"
     "      if (timeout)\n"
     "         ret = pthread_cond_timedwait(&futex_cnd, &futex_mtx, timeout);\n"
     "      else\n"
     "         ret = pthread_cond_wait(&futex_cnd, &futex_mtx);\n"
     "   }\n"
     "   pthread_mutex_unlock(&futex_mtx);\n"
     "   return ret == ETIMEDOUT ? ETIMEDOUT : 0;\n}\n\n")
anchor="#else\n#error UTIL_FUTEX_SUPPORTED is not implemented"
assert anchor in s, "futex.c anchor missing"
open(p,"w").write(s.replace(anchor, sun+anchor, 1))
print("futex.c patched")
PYFC
fi
echo "futex patch done"
