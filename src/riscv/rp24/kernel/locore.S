/*
 * locore.S -- illumos riscv64 machine-dependent kernel entry, R-P23 skeleton.
 *
 * This is the R-P23 headline: the illumos-MD kernel entry sequence built with
 * the NATIVE riscv64-unknown-solaris2.11 toolchain (the R-P22 solaris-target
 * gcc + the R-P17 binutils), producing an EM_RISCV kernel ELF that OpenSBI
 * boots on qemu-system-riscv64 -machine virt.  Where R-P22 ran a standalone
 * hello, this runs the actual illumos startup path:
 *
 *   OpenSBI (M-mode) -> _start (S-mode, here)
 *     mask S-mode interrupts, claim the boot hart, establish the boot stack,
 *     zero BSS, install the real trap vector (stvec -> _trap_entry), then
 *     call mlsetup(hartid, dtb) -- the machine-dependent bring-up -- which
 *     returns into main() (the illumos banner) and never returns; the boot
 *     hart falls into the idle loop (wfi).
 *
 * S-MODE ENTRY CONTRACT (OpenSBI fw_dynamic -> S-mode payload on qemu virt):
 *   Privilege : Supervisor.  M-mode is OpenSBI's; all firmware services
 *               (console/timer/HSM/reset) go through the SBI ecall ABI.
 *   Load addr : 0x80200000 (OpenSBI's default S-mode payload jump address;
 *               riscv.lds links _start there).
 *   a0 = hartid, a1 = dtb (flattened devicetree phys addr).
 *   satp = 0 (bare mode; we run on physical addresses -- Sv39 paging is R-P24).
 *   sstatus.SIE clear.
 *
 * We preserve a0/a1 across stack + BSS setup so mlsetup() gets (hartid, dtb).
 *
 * CRIB PROVENANCE: the "mask ints, claim boot hart via amoswap, set sp, clear
 * BSS, install stvec, call mlsetup" shape is the R-P2..R-P16 uts/riscv64
 * locore.S (this repo) + uts/i86pc/ml/locore.s + richlowe arm64-gate
 * uts/aarch64/ml/locore.s; the S-mode entry register contract + 0x80200000
 * payload address is the OpenSBI + qemu-virt boot convention; the trap frame
 * layout uses the genassym regs_r_* offsets (assym.h) shared with the R-P22
 * mach_trap.S.
 */

#include "assym.h"

	.section .text.start, "ax", @progbits
	.globl	_start
	.type	_start, @function
_start:
	/* Enter with S-mode interrupts off per the contract; be explicit. */
	csrci	sstatus, 0x2		/* clear sstatus.SIE (bit 1) */
	csrw	sie, zero		/* mask all S-mode interrupt sources */

	/* set up the global pointer (relaxation off around the la) */
.option push
.option norelax
	la	gp, __global_pointer$
.option pop

	/*
	 * Claim boot-hart status atomically.  Only the first hart to swap 1
	 * into hart_claimed proceeds; any others park.  Preserves a0/a1.
	 */
	la	t0, hart_claimed
	li	t1, 1
	amoswap.w.aq t2, t1, (t0)
	bnez	t2, park

	/* Establish the boot stack (full-descending, 16-byte aligned). */
	la	sp, boot_stack_top
	andi	sp, sp, ~15

	/* Zero BSS ( __bss_start .. __bss_end ), 8 bytes at a time. */
	la	t0, __bss_start
	la	t1, __bss_end
1:	bgeu	t0, t1, 2f
	sd	zero, 0(t0)
	addi	t0, t0, 8
	j	1b
2:

	/*
	 * Install the real S-mode trap vector (Direct mode; low 2 bits 0) so a
	 * fault during bring-up lands in _trap_entry -> rv_trap_dispatch, not a
	 * garbage handler.  This is the R-P22.3 mach_trap.S dispatcher wired in.
	 */
	la	t0, _trap_entry
	csrw	stvec, t0

	/*
	 * Hand off to C.  a0=hartid, a1=dtb still live (we clobbered only
	 * t0-t2, sp, gp).  mlsetup does the MD bring-up then enters main();
	 * neither returns.  If mlsetup returns, park.
	 */
	call	mlsetup

park:
	wfi
	j	park
	.size	_start, . - _start

	/*
	 * _trap_entry -- the stvec landing pad.  Direct mode sends every trap
	 * here; we jump into the R-P22.3 rv_trap_dispatch (save frame, decode
	 * scause, dispatch interrupt/syscall/synchronous C handlers, restore,
	 * sret).  Kept 4-byte aligned (stvec Direct mode requires low bits 0).
	 */
	.section .text
	.align 2
	.globl	_trap_entry
	.type	_trap_entry, @function
_trap_entry:
	j	rv_trap_dispatch
	.size	_trap_entry, . - _trap_entry

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
