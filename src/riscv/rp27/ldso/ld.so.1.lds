/*
 * ld.so.1.lds -- R-P27 riscv64 ld.so.1 link script.  ld.so.1 lives in the same
 * user address space as the application it hosts, so it must link at a base
 * that does NOT collide with the app (linked at 0x10000) or the user stack
 * (top 0x40000000).  We place it at 0x30000000: well above the app, below the
 * stack.  It is a static ET_EXEC (self-relocating is unnecessary at this base:
 * the kernel maps its PT_LOAD segments at these exact VAs), entry _rtld_start.
 */
ENTRY(_rtld_start)
SECTIONS
{
	. = 0x30000000;
	.text : { *(.text.init) *(.text) *(.text.*) }
	. = ALIGN(0x1000);
	.rodata : { *(.rodata) *(.rodata.*) }
	. = ALIGN(0x1000);
	.data : { *(.data) *(.data.*) *(.sdata) *(.sdata.*) }
	.bss : { *(.bss) *(.bss.*) *(.sbss) *(.sbss.*) *(COMMON) }
	/DISCARD/ : { *(.riscv.attributes) *(.comment) *(.note*) *(.eh_frame*) }
}
