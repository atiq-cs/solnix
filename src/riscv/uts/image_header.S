/*
 * image_header.S — the Linux RISC-V "Image" header (arch/riscv/include/asm/image.h),
 * emitted as the first 64 bytes of the linked kernel.
 *
 * WHY this exists: U-Boot's riscv `booti` is the only boot command on the
 * SpaceMiT K1's mainline U-Boot that passes the (a0=hartid, a1=dtb) ABI
 * locore.S expects -- and booti_setup() in U-Boot's arch/riscv/lib/image.c
 * REJECTS any image whose magic at offset 0x38 is not 0x05435352 ("RSC\x05")
 * with "Bad Linux RISCV Image magic!". A raw ELF therefore cannot be booted
 * with booti, and a raw flat binary cannot either.
 *
 * The header is placed FIRST in .text (see riscv.ld .text.image_header) and its
 * code0 slot is a real instruction that jumps to _start, so the image is
 * executable from byte 0 as well as via the ELF entry point:
 *
 *   - `booti` (U-Boot, K1 silicon): relocates the flat image to
 *     gd->ram_base + text_offset, then calls it at offset 0 -> `j _start`.
 *   - OpenSBI fw_payload / qemu -kernel: jumps to the ELF e_entry, which is
 *     _start itself, so the header is simply never executed. It is inert on
 *     the paths that do not need it, which is why adding it cannot regress the
 *     qemu gates.
 *
 * text_offset is an OFFSET FROM THE DRAM BASE, not an absolute address,
 * because booti_setup() computes the relocation target as
 * gd->ram_base + text_offset. riscv.ld computes it as BASE - DRAM_BASE and
 * both values come from the linker, so they cannot drift apart from the link.
 *
 * ⚠️ This comment previously said text_offset "must equal the address riscv.ld
 * linked the image at ... and K1's gd->ram_base is 0x0". That was correct code
 * resting on a correctly-documented premise -- and the premise silently stopped
 * holding when a second board appeared. The SpacemiT K3's gd->ram_base is
 * 0x102000000 (DRAM 0x102000000..0x900000000, measured; see
 * docs/k3-vendor-dtb-findings.md), so an absolute text_offset relocates the
 * image ~4 GiB past where it was linked. Neither qemu virt nor the K1 can
 * expose this, because gd->ram_base is 0 on both -- which is why it survived
 * every gate.
 */

	.section .text.image_header, "ax"
	.globl _image_header
_image_header:
	j	_start			/* code0: 4 bytes, jumps past the header */
	.word	0			/* code1 (unused; the j above is 4 B) */
	.quad	_image_text_offset	/* text_offset: link base - DRAM base */
	.quad	_image_size		/* image_size: bytes to relocate/reserve */
	.quad	0			/* flags: 0 = LE, no constraints */
	.word	2			/* version 0.2 (major<<16 | minor) */
	.word	0			/* res1 */
	.quad	0			/* res2 */
	.quad	0			/* res3 */
	.word	0x05435352		/* magic "RSC\x05" @ offset 0x38 */
	.word	0			/* res4 */
	.size	_image_header, . - _image_header
