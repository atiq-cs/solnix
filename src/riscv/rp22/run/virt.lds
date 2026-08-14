/*
 * Link script for a qemu-system-riscv64 -machine virt payload.  OpenSBI
 * fw_dynamic relocates itself into the low part of DRAM (0x80000000) and
 * jumps to the supervisor payload at 0x80200000.  Crib: the qemu-virt DRAM
 * base (0x80000000) + the conventional OpenSBI 2 MiB payload offset.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
	. = 0x80200000;
	.text : {
		*(.text.init)
		*(.text .text.*)
	}
	. = ALIGN(16);
	.rodata : { *(.rodata .rodata.*) }
	. = ALIGN(16);
	.data : { *(.data .data.*) *(.sdata .sdata.*) }
	. = ALIGN(16);
	__global_pointer$ = . + 0x800;
	.bss : {
		__bss_start = .;
		*(.sbss .sbss.*)
		*(.bss .bss.*)
		*(COMMON)
		. = ALIGN(16);
		__bss_end = .;
	}
	. = ALIGN(16);
	. = . + 0x4000;   /* 16 KiB boot stack */
	__boot_stack_top = .;
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) }
}
