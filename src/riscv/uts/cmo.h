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
 * Two backends, selected at build time (analysis §2.5):
 *   - default: T-Head custom cache ops (raw .long-encoded opcode-0xb custom-0
 *     instructions: thead.dcache.clean/inval/flush, thead.sync). Works on the
 *     C906/C910/X60 T-Head lineage. n-hys's asm/t-head.h, verbatim encodings.
 *   - -DCMO_ZICBOM: the ratified RISC-V Zicbom ops (cbo.clean/flush/inval).
 *     Portable; prefer it IF the Jupiter2 DT `riscv,isa` lists `zicbom`.
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

#if defined(CMO_ZICBOM)

/*
 * Zicbom backend: cbo.clean/flush/inval operate on the cache block containing
 * the byte at 0(rs1). Range-loop by DCACHE_LINE. Encoded via the .insn form
 * (rd=0, funct3=010 MISC-MEM, immediate selects the op) so no -march=_zicbom
 * toolchain support is required.
 */
static inline void
cmo_dcache_clean(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, DCACHE_LINE); addr < end;
	    addr += DCACHE_LINE)
		__asm__ __volatile__(".insn i 0x0f, 2, x0, %0, 1"
		    :: "r"(addr) : "memory");
	__asm__ __volatile__("fence rw, rw" ::: "memory");
}
static inline void
cmo_dcache_invalidate(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, DCACHE_LINE); addr < end;
	    addr += DCACHE_LINE)
		__asm__ __volatile__(".insn i 0x0f, 2, x0, %0, 0"
		    :: "r"(addr) : "memory");
	__asm__ __volatile__("fence rw, rw" ::: "memory");
}
static inline void
cmo_dcache_flush(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, DCACHE_LINE); addr < end;
	    addr += DCACHE_LINE)
		__asm__ __volatile__(".insn i 0x0f, 2, x0, %0, 2"
		    :: "r"(addr) : "memory");
	__asm__ __volatile__("fence rw, rw" ::: "memory");
}

/*
 * Zicbom has no instruction-cache-invalidate op; the ISA-portable icache sync
 * is `fence.i' (cross-hart broadcast via SBI remote-fence-i is added for SMP,
 * see cmo.c). Provide the same entry point the T-Head backend exposes so
 * sync_icache() is backend-agnostic.
 */
static inline void
cmo_icache_invalidate(unsigned long addr, unsigned long size)
{
	(void) addr;
	(void) size;
	__asm__ __volatile__("fence.i" ::: "memory");
}

#else /* T-Head custom backend (default) — n-hys asm/t-head.h verbatim ISA */

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
cmo_dcache_clean(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, DCACHE_LINE); addr < end;
	    addr += DCACHE_LINE)
		_thead_dcache_clean_vaddr(addr);
	thead_sync_s();
}
static inline void
cmo_dcache_invalidate(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, DCACHE_LINE); addr < end;
	    addr += DCACHE_LINE)
		_thead_dcache_invalidate_vaddr(addr);
	thead_sync_s();
}
static inline void
cmo_dcache_flush(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, DCACHE_LINE); addr < end;
	    addr += DCACHE_LINE)
		_thead_dcache_flush_vaddr(addr);
	thead_sync_s();
}
static inline void
cmo_icache_invalidate(unsigned long addr, unsigned long size)
{
	unsigned long end = addr + size;
	for (addr = CMO_ALIGN(addr, ICACHE_LINE); addr < end;
	    addr += ICACHE_LINE)
		_thead_icache_invalidate_vaddr(addr);
	thead_sync_is();
}

#endif /* CMO backend */

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

#endif /* _RISCV_CMO_H */
