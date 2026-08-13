/* Target definitions for GCC for RISC-V (riscv64) running illumos/Solaris 2.
   Copyright (C) 1993-2024 Free Software Foundation, Inc.

This file is part of GCC.

GCC is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3, or (at your option)
any later version.

GCC is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GCC; see the file COPYING3.  If not see
<http://www.gnu.org/licenses/>.  */

/*
 * Installs as gcc/config/riscv/sol2.h.
 *
 * PROVENANCE: modeled on the richlowe/gcc arm64-gate aarch64/sol2.h (the
 * existing solnix aarch64-unknown-solaris2.11 target) and gcc's own
 * i386/sol2.h / sparc/sol2.h.  Only the pieces that differ per-arch live here;
 * everything Solaris-generic (crt1/crti/crtn STARTFILE/ENDFILE, %init/%fini,
 * Solaris #pragma, wrapped <stdint.h>, __cxa_atexit on 11.4) comes from the
 * common config/sol2.h that config.gcc appends via ${sol2_tm_file_tail}.
 *
 * The riscv/elf.h that config.gcc pulls in for the ELF base assumes Newlib
 * (crt0 + --start-group -lc -lgloss), so this header UNDEFs those Newlib
 * assumptions and lets the common sol2.h drive the Solaris libc/crt model.
 */

/* Solaris/illumos ELF is little-endian LP64D riscv64. */

/* Follow the Solaris TLS code-sequence conventions (as x86/sparc sol2 do). */
#undef TARGET_SUN_TLS
#define TARGET_SUN_TLS 1

/*
 * Drop the Newlib-oriented link/lib/startfile specs inherited from
 * riscv/elf.h.  The common sol2.h supplies the Solaris STARTFILE_SPEC
 * (crt1 crti crtbegin ... crtend crtn) and LIB_SPEC (-lc), so we clear the
 * ELF/Newlib ones here and do not redefine them.
 */
#undef LIB_SPEC
#undef STARTFILE_SPEC
#undef ENDFILE_SPEC
#undef RISCV_USE_CUSTOMISED_MULTI_LIB

/*
 * GNU ld (and the richlowe binutils *-solaris2.11 ld) drive the riscv64 ELF
 * output with the elf64lriscv emulation.  The Solaris link-editor (sgs) uses
 * its own -z/-M model and ignores -m, so this is harmless there.
 */
#undef LINK_SPEC
#define LINK_SPEC "\
-melf64lriscv \
%{mno-relax:--no-relax} \
%{shared:-shared} \
%{!shared: \
  %{!static: \
    %{rdynamic:-export-dynamic} \
    %{!dynamic-linker:-dynamic-linker /usr/lib/64/ld.so.1}} \
  %{static:-static}}"

/* riscv64 solaris is 64-bit only; the 64-bit libdir subdir is "64". */
#undef ARCH64_SUBDIR
#define ARCH64_SUBDIR "64"

/*
 * The Solaris assembler entry (the richlowe binutils gas) understands the
 * standard riscv -march/-mabi passthrough; no -xarch translation is needed
 * (unlike x86 Studio as), so ASM_SPEC stays the riscv/elf.h default.
 */
