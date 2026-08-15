/*
 * kernel.lds -- R-P30: link the illumos riscv64 `unix` S-mode payload to
 * EXECUTE at HIGH VA (KERNEL_DMAP_BASE + 0x80200000) while LOADING at the
 * physical address 0x80200000 (where OpenSBI jumps the S-mode payload on
 * qemu virt).  This is the R-P30 headline: a true high-half kernel whose
 * virtual link address != its physical load address.
 *
 * Mechanism:
 *   VMA (virtual/link address) = KADDR = KERNEL_DMAP_BASE + 0x80200000, so
 *     every symbol the kernel references resolves to a canonical Sv39 high VA.
 *   LMA (load address) = PADDR = 0x80200000, set via AT(), so the ELF program
 *     headers carry p_paddr = 0x80200000 and qemu deposits the image at the
 *     physical RAM OpenSBI hands the S-payload.  OpenSBI/qemu jump the S-mode
 *     payload to the PHYSICAL load address of the first loaded byte (verified:
 *     Domain0 Next Address == the low load address even when e_entry is high),
 *     so the physical byte at 0x80200000 -- _start (.text.start) -- runs first,
 *     in bare mode (satp=0), position-independently (medany PC-relative).
 *
 *   _start (locore.S) therefore runs at PHYSICAL 0x80200000: it builds the Sv39
 *   boot tables (identity map of the low physical window to survive the satp
 *   flip + the kernel HIGH mapping + the direct-map), enables paging, then JUMPS
 *   PC to the high VA of _start_high -- from there the kernel runs purely at
 *   high VA and drops the low identity map.
 *
 * The sections stay PAGE-ALIGNED + bracketed by boundary symbols
 * (__text_start/__etext, __rodata_start/__erodata, __data_start/__end) for the
 * per-segment W^X HAT (text RX, rodata R, data/bss RW).
 *
 * CRIB PROVENANCE: the VMA-high / LMA-low split via AT() is the standard GNU ld
 * high-half-kernel idiom (Linux vmlinux.lds.S _text at PAGE_OFFSET, load_addr
 * via AT; illumos i86pc unix linked at KERNELBASE loaded low); _start-at-load-
 * address-first is this repo's R-P2 riscv.ld + the OpenSBI/qemu-virt S-payload
 * convention; the page-aligned per-segment layout + boundary symbols for a W^X
 * kernel map is the illumos unix.lds / i86pc hat_kern_setup segment split.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

/* physical load address (OpenSBI S-payload) and the high virtual link base. */
PADDR = 0x80200000;
KADDR = 0xffffffc000000000 + 0x80200000;
LOAD_OFFSET = KADDR - PADDR;	/* VMA - LMA (the direct-map bias) */

SECTIONS
{
	. = KADDR;

	__text_start = .;
	.text : AT(ADDR(.text) - LOAD_OFFSET) {
		*(.text.start)		/* _start MUST be first (loads at PADDR) */
		*(.text .text.*)
	}
	. = ALIGN(4096);
	__etext = .;

	__rodata_start = .;
	.rodata : AT(ADDR(.rodata) - LOAD_OFFSET) {
		*(.rodata .rodata.*)
		*(.srodata .srodata.*)
	}
	. = ALIGN(4096);
	__erodata = .;

	__data_start = .;
	.data : AT(ADDR(.data) - LOAD_OFFSET) {
		*(.data .data.*)
		*(.sdata .sdata.*)
	}

	. = ALIGN(8);
	__global_pointer$ = . + 0x800;

	.bss : AT(ADDR(.bss) - LOAD_OFFSET) {
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
