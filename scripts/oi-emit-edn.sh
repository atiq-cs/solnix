#!/usr/bin/env bash
# oi-emit-edn.sh — emit a Mentat/Datomic-ready EDN datom for one built+published
# solnix package into docs/registry/edn/. Called by the fleet-publish step right
# after a package is signed+pushed to the solnix.io cache.
#
# The EDN is the durable package index (system, version, compiler+version, libc
# version, deps, the separate `debug` output). When a writable pg_mentat/Mentat
# endpoint for solnix exists, these files transact directly (schema.edn first).
#
# Usage:
#   oi-emit-edn.sh --store /nix/store/HASH-pname-1.2.3 --system x86_64-solaris \
#     --compiler gcc --compiler-ver 14.3.0 --libc-store /nix/store/..-libc \
#     --libc-ver illumos-960edb1c89 [--debug /nix/store/HASH-pname-1.2.3-debug] \
#     [--dep /nix/store/..-zlib-1.3.1 --dep ...] [--sig cache.solnix.io-1]
set -eu
OUT_DIR="${EDN_DIR:-$(cd "$(dirname "$0")/.."/docs/registry/edn 2>/dev/null && pwd || echo docs/registry/edn)}"
mkdir -p "$OUT_DIR"
store=""; system=""; compiler=""; cver=""; libc=""; libcver=""; debug=""; sig="cache.solnix.io-1"; deps=()
while [ $# -gt 0 ]; do case "$1" in
  --store) store="$2"; shift 2;; --system) system="$2"; shift 2;;
  --compiler) compiler="$2"; shift 2;; --compiler-ver) cver="$2"; shift 2;;
  --libc-store) libc="$2"; shift 2;; --libc-ver) libcver="$2"; shift 2;;
  --debug) debug="$2"; shift 2;; --dep) deps+=("$2"); shift 2;;
  --sig) sig="$2"; shift 2;; *) echo "unknown arg $1" >&2; exit 2;; esac; done
[ -n "$store" ] || { echo "need --store" >&2; exit 2; }
base="${store##*/}"                 # HASH-pname-version
hash="${base%%-*}"                  # HASH
rest="${base#*-}"                   # pname-version
pname="${rest%-*}"; version="${rest##*-}"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
f="$OUT_DIR/${rest}-${compiler}.edn"
{
  printf '{:pkg/store-path "%s"\n' "$store"
  printf ' :pkg/name "%s" :pkg/version "%s"\n' "$pname" "$version"
  printf ' :pkg/narinfo-hash "%s"\n' "$hash"
  [ -n "$system" ]  && printf ' :pkg/system "%s"\n' "$system"
  [ -n "$compiler" ]&& printf ' :pkg/compiler "%s"\n' "$compiler"
  [ -n "$cver" ]    && printf ' :pkg/compiler-ver "%s"\n' "$cver"
  [ -n "$libc" ]    && printf ' :pkg/libc-store "%s"\n' "$libc"
  [ -n "$libcver" ] && printf ' :pkg/libc-ver "%s"\n' "$libcver"
  [ -n "$debug" ]   && printf ' :pkg/debug-path "%s"\n' "$debug"
  for d in "${deps[@]:-}"; do [ -n "$d" ] && printf ' :pkg/dep "%s"\n' "$d"; done
  printf ' :pkg/cached-at "%s" :pkg/cache-sig "%s"}\n' "$now" "$sig"
} > "$f"
echo "wrote $f"
