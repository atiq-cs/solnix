/*
 * solnix-pkg.ld -- link script for userland PACKAGES built with solnix-cc against
 * newlib. Same base and symbols as uts/user/newlib.ld (0x40010000, Sv39 slot 1,
 * medlow reach; __global_pointer$, __bss_start, _end), but with TWO PT_LOAD
 * segments -- text R+X, data R+W -- instead of one RWX segment.
 *
 * Why: (1) W^X for userland; (2) the single RWX segment makes ld warn, and
 * configure scripts that link with --fatal-warnings (dash's) then mis-detect
 * every libc function as missing.
 *
 * The data segment starts on a fresh page: uts/as.c as_map() gives every PT_LOAD
 * its OWN freshly allocated pages, so two segments sharing a page would have the
 * second overwrite the first's mapping. Do not let segments share a page.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
	text PT_LOAD FILEHDR PHDRS FLAGS(5);	/* R X */
	data PT_LOAD FLAGS(6);			/* R W */
}

SECTIONS
{
	. = 0x40010000 + SIZEOF_HEADERS;

	.text : {
		*(.text.init)
		*(.text.unlikely .text.unlikely.*)
		*(.text.startup .text.startup.*)
		*(.text .text.*)
	} :text

	.rodata : {
		*(.rodata .rodata.*)
		*(.srodata .srodata.*)
	} :text

	. = ALIGN(0x1000);

	.preinit_array : {
		PROVIDE_HIDDEN(__preinit_array_start = .);
		KEEP(*(.preinit_array))
		PROVIDE_HIDDEN(__preinit_array_end = .);
	} :data
	.init_array : {
		PROVIDE_HIDDEN(__init_array_start = .);
		KEEP(*(SORT(.init_array.*)))
		KEEP(*(.init_array))
		PROVIDE_HIDDEN(__init_array_end = .);
	} :data
	.fini_array : {
		PROVIDE_HIDDEN(__fini_array_start = .);
		KEEP(*(SORT(.fini_array.*)))
		KEEP(*(.fini_array))
		PROVIDE_HIDDEN(__fini_array_end = .);
	} :data

	.data : { *(.data .data.*) } :data

	.sdata : {
		PROVIDE(__global_pointer$ = . + 0x800);
		*(.sdata .sdata.*)
	} :data

	__bss_start = .;
	.sbss : { *(.sbss .sbss.*) *(.scommon) } :data
	.bss : { *(.bss .bss.*) *(COMMON) } :data
	. = ALIGN(16);
	_end = .;
	PROVIDE(end = .);

	/DISCARD/ : {
		*(.comment)
		*(.note*)
		*(.riscv.attributes)
		*(.eh_frame*)
		*(.debug*)
	}
}
