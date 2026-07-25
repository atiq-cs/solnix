#!/usr/bin/env bash
# gate-gcc14.sh — GATE GCC: prove the sliced gcc14 store toolchain compiles,
# links, and RUNS a hello against the sliced libc, and is ldd-clean. Run ON host.
set -uo pipefail  # NOT -e: diagnostic pipes (head/grep) legitimately return nonzero
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH
G="${1:?usage: gate-gcc14.sh <gcc14-store-path> <libc-store-path>}"
LIBC="${2:?need libc store path}"
GCC=$G/usr/gcc/14/bin/gcc
LIBDIR=$LIBC/lib/amd64; USRLIB=$LIBC/usr/lib/amd64; INC=$LIBC/usr/include

echo "=== gcc --version (from store) ==="; "$GCC" --version | head -2
echo "=== gcc -dumpmachine ==="; "$GCC" -dumpmachine
echo "=== ldd store gcc driver ==="; ldd "$GCC" 2>&1
echo "--- driver leaks ---"; ldd "$GCC" 2>&1 | awk '/=>/{print}' | grep -v '/nix/store/' | grep -E '/lib/|/usr/lib/' || echo "<none — clean>"
CC1P=$G/usr/gcc/14/lib/gcc/x86_64-pc-solaris2.11/14.3.0/cc1plus
echo "=== ldd cc1plus ==="; ldd "$CC1P" 2>&1
echo "--- cc1plus leaks ---"; ldd "$CC1P" 2>&1 | awk '/=>/{print}' | grep -v '/nix/store/' | grep -E '/lib/|/usr/lib/' || echo "<none — clean>"

WORK=/var/tmp/gate-gcc14; mkdir -p "$WORK"; cd "$WORK"
cat > hello.c <<'EOF'
#include <stdio.h>
int main(void){ puts("hello from GCC-14 sliced toolchain on illumos"); return 0; }
EOF
echo "=== compile+link+run C hello (store gcc14 -> sliced libc) ==="
"$GCC" -m64 -nostdinc -isystem "$INC" -B "$USRLIB" -L "$LIBDIR" -L "$USRLIB" -Wl,-R,"$LIBDIR" hello.c -o hello-gcc14
echo "-- run --"; ./hello-gcc14
echo "-- elfdump --"; /usr/bin/elfdump -d hello-gcc14 | grep -Ei 'NEEDED|RUNPATH|INTERP' | head
echo "-- ldd --"; ldd hello-gcc14 2>&1
echo "-- leaks --"; ldd hello-gcc14 2>&1 | awk '/=>/{print}' | grep -v '/nix/store/' | grep -E '/lib/|/usr/lib/' || echo "<none — clean>"

echo "=== compile+link+run C++ hello (store g++ -> gcc14 libstdc++) ==="
GXX=$G/usr/gcc/14/bin/g++
cat > hello.cc <<'EOF'
#include <iostream>
#include <string>
int main(){ std::string s="hello from GCC-14 g++ (libstdc++) on illumos"; std::cout<<s<<std::endl; return 0; }
EOF
# C++: let g++ find its OWN (store-relocatable) C++ + internal headers; add the
# sliced libc /usr/include as a high-priority -isystem so the C runtime headers
# come from the slice, not host /usr/include. NO -nostdinc (that kills the C++
# search dirs). Link path/crt/RUNPATH point at the sliced libc + gcc14 runtime.
"$GXX" -m64 -isystem "$INC" -B "$USRLIB" -L "$LIBDIR" -L "$USRLIB" \
  -Wl,-R,"$LIBDIR" -Wl,-R,"$G/usr/gcc/14/lib/amd64" hello.cc -o hellocc-gcc14
echo "-- run --"; ./hellocc-gcc14
echo "-- ldd libstdc++ resolution --"; ldd hellocc-gcc14 2>&1 | grep -E 'libstdc|libgcc'
echo "-- C++ ldd leaks --"; ldd hellocc-gcc14 2>&1 | awk '/=>/{print}' | grep -v '/nix/store/' | grep -E '/lib/|/usr/lib/' || echo "<none — clean>"
echo "GATE GCC DONE"
