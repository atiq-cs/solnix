/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 solnix contributors
 * SPDX-License-Identifier: MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

/*
 * nvidia_drm_bar1.h -- the arithmetic of GEM mmap (D2.3), with no kernel
 * dependency, so test/test_bar1.c runs the same code in userland. Used by
 * nvidia_drm_illumos.c (devmap) and nvidia_drm_glue.c (the offset lookup).
 * The includer provides uint32_t/uint64_t and the errno values.
 *
 * A dumb buffer (or any nvkms-memory object in video memory) is mapped by
 * NVKMS into the GPU's FB aperture; mapMemory(USER) gives nvidia-drm its CPU
 * physical address there (RM osMapPciMemoryAreaUser: the BAR1 bus address
 * of range 0). devmap_devmem_setup(9F) takes a "reg" register number and an
 * offset into it, so the shell needs (1) which "reg" entry is the FB BAR and
 * where it is assigned, and (2) that the object's range lies inside it.
 */
#ifndef _NVIDIA_DRM_BAR1_H
#define _NVIDIA_DRM_BAR1_H

#define	NVD_PAGE_SHIFT		12
#define	NVD_PAGE_SIZE		(1ULL << NVD_PAGE_SHIFT)
#define	NVD_PAGE_OFFSET		(NVD_PAGE_SIZE - 1)

/* pci_regspec_t (sys/pci.h): phys_hi, phys_mid, phys_low, size_hi, size_low */
#define	NVD_REGSPEC_INTS	5
#define	NVD_REG_SPACE(hi)	(((uint32_t)(hi) >> 24) & 3u)	/* PCI_REG_ADDR_G */
#define	NVD_REG_REG(hi)		((uint32_t)(hi) & 0xffu)	/* PCI_REG_REG_G */
#define	NVD_SPACE_MEM32		2u
#define	NVD_SPACE_MEM64		3u
#define	NVD_CONF_BASE0		0x10u
#define	NVD_NBARS		6u

struct nvd_bar1 {
	uint32_t	rnumber;	/* index of the FB BAR in "reg" */
	uint32_t	cfgoff;		/* its config-space offset (0x14 on the X1E) */
	uint64_t	base;		/* assigned CPU physical address */
	uint64_t	size;
};

/*
 * The FB aperture as the nvidia module's nv_pci_map_bars() picks it (so it
 * is the BAR RM's gpuPhysFbAddr names): of the memory BARs in
 * "assigned-addresses", the first is the registers, the next valid one (an
 * upper-half duplicate of a 64-bit BAR skipped) is the FB. Then the "reg"
 * entry with that config offset, as nv_bar_rnumber() finds it. 0, or ENXIO.
 */
static inline int
nvd_bar1_locate(const int *reg, uint32_t nreg_ints, const int *aa,
    uint32_t naa_ints, struct nvd_bar1 *b)
{
	uint64_t start[NVD_NBARS] = { 0 }, size[NVD_NBARS] = { 0 };
	uint32_t i, n, idx, fb = NVD_NBARS, first = NVD_NBARS;

	n = naa_ints / NVD_REGSPEC_INTS;
	for (i = 0; i < n; i++) {
		const int *r = &aa[i * NVD_REGSPEC_INTS];
		uint32_t sp = NVD_REG_SPACE(r[0]), off = NVD_REG_REG(r[0]);

		if (sp != NVD_SPACE_MEM32 && sp != NVD_SPACE_MEM64)
			continue;
		if (off < NVD_CONF_BASE0 || off >= NVD_CONF_BASE0 + 4 * NVD_NBARS ||
		    (off - NVD_CONF_BASE0) % 4 != 0)
			continue;
		idx = (off - NVD_CONF_BASE0) / 4;
		start[idx] = ((uint64_t)(uint32_t)r[1] << 32) | (uint32_t)r[2];
		size[idx] = ((uint64_t)(uint32_t)r[3] << 32) | (uint32_t)r[4];
	}
	for (i = 0; i < NVD_NBARS; i++) {
		if (size[i] == 0)
			continue;
		if (first == NVD_NBARS) {
			first = i;
			continue;
		}
		if (i > 0 && size[i - 1] != 0 && start[i - 1] == start[i] &&
		    size[i - 1] == size[i])
			continue;	/* upper half of a 64-bit BAR */
		fb = i;
		break;
	}
#ifdef NVD_BAR1_SABOTAGE_FB
	fb = first;		/* negative control: the register BAR as the FB */
#endif
	if (fb == NVD_NBARS || start[fb] == 0)
		return (ENXIO);
	b->cfgoff = NVD_CONF_BASE0 + 4 * fb;
	b->base = start[fb];
	b->size = size[fb];
	n = nreg_ints / NVD_REGSPEC_INTS;
	for (i = 0; i < n; i++) {
		uint32_t hi = (uint32_t)reg[i * NVD_REGSPEC_INTS];

		if (NVD_REG_REG(hi) == b->cfgoff &&
		    (NVD_REG_SPACE(hi) == NVD_SPACE_MEM32 ||
		    NVD_REG_SPACE(hi) == NVD_SPACE_MEM64)) {
			b->rnumber = i;
			return (0);
		}
	}
	return (ENXIO);
}

/*
 * An mmap(2) of a DRM fd at a GEM fake offset: the page-based start and
 * length drm_vma_offset_exact_lookup_locked() takes, and the length mapped
 * (whole pages). 0, or EINVAL.
 */
static inline int
nvd_vma_req(int64_t off, uint64_t len, uint64_t *startp, uint64_t *pagesp,
    uint64_t *rlenp)
{
	if (off < 0 || ((uint64_t)off & NVD_PAGE_OFFSET) != 0 || len == 0 ||
	    len > ~0ULL - NVD_PAGE_OFFSET)
		return (EINVAL);
	*startp = (uint64_t)off >> NVD_PAGE_SHIFT;
	*rlenp = (len + NVD_PAGE_OFFSET) & ~NVD_PAGE_OFFSET;
	*pagesp = *rlenp >> NVD_PAGE_SHIFT;
	return (0);
}

/*
 * The object's mapped range, [pa, pa + rlen), must be whole pages inside the
 * object and inside the FB BAR. Sets the offset into the BAR. 0, or ERANGE.
 */
static inline int
nvd_bar1_range(const struct nvd_bar1 *b, uint64_t pa, uint64_t objsize,
    uint64_t rlen, uint64_t *roffp)
{
	uint64_t roff;

	if ((pa & NVD_PAGE_OFFSET) != 0 || (rlen & NVD_PAGE_OFFSET) != 0 ||
	    rlen == 0 || rlen > objsize || pa < b->base)
		return (ERANGE);
	roff = pa - b->base;
#ifdef NVD_BAR1_SABOTAGE_RANGE
	if (roff > b->size)	/* negative control: no end check */
#else
	if (roff >= b->size || rlen > b->size - roff)
#endif
		return (ERANGE);
	*roffp = roff;
	return (0);
}

#endif /* _NVIDIA_DRM_BAR1_H */
