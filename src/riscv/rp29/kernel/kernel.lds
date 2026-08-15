/*
 * kernel.lds -- link the illumos riscv64 `unix` skeleton S-mode payload for
 * qemu virt.  OpenSBI (fw_dynamic) occupies RAM base 0x80000000 and jumps the
 * S-mode payload to 0x80200000; we link _start there so the jump lands on our
 * first instruction.  qemu honors the ELF program headers, so the LOAD
 * segments are placed at their p_paddr.  Entry = _start (locore.S,
 * .text.start).
 *
 * R-P29: the sections are PAGE-ALIGNED and bracketed by boundary symbols
 * (__text_start/__etext, __rodata_start/__erodata, __data_start/__end) so the
 * full HAT can map each kernel segment at high VA with per-segment R^X
 * permissions: text RX, rodata R, data/bss RW -- no page both writable and
 * executable (W^X).  4 KiB alignment lets each segment be mapped by whole 4 KiB
 * leaf PTEs with the right permission bits.
 *
 * CRIB PROVENANCE: this repo's R-P2 uts/riscv64/riscv.ld (0x80200000 base,
 * .text.start first) + the R-P22 run/virt.lds (__global_pointer$ + boot-stack
 * tail); the page-aligned per-segment layout + boundary symbols for a W^X
 * kernel map is the illumos unix.lds / i86pc hat_kern_setup segment split +
 * the RISC-V privileged-spec leaf R/W/X bits.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
	. = 0x80200000;

	__text_start = .;
	.text : {
		*(.text.start)		/* _start MUST be first (OpenSBI jumps here) */
		*(.text .text.*)
	}
	. = ALIGN(4096);
	__etext = .;

	__rodata_start = .;
	.rodata : {
		*(.rodata .rodata.*)
		*(.srodata .srodata.*)
	}
	. = ALIGN(4096);
	__erodata = .;

	__data_start = .;
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
	. = ALIGN(4096);
	__end = .;

	/DISCARD/ : {
		*(.comment) *(.note*) *(.eh_frame) *(.riscv.attributes)
	}
}
