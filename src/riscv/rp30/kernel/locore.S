/*
 * locore.S -- illumos riscv64 machine-dependent kernel entry.
 *
 * R-P30 headline: the kernel is LINKED + EXECUTES at HIGH VA
 * (KERNEL_DMAP_BASE + 0x80200000).  It is LOADED at physical 0x80200000 (the
 * ELF LMA, where OpenSBI jumps the S-mode payload).  So _start runs FIRST at
 * PHYSICAL 0x80200000 in bare mode (satp=0), position-independently (medany
 * PC-relative addressing computes the PHYSICAL address of every high-linked
 * symbol, because runtime PC and link-time PC differ by exactly the same
 * KERNEL_DMAP_BASE offset that separates the symbol's physical and virtual
 * addresses).  _start:
 *
 *   mask S-mode interrupts, claim the boot hart, set a PHYSICAL gp+sp, zero
 *   BSS (physical writes), call hat_earlyboot() (builds the Sv39 boot tables:
 *   a low identity window to survive the satp flip + the kernel HIGH map +
 *   the direct-map + the DRAM window + MMIO -- but does NOT enable paging),
 *   write satp + sfence.vma (paging ON), then JUMP PC to the HIGH VA of
 *   _start_high.  From _start_high on, the kernel runs purely at high VA:
 *   reload gp+sp to the high link addresses, install stvec, call mlsetup ->
 *   main.  main() then DROPS the low identity map entirely (hat_drop_identity),
 *   so the kernel runs with ONLY the high R^X kernel map + the direct-map.
 *
 * S-MODE ENTRY CONTRACT (OpenSBI fw_dynamic -> S-mode payload on qemu virt):
 *   Privilege : Supervisor.  a0 = hartid, a1 = dtb (phys).  satp = 0 (bare).
 *   sstatus.SIE clear.  Entry runs at the PHYSICAL load address 0x80200000.
 *
 * CRIB PROVENANCE: the "run at the physical load address, build page tables,
 * enable paging, jump to the high-half virtual _start" trampoline is the Linux
 * arch/riscv/kernel/head.S relocate_enable_mmu + setup_vm idiom + the i86pc/
 * aarch64 boot-map-then-jump-to-KERNELBASE transition; the "mask ints, claim
 * boot hart via amoswap, set sp, clear BSS, install stvec, call mlsetup" shape
 * is the R-P2..R-P16 uts/riscv64 locore.S (this repo) + uts/i86pc/ml/locore.s;
 * the S-mode entry register contract + physical 0x80200000 payload address is
 * the OpenSBI + qemu-virt boot convention.
 */

#include "assym.h"

/* KERNEL_DMAP_BASE (mmu_riscv.h) -- the low->high VA offset. */
#define	DMAP_BASE	0xffffffc000000000

	.section .text.start, "ax", @progbits
	.globl	_start
	.type	_start, @function
_start:
	/* Enter with S-mode interrupts off per the contract; be explicit. */
	csrci	sstatus, 0x2		/* clear sstatus.SIE (bit 1) */
	csrw	sie, zero		/* mask all S-mode interrupt sources */
	csrw	sscratch, zero		/* R-P25: sscratch==0 while in the kernel */

	/*
	 * We run at PHYSICAL 0x80200000, paging OFF.  Set gp to the PHYSICAL
	 * __global_pointer$ (medany `la` computes PC-relative -> physical) so
	 * any gp-relative access in the C bootstrap resolves; reloaded to the
	 * HIGH gp in _start_high after paging is on.
	 */
.option push
.option norelax
	la	gp, __global_pointer$
