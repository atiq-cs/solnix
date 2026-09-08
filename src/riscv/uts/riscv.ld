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

/*
 * OpenSBI's default S-mode payload load/jump address on qemu virt.
 *
 * OVERRIDABLE (`ld --defsym KBASE=<addr>`) because 0x80200000 is NOT DRAM on
 * every RISC-V platform. On the SpaceMiT K1 (Milk-V Jupiter / BPI-F3) DRAM is
 * 0x0..0x80000000 and the 2-4 GiB physical window is SoC MMIO (uart0
 * 0xd4017000, PLIC 0xe0000000, CLINT 0xe4000000), so 0x80200000 falls in a
 * hole: mainline U-Boot's arch/riscv/cpu/k1/dram.c sets gd->ram_base = 0x0 and
 * caps bank 0 at 2 GiB. build-k1-payload.sh therefore relinks with a KBASE
 * inside K1 DRAM. Default is unchanged, so the qemu-virt gates are unaffected.
 */
BASE = DEFINED(KBASE) ? KBASE : 0x80200000;

MEMORY
{
	/* RAM from the payload base up; qemu virt default has >=128M total.
	 * Kept (rather than dropped) so an over-large kernel still fails the link
	 * instead of silently overflowing the region. */
	RAM (rwxa) : ORIGIN = DEFINED(KBASE) ? KBASE : 0x80200000, LENGTH = 120M
}

SECTIONS
{
	. = BASE;

	.text : {
		/*
		 * The Linux RISC-V Image header (image_header.S) is byte 0 so that
		 * U-Boot `booti` accepts the image; its code0 slot is `j _start`, so
		 * entering at byte 0 still reaches _start. Firmware that honors the
		 * ELF entry (OpenSBI fw_payload, qemu -kernel) jumps straight to
		 * _start and never executes the header.
		 */
		*(.text.image_header)
		*(.text.start)		/* _start (OpenSBI's ELF-entry target) */
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

	_end = .;

	/*
	 * Fed to the Image header. text_offset is what U-Boot adds to
	 * gd->ram_base to decide where to relocate the image, so it must equal
	 * the link base; taking both from the linker keeps them consistent by
	 * construction. image_size covers BSS so U-Boot's lmb reservation does
	 * not hand our BSS out to something else.
	 */
	_image_text_offset = BASE;
	_image_size = _end - BASE;

	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) *(.riscv.attributes) }
}
