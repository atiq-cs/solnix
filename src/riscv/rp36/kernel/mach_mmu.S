/*
 * mach_mmu.S -- riscv64 MMU primitives, an R-P22.3 MD unit.
 *
 * Two leaf routines the VM layer needs:
 *   rv_set_satp(uint64_t satp)  -- install a page table root (satp CSR) and
 *                                  flush the local TLB (sfence.vma) so the new
 *                                  translation takes effect;
 *   rv_tlb_flush_all(void)      -- global local-TLB flush (sfence.vma x0,x0).
 * A fence.i / sfence pair after satp is the RISC-V-mandated ordering for a
 * root switch.  This unit adds CSR writes + the SATP mode field manipulation
 * to the partial-link coverage.
 *
 * CRIB PROVENANCE: the "csrw satp; sfence.vma" root-switch sequence + the
 * "sfence.vma zero,zero" global flush are the RISC-V privileged spec (satp +
 * SFENCE.VMA semantics); the illumos hat/mmu MD split (a leaf that just pokes
 * the hardware root register) is the R-P7 mmu slice.
 */

#include	"assym.h"

	.section .text
	.align 2

	/* void rv_set_satp(uint64_t satp) : a0 = new satp value */
	.globl	rv_set_satp
	.type	rv_set_satp, @function
rv_set_satp:
	csrw	satp, a0
	sfence.vma			/* flush stale translations */
	ret
	.size	rv_set_satp, . - rv_set_satp

	/* void rv_tlb_flush_all(void) : global local-hart TLB flush */
	.globl	rv_tlb_flush_all
	.type	rv_tlb_flush_all, @function
rv_tlb_flush_all:
	sfence.vma	zero, zero
	ret
	.size	rv_tlb_flush_all, . - rv_tlb_flush_all

	/*
	 * R-P36: ASID-scoped flush.  sfence.vma x0, aN flushes only the TLB
	 * entries whose ASID matches aN (leaving other address spaces' entries
	 * live) -- the RISC-V privileged-spec SFENCE.VMA with rs2=ASID, rs1=x0.
	 * void rv_tlb_flush_asid(unsigned long asid) : a0 = ASID to flush.
	 */
	.globl	rv_tlb_flush_asid
	.type	rv_tlb_flush_asid, @function
rv_tlb_flush_asid:
	sfence.vma	zero, a0
	ret
	.size	rv_tlb_flush_asid, . - rv_tlb_flush_asid

	/* uint64_t rv_get_satp(void) : read the current page-table root */
	.globl	rv_get_satp
	.type	rv_get_satp, @function
rv_get_satp:
	csrr	a0, satp
	ret
	.size	rv_get_satp, . - rv_get_satp
