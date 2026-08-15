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

	.balign 16
	.globl	preempt_elf_start
preempt_elf_start:
	.incbin	"preempt.bin"
	.globl	preempt_elf_end
preempt_elf_end:

	.balign 16
	.globl	fsexec_elf_start
fsexec_elf_start:
	.incbin	"fsexec.bin"
	.globl	fsexec_elf_end
fsexec_elf_end:

	.balign 16
	.globl	dynexec_elf_start
dynexec_elf_start:
	.incbin	"dynexec.bin"
	.globl	dynexec_elf_end
dynexec_elf_end:

	/*
	 * R-P27: the initramfs blob -- a name+size+bytes archive (built by
	 * user/mkinitramfs.py) that ramfs.c walks to resolve exec(path).  This
	 * is the fs-backed-exec substrate: the process bytes ride in the kernel
	 * .rodata as a walkable archive, not a per-program .incbin.
	 */
	.balign 16
	.globl	initramfs_start
initramfs_start:
	.incbin	"initramfs.bin"
	.globl	initramfs_end
initramfs_end:
