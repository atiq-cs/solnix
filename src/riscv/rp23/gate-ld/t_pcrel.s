/*
 * t_pcrel.s -- a real riscv64 test object for the R-P23 ldmin driver: an
 * auipc/addi %pcrel_hi/%pcrel_lo pair that loads the address of a .text-local
 * datum (kept in .text so a single-section link at one address resolves it
 * identically under both ldmin and GNU ld).  The R-P22 toolchain assembles it
 * to an EM_RISCV .o with R_RISCV_PCREL_HI20 + R_RISCV_PCREL_LO12_I relocs;
 * ldmin links it through the illumos backend, GNU ld links the same object at
 * the same address, and the relocated .text bytes are diffed byte-for-byte.
 */
	.text
	.option norvc			/* keep 4-byte insns for a stable diff */
	.globl	load_addr
	.type	load_addr, @function
load_addr:
.Lpcrel_hi0:
	auipc	a5, %pcrel_hi(target)		/* R_RISCV_PCREL_HI20 */
	addi	a5, a5, %pcrel_lo(.Lpcrel_hi0)	/* R_RISCV_PCREL_LO12_I */
	ret
	.size	load_addr, . - load_addr

	.align 3
	.globl	target
	.type	target, @object
target:
	.dword	0x1122334455667788
	.size	target, 8
