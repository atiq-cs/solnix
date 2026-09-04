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
 * Copyright 2022 Hayashi Naoyuki
 *
 * Portions Copyright 2022 Hayashi Naoyuki; adapted for solnix from
 * n-hys/illumos-gate (usr/src/uts/riscv64pf/sun20i/asm/t-head.h +
 * usr/src/uts/riscv64pf/sun20i/os/sun20i_dep.c).
 */

/*
 * cmo.h — RISC-V cache-maintenance operations (CMO) for non-coherent DMA.
 *
 * The SpaceMiT K1's X60 core is T-Head-derived, and its dwcmshc-sdhci / dwmac
 * DMA is non-coherent: descriptor rings and DMA buffers must be explicitly
 * cleaned (write-back before the device reads) and invalidated (before the CPU
 * reads what the device wrote). Our qemu-virt bring-up never needed this
 * because qemu DMA is coherent; on real K1 silicon it BLOCKS MMC + ethernet.
 *
 * Three backends.  The first two are the instruction sets themselves; the third
 * is the runtime dispatcher that decides between them, which is what kernel code
 * should call:
 *   - the T-Head custom cache ops (raw .long-encoded opcode-0xb custom-0
 *     instructions: thead.dcache.clean/inval/flush, thead.sync). Works on the
 *     C906/C910/X60 T-Head lineage. n-hys's asm/t-head.h, verbatim encodings.
 *   - the ratified RISC-V Zicbom ops (cbo.clean/flush/inval). Portable; what a
 *     DT that lists `zicbom` in riscv,isa gets.
 *   - cmo_dma_wb()/cmo_dma_inv(): dispatch on cmo_backend, chosen ONCE at boot
 *     by cmo_init() from the DT.  Drivers call these and never the raw ops.
 *
 * WHY runtime and not a build flag: a custom-opcode instruction the CPU does not
 * implement raises an ILLEGAL INSTRUCTION trap, so a kernel built for T-Head
 * dies the moment any driver touches the DMA path on a non-T-Head part -- and
 * qemu-virt's default rv64 CPU is exactly such a part (it implements Zicbom and
 * traps the T-Head encodings).  One kernel image has to boot both the Jupiter
 * and QEMU, so the choice cannot be baked in at compile time.  CMO_ZICBOM and
 * CMO_THEAD still force a single backend for a build that wants no dispatch.
 *
 * DCACHE_LINE / ICACHE_LINE default to 64 (K1 and the D1 both use 64-byte
 * lines); override at build time for other parts.
 */

#ifndef _RISCV_CMO_H
#define	_RISCV_CMO_H

#ifndef DCACHE_LINE
#define	DCACHE_LINE	64
#endif
#ifndef ICACHE_LINE
#define	ICACHE_LINE	64
#endif

/* Align `x' down to the cache-line boundary (P2ALIGN, self-contained). */
#define	CMO_ALIGN(x, a)	((unsigned long)(x) & ~((unsigned long)(a) - 1))

/*
 * ---------------------------------------------------------------------------
 * Backend 1: Zicbom (the ratified RISC-V extension).
 *
 * cbo.clean/flush/inval operate on the cache block containing the byte at
 * 0(rs1). Range-loop by DCACHE_LINE. Encoded via the .insn form (rd=0,
 * funct3=010 MISC-MEM, immediate selects the op) so no -march=_zicbom
 * toolchain support is required.
 * ---------------------------------------------------------------------------
 */
static inline void
zicbom_dcache_clean(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, DCACHE_LINE); addr < end;
	    addr += DCACHE_LINE)
		__asm__ __volatile__(".insn i 0x0f, 2, x0, %0, 1"
		    :: "r"(addr) : "memory");
	__asm__ __volatile__("fence rw, rw" ::: "memory");
}
static inline void
zicbom_dcache_invalidate(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, DCACHE_LINE); addr < end;
	    addr += DCACHE_LINE)
		__asm__ __volatile__(".insn i 0x0f, 2, x0, %0, 0"
		    :: "r"(addr) : "memory");
	__asm__ __volatile__("fence rw, rw" ::: "memory");
}
static inline void
zicbom_dcache_flush(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, DCACHE_LINE); addr < end;
	    addr += DCACHE_LINE)
		__asm__ __volatile__(".insn i 0x0f, 2, x0, %0, 2"
		    :: "r"(addr) : "memory");
	__asm__ __volatile__("fence rw, rw" ::: "memory");
}

