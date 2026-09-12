/*
 * amdgpu_ip.h - C3-amdgpu-c: the Navi 12 IP-block bring-up model, illumos side.
 *
 * The amdgpu device is a collection of IP (intellectual-property) blocks --
 * GC (graphics/compute), SDMA (system DMA / copy engine), GMC (graphics memory
 * controller / GART), IH (interrupt handler), plus PSP/SMU/DCE/VCN (deferred).
 * Each block lives at a per-block base offset into the MMIO register BAR
 * (BAR5, mapped by C3-amdgpu-a). RREG32/WREG32 (amdgpu.c) address a block's
 * registers as reg_offset[hwip][inst][seg] + reg -- the SOC15 register model.
 *
 * This header holds:
 *   1. the SOC15 HWIP index enum (the first index into reg_offset[]);
 *   2. the Navi 12 IP-base table shape (struct ip_base / IP_BASE_INSTANCE),
 *      cribbed VERBATIM from ../amdgpu-ref/src/navi12_ip_offset.h (the AMD
 *      register bases -- NOT invented);
 *   3. navi12_reg_base_init: fill reg_offset[] from that table
 *      (crib: ../amdgpu-ref/src/amdgpu_navi12_reg_init.c navi12_reg_base_init);
 *   4. the reduced ring + GMC + IH state the IP blocks own;
 *   5. the ip_blocks_init entry the attach path calls after TTM.
 *
 * Crib provenance (register bases + struct shapes; NO Linux/NetBSD .c lifted):
 *   - reg_offset[][][] model + SOC15_REG_OFFSET: ../amdgpu-ref/src/soc15_common.h
 *   - the *_HWIP enum ordering: amd/include/soc15_hw_ip.h + the Linux
 *     amdgpu reg_offset index enum (GC_HWIP..MAX_HWIP)
 *   - navi12_reg_base_init / the IP_BASE table numbers:
 *     ../amdgpu-ref/src/amdgpu_navi12_reg_init.c + navi12_ip_offset.h
 *   - struct amdgpu_ring: ../amdgpu-ref/src/amdgpu_ring.h (reduced HARD)
 *   - amdgpu_ring_init flow: ../amdgpu-ref/src/amdgpu_ring.c
 *   - the GART/gmc model: ../amdgpu-ref/src/amdgpu_gart.h + amdgpu_gart.c
 *     amdgpu_gart_init (table_size = num_gpu_pages*8) + gmc_v10_0 gart_size
 *   - the IH ring: ../amdgpu-ref/src/amdgpu_ih.h + navi10_ih.c
 */

#ifndef _AMDGPU_IP_H_
#define _AMDGPU_IP_H_

#include <sys/types.h>
#include "amdgpu_priv.h"
#include "ttm_priv.h"		/* struct amdgpu_bo, amdgpu_bo_create */
#include "drm_sched.h"		/* struct drm_gpu_scheduler (C3-amdgpu-d) */

struct amdgpu_softc;

/*
 * The SOC15 IP-base table (crib: navi12_ip_offset.h, VERBATIM shape).
 * MAX_INSTANCE/MAX_SEGMENT match the Navi 12 table. reg_offset[hwip][inst] is
 * a pointer into a per-instance segment[] base array; a register's MMIO word
 * index is segment[reg_BASE_IDX] + reg (SOC15_REG_OFFSET).
 */
#define	AMDGPU_MAX_INSTANCE	7
#define	AMDGPU_MAX_SEGMENT	5

struct ip_base_instance {
	uint32_t	segment[AMDGPU_MAX_SEGMENT];
};
struct ip_base {
	struct ip_base_instance	instance[AMDGPU_MAX_INSTANCE];
};

/*
 * The reg_offset[] first-index HWIP enum. Cribbed from the Linux amdgpu
 * reg_offset index enum (drivers/gpu/drm/amd/amdgpu/soc15.h-adjacent
 * amdgpu.h HWIP list); only the load-bearing blocks for the reduced Navi 12
 * bring-up (GC, HDP, MMHUB, ATHUB, NBIO, MP0, OSSSYS=IH, SDMA0/1) are used,
 * the rest are present so the enum ordinals match the crib's reg_base_init.
 */
enum amdgpu_hwip {
	GC_HWIP = 0,
	HDP_HWIP,
	SDMA0_HWIP,
	SDMA1_HWIP,
	MMHUB_HWIP,
	ATHUB_HWIP,
	NBIO_HWIP,
	MP0_HWIP,
	MP1_HWIP,
	UVD_HWIP,
	VCN_HWIP = UVD_HWIP,
	DF_HWIP,
	DCE_HWIP,
	OSSSYS_HWIP,
	SMUIO_HWIP,
	PWR_HWIP,
	NBIF_HWIP,
	THM_HWIP,
	CLK_HWIP,
	UMC_HWIP,
	MAX_HWIP
};

