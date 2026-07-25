#!/usr/bin/env bash
# gate-clang.sh — GATE CLANG: prove the sliced clang-21 store toolchain compiles,
# links, and RUNS a C and C++ hello against the sliced libc, ldd-clean. Run ON host.
set -uo pipefail   # NOT -e: diagnostic pipes (head/grep) legitimately return nonzero
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH
C="${1:?usage: gate-clang.sh <clang-store-path> <libc-store-path> <gcc14-store-path>}"
LIBC="${2:?need libc store path}"
G="${3:?need gcc14 store path}"   # clang uses gcc14's libstdc++ + C++ headers
CLANG=$C/usr/clang/21/bin/clang
CLANGXX=$C/usr/clang/21/bin/clang++
LIBDIR=$LIBC/lib/amd64; USRLIB=$LIBC/usr/lib/amd64; INC=$LIBC/usr/include
GCCRT=$G/usr/gcc/14/lib/amd64
GXXINC=$G/usr/gcc/14/include/c++/14

echo "=== clang --version (from store) ==="; "$CLANG" --version | head -4
echo "=== clang -dumpmachine ==="; "$CLANG" -dumpmachine
echo "=== ldd store clang driver ==="; ldd "$CLANG" 2>&1
echo "--- driver leaks ---"; ldd "$CLANG" 2>&1 | awk '/=>/{print}' | grep -v '/nix/store/' | grep -E '/lib/|/usr/lib/' || echo "<none — clean>"
echo "=== ldd libLLVM.so.21.1 (211MB; RUNPATH-grow proof) ==="
ldd "$C/usr/clang/21/lib/libLLVM.so.21.1" 2>&1 | head
echo "--- libLLVM leaks ---"; ldd "$C/usr/clang/21/lib/libLLVM.so.21.1" 2>&1 | awk '/=>/{print}' | grep -v '/nix/store/' | grep -E '/lib/|/usr/lib/' || echo "<none — clean>"

WORK=/var/tmp/gate-clang; mkdir -p "$WORK"; cd "$WORK"
cat > hello.c <<'EOF'
#include <stdio.h>
int main(void){ puts("hello from Clang-21 sliced toolchain on illumos"); return 0; }
EOF
echo "=== compile+link+run C hello (store clang -> sliced libc, Solaris ld) ==="
# --gcc-toolchain points clang at the store gcc14 for crt/startfiles + libgcc.
# -nostdinc + -isystem: use ONLY the sliced libc headers. -B: sliced crt.
# -Wl,-R: bake the store libc into RUNPATH.
"$CLANG" -target x86_64-pc-solaris2.11 \
  --gcc-toolchain="$G/usr/gcc/14" \
  -nostdinc -isystem "$INC" -B "$USRLIB" \
  -L "$LIBDIR" -L "$USRLIB" -Wl,-R,"$LIBDIR" -Wl,-R,"$GCCRT" \
  hello.c -o hello-clang
echo "-- run --"; ./hello-clang
echo "-- elfdump --"; /usr/bin/elfdump -d hello-clang | grep -Ei 'NEEDED|RUNPATH|INTERP' | head
echo "-- ldd --"; ldd hello-clang 2>&1
echo "-- leaks --"; ldd hello-clang 2>&1 | awk '/=>/{print}' | grep -v '/nix/store/' | grep -E '/lib/|/usr/lib/' || echo "<none — clean>"

echo "=== compile+link+run C++ hello (store clang++ -> gcc14 libstdc++) ==="
cat > hello.cc <<'EOF'
#include <iostream>
#include <string>
int main(){ std::string s="hello from Clang-21 clang++ (libstdc++) on illumos"; std::cout<<s<<std::endl; return 0; }
EOF
# C++: clang uses gcc14's libstdc++ + its C++ headers via --gcc-toolchain +
# -stdlib=libstdc++. Let clang's driver find the C++ header dirs from the
# gcc-toolchain; add sliced libc /usr/include for the C runtime headers.
"$CLANGXX" -target x86_64-pc-solaris2.11 \
  --gcc-toolchain="$G/usr/gcc/14" -stdlib=libstdc++ \
  -isystem "$INC" -B "$USRLIB" \
  -L "$LIBDIR" -L "$USRLIB" -Wl,-R,"$LIBDIR" -Wl,-R,"$GCCRT" \
  hello.cc -o hellocc-clang
echo "-- run --"; ./hellocc-clang
echo "-- ldd libstdc++ resolution --"; ldd hellocc-clang 2>&1 | grep -E 'libstdc|libgcc'
echo "GATE CLANG DONE"
