/*
 * fp.h - the riscv64 FP context type and policy interface. See fp.c for why
 * this exists and why the state lives here rather than in the trap frame.
 */

#ifndef	_FP_H
#define	_FP_H

/*
 * The layout float.s addresses. _fpu_save/_fpu_restore reference exactly two
 * offsets into this struct, FPU_CTX_FPU_REGS and FPU_CTX_FPU_CSR, which must
 * agree with the generated assym.h -- keep the two in step if this changes.
 *
 * 32 doubles then fcsr. fcsr is architecturally 32 bits but is stored in a
 * 64-bit slot because float.s moves it with sd/ld (frcsr/fscsr go through an
 * integer register), and because it keeps the struct 8-byte aligned throughout.
 */
#define	FPU_NREGS	32

typedef struct fpu_ctx {
	unsigned long	fpu_regs[FPU_NREGS];	/* f0..f31, offset 0 */
	unsigned long	fpu_csr;		/* fcsr, offset 256 */
} fpu_ctx_t;

/*
 * These must match the struct above and are what float.s uses. They are
 * asserted at compile time in fp.c's translation unit rather than trusted.
 */
#define	FPU_CTX_FPU_REGS	0
#define	FPU_CTX_FPU_CSR		(FPU_NREGS * 8)

/*
 * Policy. fp_switch() is the only entry the dispatcher needs; the rest are for
 * the trap path and process lifecycle.
 */
extern void fp_switch(fpu_ctx_t *old, fpu_ctx_t *new);
extern int fp_save(fpu_ctx_t *ctx);
extern void fp_restore(fpu_ctx_t *ctx);
extern int fp_fenflt(fpu_ctx_t **ctxp, unsigned long *sstatusp);
extern int fp_fork(fpu_ctx_t *parent, fpu_ctx_t **childp);
extern void fp_exec_reset(fpu_ctx_t *ctx);

/*
 * Backing-store hooks. Kept separate from policy so fp.c does not need to know
 * this kernel's allocator, and so a test can substitute them.
 */
extern fpu_ctx_t *fp_ctx_alloc(void);
extern void fp_ctx_copy(fpu_ctx_t *dst, const fpu_ctx_t *src);
extern void fp_ctx_zero(fpu_ctx_t *ctx);

/*
 * Negative control: set to 0 to disable save/restore so the FP test must FAIL.
 * See fp.c.
 */
extern volatile int fp_swtch_enabled;

#endif	/* _FP_H */