/*
 * struct amdgpu_ring - the reduced GPU command ring (crib:
 * ../amdgpu-ref/src/amdgpu_ring.h struct amdgpu_ring, reduced HARD).
 *
 * A ring is a command buffer in a GTT amdgpu_bo the CPU writes packets to and
 * the GPU reads via a read/write pointer. Kept: the ring BO + its CPU/GPU
 * addresses, ring_size/buf_mask/ptr_mask, wptr, the rptr/wptr writeback slots,
 * and the doorbell index. Dropped (deferred): funcs vtable, fence_drv, the
 * drm_sched entity, mqd/eop (compute), priority -- none needed to allocate the
 * ring BO and set up the pointers, which is the C3-amdgpu-c milestone.
 */
enum amdgpu_ring_type {
	AMDGPU_RING_TYPE_GFX = 0,
	AMDGPU_RING_TYPE_SDMA,
};

struct amdgpu_ring {
	struct amdgpu_softc	*sc;
	enum amdgpu_ring_type	type;

	struct amdgpu_bo	*ring_obj;	/* GTT BO holding the ring */
	volatile uint32_t	*ring;		/* CPU ptr into the ring BO */
	uint64_t		gpu_addr;	/* GPU addr of the ring BO */
	uint32_t		ring_size;	/* bytes, power of two */
	uint32_t		buf_mask;	/* (ring_size/4) - 1 */
	uint64_t		ptr_mask;	/* dword index mask */
	uint32_t		max_dw;		/* max dwords per submission */
	uint64_t		wptr;		/* CPU write pointer (dwords) */

	/* rptr/wptr writeback slots (dword offsets into sc->wb) */
	uint32_t		rptr_offs;
	uint32_t		wptr_offs;
	uint32_t		fence_offs;

	uint32_t		doorbell_index;	/* BAR2 doorbell dword slot */
	boolean_t		use_doorbell;
	char			name[16];
};

/* max ring dword defaults (crib: gfx_v10_0/sdma_v5_0 amdgpu_ring_init calls) */
#define	AMDGPU_GFX_RING_MAX_DW	256
#define	AMDGPU_SDMA_RING_MAX_DW	256
#define	AMDGPU_SCHED_HW_SUBMISSION 2	/* amdgpu_sched_hw_submission default */

/*
 * struct amdgpu_ih - the reduced interrupt-handler ring (crib:
 * ../amdgpu-ref/src/amdgpu_ih.h struct amdgpu_ih_ring + navi10_ih.c).
 *
 * The GPU writes interrupt-vector (IV) entries into this ring; the ISR
 * (amdgpu.c's amdgpu_intr_stub, the MSI-X vector C3-amdgpu-a reserved) drains
 * it. Reduced: the ring BO + its CPU/GPU address + rptr/wptr; the per-IV
 * decode + the per-IP-block .process dispatch are deferred (need firmware +
 * live hardware, C3-amdgpu-d).
 */
struct amdgpu_ih {
	struct amdgpu_bo	*ring_obj;	/* GTT BO holding the IH ring */
	volatile uint32_t	*ring;		/* CPU ptr */
	uint64_t		gpu_addr;	/* GPU addr */
	uint32_t		ring_size;	/* bytes, power of two */
	uint32_t		ptr_mask;	/* dword index mask */
	uint32_t		rptr;		/* CPU-consumed read pointer */
	boolean_t		enabled;
};

/* IH ring default size (crib: navi10_ih.c ih.ring_size = 256*1024). */
#define	AMDGPU_IH_RING_SIZE	(256 * 1024)

/*
 * struct amdgpu_gmc - the reduced graphics memory controller / GART (crib:
 * ../amdgpu-ref/src/amdgpu_gmc.h struct amdgpu_gmc + amdgpu_gart.h
 * struct amdgpu_gart). The GART is the GPU's page table over system RAM
 * (== the TTM GTT): num_gpu_pages PTEs of 8 bytes each in a table BO.
 *
 * Reduced: gart_size + the table BO + its CPU/GPU addr; no per-page PTE
 * programming loop (that walks the GTT DMA cookies and needs the SDMA copy
 * engine / live registers -- deferred). The table BO is allocated in GTT here
 * (real amdgpu uses VRAM) so it has a CPU-visible mapping for the reduced
 * bring-up (VRAM CPU-mmap is the deferred devmap path, see design doc).
 */
