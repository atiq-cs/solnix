/*
 * fpsave.S - move the riscv64 FP register file to and from memory.
 *
 * WHY NOT float.s. illumos-gate's usr/src/uts/riscv64/ml/float.s was imported
 * into this tree but is not buildable here: it needs <sys/asm_linkage.h> for its
 * ENTRY/SET_SIZE macros and a generated assym.h for FPU_CTX_* offsets, neither
 * of which this port has. Rather than import that machinery for two routines,
 * this file is written in the same plain idiom as swtch.S and locore.S, with the
 * offsets as literals that fp.c proves at compile time (_Static_assert on
 * offsetof) -- so a layout drift breaks the build rather than corrupting state.
 *
 * WHY ITS OWN -march. The kernel is compiled SOFT-FLOAT
 * (-march=rv64imac_zicsr_zifencei) and must stay that way: it contains no FP
 * code of its own, which is exactly what makes lazy FP handling safe. But these
 * two routines are the one place that must emit fsd/fld/frcsr/fscsr, so this
 * file alone is assembled with the F and D extensions enabled. Assembling it
 * with the kernel's soft-float -march fails outright with "extension `d'
 * required", which is how this was found.
 *
 * The caller (fp.c) guarantees sstatus.FS is not Off before calling either
 * routine -- with the FPU disabled every instruction below would trap.
 *
 * struct fpu_ctx layout, asserted in fp.c:
 *	offset 0	f0..f31, 8 bytes each	(FPU_CTX_FPU_REGS)
 *	offset 256	fcsr			(FPU_CTX_FPU_CSR)
 */

	.option arch, +f, +d

#define	FPU_REGS	0
#define	FPU_CSR		256

/*
 * void _fpu_save(fpu_ctx_t *ctx)   -- a0 = ctx
 */
	.text
	.globl _fpu_save
	.type _fpu_save, @function
_fpu_save:
	fsd	f0,  (FPU_REGS + 0 * 8)(a0)
	fsd	f1,  (FPU_REGS + 1 * 8)(a0)
	fsd	f2,  (FPU_REGS + 2 * 8)(a0)
	fsd	f3,  (FPU_REGS + 3 * 8)(a0)
	fsd	f4,  (FPU_REGS + 4 * 8)(a0)
	fsd	f5,  (FPU_REGS + 5 * 8)(a0)
	fsd	f6,  (FPU_REGS + 6 * 8)(a0)
	fsd	f7,  (FPU_REGS + 7 * 8)(a0)
	fsd	f8,  (FPU_REGS + 8 * 8)(a0)
	fsd	f9,  (FPU_REGS + 9 * 8)(a0)
	fsd	f10, (FPU_REGS + 10 * 8)(a0)
	fsd	f11, (FPU_REGS + 11 * 8)(a0)
	fsd	f12, (FPU_REGS + 12 * 8)(a0)
	fsd	f13, (FPU_REGS + 13 * 8)(a0)
	fsd	f14, (FPU_REGS + 14 * 8)(a0)
	fsd	f15, (FPU_REGS + 15 * 8)(a0)
	fsd	f16, (FPU_REGS + 16 * 8)(a0)
	fsd	f17, (FPU_REGS + 17 * 8)(a0)
	fsd	f18, (FPU_REGS + 18 * 8)(a0)
	fsd	f19, (FPU_REGS + 19 * 8)(a0)
	fsd	f20, (FPU_REGS + 20 * 8)(a0)
	fsd	f21, (FPU_REGS + 21 * 8)(a0)
	fsd	f22, (FPU_REGS + 22 * 8)(a0)
	fsd	f23, (FPU_REGS + 23 * 8)(a0)
	fsd	f24, (FPU_REGS + 24 * 8)(a0)
	fsd	f25, (FPU_REGS + 25 * 8)(a0)
	fsd	f26, (FPU_REGS + 26 * 8)(a0)
	fsd	f27, (FPU_REGS + 27 * 8)(a0)
	fsd	f28, (FPU_REGS + 28 * 8)(a0)
	fsd	f29, (FPU_REGS + 29 * 8)(a0)
	fsd	f30, (FPU_REGS + 30 * 8)(a0)
	fsd	f31, (FPU_REGS + 31 * 8)(a0)
	frcsr	t0
	sd	t0,  FPU_CSR(a0)
	ret
	.size _fpu_save, . - _fpu_save

/*
 * void _fpu_restore(fpu_ctx_t *ctx)   -- a0 = ctx
 *
 * fcsr is restored LAST so the loads above cannot raise flags that then get
 * overwritten -- the restored fcsr is the one the thread saved.
 */
	.globl _fpu_restore
	.type _fpu_restore, @function
_fpu_restore:
	fld	f0,  (FPU_REGS + 0 * 8)(a0)
	fld	f1,  (FPU_REGS + 1 * 8)(a0)
	fld	f2,  (FPU_REGS + 2 * 8)(a0)
	fld	f3,  (FPU_REGS + 3 * 8)(a0)
	fld	f4,  (FPU_REGS + 4 * 8)(a0)
	fld	f5,  (FPU_REGS + 5 * 8)(a0)
	fld	f6,  (FPU_REGS + 6 * 8)(a0)
	fld	f7,  (FPU_REGS + 7 * 8)(a0)
	fld	f8,  (FPU_REGS + 8 * 8)(a0)
	fld	f9,  (FPU_REGS + 9 * 8)(a0)
	fld	f10, (FPU_REGS + 10 * 8)(a0)
	fld	f11, (FPU_REGS + 11 * 8)(a0)
	fld	f12, (FPU_REGS + 12 * 8)(a0)
	fld	f13, (FPU_REGS + 13 * 8)(a0)
	fld	f14, (FPU_REGS + 14 * 8)(a0)
	fld	f15, (FPU_REGS + 15 * 8)(a0)
	fld	f16, (FPU_REGS + 16 * 8)(a0)
	fld	f17, (FPU_REGS + 17 * 8)(a0)
	fld	f18, (FPU_REGS + 18 * 8)(a0)
	fld	f19, (FPU_REGS + 19 * 8)(a0)
	fld	f20, (FPU_REGS + 20 * 8)(a0)
	fld	f21, (FPU_REGS + 21 * 8)(a0)
	fld	f22, (FPU_REGS + 22 * 8)(a0)
	fld	f23, (FPU_REGS + 23 * 8)(a0)
	fld	f24, (FPU_REGS + 24 * 8)(a0)
	fld	f25, (FPU_REGS + 25 * 8)(a0)
	fld	f26, (FPU_REGS + 26 * 8)(a0)
	fld	f27, (FPU_REGS + 27 * 8)(a0)
	fld	f28, (FPU_REGS + 28 * 8)(a0)
	fld	f29, (FPU_REGS + 29 * 8)(a0)
	fld	f30, (FPU_REGS + 30 * 8)(a0)
	fld	f31, (FPU_REGS + 31 * 8)(a0)
	ld	t0,  FPU_CSR(a0)
	fscsr	t0
	ret
	.size _fpu_restore, . - _fpu_restore
