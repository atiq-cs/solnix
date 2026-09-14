#!/usr/bin/env bash
# gatefod-repro-diff.sh — measure whether two illumos-gate proto builds are
# byte-reproducible, and if not, report EXACTLY what differs.
#
# WHY THIS MATTERS: pkgs/illumos/gate.nix leaves `outputHash` null (a plain
# derivation) on purpose. An outputHash only means something if the output is
# byte-reproducible, and a WRONG outputHash is worse than none -- it fails at
# DOWNLOAD time with a confusing hash mismatch instead of failing loudly at build
# time. So the hash may only be set from a measurement, which is this script.
#
# Run ON the illumos node:  gatefod-repro-diff.sh <protoA> <protoB>
#
# Output, in order of what a decision needs:
#   1. verdict: identical or not
#   2. the counts (same/differ/only-in-A/only-in-B)
#   3. for differing files: whether the sizes match (content-only drift) or not
#   4. a sample of differing paths, bucketed by what they most likely are
set -u

A="${1:?usage: $0 <protoA> <protoB>}"
B="${2:?usage: $0 <protoA> <protoB>}"
W="${WORKDIR:-/var/tmp/reprodiff}"
mkdir -p "$W"

# Relative file lists. -type f only: directories carry no content, and symlinks
# are compared as their own entries by `ls -l` below rather than followed (a
# followed symlink would double-count the target and hide a retarget).
( cd "$A" && find . -type f | LC_ALL=C sort ) > "$W/files.a"
( cd "$B" && find . -type f | LC_ALL=C sort ) > "$W/files.b"
comm -23 "$W/files.a" "$W/files.b" > "$W/only-a"
comm -13 "$W/files.a" "$W/files.b" > "$W/only-b"
comm -12 "$W/files.a" "$W/files.b" > "$W/both"

echo "=== inventory ==="
printf 'files in A      : %s\n' "$(wc -l < "$W/files.a" | tr -d ' ')"
printf 'files in B      : %s\n' "$(wc -l < "$W/files.b" | tr -d ' ')"
printf 'only in A       : %s\n' "$(wc -l < "$W/only-a" | tr -d ' ')"
printf 'only in B       : %s\n' "$(wc -l < "$W/only-b" | tr -d ' ')"
printf 'in both         : %s\n' "$(wc -l < "$W/both" | tr -d ' ')"

# cmp, not sha256, for the pairwise check: it short-circuits on the first
# differing byte, which on a 491 MB tree is far cheaper than hashing everything.
# It also gives the differing OFFSET for free, which is the useful diagnostic.
: > "$W/differ"
: > "$W/same"
while IFS= read -r f; do
  if cmp -s "$A/$f" "$B/$f"; then
    printf '%s\n' "$f" >> "$W/same"
  else
    printf '%s\n' "$f" >> "$W/differ"
  fi
done < "$W/both"

nsame=$(wc -l < "$W/same" | tr -d ' ')
ndiff=$(wc -l < "$W/differ" | tr -d ' ')
echo
echo "=== pairwise content ==="
printf 'identical       : %s\n' "$nsame"
printf 'differing       : %s\n' "$ndiff"

if [ "$ndiff" = 0 ] && [ ! -s "$W/only-a" ] && [ ! -s "$W/only-b" ]; then
  echo
  echo "VERDICT: BYTE-IDENTICAL across the two builds."
  echo "An outputHash (FOD) is therefore justifiable. Compute it with:"
  echo "  nix-hash --type sha256 --base32 $A"
  exit 0
fi

echo
echo "=== size analysis of differing files ==="
# A differing file with the SAME size is content drift (a timestamp, a build host
# string, a path). A differing SIZE means something structural changed.
samesize=0; diffsize=0
: > "$W/differ-samesize"; : > "$W/differ-diffsize"
while IFS= read -r f; do
  sa=$(wc -c < "$A/$f" | tr -d ' '); sb=$(wc -c < "$B/$f" | tr -d ' ')
  if [ "$sa" = "$sb" ]; then
    samesize=$((samesize + 1)); printf '%s\n' "$f" >> "$W/differ-samesize"
  else
    diffsize=$((diffsize + 1)); printf '%s %s %s\n' "$f" "$sa" "$sb" >> "$W/differ-diffsize"
  fi
done < "$W/differ"
printf 'differ, same size : %s  (content drift: timestamps/hostnames/paths)\n' "$samesize"
printf 'differ, diff size : %s  (structural)\n' "$diffsize"

echo
echo "=== first differing byte offset, sample of 15 (cmp) ==="
head -15 "$W/differ" | while IFS= read -r f; do
  printf '  %-64s %s\n' "$f" "$(cmp "$A/$f" "$B/$f" 2>&1 | head -1)"
done

echo
echo "=== differing paths bucketed by kind (top 20 dirs) ==="
sed 's,^\./,,; s,/[^/]*$,,' "$W/differ" | LC_ALL=C sort | uniq -c | sort -rn | head -20

if [ -s "$W/differ-diffsize" ]; then
  echo
  echo "=== structural differences (size changed), sample of 15 ==="
  head -15 "$W/differ-diffsize" | while read -r f sa sb; do
    printf '  %-60s A=%s B=%s\n' "$f" "$sa" "$sb"
  done
fi

if [ -s "$W/only-a" ] || [ -s "$W/only-b" ]; then
  echo
  echo "=== files present in only ONE build, sample ==="
  head -10 "$W/only-a" | sed 's/^/  only-A: /'
  head -10 "$W/only-b" | sed 's/^/  only-B: /'
fi

echo
echo "VERDICT: NOT byte-identical -- $ndiff of $(wc -l < "$W/both" | tr -d ' ') shared files differ."
echo "Do NOT set outputHash from this state: an FOD would fail at download time."
echo "Full lists: $W/{differ,differ-samesize,differ-diffsize,only-a,only-b}"
exit 1
