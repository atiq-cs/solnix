#!/usr/bin/env bash
# oi-closure.sh — compute the transitive, ABI-AWARE non-libc NEEDED closure of a
# set of proto binaries, as proto-relative lib paths, for pasting into
# base-tools' `baseToolLibs` in pkgs/illumos/default.nix. Run ON the illumos host.
#
#   ./oi-closure.sh <gate-store-path> [tool ...]
#
# illumos is dual-ABI: a 32-bit binary resolves NEEDED from lib/ + usr/lib/;
# a 64-bit binary from lib/amd64/ + usr/lib/amd64/ (+ the fm/ variants). This
# BFS tracks each object's ELF class and resolves each soname in the matching
# ABI dir, so the 32-bit SMF stack and 64-bit ksh93 both get complete closures.
#
# Defaults to the base-tools binary set if no tools are given. Prints, sorted:
#   - resolved proto-relative lib paths (32- and 64-bit)
#   - UNRESOLVED sonames (external libs not in the proto: libxml2/libsqlite-sys/
#     libz for svccfg/svc.configd, which are excluded).
set -euo pipefail
export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH
G="${1:?usage: oi-closure.sh <gate-store-path> [tool ...]}"; shift || true

# sonames the libc slice already provides (BOTH ABIs) — do NOT re-slice.
LIBC_HAS=" libc.so.1 libm.so.1 libm.so.2 libsocket.so.1 libnsl.so.1 libresolv.so.2 libelf.so.1 libpthread.so.1 librt.so.1 libdl.so.1 libmp.so.2 libcustr.so.1 libofmt.so.1 libmd.so.1 "

if [ "$#" -eq 0 ]; then
  set -- usr/bin/svcs usr/sbin/svcadm lib/svc/bin/svc.startd sbin/init \
         sbin/sh usr/bin/ls usr/bin/cp usr/bin/mv \
         usr/bin/cat usr/bin/rm usr/bin/mkdir usr/bin/ln
fi

elfclass() { # 32 | 64
  case "$(file "$1" 2>/dev/null)" in *64-bit*) echo 64;; *) echo 32;; esac
}
resolve() { # $1 soname  $2 class(32|64) -> proto-relative path or UNRESOLVED:<so>
  if [ "$2" = 64 ]; then dirs="lib/amd64 usr/lib/amd64 lib/fm/amd64 usr/lib/fm/amd64";
  else dirs="lib usr/lib lib/fm usr/lib/fm"; fi
  for d in $dirs; do [ -f "$G/$d/$1" ] && { echo "$d/$1"; return; }; done
  echo "UNRESOLVED:$1"
}

declare -A seen
queue=""; for t in "$@"; do
  [ -e "$G/$t" ] || echo "WARN: tool missing in proto: $t" >&2
  queue="$queue $G/$t"
done
result=""; unres=""
while [ -n "$queue" ]; do
  set -- $queue; f=$1; shift; queue="$*"
  cls=$(elfclass "$f")
  for so in $(/usr/bin/elfdump -d "$f" 2>/dev/null | awk '/NEEDED/{print $NF}'); do
    case "$LIBC_HAS" in *" $so "*) continue;; esac
    key="$so:$cls"
    [ -n "${seen[$key]:-}" ] && continue; seen[$key]=1
    p=$(resolve "$so" "$cls")
    case "$p" in UNRESOLVED:*) unres="$unres ${p#UNRESOLVED:}"; continue;; esac
    result="$result $p"; queue="$queue $G/$p"
  done
done

echo "=== resolved lib closure (paste into baseToolLibs) ==="
for r in $result; do echo "\"$r\""; done | sort -u
echo "=== UNRESOLVED (external, not in proto) ==="
for u in $unres; do echo "$u"; done | sort -u
