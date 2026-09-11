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
 * every RISC-V platform, and the two SpacemiT SoCs this tree targets disagree
 * with each other as well as with qemu:
 *
 *   qemu virt    DRAM 0x80000000..            (OpenSBI at base, payload +2 MiB)
 *   SpacemiT K1  DRAM 0x0..0x80000000, then SoC MMIO in the 2-4 GiB window
 *                (uart0 0xd4017000, PLIC 0xe0000000, CLINT 0xe4000000).
 *                Mainline U-Boot arch/riscv/cpu/k1/dram.c: gd->ram_base = 0x0,
 *                bank 0 capped at 2 GiB. 0x80200000 is a HOLE here.
 *   SpacemiT K3  DRAM 0x102000000..0x900000000 (32.0 GiB). There is NO memory
 *                below 0x102000000 at all, so BOTH 0x80200000 and the K1's low
 *                DRAM are holes. Measured from the board's own devicetree
 *                (memory@102000000, reg = <0x01 0x2000000 0x07 0xfe000000>),
 *                not inferred: see docs/k3-vendor-dtb-findings.md.
 *
 * So there is no single correct default; each board supplies its own KBASE via
 * its build script (build-k1-payload.sh, build-k3-payload.sh). The default
 * stays 0x80200000 so the qemu-virt gates are byte-identical.
 *
 * Note 0x102000000 is 32 MiB ABOVE the 4 GiB line, not 4 GiB exactly, so a
 * "link at 4 GiB" shortcut lands in the same hole as 0x80200000.
 */
BASE = DEFINED(KBASE) ? KBASE : 0x80200000;

/*
 * DRAM_BASE — the START of the DRAM bank the firmware reports, which is NOT
 * the same thing as our link address and matters for exactly one value: the
 * Image header's text_offset (see below).
 *
 * Defaults to 0 because that is qemu-virt's AND the K1's gd->ram_base, so the
 * default keeps both of those paths byte-identical.
 */
DRAM_BASE = DEFINED(KDRAM_BASE) ? KDRAM_BASE : 0x0;

MEMORY
{
	/* RAM from the payload base up; qemu virt default has >=128M total.
	 * Kept (rather than dropped) so an over-large kernel still fails the link
	 * instead of silently overflowing the region. */
	RAM (rwxa) : ORIGIN = DEFINED(KBASE) ? KBASE : 0x80200000, LENGTH = 120M
}

/*
 * text_offset must be an offset FROM the DRAM base, not an absolute address,
 * because U-Boot's arch/riscv/lib/image.c booti_setup() relocates the image to
 * gd->ram_base + text_offset.
 *
 * This was `_image_text_offset = BASE`, i.e. absolute — which is correct only
 * while gd->ram_base is 0. It is 0 on qemu virt and on the K1, so the bug was
 * invisible and stayed invisible through 8/8 gate passes. On the K3
 * gd->ram_base is 0x102000000, so an absolute text_offset of 0x102200000 would
 * relocate the image to 0x204200000 — ~4 GiB past where it was linked, whose
 * absolute-addressed code and data would then all be wrong.
 *
 * BASE - DRAM_BASE is the offset within the bank (K3: 0x200000), and
 * gd->ram_base + 0x200000 == 0x102200000 == BASE. With DRAM_BASE defaulting to
 * 0 this expression reduces to the old value on qemu and the K1.
 *
 * The same premise-drift caught image_header.S:23-27, whose comment correctly
 * documented "K1's gd->ram_base is 0x0" — correct code resting on a documented
 * premise that a new board silently invalidated.
 */
TEXT_OFFSET = BASE - DRAM_BASE;

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
	 * gd->ram_base to decide where to relocate the image, so it is an OFFSET
	 * FROM DRAM_BASE, not the absolute link address (see TEXT_OFFSET above).
	 * Taking both from the linker keeps them consistent by construction.
	 * image_size covers BSS so U-Boot's lmb reservation does not hand our BSS
	 * out to something else.
	 */
	_image_text_offset = TEXT_OFFSET;
	_image_size = _end - BASE;

	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) *(.riscv.attributes) }
}