.option pop

	/*
	 * Claim boot-hart status atomically.  Only the first hart to swap 1
	 * into hart_claimed proceeds; any others park.  Preserves a0/a1.
	 * (la gives the PHYSICAL address of hart_claimed -- correct pre-paging.)
	 */
	la	t0, hart_claimed
	li	t1, 1
	amoswap.w.aq t2, t1, (t0)
	bnez	t2, park

	/* Establish the boot stack (PHYSICAL, full-descending, 16-aligned). */
	la	sp, boot_stack_top
	andi	sp, sp, ~15

	/*
	 * Zero BSS ( __bss_start .. __bss_end ), 8 bytes at a time.  Done at
	 * PHYSICAL addresses (paging off) BEFORE building the page tables --
	 * the boot page tables live in BSS, so they must be zeroed before
	 * hat_earlyboot populates them.
	 */
	la	t0, __bss_start
	la	t1, __bss_end
1:	bgeu	t0, t1, 2f
	sd	zero, 0(t0)
	addi	t0, t0, 8
	j	1b
2:

	/*
	 * Build the Sv39 boot tables (physical addresses throughout) and get
	 * the satp value to install.  hat_earlyboot preserves nothing but the
	 * ABI-callee-saved set; a0/a1 (hartid/dtb) are caller-saved, so stash
	 * them in callee-saved s-regs across the call.
	 */
	mv	s0, a0			/* save hartid */
	mv	s1, a1			/* save dtb */
	call	hat_earlyboot		/* a0 = satp value (paging NOT yet on) */

	/*
	 * Enable paging: write satp (Sv39, boot root) + sfence.vma.  We are
	 * identity-mapped at the low physical window, so the fetch of the very
	 * next instruction still resolves at the current (physical) PC.
	 */
	csrw	satp, a0
	sfence.vma

	/* restore hartid/dtb for mlsetup. */
	mv	a0, s0
	mv	a1, s1

	/*
	 * Jump PC to the HIGH VA of _start_high.  `la` gives the PHYSICAL
	 * address of _start_high; add KERNEL_DMAP_BASE to get its canonical
	 * high VA (physical load addr + DMAP == high link addr).  jr there:
	 * from this instruction on, PC is high and the kernel runs at high VA.
	 */
	la	t0, _start_high
	li	t1, DMAP_BASE
	add	t0, t0, t1
	jr	t0

park:
	wfi
	j	park
	.size	_start, . - _start

	/*
	 * _start_high -- the kernel now executes at HIGH VA (paging on, PC in
	 * the canonical Sv39 high half).  Reload gp+sp to the HIGH link
	 * addresses (medany `la` now computes high, since PC is high), install
	 * the trap vector, and hand off to C (mlsetup -> main).  a0=hartid,
	 * a1=dtb are live.
	 */
	.align 2
	.globl	_start_high
	.type	_start_high, @function
_start_high:
.option push
.option norelax
	la	gp, __global_pointer$	/* HIGH gp now */
.option pop
	la	sp, boot_stack_top	/* HIGH stack now */
	andi	sp, sp, ~15

	la	t0, _u_trap_entry	/* HIGH trap trampoline */
	csrw	stvec, t0

	call	mlsetup			/* does not return */
1:	wfi
	j	1b
	.size	_start_high, . - _start_high

	/*
	 * _secondary_start -- SMP: the entry OpenSBI's HSM hart_start jumps a
	 * SECONDARY hart to, in S-mode, bare (satp=0), running at its PHYSICAL
	 * load address.  a0 = hartid, a1 = the kernel satp value we passed to
	 * sbi_hart_start.  We install that satp (turning paging on for this
	 * hart), then jump to the HIGH VA of _secondary_high.
	 *
	 * CRIB PROVENANCE: an AP entry that turns on paging then jumps to the
	 * high-half virtual continuation is Linux secondary_start_sbi +
	 * relocate_enable_mmu; the S-mode bare-mode entry register contract
	 * (a0=hartid, a1=opaque) is the SBI HSM spec.
	 */
	.align 2
	.globl	_secondary_start
	.type	_secondary_start, @function
