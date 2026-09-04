/*
 * harness.ld -- link the R-P64 virtio-gpu harness at the qemu-virt RAM base.
 * -bios none -kernel enters _start at 0x80000000.  RAM sized for the 4 MiB
 * framebuffer + rings in .bss.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
	RAM (rwxa) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS
{
	. = 0x80000000;

	.text : {
		*(.text.start)
		*(.text .text.*)
	} > RAM

	.rodata : { *(.rodata .rodata.*) } > RAM
	.data   : { *(.data .data.*) }     > RAM

	.bss (NOLOAD) : ALIGN(4096) {
		__bss_start = .;
		*(.bss .bss.* COMMON)
		. = ALIGN(8);
		__bss_end = .;
	} > RAM

	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) *(.riscv.attributes) }
}
