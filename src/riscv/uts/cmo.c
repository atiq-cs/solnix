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
 * Cross-hart instruction-cache sync uses a local `fence.i`; a full SMP kernel
 * broadcasts an icache fence to the other harts (SBI remote-fence-i or an
 * IPI). Single-hart bring-up and the selftest are correct with the local
 * fence; the SMP broadcast is added when the K1 runs multi-hart.
 */

#include "cmo.h"

extern void sbi_console_puts(const char *s);
extern void kputhex(unsigned long v);

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

	sbi_console_puts("[cmo] T-Head CMO clean+invalidate over ");
	kputhex(sizeof (buf));
	sbi_console_puts(ok ? " bytes OK (DMA-coherence path staged for "
	    "K1 non-coherent MMC/eth)\n" :
	    " bytes FAILED (CMO encoding clobbered memory)\n");
	return (ok);
}
