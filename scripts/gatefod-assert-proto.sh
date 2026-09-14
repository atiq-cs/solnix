#!/usr/bin/env bash
# gatefod-assert-proto.sh — the proto assertion from pkgs/illumos/gate.nix, as a
# STANDALONE runnable check, plus its NEGATIVE CONTROL.
#
# WHY THIS FILE EXISTS: `nightly` exits non-zero while still producing a good
# kernel (measured: a missing /usr/ast/bin/msgcc makes every libast .mso target
# die Error 127 and fails the CHECK phase, while uts/ has already staged a working
# unix + genunix into the proto). So gate.nix runs `nightly || true` and decides
# from the PROTO instead of the exit code. That makes the assertion the only thing
# standing between a broken build and a store path full of nothing — and a check
# that cannot fail proves nothing. `selftest` below fabricates four bad protos and
# requires the assertion to REJECT every one.
#
#   gatefod-assert-proto.sh check <proto-dir>   assert one proto (exit 0 = real)
#   gatefod-assert-proto.sh selftest            negative control: 1 good + 4 bad
#
# POSIX-only on purpose: illumos has no stat(1) (not even gstat) and no
# readlink(1), and both have SILENTLY broken checks in this project before — a
# `stat -c %s` gate that was always false, and a `$(readlink ...)` that expanded
# empty so `ln -sf ""` no-oped. od(1) and wc(1) ship on every illumos.
set -u

# ELFCLASS64 = e_ident[EI_CLASS] (offset 4) == 2; EM_AMD64 = e_machine (offset 18) == 62.
#
# WHY THE NUMBERS ARE COMPARED WITH -eq AND NOT WITH `=`: illumos od ZERO-PADS its
# numeric output to the field width and GNU od does not. The same byte reads back as
# "2" under GNU od and "002" under illumos od; e_machine reads "62" vs "00062". A
# string compare against "2"/"62" therefore succeeded on the Linux dev box and FAILED
# on illumos -- the selftest's positive control failed on the target while all four
# negative cases still "passed", reporting 4/5 and looking almost right. Arithmetic
# comparison is padding-agnostic. (Corollary: an all-negative test suite would have
# reported a clean pass here. Keep the positive control.)
elf64_amd64() {
  [ -f "$1" ] || return 1
  magic=$(od -An -tx1 -N4 "$1" | tr -d ' \n')
  [ "$magic" = "7f454c46" ] || return 1
  cls=$(od -An -tu1 -j4 -N1 "$1" | tr -d ' \n')
  [ "$cls" -eq 2 ] 2>/dev/null || return 1
  mach=$(od -An -tu2 -j18 -N2 "$1" | tr -d ' \n')
  [ "$mach" -eq 62 ] 2>/dev/null || return 1
  return 0
}

assert_proto() {  # $1 = proto dir -> 0 real, 1 broken
  PROTO="$1"
  fail=0
  if [ ! -d "$PROTO" ]; then echo "FATAL: no proto dir at $PROTO" >&2; return 1; fi
  check_elf() {
    f="$PROTO/$1"
    if [ ! -f "$f" ]; then echo "FATAL: proto missing $1 ($2)" >&2; fail=1; return; fi
    if elf64_amd64 "$f"; then
      echo "OK   $1 — ELFCLASS64/EM_AMD64 ($(wc -c < "$f" | tr -d ' ') bytes)"
    else
      echo "FATAL: $1 is not ELFCLASS64/EM_AMD64 ($2)" >&2; fail=1
    fi
  }
  check_elf platform/i86pc/kernel/amd64/unix "the kernel"
  check_elf kernel/amd64/genunix          "the generic kernel module"
  check_elf lib/amd64/libc.so.1           "libc"
  [ -d "$PROTO/usr/include" ] || { echo "FATAL: proto has no usr/include (headers)" >&2; fail=1; }
  return "$fail"
}