struct amdgpu_gmc {
	uint64_t		gart_size;	/* GART aperture in bytes */
	uint64_t		num_gpu_pages;	/* gart_size / GPU_PAGE_SIZE */
	uint64_t		table_size;	/* num_gpu_pages * 8 (PTE size) */
	struct amdgpu_bo	*table_bo;	/* the page-table BO */
	uint64_t		table_gpu_addr;	/* GPU addr of the table */
	void			*table_cpu_addr; /* CPU ptr into the table */
	uint64_t		gart_pte_flags;	/* default PTE flags */
	boolean_t		initialized;
};

/* GART default size (crib: gmc_v10_0 default gart_size = 512 MB on Navi). */
#define	AMDGPU_GMC_DEFAULT_GART_SIZE	(512ULL * 1024 * 1024)
#define	AMDGPU_GART_PTE_SIZE		8	/* bytes per GART PTE */

/*
 * struct amdgpu_wb - the writeback buffer (crib: amdgpu.h struct amdgpu_wb).
 * A small GTT BO of uint32_t slots the GPU writes ring rptr/wptr/fence values
 * into; each ring reserves a few slots. A bitmap tracks used slots.
 */
#define	AMDGPU_MAX_WB		128

struct amdgpu_wb {
	struct amdgpu_bo	*wb_obj;
	volatile uint32_t	*wb;		/* CPU ptr (num_wb dwords) */
	uint64_t		gpu_addr;	/* GPU addr of slot 0 */
	uint32_t		num_wb;
	uint32_t		used;		/* count of allocated slots */
	uint8_t			bitmap[AMDGPU_MAX_WB];
};

/*
 * struct amdgpu_ip - the aggregate IP-block state hung off the softc. Holds
 * the SOC15 reg_offset table + the GMC + the GFX/SDMA rings + the IH ring +
 * the writeback buffer.
 */
struct amdgpu_ip {
	/* SOC15 register-base table: reg_offset[hwip][inst] -> segment base[] */
	const uint32_t		*reg_offset[MAX_HWIP][AMDGPU_MAX_INSTANCE];

	struct amdgpu_wb		wb;
	struct amdgpu_gmc		gmc;
	struct amdgpu_ring		gfx_ring;
	struct amdgpu_ring		sdma_ring;
	struct amdgpu_ih		ih;
	/*
	 * C3-amdgpu-d: the per-device GPU scheduler wiring the ring to the C1c
	 * drm_sched for the live EXECBUFFER path (amdgpu_job -> run_job ->
	 * amdgpu_ib_schedule -> ring). sched_ready gates it; NULL/false off the
	 * scheduler init.
	 */
	struct drm_gpu_scheduler	sched;
	boolean_t			sched_ready;
	boolean_t			initialized;
};

/* --- navi12 reg base (amdgpu_ip.c) --- */
int	navi12_reg_base_init(struct amdgpu_softc *);
uint32_t amdgpu_reg_offset(struct amdgpu_softc *, enum amdgpu_hwip hwip,
	    uint32_t inst, uint32_t seg, uint32_t reg);

/* --- writeback (amdgpu_ip.c) --- */
int	amdgpu_wb_init(struct amdgpu_softc *);
void	amdgpu_wb_fini(struct amdgpu_softc *);
int	amdgpu_wb_get(struct amdgpu_softc *, uint32_t *slot);
void	amdgpu_wb_free(struct amdgpu_softc *, uint32_t slot);

/* --- GMC / GART (gmc.c) --- */
int	amdgpu_gmc_init(struct amdgpu_softc *);
void	amdgpu_gmc_fini(struct amdgpu_softc *);

/* --- rings (amdgpu_ring.c) --- */
int	amdgpu_ring_init(struct amdgpu_softc *, struct amdgpu_ring *ring,
	    enum amdgpu_ring_type type, uint32_t max_dw, const char *name);
void	amdgpu_ring_fini(struct amdgpu_ring *ring);
void	amdgpu_ring_write(struct amdgpu_ring *ring, uint32_t v);

/* --- IH ring (amdgpu_ring.c) --- */
int	amdgpu_ih_ring_init(struct amdgpu_softc *);
void	amdgpu_ih_ring_fini(struct amdgpu_softc *);

/* --- the aggregate bring-up (amdgpu_ip.c) --- */
int	amdgpu_ip_blocks_init(struct amdgpu_softc *);
void	amdgpu_ip_blocks_fini(struct amdgpu_softc *);

#endif	/* _AMDGPU_IP_H_ */
