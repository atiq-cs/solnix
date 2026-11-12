#!/usr/bin/bash
# split-debug.sh <out> <debug> <buildKey> <binutils-bin> <fail-file>: NixOS's separate-debug-info.sh for illumos
# (pkgs/build-support/setup-hooks/separate-debug-info.sh), run by every builder in place of its `gstrip --strip-debug`.
# Each ET_EXEC/ET_DYN ELF in <out> with DWARF gets:
#   1. a GNU build-id note, unless it has one (Go's linker writes one). illumos ld emits none, so it is added post-link as a
#      NON-alloc SHT_NOTE (an alloc one lands outside every segment: "allocated section not in segment"). The id is
#      sha1(buildKey ":" path-in-out), NOT a digest of the ELF bytes: an unsandboxed --check builds at a scratch out and Nix
#      rewrites only the hash string, so any digest over bytes that hold $out would DIFFER (the cc1 checksum, wave5).
#   2. <debug>/lib/debug/.build-id/xx/rest.debug = gobjcopy --only-keep-debug --compress-debug-sections=zlib (NixOS's choice;
#      it is for size). It does NOT keep build inputs out of the references: gobjcopy leaves a section uncompressed when zlib
#      would not shrink it, and a 150-byte .debug_line_str kept the gcc path (test-split.sh C). The builders' -fdebug-prefix-map
#      for gcc and the gate proto do that, and each builder fails if $debug names either. No --add-gnu-debuglink: its CRC is over the .debug bytes (same --check hazard); gdb finds
#      the file by build-id under NIX_DEBUG_INFO_DIRS, as on NixOS.
#   3. rest.executable -> the ELF in <out>, as nixpkgs. No rest.source: source tarballs are not served (wave6 plan s39).
#   4. gstrip --strip-debug -D. ar archives and ET_REL objects are only stripped (as before). A failure is a closure-gate
#      failure (written to <fail-file>): the out never ships DWARF that names a build input, and never loses it silently.
# Departure from NixOS: every package, not opt-in (the maintainer wants symbols on every test host).
# Step 2 keeps a .debug UNCOMPRESSED when it names one of this build's outputs (glibdbg 2026-11-11; wave8 made it the default
# for every x86 store-only, cargo and go build, where it had been glib's opt-in copy split-debug-selfref.sh).
set -u
out=$1; dbg=$2; key=$3; bu=$4; fail=$5
# binutils names: g-prefixed in the store binutils (OI layout), plain in an OI host's /usr/gnu/bin
tool() { for n in "$bu/g$1" "$bu/$1"; do [ -x "$n" ] && { echo "$n"; return 0; }; done; echo "FATAL: no $1 in $bu" >&2; return 1; }
OBJCOPY=$(tool objcopy) && READELF=$(tool readelf) && STRIP=$(tool strip) || { echo "split-debug: binutils missing in $bu" >> "$fail"; exit 0; }
mkdir -p "$dbg/lib/debug"
# this build's own outputs (Nix rewrites each one's scratch hash under --check). mk-src-pkg's man/info/doc are output paths; in
# cargo-build.sh and go-pkg-build.sh $man is the man-install SHELL TEXT, so only a word whose hash part is 32 nix-base32 chars counts
# (an empty hash would make `grep -q ""` match every file and leave every .debug uncompressed).
own=""; set -f   # no globbing of that shell text
for o in $out $dbg ${man:-} ${info:-} ${doc:-}; do h=${o:11:32}
  case $h in *[!0-9a-z]*) continue;; esac; [ ${#h} = 32 ] && own="$own $h"; done; set +f
# sorted: of two hard links (perl, perl5.42.3) the first path names the build-id, and find's order is the directory's
find "$out" -type f | LC_ALL=C sort | while read -r f; do
  m=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')
  case "$m" in 7f454c46|213c6172) ;; *) continue;; esac
  chmod u+w "$f"
  t=""; [ "$m" = 7f454c46 ] && t=$(od -An -tu2 -j16 -N2 "$f" | tr -d ' ')   # e_type (LE): 2 EXEC, 3 DYN
  # -eq, not =: illumos od zero-pads (-tu2 of 3 prints 00003), GNU od does not; with illumos od first no ELF was split (lixi11).
  # ./split-debug.sh keeps the = compare for the seed instance and aarch64 (both run GNU od first); this copy is for x86 store-only.
  if { [ "$t" -eq 2 ] 2>/dev/null || [ "$t" -eq 3 ] 2>/dev/null; } && "$READELF" -SW "$f" 2>/dev/null | grep -q ' \.debug_info '; then
    id=$("$READELF" -n "$f" 2>/dev/null | awk '/Build ID:/{print $3; exit}')
    if [ -z "$id" ]; then
      id=$(printf '%s' "$key:${f#$out/}" | /usr/bin/digest -a sha1)
      n="$f.bid"; printf '\004\000\000\000\024\000\000\000\003\000\000\000GNU\000'"$(printf '%s' "$id" | sed 's/../\\x&/g')" > "$n"
      [ "$(wc -c < "$n" | tr -d ' ')" = 36 ] || echo "$f: split-debug: build-id note is not 36 bytes" >> "$fail"
      "$OBJCOPY" --add-section ".note.gnu.build-id=$n" "$f" 2>> "$fail.log" \
        || echo "$f: split-debug: cannot add the build-id note" >> "$fail"
      rm -f "$n"
      [ "$("$READELF" -n "$f" 2>/dev/null | awk '/Build ID:/{print $3; exit}')" = "$id" ] \
        || echo "$f: split-debug: build-id note not readable after adding it" >> "$fail"
    fi
    d="$dbg/lib/debug/.build-id/$(echo "$id" | cut -c1-2)"; r=$(echo "$id" | cut -c3-)
    if [ ! -e "$d/$r.debug" ]; then   # Go: two binaries with one id (never seen) keep the first; objcopy breaks hard links
      mkdir -p "$d"
      # A .debug whose DWARF names this build's own outputs stays UNCOMPRESSED (glib: GIO_MODULE_DIR as a DW_OP_implicit_value).
      # An unsandboxed --check builds at a scratch out and Nix rewrites that hash back in the output's bytes, but not inside a
      # zlib stream, so a compressed copy DIFFERS (glibdbg 2026-11-11). Every other .debug: the same one-step compressed copy.
      "$OBJCOPY" --only-keep-debug "$f" "$d/$r.debug" 2>> "$fail.log" \
        || echo "$f: split-debug: --only-keep-debug failed" >> "$fail"
      # one hash per grep: illumos grep with two -e patterns misses a match in a file with NUL bytes (measured, glibdbg)
      keep=0
      for h in $own; do rc=0; LC_ALL=C grep -q "$h" "$d/$r.debug" || rc=$?
        case $rc in 0) keep=1;; 1) ;; *) echo "$f: split-debug: grep exited $rc" >> "$fail";; esac
      done
      if [ $keep = 0 ]; then
        rm -f "$d/$r.debug"
        "$OBJCOPY" --only-keep-debug --compress-debug-sections=zlib "$f" "$d/$r.debug" 2>> "$fail.log" \
          || echo "$f: split-debug: --only-keep-debug failed" >> "$fail"
      fi
      chmod 0444 "$d/$r.debug"; ln -s "$f" "$d/$r.executable"
    fi
  fi
  "$STRIP" --strip-debug -D "$f" 2>> "$fail.log" || echo "$f: split-debug: gstrip failed" >> "$fail"
done
true
