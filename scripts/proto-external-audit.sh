#!/bin/sh
# proto-external-audit.sh -- how much of the gate proto's USERLAND cannot resolve its
# own DT_NEEDED from inside the proto? Counts, per unresolvable soname, how many proto
# ELF objects transitively need it.
#
# This exists because a slice build FAILED on libxml2.so.16 and the question "is that
# one binary or the whole userland" decides whether the proto can be sliced at all.
P=${1:-/var/tmp/proto-unpack/wn8w5j1pkc9k3zgkq3bsqxk285dqbi7m-illumos-gate-proto}
OUT=${2:-/var/tmp/ext-audit}
mkdir -p "$OUT"

# 1. every soname the proto's own libs/bins DECLARE as NEEDED, and whether the proto
#    can supply it in the matching ABI.
: > "$OUT/needed-all.txt"
find "$P" \( -path "$P/kernel" -o -path "$P/platform" -o -path "$P/boot" \) -prune -o -type f -print 2>/dev/null \
| while read -r f; do
  /usr/bin/elfdump -d "$f" 2>/dev/null | awk '$2=="NEEDED"{print $NF}'
done | sort | uniq -c | sort -rn > "$OUT/needed-all.txt"

# 2. which of those sonames exist NOWHERE in the proto
: > "$OUT/unresolvable.txt"
awk '{print $2}' "$OUT/needed-all.txt" | while read -r so; do
  if ! find "$P" -name "$so" -print 2>/dev/null | head -1 | grep -q .; then
    n=$(awk -v s="$so" '$2==s{print $1}' "$OUT/needed-all.txt")
    echo "$n $so" >> "$OUT/unresolvable.txt"
  fi
done
sort -rn "$OUT/unresolvable.txt" -o "$OUT/unresolvable.txt"

echo "=== sonames the proto NEEDs but does NOT contain (count = direct NEEDED refs) ==="
cat "$OUT/unresolvable.txt"
echo "=== total distinct sonames NEEDED by the proto: $(wc -l < "$OUT/needed-all.txt" | tr -d ' ') ==="
echo "=== unresolvable: $(wc -l < "$OUT/unresolvable.txt" | tr -d ' ') ==="