/*
 * ---------------------------------------------------------------------------
 * Backend 2: T-Head custom cache ops (n-hys asm/t-head.h verbatim encodings).
 *
 * Raw .long-encoded opcode-0xb custom-0 instructions. These are ILLEGAL on a
 * CPU without the T-Head extensions -- including qemu-virt's default rv64 CPU
 * -- which is why nothing may call them without checking cmo_backend first.
 * ---------------------------------------------------------------------------
 */
static inline void
thead_sync_s(void)
{
	__asm__ __volatile__(".long  ((0 << 25) | (0x19 << 20) | (0 << 15) | (0 << 12) | (0 << 7) | (0xb << 0))":::"memory");
}
static inline void
thead_sync_is(void)
{
	__asm__ __volatile__(".long  ((0 << 25) | (0x1b << 20) | (0 << 15) | (0 << 12) | (0 << 7) | (0xb << 0))":::"memory");
}
static inline void
_thead_dcache_clean_vaddr(unsigned long addr)
{
	register unsigned long a0 __asm__("a0") = addr;
	__asm__ __volatile__(".long ((1 << 25) | (4 << 20) | (10 << 15) | (0 << 12) | (0 << 7) | (0xb << 0))":: "r"(a0):"memory");
}
static inline void
_thead_dcache_invalidate_vaddr(unsigned long addr)
{
	register unsigned long a0 __asm__("a0") = addr;
	__asm__ __volatile__(".long ((1 << 25) | (6 << 20) | (10 << 15) | (0 << 12) | (0 << 7) | (0xb << 0))":: "r"(a0):"memory");
}
static inline void
_thead_dcache_flush_vaddr(unsigned long addr)
{
	register unsigned long a0 __asm__("a0") = addr;
	__asm__ __volatile__(".long ((1 << 25) | (7 << 20) | (10 << 15) | (0 << 12) | (0 << 7) | (0xb << 0))":: "r"(a0):"memory");
}
static inline void
_thead_icache_invalidate_vaddr(unsigned long addr)
{
	register unsigned long a0 __asm__("a0") = addr;
	__asm__ __volatile__(".long ((1 << 25) | (0x10 << 20) | (10 << 15) | (0 << 12) | (0 << 7) | (0xb << 0))":: "r"(a0):"memory");
}

static inline void
thead_dcache_clean(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, DCACHE_LINE); addr < end;
	    addr += DCACHE_LINE)
		_thead_dcache_clean_vaddr(addr);
	thead_sync_s();
}
static inline void
thead_dcache_invalidate(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, DCACHE_LINE); addr < end;
	    addr += DCACHE_LINE)
		_thead_dcache_invalidate_vaddr(addr);
	thead_sync_s();
}
static inline void
thead_dcache_flush(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, DCACHE_LINE); addr < end;
	    addr += DCACHE_LINE)
		_thead_dcache_flush_vaddr(addr);
	thead_sync_s();
}
static inline void
thead_icache_invalidate(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, ICACHE_LINE); addr < end;
	    addr += ICACHE_LINE)
		_thead_icache_invalidate_vaddr(addr);
	thead_sync_is();
}

/*
 * ---------------------------------------------------------------------------
 * The runtime dispatcher.
 *
 * cmo_backend says which instruction set this CPU actually implements. It is
 * set ONCE by cmo_init() (cmo.c) from the boot DT and never changes, so the
 * branch is perfectly predicted and the cost is nil next to the cache ops
 * themselves.
 *
 * CMO_NONE is the correct and SAFE default: a coherent-DMA platform (qemu-virt
 * with a plain rv64 CPU) needs only the ordering fence, and executing either
 * custom/extension op there would trap. A kernel that has not yet called
 * cmo_init() therefore degrades to the fence rather than dying.
 * ---------------------------------------------------------------------------
 */
