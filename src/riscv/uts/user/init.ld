/*
 * init.ld — link script for the solnix riscv64 userland /sbin/init (R-P7).
 * Static ET_EXEC, loaded at 0xC0010000 (low-canonical Sv39 range, VPN2 slot 3
 * — a level-2 slot with NO kernel entry, so the user AS owns it entirely; the
 * kernel's identity gigapages live in slots 0/2 and the KERNELBASE tables in
 * slot 256+). One PT_LOAD covering text+rodata+data+bss. Entry = _start.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
	. = 0xC0010000;
	.text : { *(.text*) }
	.rodata : { *(.rodata*) }
	.data : { *(.data*) }
	.bss : { *(.bss*) *(COMMON) }
	/DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) }
}
