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

	/*
	 * _rtld_bind -- R-P31.2 LAZY-binding trampoline.  The standard riscv
	 * PLT0 header jumps HERE (via .got.plt[0], which rtld_main set to this
	 * address) on the FIRST call to any unbound PLT entry, with:
	 *   t0 = .got.plt[1]  = the identifier rtld_main stored (the app lobj*)
	 *   t1 = (retaddr - PLT0 - 44) >> 1 = N*8, the reloc arg for entry N
	 *   a0..a7, fa0..fa7 = the REAL arguments to the target function
	 * We must preserve every argument register, call the C resolver
	 *   rtld_bind(id = t0, reloc_arg = t1)
	 * which resolves symbol N, patches .got.plt[2+N], and returns the target
	 * function address in a0; then restore the argument registers and tail-
	 * jump to the resolved function so the original call proceeds.  The
	 * SECOND call finds the patched GOT slot and never reaches here.
	 *
	 * CRIB PROVENANCE: the resolver trampoline saving the argument registers,
	 * calling the C binder with (link-map, reloc-index), then jumping to the
	 * resolved address is glibc sysdeps/riscv _dl_runtime_resolve +
	 * illumos ld.so.1 elf_rtbndr (usr/src/cmd/sgs/rtld/riscv...); the exact
	 * (t0=id, t1=reloc-arg) hand-off is the binutils riscv PLT0 contract.
	 */
	.align 2
	.globl	_rtld_bind
	.type	_rtld_bind, @function
_rtld_bind:
	addi	sp, sp, -160
	/* save the integer argument registers + ra. */
	sd	ra, 0(sp)
	sd	a0, 8(sp)
	sd	a1, 16(sp)
	sd	a2, 24(sp)
	sd	a3, 32(sp)
	sd	a4, 40(sp)
	sd	a5, 48(sp)
	sd	a6, 56(sp)
	sd	a7, 64(sp)
	/* save the FP argument registers (lp64d passes FP args in fa0..fa7). */
	fsd	fa0, 72(sp)
	fsd	fa1, 80(sp)
	fsd	fa2, 88(sp)
	fsd	fa3, 96(sp)
	fsd	fa4, 104(sp)
	fsd	fa5, 112(sp)
	fsd	fa6, 120(sp)
	fsd	fa7, 128(sp)
	/* resolve: a0 = id (t0), a1 = reloc arg (t1). */
	mv	a0, t0
	mv	a1, t1
	call	rtld_bind		/* returns the target addr in a0 */
	mv	t3, a0			/* stash the resolved target */
	/* restore the argument registers. */
	ld	ra, 0(sp)
	ld	a0, 8(sp)
	ld	a1, 16(sp)
	ld	a2, 24(sp)
	ld	a3, 32(sp)
	ld	a4, 40(sp)
	ld	a5, 48(sp)
	ld	a6, 56(sp)
	ld	a7, 64(sp)
	fld	fa0, 72(sp)
	fld	fa1, 80(sp)
	fld	fa2, 88(sp)
	fld	fa3, 96(sp)
	fld	fa4, 104(sp)
	fld	fa5, 112(sp)
	fld	fa6, 120(sp)
	fld	fa7, 128(sp)
	addi	sp, sp, 160
	jr	t3			/* tail-call the resolved function */
	.size	_rtld_bind, . - _rtld_bind