#define	CMO_NONE	0	/* coherent DMA: `fence' is sufficient */
#define	CMO_BACKEND_ZICBOM	1
#define	CMO_BACKEND_THEAD	2

extern int cmo_backend;

/*
 * CMO_ZICBOM / CMO_THEAD force one backend at build time and drop the branch,
 * for a build that targets exactly one part. Unset (the normal case) means
 * runtime dispatch, which is what lets ONE kernel image boot both QEMU and the
 * Jupiter.
 */
#if defined(CMO_ZICBOM)
#define	CMO_FIXED_BACKEND	CMO_BACKEND_ZICBOM
#elif defined(CMO_THEAD)
#define	CMO_FIXED_BACKEND	CMO_BACKEND_THEAD
#endif

static inline int
cmo_active_backend(void)
{
#ifdef CMO_FIXED_BACKEND
	return (CMO_FIXED_BACKEND);
#else
	return (cmo_backend);
#endif
}

static inline void
cmo_dcache_clean(unsigned long addr, unsigned long size)
{
	switch (cmo_active_backend()) {
	case CMO_BACKEND_ZICBOM:
		zicbom_dcache_clean(addr, size);
		break;
	case CMO_BACKEND_THEAD:
		thead_dcache_clean(addr, size);
		break;
	default:
		/* Coherent DMA: only the ordering guarantee is needed. */
		__asm__ __volatile__("fence rw, rw" ::: "memory");
		break;
	}
}
static inline void
cmo_dcache_invalidate(unsigned long addr, unsigned long size)
{
	switch (cmo_active_backend()) {
	case CMO_BACKEND_ZICBOM:
		zicbom_dcache_invalidate(addr, size);
		break;
	case CMO_BACKEND_THEAD:
		thead_dcache_invalidate(addr, size);
		break;
	default:
		__asm__ __volatile__("fence rw, rw" ::: "memory");
		break;
	}
}
static inline void
cmo_dcache_flush(unsigned long addr, unsigned long size)
{
	switch (cmo_active_backend()) {
	case CMO_BACKEND_ZICBOM:
		zicbom_dcache_flush(addr, size);
		break;
	case CMO_BACKEND_THEAD:
		thead_dcache_flush(addr, size);
		break;
	default:
		__asm__ __volatile__("fence rw, rw" ::: "memory");
		break;
	}
}

/*
 * Zicbom has no instruction-cache-invalidate op, so the portable icache sync is
 * `fence.i'; only the T-Head backend has a range op. (Cross-hart broadcast via
 * SBI remote-fence-i is added for SMP -- see cmo.c.)
 */
static inline void
cmo_icache_invalidate(unsigned long addr, unsigned long size)
{
	if (cmo_active_backend() == CMO_BACKEND_THEAD) {
		thead_icache_invalidate(addr, size);
		return;
	}
	(void) addr;
	(void) size;
	__asm__ __volatile__("fence.i" ::: "memory");
}

/*
 * DMA-facing helpers (the sun20i_dep.c hooks, generalized). A driver:
 *   - cmo_dma_wb(desc, len)     before the device reads the descriptor/buffer.
 *   - cmo_dma_inv(buf, len)     before the CPU reads a device-filled buffer.
 * cmo.c wires sync_icache()/sync_data_memory() (kobj/SDT) on top of these.
 */
static inline void
cmo_dma_wb(unsigned long addr, unsigned long size)
{
	cmo_dcache_clean(addr, size);
}
static inline void
cmo_dma_inv(unsigned long addr, unsigned long size)
{
	cmo_dcache_invalidate(addr, size);
}

void sync_data_memory(void *addr, unsigned long len);
void sync_icache(void *addr, unsigned long len);
int cmo_selftest(void);
/*
 * cmo_init -- choose the backend for THIS boot from the DT's riscv,isa. Must be
 * called before any driver touches a DMA path. Returns the chosen backend.
 */
int cmo_init(unsigned long dtb);
const char *cmo_backend_name(void);

#endif /* _RISCV_CMO_H */
