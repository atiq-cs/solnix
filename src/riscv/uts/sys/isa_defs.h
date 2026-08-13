/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or http://www.opensolaris.org/os/licensing.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */

/*
 * isa_defs.h — riscv64 stanza for illumos <sys/isa_defs.h>.
 *
 * This is the machine-selection block that <sys/isa_defs.h> in the illumos
 * gate must grow for riscv64. Every illumos source funnels its ISA feature
 * macros through <sys/isa_defs.h>; the gate currently has stanzas for
 * __sparc, __sparcv9, __i386, __amd64, __aarch64. This file is the riscv64
 * block to splice in (under `#elif defined(__riscv) && (__riscv_xlen == 64)`)
 * and is also directly includable by the freestanding solnix riscv bring-up
 * kernel so its MI includes see a consistent ISA model before the full gate
 * <sys/isa_defs.h> exists.
 *
 * The values follow the RISC-V calling convention / ELF psABI (the LP64D
 * "riscv64-unknown-solaris2.11" ABI this port targets) and the illumos
 * conventions the sibling arch stanzas establish:
 *
 *   - LP64 data model  (long and pointer are 64-bit; int is 32-bit).
 *   - little-endian     (RISC-V is bi-endian by spec, but every server
 *                        profile / the LP64D psABI is little-endian; illumos
 *                        riscv64 is _LITTLE_ENDIAN like amd64/aarch64).
 *   - no _MULTI_DATAMODEL: riscv64-solaris is 64-bit only (no ILP32 sibling
 *                        ABI shipped), exactly like the aarch64 port. There is
 *                        no /lib vs /lib/64 split; the LP64D world is the only
 *                        world (IPD-24 style: /lib -> the 64-bit objects).
 *   - _LONG_LONG_LTOH   little-endian long-long byte order.
 *   - _MAX_ALIGNMENT 16 the psABI aligns the stack and max scalar (long
 *                        double / 128-bit) to 16 bytes; the stack pointer is
 *                        kept 16-byte aligned by the calling convention.
 *   - unaligned access  NOT assumed: RISC-V permits misaligned loads/stores to
 *                        trap (and they do on many implementations, incl. under
 *                        OpenSBI emulation), so _ALIGNMENT_REQUIRED = 1, like
 *                        sparc, unlike x86.
 */

#ifndef	_SYS_ISA_DEFS_RISCV_H
#define	_SYS_ISA_DEFS_RISCV_H

#ifdef	__cplusplus
extern "C" {
#endif

#if defined(__riscv) && (__riscv_xlen == 64)

/*
 * Define the appropriate "processor characteristics" shared between all
 * illumos sources; these mirror the amd64/aarch64 stanzas' contract.
 */
#define	_LITTLE_ENDIAN
#define	_STACK_GROWS_DOWNWARD
#define	_LONG_LONG_LTOH
#define	_BIT_FIELDS_LTOH
#define	_IEEE_754
#define	_CHAR_IS_SIGNED			/* RISC-V psABI: char is signed */
#define	_BOOL_ALIGNMENT			1
#define	_CHAR_ALIGNMENT			1
#define	_SHORT_ALIGNMENT		2
#define	_INT_ALIGNMENT			4
#define	_FLOAT_ALIGNMENT		4
#define	_FLOAT_COMPLEX_ALIGNMENT	4
#define	_LONG_ALIGNMENT			8
#define	_LONG_LONG_ALIGNMENT		8
#define	_DOUBLE_ALIGNMENT		8
#define	_DOUBLE_COMPLEX_ALIGNMENT	8
#define	_LONG_DOUBLE_ALIGNMENT		16	/* 128-bit long double */
#define	_LONG_DOUBLE_COMPLEX_ALIGNMENT	16
#define	_POINTER_ALIGNMENT		8
#define	_MAX_ALIGNMENT			16
#define	_ALIGNMENT_REQUIRED		1	/* misaligned may trap */

/*
 * Define the appropriate "long long" and "pointer" characteristics.
 * riscv64-solaris is a pure LP64 ABI (no ILP32 sibling), so there is no
 * _MULTI_DATAMODEL; the compilation model is fixed 64-bit.
 */
#define	_LONG_LONG_ALIGNMENT_32		_INT_ALIGNMENT

#if !defined(_LP64) && !defined(_KERNEL)
#define	_LP64
#endif
#if !defined(_I32LPx) && defined(_KERNEL)
#define	_I32LPx
#endif

/*
 * The RISC-V page size for illumos riscv64 (Sv39/Sv48) is 4 KiB base; the
 * default user thread and system stack alignment follows the psABI 16-byte
 * boundary. These are the illumos-portable ISA facts other sources key on.
 */
#define	_SUNOS_VTOC_16			/* EFI/VTOC-16 disk labels, like amd64 */
#define	_DMA_USES_PHYSADDR
#define	_FIRMWARE_NEEDS_FDISK		/* GPT/EFI, not SMI VTOC-8 */
#define	_PSM_MODULES
#define	_RTC_CONFIG
#define	_DONT_USE_1275_GENERIC_NAMES
#define	_HAVE_CPUID_INSN		0	/* no cpuid; use mvendorid/marchid CSRs */

#else	/* !(__riscv && __riscv_xlen == 64) */

#error	"sys/isa_defs.h riscv stanza included on a non-riscv64 target"

#endif	/* __riscv && __riscv_xlen == 64 */

#ifdef	__cplusplus
}
#endif

#endif	/* _SYS_ISA_DEFS_RISCV_H */