_secondary_start:
	csrci	sstatus, 0x2		/* clear sstatus.SIE */
	csrw	sie, zero		/* mask S-mode interrupt sources */
	csrw	sscratch, zero		/* sscratch==0 while in the kernel */

	/* turn paging on for this hart with the shared kernel satp (a1). */
	csrw	satp, a1
	sfence.vma

	/* jump to the HIGH continuation (a0=hartid preserved). */
	la	t0, _secondary_high
	li	t1, DMAP_BASE
	add	t0, t0, t1
	jr	t0
	.size	_secondary_start, . - _secondary_start

	.align 2
	.globl	_secondary_high
	.type	_secondary_high, @function
_secondary_high:
.option push
.option norelax
	la	gp, __global_pointer$	/* HIGH gp */
.option pop
	la	sp, secondary_stack_top	/* HIGH per-hart stack */
	andi	sp, sp, ~15
	la	t0, _u_trap_entry
	csrw	stvec, t0
	call	secondary_main		/* enters the shared scheduler */
1:	wfi
	j	1b
	.size	_secondary_high, . - _secondary_high

	/*
	 * disp_ap_entry -- per-CPU dispatch AP entry: like _secondary_start but
	 * the high continuation lands in disp_secondary_main (the per-CPU
	 * dispatcher) instead of the shared-runq secondary_main.
	 */
	.align 2
	.globl	disp_ap_entry
	.type	disp_ap_entry, @function
disp_ap_entry:
	csrci	sstatus, 0x2
	csrw	sie, zero
	csrw	sscratch, zero
	csrw	satp, a1
	sfence.vma
	la	t0, disp_ap_high
	li	t1, DMAP_BASE
	add	t0, t0, t1
	jr	t0
	.size	disp_ap_entry, . - disp_ap_entry

	.align 2
	.globl	disp_ap_high
	.type	disp_ap_high, @function
disp_ap_high:
.option push
.option norelax
	la	gp, __global_pointer$
.option pop
	la	sp, secondary_stack_top
	andi	sp, sp, ~15
	la	t0, _u_trap_entry
	csrw	stvec, t0
	call	disp_secondary_main
1:	wfi
	j	1b
	.size	disp_ap_high, . - disp_ap_high

	/*
	 * sc_ap_entry -- R-P30.2 TS/RT class-scheduler AP entry: like
	 * disp_ap_entry but the high continuation lands in sc_secondary_main
	 * (the class dispatcher) so the secondary hart schedules from the shared
	 * TS/RT class runq.
	 */
	.align 2
	.globl	sc_ap_entry
	.type	sc_ap_entry, @function
sc_ap_entry:
	csrci	sstatus, 0x2
	csrw	sie, zero
	csrw	sscratch, zero
	csrw	satp, a1
	sfence.vma
	la	t0, sc_ap_high
	li	t1, DMAP_BASE
	add	t0, t0, t1
	jr	t0
	.size	sc_ap_entry, . - sc_ap_entry

	.align 2
	.globl	sc_ap_high
	.type	sc_ap_high, @function
sc_ap_high:
.option push
.option norelax
	la	gp, __global_pointer$
.option pop
	la	sp, secondary_stack_top
	andi	sp, sp, ~15
	la	t0, _u_trap_entry
	csrw	stvec, t0
	call	sc_secondary_main
1:	wfi
	j	1b
	.size	sc_ap_high, . - sc_ap_high

	/*
	 * hart_claimed: boot-hart election flag.  In .data (init 0) so the BSS
	 * clear does not reset it after a hart has claimed.  .word matches
	 * amoswap.w.
	 */
	.section .data
	.align 2
	.globl	hart_claimed
hart_claimed:
	.word	0

	/* Boot stack: 16 KiB in BSS; boot_stack_top is the high end. */
	.section .bss
	.align 16
	.globl	boot_stack
boot_stack:
	.skip	16384
	.globl	boot_stack_top
boot_stack_top:

	/* SMP: a 16 KiB stack for the secondary hart. */
	.align 16
	.globl	secondary_stack
secondary_stack:
	.skip	16384
	.globl	secondary_stack_top
secondary_stack_top:
