/*
 * locore.S — illumos riscv64 machine-dependent kernel entry (R-P2).
 *
 * FIRST illumos RISC-V kernel instructions. This is the supervisor-mode (S-mode)
 * entry point reached from OpenSBI (the M-mode firmware / SBI runtime) on
 * qemu-system-riscv64 -machine virt. It is the riscv64 analog of
 * uts/i86pc/ml/locore.s and richlowe/arm64-gate uts/aarch64/ml/locore.s:
 * establish a boot stack, clear BSS, and hand off to C (mlsetup -> main).
 *
 * ---------------------------------------------------------------------------
 * S-MODE ENTRY CONTRACT (established here; the reusable R-P2 foundation)
 * ---------------------------------------------------------------------------
 * OpenSBI, after M-mode firmware init, jumps to the S-mode payload (this ELF)
 * per the SBI/OpenSBI boot convention:
 *
 *   - Privilege:   Supervisor (S-mode). M-mode is owned by OpenSBI; we never
 *                  touch mhartid/mstatus/etc. All firmware services (console,
 *                  timer, IPI, hart start) go through the SBI ecall ABI.
 *   - Load addr:   0x80200000 (OpenSBI's default S-mode payload / "jump" addr;
 *                  OpenSBI firmware itself occupies 0x80000000..~0x80080000).
 *                  Our linker script (riscv.ld) links _start there.
 *   - a0 = hartid  (the boot hart's ID; NOT necessarily 0)
 *   - a1 = dtb     (physical address of the flattened devicetree blob)
 *   - satp = 0     (MMU off / bare mode; we run on physical addresses until the
 *                  HAT/Sv39 work in R-P3 turns paging on)
 *   - sstatus.SIE  clear (S-mode interrupts disabled)
 *
 * We must preserve a0/a1 across the stack + BSS setup so C main() gets
 * (hartid, dtb). This mirrors how uts/aarch64 locore preserves x0 (the DTB
 * pointer) from u-boot/EFI into mlsetup.
 * ---------------------------------------------------------------------------
 *
 * ISA: rv64imac + zicsr (CSR access for stvec/sstatus in later phases; here we
 * only read/keep the boot regs and park secondary harts in wfi).
 *
 * NOTE ON SECONDARY HARTS: under OpenSBI's default (fw_dynamic) boot, only the
 * boot hart is released to the S-mode payload; other harts remain parked in
 * firmware until brought up via the SBI HSM extension (sbi_hart_start), which
 * is R-P4 work. We still install a defensive park loop keyed on a global
 * "boot hart claimed" flag so that if a platform releases all harts here, only
 * the first arrival proceeds and the rest spin in wfi. (qemu virt default is
 * a single hart, so this is belt-and-suspenders for the R-P4 SMP path.)
 */

	.section .text.start, "ax"
	.globl _start
	.type _start, @function
_start:
	/*
	 * Disable S-mode interrupts until traps are wired up (R-P3). We enter
	 * with them off per the contract, but be explicit — a stray timer/soft
	 * interrupt before stvec is set would fault into a garbage handler.
	 */
	csrci	sstatus, 0x2		/* clear sstatus.SIE (bit 1) */
	csrw	sie, zero		/* mask all S-mode interrupt sources */

	/*
	 * Claim boot-hart status atomically. Only the first hart to swap 1 into
	 * hart_claimed proceeds; any others park. Preserves a0(hartid)/a1(dtb).
	 */
	la	t0, hart_claimed
	li	t1, 1
	amoswap.w.aq t2, t1, (t0)	/* t2 = old value; t0-> now 1 */
	bnez	t2, park		/* someone already claimed -> park */

	/*
	 * Establish the boot stack. RISC-V stacks are full-descending and the
	 * ABI requires sp 16-byte aligned. boot_stack_top is the top of a BSS
	 * region reserved below.
	 */
	la	sp, boot_stack_top
	andi	sp, sp, ~15		/* enforce 16-byte alignment */

	/*
	 * Zero the BSS ( __bss_start .. __bss_end ), 8 bytes at a time. C code
	 * (and the banner's static data path) assumes a clean BSS. Note:
	 * hart_claimed lives in .data (already initialized), NOT .bss, so this
	 * does not clobber our claim.
	 */
	la	t0, __bss_start
	la	t1, __bss_end
1:
	bgeu	t0, t1, 2f
	sd	zero, 0(t0)
	addi	t0, t0, 8
	j	1b
2:

	/*
	 * Set up a trap vector early so a fault during bring-up lands somewhere
	 * deterministic instead of looping in firmware. stvec is Direct mode
	 * (low 2 bits = 0): all traps jump to trap_park. Real trap handling is
	 * R-P3; this is just a safety net that halts loudly-quietly.
	 */
	la	t0, trap_park
	csrw	stvec, t0

	/*
	 * Hand off to C. a0=hartid, a1=dtb are still live (we clobbered only
	 * t0-t2, sp). C prototype:  void mlsetup(uint64_t hartid, uint64_t dtb);
	 * mlsetup does the R-P3 machine-dependent bring-up (trap vector, Sv39
	 * paging, timer) then enters main(). It must not return; if it does,
	 * park.
	 */
	call	mlsetup

	/* mlsetup()/main() should never return. If it does, fall into park. */
park:
	wfi
	j	park

	/*
	 * trap_park: minimal S-mode trap landing pad. In R-P2 we have no trap
	 * frame / dispatch yet, so any synchronous exception or interrupt that
	 * reaches here simply halts. R-P3 replaces this with a real trap vector
	 * that saves a frame and calls trap(). Kept 4-byte aligned (stvec low
	 * bits must be 0 in Direct mode).
	 */
	.align 2
	.globl trap_park
	.type trap_park, @function
trap_park:
	wfi
	j	trap_park

	.size _start, . - _start

	/*
	 * ---------------------------------------------------------------------
	 * _secondary_start — SBI HSM secondary-hart entry (R-P4 SMP).
	 * ---------------------------------------------------------------------
	 * The boot hart calls sbi_hart_start(hartid, PA(_secondary_start),
	 * opaque) for each secondary. OpenSBI releases that hart into S-mode
	 * here with:
	 *   a0 = hartid   (this hart's id)
	 *   a1 = opaque   (we pass the hart's assigned per-cpu stack TOP)
	 *   satp = 0      (bare; VA==PA — and _secondary_start's PA is inside the
	 *                 identity-mapped kernel gigapage, so this label resolves
	 *                 the same before and after we load the shared satp)
	 *   sstatus.SIE clear
	 *
	 * Each secondary: masks interrupts, adopts the assigned stack, loads the
	 * SHARED kernel page table (the boot hart published its satp in
	 * kernel_satp before starting us), sfence.vma, then calls C
	 * secondary_main(hartid). It must not return; if it does, park.
	 *
	 * NOTE: BSS is already cleared by the boot hart; secondaries must NOT
	 * clear it again (that would wipe live kernel state).
	 */
	.section .text
	.align 2
	.globl _secondary_start
	.type _secondary_start, @function
_secondary_start:
	csrci	sstatus, 0x2		/* clear sstatus.SIE */
	csrw	sie, zero		/* mask all S-mode interrupt sources */

	/* Adopt the per-cpu stack top handed to us in a1 (opaque). */
	mv	sp, a1
	andi	sp, sp, ~15		/* enforce 16-byte alignment */

	/* Install the real trap vector on this hart too (Direct mode). */
	la	t0, _trap_entry
	csrw	stvec, t0

	/*
	 * Load the SHARED kernel page table. The boot hart stored its live
	 * satp (MODE=Sv39, root PT PPN) into kernel_satp before starting us, so
	 * every hart walks the same tables. sfence.vma flushes this hart's TLB.
	 */
	la	t0, kernel_satp
	ld	t1, 0(t0)
	csrw	satp, t1
	sfence.vma

	/* Hand off to C: void secondary_main(uint64_t hartid). a0=hartid live. */
	call	secondary_main

	/* secondary_main must not return. Park if it does. */
1:	wfi
	j	1b

	.size _secondary_start, . - _secondary_start

	/*
	 * hart_claimed: boot-hart election flag. In .data (initialized to 0) so
	 * the BSS clear above does not reset it after a hart has claimed. .word
	 * (32-bit) to match amoswap.w.
	 */
	.section .data
	.align 2
	.globl hart_claimed
hart_claimed:
	.word 0

	/*
	 * kernel_satp: the shared kernel page-table satp, published by the boot
	 * hart (hat_boot_init) before it starts secondaries. Each secondary
	 * loads this so all harts translate through the one root table. In
	 * .data (survives the BSS clear); 8 bytes for a 64-bit satp.
	 */
	.align 3
	.globl kernel_satp
kernel_satp:
	.dword 0

	/*
	 * Boot stack: 16 KiB in BSS. Ample for the R-P2 banner path; grows into
	 * a per-cpu stack scheme in R-P4 (SMP). boot_stack_top is the high end.
	 */
	.section .bss
	.align 16
	.globl boot_stack
boot_stack:
	.skip 16384
	.globl boot_stack_top
boot_stack_top:

	/*
	 * Per-secondary-hart boot stacks (R-P4 SMP). One 16 KiB stack per
	 * possible secondary hart (MAXCPU-1). The boot hart uses boot_stack;
	 * secondaries are handed secondary_stacks[i]+16384 as their sp via the
	 * SBI hart_start opaque arg.
	 *
	 * MUST stay in step with MAXCPU in main.c and proc.c. Sized for the
	 * SpacemiT K3's 16 harts (15 secondaries = 240 KiB of BSS); qemu virt
	 * -smp 4..8 simply uses fewer of them.
	 */
	.align 16
	.globl secondary_stacks
secondary_stacks:
	.skip 16384 * 15		/* MAXCPU(16) - 1 boot hart */
