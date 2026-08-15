/*
 * user_elf.S -- R-P26: embed the two static riscv64-solaris userland ELFs
 * (the forker + the exec target execee) into the kernel image via .incbin,
 * exposing user_elf_start/user_elf_end (forker) and execee_elf_start/
 * execee_elf_end (execee) so exec_image() can map either program's PT_LOAD
 * segments into a fresh user address space.  This is the anti-wedge substrate:
 * no filesystem / boot loader needed to get the process bytes -- they ride in
 * the kernel .rodata.
 *
 * CRIB PROVENANCE: embedding an init/user payload in the kernel image via
 * .incbin (rather than a root filesystem) is the classic "linked-in init"
 * bring-up idiom (Linux initramfs-in-kernel, illumos boot_archive-less bring-up).
 */
	.section .rodata
	.balign 16
	.globl	user_elf_start
user_elf_start:
	.incbin	"forker.bin"
	.globl	user_elf_end
user_elf_end:

	.balign 16
	.globl	execee_elf_start
execee_elf_start:
	.incbin	"execee.bin"
	.globl	execee_elf_end
execee_elf_end:
