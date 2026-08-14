/*
 * riscv64 bare-metal boot glue for qemu-system-riscv64 -machine virt.
 * OpenSBI (fw_dynamic) loads this payload at 0x80200000 and enters in
 * S-mode with a0=hartid, a1=fdt.  We set up a stack and call kmain().
 * Crib: OpenSBI FW_JUMP payload contract (riscv/opensbi docs) + the
 * illumos riscv64 R-P2 locore stack-setup idiom (sp = top of BSS stack).
 */
	.section .text.init,"ax",@progbits
	.globl _start
_start:
	/* mask interrupts, clear sstatus.SIE conceptually (S-mode entry) */
	csrw	sie, zero
	/* set up global pointer (relaxation off around this) */
.option push
.option norelax
	la	gp, __global_pointer$
.option pop
	/* stack: top of the reserved boot stack */
	la	sp, __boot_stack_top
	/* zero the BSS */
	la	t0, __bss_start
	la	t1, __bss_end
1:	bgeu	t0, t1, 2f
	sd	zero, 0(t0)
	addi	t0, t0, 8
	j	1b
2:
	/* a0=hartid, a1=fdt preserved from SBI; hand to kmain */
	call	kmain
	/* if kmain returns, spin */
3:	wfi
	j	3b
