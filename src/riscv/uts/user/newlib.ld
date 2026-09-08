/*
 * newlib.ld -- link script for solnix riscv64 programs built against the REAL
 * newlib libc.a, as opposed to init.ld which links the hand-written user/libc.c
 * slice.
 *
 * WHY A SEPARATE SCRIPT, AND WHY 0x40010000.
 *
 * newlib's shipped libc.a is compiled -mcmodel=medlow: 1547 of its text
 * relocations are absolute R_RISCV_HI20 (`lui`) against only 3 R_RISCV_PCREL_HI20.
 * medlow can only address the +/-2 GiB window around 0, i.e. [0, 0x7FFFFFFF].
 * The existing userland link base 0xC0010000 is OUTSIDE that window, so linking
 * newlib there fails at link time with a wall of
 *
 *   relocation truncated to fit: R_RISCV_HI20 against symbol `errno'
 *
 * There is exactly one multilib (`gcc -print-multi-lib` => ".;"), so no
 * medany-compiled newlib is available without rebuilding it.
 *
 * 0x40010000 is Sv39 level-2 slot 1. hat_as_newroot() copies only slots 0
 * (low MMIO), 2 (kernel RAM) and the high half 256..511 into a new user root,
 * deliberately leaving slots 1 and 3 clear for user mappings. So slot 1 is a
 * genuinely free user slot -- and unlike slot 3 it lies inside medlow's reach.
 * The boot-time ALIAS_VA proof page also sits at 0x40000000, but only in the
 * KERNEL root (never copied into a process root), so there is no collision.
 *
 * The user stack stays where the kernel puts it, at 0xfffff000 in slot 3; stack
 * access is sp-relative and needs no absolute relocation, so the split between
 * slot 1 (text/data/heap) and slot 3 (stack) is harmless.
 *
 * crt0.o requires three symbols from the script: __global_pointer$ (for the gp
 * relaxation), and __bss_start/_end (it memsets that range before calling main).
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
	. = 0x40010000;

	.text : {
		*(.text.init)
		*(.text*)
	}

	.rodata : {
		*(.rodata*)
		*(.srodata*)
	}

	/* newlib's __libc_init_array/__libc_fini_array walk these. Empty for a
	 * plain C program, but crt0 dereferences the bounds, so they must exist
	 * and be consistently ordered. */
	.preinit_array : {
		PROVIDE_HIDDEN(__preinit_array_start = .);
		KEEP(*(.preinit_array))
		PROVIDE_HIDDEN(__preinit_array_end = .);
	}
	.init_array : {
		PROVIDE_HIDDEN(__init_array_start = .);
		KEEP(*(SORT(.init_array.*)))
		KEEP(*(.init_array))
		PROVIDE_HIDDEN(__init_array_end = .);
	}
	.fini_array : {
		PROVIDE_HIDDEN(__fini_array_start = .);
		KEEP(*(SORT(.fini_array.*)))
		KEEP(*(.fini_array))
		PROVIDE_HIDDEN(__fini_array_end = .);
	}

	.data : {
		*(.data*)
	}

	/*
	 * gp points 0x800 into .sdata so the linker's gp-relative relaxation can
	 * reach the whole small-data area with a signed 12-bit offset. This is
	 * the standard riscv convention and crt0's first two instructions load it.
	 */
	.sdata : {
		PROVIDE(__global_pointer$ = . + 0x800);
		*(.sdata*)
	}

	/* crt0 zeroes [__bss_start, _end), so sbss and bss must be adjacent and
	 * bracketed by these two symbols. */
	__bss_start = .;
	.sbss : {
		*(.sbss*)
		*(.scommon)
	}
	.bss : {
		*(.bss*)
		*(COMMON)
	}
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
