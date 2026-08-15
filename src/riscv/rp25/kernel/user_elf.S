/*
 * user_elf.S -- R-P25: embed the static riscv64-solaris userland hello ELF
 * (rp25/user/hello_user) into the kernel image via .incbin, exposing
 * user_elf_start/user_elf_end so exec_user() can map its PT_LOAD segments into
 * a fresh user address space.  This is the anti-wedge substrate: no filesystem
 * / boot loader needed to get the process bytes -- they ride in the kernel .rodata.
 *
 * CRIB PROVENANCE: embedding an init/user payload in the kernel image via
 * .incbin (rather than a root filesystem) is the classic "linked-in init"
 * bring-up idiom (Linux initramfs-in-kernel, illumos boot_archive-less bring-up).
 */
	.section .rodata
	.balign 16
	.globl	user_elf_start
user_elf_start:
	.incbin	"user_hello.bin"
	.globl	user_elf_end
user_elf_end:
