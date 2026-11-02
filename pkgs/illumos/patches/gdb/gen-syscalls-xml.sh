#!/bin/sh
# gen-syscalls-xml.sh <sys/syscall.h> -- gdb's syscall table for illumos (data-directory/syscalls/illumos.xml), made
# from the gate proto's header at build time so it tracks the gate. OmniOS and OI generate theirs the same way (an
# egrep over /usr/include/sys/syscall.h in build.sh / gen_syscall_table.sh). One file serves amd64 and i386: the
# header has no per-ISA numbers (no #if around the SYS_ table), as FreeBSD's and NetBSD's single freebsd.xml/netbsd.xml.
# Aliases (#define SYS_waitsys SYS_waitid) become alias= on the real entry, so `catch syscall waitsys` works too.
set -eu
h=$1
awk '
  $1 == "#define" && $2 ~ /^SYS_[A-Za-z0-9_]+$/ {
    n = substr($2, 5)
    if ($3 ~ /^[0-9]+$/) { num[n] = $3; order[++k] = n }
    else if ($3 ~ /^SYS_/) alias[substr($3, 5)] = n
  }
  END {
    if (k < 200) { print "gen-syscalls-xml: only " k+0 " syscalls parsed" > "/dev/stderr"; exit 1 }
    print "<?xml version=\"1.0\"?>"
    print "<!-- generated from illumos sys/syscall.h by solnix pkgs/illumos/patches/gdb/gen-syscalls-xml.sh -->"
    print "<!DOCTYPE feature SYSTEM \"gdb-syscalls.dtd\">"
    print "<syscalls_info>"
    for (i = 1; i <= k; i++) {
      n = order[i]; a = (n in alias) ? " alias=\"" alias[n] "\"" : ""
      printf "  <syscall name=\"%s\" number=\"%s\"%s/>\n", n, num[n], a
    }
    print "</syscalls_info>"
  }' "$h"
