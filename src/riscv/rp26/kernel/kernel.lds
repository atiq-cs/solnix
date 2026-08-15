/*
 * kernel.lds -- link the illumos riscv64 `unix` skeleton S-mode payload for
 * qemu virt (R-P23).  OpenSBI (fw_dynamic) occupies RAM base 0x80000000 and
 * jumps the S-mode payload to 0x80200000; we link _start there so the jump
 * lands on our first instruction.  qemu honors the ELF program headers, so the
 * LOAD segments are placed at their p_paddr.  Entry = _start (locore.S,
 * .text.start).
 *
 * CRIB PROVENANCE: this repo's R-P2 uts/riscv64/riscv.ld (0x80200000 base,
 * .text.start first, discard notes/attributes) + the R-P22 run/virt.lds
 * (__global_pointer$ + boot-stack tail) -- merged into one native kernel
 * ldscript.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
	. = 0x80200000;

	.text : {
		*(.text.start)		/* _start MUST be first (OpenSBI jumps here) */
		*(.text .text.*)
	}

	. = ALIGN(8);
	.rodata : {
		*(.rodata .rodata.*)
		*(.srodata .srodata.*)
	}

	. = ALIGN(8);
	.data : {
		*(.data .data.*)
		*(.sdata .sdata.*)
	}

	. = ALIGN(8);
	__global_pointer$ = . + 0x800;

	.bss : {
		. = ALIGN(4096);	/* page tables + boot heap need PAGESIZE align */
		__bss_start = .;
		*(.sbss .sbss.*)
		*(.bss .bss.* COMMON)
		. = ALIGN(8);
		__bss_end = .;
	}

	/DISCARD/ : {
		*(.comment) *(.note*) *(.eh_frame) *(.riscv.attributes)
	}
}
