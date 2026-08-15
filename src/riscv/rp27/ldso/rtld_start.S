/*
 * rtld_start.S -- R-P27: the riscv64 ld.so.1 bootstrap.  The kernel exec path,
 * on seeing the dynamic hello's PT_INTERP (/usr/lib/ld.so.1), loads BOTH the
 * application and this interpreter into the user AS and enters HERE (ld.so.1's
 * entry) in U-mode, with the psABI initial stack set up and an auxv carrying
 * AT_ENTRY (the app _start), AT_PHDR/AT_PHNUM/AT_PHENT (the app's program
 * headers) and AT_BASE (this interpreter's load base).
 *
 * _rtld_start reads sp (= &argc), calls rtld_main(sp) which relocates the app
 * + loads its DT_NEEDED objects and returns the app entry point, then jumps to
 * it with the ORIGINAL sp restored (so the app's crt _start sees argc/argv/
 * envp/auxv exactly as the psABI requires).
 *
 * CRIB PROVENANCE: an assembly entry that captures the initial sp, calls the C
 * runtime linker, and tail-jumps to the relocated executable's entry with the
 * process stack intact is the illumos ld.so.1 rtld_start / _rt_boot (usr/src/
 * cmd/sgs/rtld/riscv... modeled on amd64/sparc) + the RISC-V psABI program
 * startup (auxv on the initial stack, no register args).\n */
	.section .text
	.align 2
	.globl	_rtld_start
	.type	_rtld_start, @function
_rtld_start:
	li	ra, 0			/* mark the outermost frame */
	li	s0, 0
	mv	s1, sp			/* save the initial stack pointer */
	mv	a0, sp			/* arg0 = &argc (the initial stack) */
	call	rtld_main		/* returns the app entry VA in a0 */
	mv	t0, a0			/* app _start */
	mv	sp, s1			/* restore the psABI initial stack */
	li	ra, 0
	li	s0, 0
	li	gp, 0			/* the app crt sets its own gp */
	jr	t0			/* enter the application */
	.size	_rtld_start, . - _rtld_start
