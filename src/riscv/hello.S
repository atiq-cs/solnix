/*
 * hello.S — minimal machine-mode "hello" for qemu-system-riscv64 -machine virt.
 *
 * Proves the RISC-V bring-up substrate end to end: riscv64 cross toolchain
 * (as/ld) -> ELF -> qemu virt -> NS16550A UART @ 0x10000000 prints text.
 * This is the future illumos riscv64 port's earliest boot smoke test.
 * It is NOT an OS: no illumos riscv port exists (see docs/design-riscv-port.md).
 *
 * On `qemu-system-riscv64 -machine virt -bios none -kernel hello.elf`, all
 * harts enter at the ELF entry (linked at 0x80000000, RAM base). We keep only
 * hart 0, everything else parks in wfi.
 */
	.section .text.start, "ax"
	.globl _start
_start:
	/* Park all harts except hart 0 (mhartid == 0). */
	csrr	t0, mhartid
	bnez	t0, park

	/* Set up a small stack (top of a 4 KiB block after our code). */
	la	sp, stack_top

	/* Print the message via the 16550 UART at 0x10000000.
	 * Register x=0: THR (write byte to transmit). No FIFO setup needed on
	 * qemu's virt 16550 for basic TX; it drains immediately under emulation.
	 */
	la	a0, msg
puts_loop:
	lbu	a1, 0(a0)		/* next char */
	beqz	a1, done		/* NUL -> done */
	li	a2, 0x10000000		/* UART base (THR at offset 0) */
	sb	a1, 0(a2)		/* transmit */
	addi	a0, a0, 1
	j	puts_loop

done:
	/*
	 * Shut the machine down cleanly via the SiFive Test finisher device
	 * that qemu virt exposes at 0x100000: write 0x5555 = PASS/poweroff.
	 * (If it weren't present we'd fall through to wfi and hang; qemu virt
	 * always provides it.)
	 */
	li	t0, 0x100000
	li	t1, 0x5555
	sw	t1, 0(t0)

park:
	wfi
	j	park

	.section .rodata
msg:
	.asciz	"hello from machine mode: riscv64 qemu virt substrate OK\n"

	.section .bss
	.align 4
stack:
	.skip 4096
stack_top:
