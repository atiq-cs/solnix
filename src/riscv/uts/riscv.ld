/*
 * riscv.ld — link the illumos riscv64 `unix` S-mode payload for qemu virt (R-P2).
 *
 * Under qemu-system-riscv64 -machine virt with the DEFAULT -bios (OpenSBI),
 * OpenSBI occupies the RAM base 0x80000000 and jumps the S-mode payload
 * (this kernel) to its default payload address 0x80200000. We link _start
 * there so OpenSBI's jump lands on our first instruction.
 *
 * qemu loads a `-kernel <elf>` by honoring the ELF program headers (LOAD segs
 * at their p_paddr), so linking at 0x80200000 places the image where OpenSBI
 * expects the payload. Entry = _start (locore.S, .text.start).
 *
 * This is the riscv64 analog of a uts/<platform> unix mapfile/ldscript; it is
 * intentionally flat for R-P2 (no per-module sections, no CTF/mapfile yet).
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

/* OpenSBI's default S-mode payload load/jump address on qemu virt. */
BASE = 0x80200000;

MEMORY
{
	/* RAM from the payload base up; qemu virt default has >=128M total. */
	RAM (rwxa) : ORIGIN = 0x80200000, LENGTH = 120M
}

SECTIONS
{
	. = BASE;

	.text : {
		*(.text.start)		/* _start MUST be first (OpenSBI jumps here) */
		*(.text .text.*)
	} > RAM

	.rodata : {
		. = ALIGN(8);
		*(.rodata .rodata.*)
		*(.srodata .srodata.*)
	} > RAM

	.data : {
		. = ALIGN(8);
		*(.data .data.*)
		*(.sdata .sdata.*)
	} > RAM

	.bss : {
		. = ALIGN(8);
		__bss_start = .;
		*(.sbss .sbss.*)
		*(.bss .bss.* COMMON)
		. = ALIGN(8);
		__bss_end = .;
	} > RAM

	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) *(.riscv.attributes) }
}
