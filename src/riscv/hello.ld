/*
 * hello.ld — link the bare-metal riscv64 hello at the qemu virt RAM base.
 *
 * qemu-system-riscv64 -machine virt places RAM at 0x80000000. With
 * `-bios none -kernel hello.elf`, harts start executing at the ELF entry
 * (_start), which we force to the very start of the image at 0x80000000.
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
		*(.text.start)		/* _start first */
		*(.text .text.*)
	} > RAM

	.rodata : { *(.rodata .rodata.*) } > RAM
	.data   : { *(.data .data.*) }     > RAM

	.bss : {
		__bss_start = .;
		*(.bss .bss.* COMMON)
		__bss_end = .;
	} > RAM

	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) }
}