# Fabricate a minimal 64-byte ELF header with a given class + machine, so the
# selftest needs no real kernel and runs anywhere.
#
# WHY awk AND NOT printf: this was first written with nested
# `printf "$(printf '\\%03o' ..)"`, which produced a 64-byte file on the Linux dev
# box but only 20 BYTES on illumos -- so the selftest's POSITIVE control silently
# failed there while all four negative cases still "passed", reporting 4/5. Two
# shells disagreeing about printf's octal escapes is exactly the class of silent
# divergence that makes a check untrustworthy. awk's %c is specified and behaves
# the same on both, and awk is on every illumos. The size is then VERIFIED with
# wc -c, never inferred from exit status.
mk_elf() {  # $1 = out, $2 = class byte (1|2), $3 = machine (decimal, LE u16)
  out="$1"; cls="$2"; mach="$3"
  mkdir -p "$(dirname "$out")"
  awk -v cls="$cls" -v mach="$mach" 'BEGIN{
    # e_ident: 0x7f E L F, EI_CLASS, EI_DATA=1 (LSB), EI_VERSION=1, then 9 pad
    printf "%c%c%c%c%c%c%c", 127, 69, 76, 70, cls, 1, 1;
    for (i = 0; i < 9; i++) printf "%c", 0;
    printf "%c%c", 2, 0;                            # e_type = ET_EXEC
    printf "%c%c", mach % 256, int(mach / 256);      # e_machine, little-endian
    for (i = 0; i < 44; i++) printf "%c", 0;         # pad to a 64-byte Ehdr
  }' > "$out"
  n=$(wc -c < "$out" | tr -d ' ')
  [ "$n" = 64 ] || { echo "BUG: mk_elf wrote $n bytes, not 64 ($out)" >&2; return 1; }
}

mk_good_proto() {  # $1 = dir
  d="$1"
  mk_elf "$d/platform/i86pc/kernel/amd64/unix" 2 62
  mk_elf "$d/kernel/amd64/genunix" 2 62
  mk_elf "$d/lib/amd64/libc.so.1" 2 62
  mkdir -p "$d/usr/include"
}

case "${1:-}" in
check)
  assert_proto "${2:?usage: $0 check <proto-dir>}"
  rc=$?
  [ "$rc" = 0 ] && echo "PROTO OK" || echo "PROTO BROKEN"
  exit "$rc"
  ;;
selftest)
  T=$(mktemp -d /var/tmp/protoselftest.XXXXXX)
  pass=0; total=0
  run() {  # $1 = label, $2 = dir, $3 = expected rc (0 pass / 1 reject)
    total=$((total + 1))
    echo "--- $1 (expect $( [ "$3" = 0 ] && echo PASS || echo REJECT )) ---"
    assert_proto "$2" > "$T/out.$total" 2>&1; rc=$?
    sed 's/^/    /' "$T/out.$total"
    if [ "$rc" = "$3" ]; then echo "    => as expected (rc=$rc)"; pass=$((pass + 1));
    else echo "    => WRONG: rc=$rc, expected $3"; fi
  }

  # 1. POSITIVE control: a complete proto must PASS. Without this the selftest
  #    could "succeed" by rejecting everything, which proves nothing either.
  mk_good_proto "$T/good"; run "complete proto" "$T/good" 0

  # 2. NEGATIVE: entirely empty proto (the "gate produced nothing" case).
  mkdir -p "$T/empty"; run "empty proto" "$T/empty" 1

  # 3. NEGATIVE: partial proto — libc + headers present, KERNEL ABSENT. This is
  #    the realistic failure: userland staged, uts/ never got there.
  mk_elf "$T/partial/lib/amd64/libc.so.1" 2 62; mkdir -p "$T/partial/usr/include"
  run "partial proto (no kernel)" "$T/partial" 1

  # 4. NEGATIVE: right paths, WRONG ARCH — a 32-bit i386 unix. Catches a build
  #    that produced ELF at the correct path but for the wrong target.
  mk_good_proto "$T/wrongarch"; mk_elf "$T/wrongarch/platform/i86pc/kernel/amd64/unix" 1 3
  run "wrong arch (ELFCLASS32/EM_386 kernel)" "$T/wrongarch" 1

  # 5. NEGATIVE: file present but NOT ELF (a 0-byte or text stub — the shape a
  #    truncated copy or a `touch` produces, and the shape that has silently
  #    passed `[ -f ]`-only checks in this project before).
  mk_good_proto "$T/stub"; : > "$T/stub/kernel/amd64/genunix"
  run "zero-byte genunix stub" "$T/stub" 1

  echo
  echo "selftest: $pass/$total as expected"
  find "$T" -mindepth 1 -delete 2>/dev/null
  rmdir "$T" 2>/dev/null
  [ "$pass" = "$total" ] || { echo "SELFTEST FAILED — the proto assertion is not trustworthy" >&2; exit 1; }
  echo "SELFTEST OK — the assertion passes a real proto and REJECTS empty/partial/wrong-arch/stub"
  ;;
*)
  echo "usage: $0 check <proto-dir> | $0 selftest" >&2; exit 2 ;;
esac
