/*
 * start.S -- R-P64 harness entry: park secondary harts, set a stack, zero bss,
 * jump to gpu_main.  M-mode entry under qemu-system-riscv64 -bios none -kernel.
 */
	.section .text.start, "ax"
	.globl _start
_start:
	csrr	t0, mhartid
	bnez	t0, park		/* keep only hart 0 */

	la	sp, stack_top

	/* zero .bss (framebuffer + virtqueue rings live here). */
	la	t0, __bss_start
	la	t1, __bss_end
1:	bgeu	t0, t1, 2f
	sd	zero, 0(t0)
	addi	t0, t0, 8
	j	1b
2:
	call	gpu_main
	/* gpu_main powers off; if it returns, park. */
park:
	wfi
	j	park

	.section .bss
	.align 12
	.space 0x10000			/* 64 KiB stack */
	.globl stack_top
stack_top:
