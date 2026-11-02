#!/usr/bin/bash
# go-build.sh -- builder for go.nix: one stage of the Go bootstrap chain.
#   go1.4 (C)   : $CC = the from-source gcc; GOOS is solaris (go1.4 predates GOOS=illumos).
#   go1.17+     : make.bash with GOROOT_BOOTSTRAP=$boot, GOOS=illumos. Built by a solaris-GOOS
#                 go, the illumos tools land in bin/illumos_amd64 and are promoted: a solaris-GOOS
#                 go passes Solaris' F_DUP2FD_CLOEXEC (0x30) to fcntl, which illumos reads as
#                 F_OFD_SETLK, so every fork/exec of the next stage fails EFAULT (measured).
#                 GO_LDFLAGS is -r (DT_RUNPATH) only: with -s the illumos binary loses its
#                 PT_TLS ("ld.so.1: go: fatal: TLS requirement failure", measured on 1.20.14).
#   final       : the closure gate over bin/ + pkg/tool/, then go version + a hello build.
set -eu
export PATH="$tools/bin:$world/usr/bin:$world/usr/sbin:$world/bin:$world/sbin"   # store tools, then the world (no /usr/bin|sbin|gnu)
/usr/bin/bash "$pathGate"; . "$illumosBin"
# FIXED build dir, not $NIX_BUILD_TOP (/tmp on OI, /var/tmp/big on dixi): go1.4's C tools name $W/cc and their
# sources, go1.17/1.20 name GOROOT/src in every binary (measured, repro2). $buildKey: see mk-src-pkg.nix.
W=/var/tmp/go-$buildKey; rm -rf "$W"; mkdir -m 700 "$W"; trap 'cd /; rm -rf "$W"' EXIT; cd "$W"
export HOME=$W GOCACHE=$W/cache GOPATH=$W/gopath CGO_ENABLED=0 GOARCH=amd64 GOTOOLCHAIN=local
tar xzf "$src"; cd go/src
if [ -z "$boot" ]; then
  # store RUNPATH for the C tools: gcc's runtime + the world's libc/libm (not the host /lib).
  # -std=gnu17: go1.4's C uses bool/true as identifiers, C23 keywords under GCC 15 (gcc1 STDENV-SWITCH.md 2.2)
  printf '#!/usr/bin/bash\nexec %s/bin/gcc -m64 -std=gnu17 -Wl,-R,%s/amd64:%s "$@"\n' "$gcc" "$gccLibDir" "$rp" > "$W/cc"; chmod +x "$W/cc"
  CC=$W/cc GOROOT_FINAL=$out/share/go bash ./make.bash
else
  GOROOT_BOOTSTRAP=$boot/share/go GOOS=illumos GO_LDFLAGS="-r $rp" bash ./make.bash
fi
cd "$W/go"
if [ -d bin/illumos_amd64 ]; then
  mv bin/illumos_amd64/* bin/; rmdir bin/illumos_amd64; find pkg/tool/solaris_amd64 -depth -delete
fi
[ -d pkg/obj ] && find pkg/obj -depth -delete
if [ -z "$boot" ]; then
  # go1.4's C tools (6a 6c 6g 6l, dist) carry DWARF naming the compiler and the gate proto, which
  # made gcc-14.3.0 + illumos-gate-proto RUNTIME references of go_1_4 (measured). Strip them
  # (mk-src-pkg's strip phase), then the same closure gate as the final stages.
  find pkg/tool bin -type f | while read -r f; do
    [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] && "$tools/bin/gstrip" --strip-debug "$f"   # store gstrip: a solnix host has no /usr/bin/gstrip
  done
fi
if [ -n "$final" ]; then
  # Upstream ships Linux/FreeBSD dynamic ELF test fixtures (src/debug/{elf,dwarf}/testdata: NEEDED
  # libc.so.6, libtiff.so.6, ...). Nothing resolves them on illumos, so the store-only-NEEDED publish
  # gate failed the toolchain on them (13 files, measured). NixOS ships them (it has no such gate);
  # we drop them. Cost: `go test debug/elf debug/dwarf` lacks those fixtures.
  find src -path '*/testdata/*' -type f | while read -r f; do
    if [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] && elfdump -d "$f" 2>/dev/null | grep -q NEEDED; then rm -f "$f"; fi
  done
fi
mkdir -p "$out/share" "$out/bin"
# fsync every file first. Go's linker writes through mmap, and on a ZFS without
# scripts/patches/0009 (every OI build host) a just-written file reads as one hole to SEEK_DATA,
# so GNU cp copied zeros, even with --sparse=never (it still asks SEEK_DATA). sync(2) does not
# push mmap'd pages there; fsync does (measured: holetest2 0/3 with sync, 3/3 with fsync).
find "$W/go" -type f -exec "$python3/bin/python3" -c 'import os,sys
for p in sys.argv[1:]:
    fd = os.open(p, os.O_RDONLY); os.fsync(fd); os.close(fd)' {} +
cp -a "$W/go" "$out/share/go"
# DT_CHECKSUM -> 0 (zero-checksum.sh says why): go1.4's C tools embed GOROOT_FINAL=$out (measured, repro2).
: > "$W/zc"; bash "$zeroChecksum" "$out" "$W/zc"; [ ! -s "$W/zc" ] || { cat "$W/zc" >&2; exit 1; }
for b in go gofmt; do ln -s ../share/go/bin/$b "$out/bin/$b"; done
"$out/bin/go" version
if [ -z "$boot" ]; then
  # go_1_4 is a build-only bootstrap seed. Gate its C-built tools (6a 6c 6g 6l dist): no compiler
  # or gate path, store RUNPATH. Its Go-built tools (go, cgo, ...) link with go1.4's cmd/ld, which
  # sets no RUNPATH (libc.so from /lib/64, caught by this gate, measured); they only ever run
  # inside the go_1_17 build. shortcut: not gated, upgrade if go_1_4 is ever shipped to a system.
  mkdir -p "$W/ctools"; for t in 6a 6c 6g 6l dist; do cp "$out/share/go/pkg/tool/solaris_amd64/$t" "$W/ctools/"; done
  bash "$storeGate" "$W/ctools" "$tsErrnoGate" "$gcc/" "$gate"
  for x in "$gcc" "$gate"; do ! grep -rqF "$(basename "$x")" "$out" || { echo "FATAL: go_1_4 names $x" >&2; exit 1; }; done
fi
if [ -n "$final" ]; then
  bash "$storeGate" "$out/share/go" "$tsErrnoGate"   # the whole tree: bin, pkg/tool and src
  "$out/bin/go" version | grep -q "^go version go$version illumos/amd64$" || { echo "FATAL: go version" >&2; exit 1; }
  mkdir -p "$W/h"; cd "$W/h"; printf 'package main\nimport "fmt"\nfunc main() { fmt.Println("hello-go") }\n' > m.go
  "$out/bin/go" mod init h >/dev/null 2>&1; "$out/bin/go" build -trimpath -ldflags "-r $rp" -o h .
  [ "$(./h)" = hello-go ] || { echo "FATAL: go hello" >&2; exit 1; }
  bash "$storeGate" "$W/h" "$tsErrnoGate"
  echo "=== go $version: check passed ===" >&2
fi
