#!/usr/bin/bash
# aarch64/dof-nodename.sh <dir> -- set the nodename of every DTrace DOF utsname record under <dir> to "localhost".
# `dtrace -G` copies the build machine's utsname into each object's .SUNW_dof: the aa64tls libc was rebuilt on the
# x86 cross host, so libc.so.1 and 9 other proto files said "solnix-builder-build" (measured, dixa4 2026-10-31), which
# the no-build-host-information policy forbids. struct utsname is 5 fields of 257 bytes; the nodename is the second.
# Only a "SunOS\0" record wholly inside .SUNW_dof is touched (the publish gate's DOF rule); prints the count.
set -eu
n=0
for f in $(grep -r -l -a -F 'SunOS' "$1" 2>/dev/null); do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  read -r doff dsz < <(/usr/bin/elfdump -c -N .SUNW_dof "$f" 2>/dev/null | awk '/sh_size:/ {s=$2} /sh_offset:/ {o=$2} END {print o, s}') || continue
  [ -n "${dsz:-}" ] || continue
  for o in $(grep -a -b -o -F 'SunOS' "$f" | cut -d: -f1); do
    [ "$o" -ge $((doff)) ] && [ $((o + 5 * 257)) -le $((doff + dsz)) ] || continue
    [ "$(dd if="$f" bs=1 skip=$((o + 5)) count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 00 ] || continue
    chmod u+w "$f"
    dd if=/dev/zero of="$f" bs=1 seek=$((o + 257)) count=257 conv=notrunc 2>/dev/null
    printf localhost | dd of="$f" bs=1 seek=$((o + 257)) conv=notrunc 2>/dev/null
    n=$((n + 1))
  done
done
echo "dof-nodename: $n utsname records set to localhost" >&2
