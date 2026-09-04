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
 * n-hys/illumos-gate (usr/src/uts/riscv64pf/sun20i/os/sun20i_dep.c).
 */

/*
 * cmo.c — cache-coherence hooks over the RISC-V CMO primitives (cmo.h).
 *
 * These are the sun20i_dep.c sync_icache/sync_data_memory hooks, generalized
 * for the K1: kobj/SDT instruction-memory sync and the DMA write-back path.
 * On real K1 silicon the DMA drivers (dwcmshc-sdhci, dwmac) call cmo_dma_wb /
 * cmo_dma_inv (cmo.h) around descriptor/buffer accesses.
 *
 * This file also owns the RUNTIME BACKEND CHOICE (cmo_init). Both instruction
 * sets cmo.h can emit -- Zicbom and the T-Head custom ops -- trap as illegal
 * instructions on a CPU that does not implement them, so which one to use is a
 * property of the booted hardware, not of the build. cmo_init reads it from the
 * DT once at startup; every cmo_* call then dispatches on the result.
 *
 * Cross-hart instruction-cache sync uses a local `fence.i`; a full SMP kernel
 * broadcasts an icache fence to the other harts (SBI remote-fence-i or an
 * IPI). Single-hart bring-up and the selftest are correct with the local
 * fence; the SMP broadcast is added when the K1 runs multi-hart.
 */

#include "cmo.h"

extern void sbi_console_puts(const char *s);
extern void kputhex(unsigned long v);

/*
 * cmo_backend -- which cache-maintenance instruction set THIS CPU implements.
 *
 * CMO_NONE until cmo_init() runs, and CMO_NONE is the safe answer: it means
 * "issue only the ordering fence", which is correct on a coherent-DMA platform
 * and, crucially, cannot trap. Both of the real backends use instructions that
 * raise an illegal-instruction exception on a CPU that lacks them, so guessing
 * wrong is fatal rather than merely slow -- hence a conservative default and an
 * explicit runtime probe.
 */
int cmo_backend = CMO_NONE;

/* fdt.c: property lookup on the boot DTB. */
extern long fdt_find_compatible(unsigned long dtb, const char *pfx);
extern int fdt_node_prop_str(unsigned long dtb, long node_off,
    const char *name, const char **out);

const char *
cmo_backend_name(void)
{
	switch (cmo_backend) {
	case CMO_BACKEND_ZICBOM:
		return ("Zicbom");
	case CMO_BACKEND_THEAD:
		return ("T-Head custom");
	default:
		return ("none (coherent DMA, fence only)");
	}
}

/* Substring search: is `needle' present in `hay'? The riscv,isa string is a
 * concatenation like "rv64imafdc_zicbom_zicboz", so a plain substring test is
 * what identifies an extension. */
static int
str_has(const char *hay, const char *needle)
{
	const char *h, *n;

	if (hay == 0 || needle == 0)
		return (0);
	for (; *hay != '\0'; hay++) {
		for (h = hay, n = needle; *n != '\0' && *h == *n; h++, n++)
			;
		if (*n == '\0')
			return (1);
	}
	return (0);
}

/*
 * cmo_init -- pick the cache-maintenance backend for this boot from the DT.
 *
 * The decision procedure, in priority order, and why:
 *
 *   1. `riscv,isa` on cpu@0 lists `zicbom` -> Zicbom. It is the ratified
 *      extension, so prefer it whenever the hardware advertises it. QEMU's
 *      default rv64 CPU lands here (its DT lists zicbom/zicboz), which is what
 *      makes the DMA paths work under emulation.
 *   2. The CPU compatible names a T-Head core (`thead,...`) -> the custom ops.
 *      T-Head parts predate Zicbom and do not advertise it.
 *   3. Otherwise CMO_NONE: assume coherent DMA and issue only the fence.
 *
 * WHY not probe by trying an instruction and catching the trap: that needs a
 * per-hart trap-handler hook and leaves a window where an unexpected fault is
 * indistinguishable from a real bug. The DT already carries the answer, and
 * reading it is both cheaper and honest about where the information came from.
 *
 * Returns the chosen backend.
 */
int
cmo_init(unsigned long dtb)
{
	const char *isa = 0;
	long cpu;

	cmo_backend = CMO_NONE;

	if (dtb != 0) {
		cpu = fdt_find_compatible(dtb, "riscv");
		if (cpu >= 0 && fdt_node_prop_str(dtb, cpu, "riscv,isa", &isa)) {
			if (str_has(isa, "zicbom"))
				cmo_backend = CMO_BACKEND_ZICBOM;
		}
		if (cmo_backend == CMO_NONE && cpu >= 0) {
			const char *compat = 0;

			if (fdt_node_prop_str(dtb, cpu, "compatible", &compat) &&
			    str_has(compat, "thead"))
				cmo_backend = CMO_BACKEND_THEAD;
		}
	}

	sbi_console_puts("[cmo] cache-maintenance backend: ");
	sbi_console_puts(cmo_backend_name());
	if (isa != 0) {
		sbi_console_puts(" (riscv,isa=\"");
		sbi_console_puts(isa);
		sbi_console_puts("\")");
	}
	sbi_console_puts("\n");
	return (cmo_backend);
}

void
sync_data_memory(void *addr, unsigned long len)
{
	cmo_dcache_clean((unsigned long)addr, len);
}

void
sync_icache(void *addr, unsigned long len)
{
	cmo_dcache_clean((unsigned long)addr, len);
	cmo_icache_invalidate((unsigned long)addr, len);
	__asm__ __volatile__("fence.i" ::: "memory");
}

/*
 * cmo_selftest — smoke test the CMO path WITHOUT a real device. Under qemu-virt
 * (coherent DMA) the T-Head custom ops trap-or-nop harmlessly, so we cannot
 * assert a visible cache effect; instead we prove the range loop issues the
 * ops over a buffer and returns, and that a clean+invalidate round-trip leaves
 * the buffer's own data intact (a broken encoding that clobbered memory would
 * fail this). Returns 1 on success. On real K1 silicon this is where a DMA
 * loopback would confirm non-coherent visibility.
 */
int
cmo_selftest(void)
{
	static volatile unsigned long buf[16];
	int i, ok = 1;

	for (i = 0; i < 16; i++)
		buf[i] = 0x5041474544554d50UL ^ (unsigned long)i;

	/* write-back the buffer (device would now see current contents) */
	cmo_dma_wb((unsigned long)buf, sizeof (buf));
	/* invalidate (CPU would re-read what a device wrote) */
	cmo_dma_inv((unsigned long)buf, sizeof (buf));

	for (i = 0; i < 16; i++)
		if (buf[i] != (0x5041474544554d50UL ^ (unsigned long)i))
			ok = 0;

	sbi_console_puts("[cmo] ");
	sbi_console_puts(cmo_backend_name());
	sbi_console_puts(" clean+invalidate over ");
	kputhex(sizeof (buf));
	sbi_console_puts(ok ? " bytes OK (DMA-coherence path live)\n" :
	    " bytes FAILED (CMO encoding clobbered memory)\n");
	return (ok);
}
