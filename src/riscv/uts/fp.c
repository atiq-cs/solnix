/*
 * fp.c - floating-point context for the solnix riscv64 kernel.
 *
 * WHY THIS EXISTS. Nothing preserved FP registers across a context switch:
 * there is no fsd/fld in swtch.S or trap.S and no FP slots in the trap frame,
 * yet sstatus reports FS=Dirty, so the FPU is enabled and accumulating state
 * that nothing saved. A fork probe proved the consequence directly -- the
 * parent stamped f0-f7, the child stamped different values, and the parent read
 * back exactly parent^child from its own registers (see
 * docs/riscv-no-fp-context-switch.md).
 *
 * It stayed hidden because our userland is built soft-float (-march=rv64imac),
 * so no process had ever used the FPU. That stops being true the moment a
 * hard-float (lp64d) Rust binary runs -- and llvmpipe, the software rasterizer
 * the desktop depends on, is nothing but float. Two hard-float processes would
 * corrupt each other SILENTLY: garbage pixels, not an error.
 *
 * WHY NOT THE TRAP FRAME. The frame is exactly full: TF_CPUID is at 280 and
 * TF_SIZE is 288, and that last slot IS TF_CPUID (it reuses the 16-byte
 * alignment pad). Adding f0-f31 + fcsr there would grow TF_SIZE 288 -> 552 and
 * put 264 bytes of fsd on EVERY 100 Hz timer tick, for threads that mostly
 * never touch the FPU. Instead the state hangs off rv_context by pointer and is
 * switched in swtch() -- ordinary C -- which leaves both swtch.S and trap.S
 * untouched. Those two files carry subtle documented constraints (the x5/t0
 * save ordering, and the tp privilege swap) and are best not disturbed.
 *
 * WHY LAZY. sstatus.FS exists precisely so a kernel need not save FP for
 * threads that do not use it. A thread starts with FS=Off; its first FP
 * instruction traps as an illegal instruction; we then allocate/restore its
 * state and set FS so it proceeds. On switch we save only when FS==Dirty. The
 * kernel itself contains no FP instructions (soft-float ABI, verified), so no
 * kernel path can dirty the FPU behind our back and pure lazy handling is safe.
 *
 * The f0-f31 + fcsr moves themselves are done by float.s (_fpu_save /
 * _fpu_restore), cribbed from illumos-gate; fpu.c from that tree is a POLICY
 * REFERENCE ONLY and is deliberately not built here -- it depends on the ctxop
 * framework, which this port does not have.
 */

#include "fp.h"

/*
 * float.s addresses this struct by two literal offsets, so a silent layout
 * drift would corrupt FP state rather than fail to build. Prove the agreement
 * at compile time instead of trusting it. 264 = 32 doubles + fcsr, which is
 * also the size illumos calls fpchip_state.
 */
_Static_assert(FPU_CTX_FPU_REGS == __builtin_offsetof(fpu_ctx_t, fpu_regs),
    "FPU_CTX_FPU_REGS disagrees with fpu_ctx_t -- float.s would corrupt state");
_Static_assert(FPU_CTX_FPU_CSR == __builtin_offsetof(fpu_ctx_t, fpu_csr),
    "FPU_CTX_FPU_CSR disagrees with fpu_ctx_t -- float.s would corrupt state");
_Static_assert(sizeof (fpu_ctx_t) == 33 * 8, "fpu_ctx_t must be 264 bytes");

/*
 * sstatus.FS is a two-bit field at [14:13]. Off means the FPU is disabled and
 * touching it traps; Initial/Clean mean enabled with state that matches memory;
 * Dirty means the registers have been written since the last save.
 */
#define	SSTATUS_FS_SHIFT	13
#define	SSTATUS_FS_MASK		(3UL << SSTATUS_FS_SHIFT)
#define	SSTATUS_FS_OFF		(0UL << SSTATUS_FS_SHIFT)
#define	SSTATUS_FS_INITIAL	(1UL << SSTATUS_FS_SHIFT)
#define	SSTATUS_FS_CLEAN	(2UL << SSTATUS_FS_SHIFT)
#define	SSTATUS_FS_DIRTY	(3UL << SSTATUS_FS_SHIFT)

/*
 * NEGATIVE CONTROL. Setting this to 0 disables save/restore while leaving
 * everything else (allocation, the first-use trap, FS bookkeeping) in place, so
 * the FP test must FAIL. A test that cannot fail proves nothing, and this
 * project has twice shipped a check that passed for the wrong reason.
 * Volatile so the compiler cannot fold the branch away.
 */
volatile int fp_swtch_enabled = 1;

extern void _fpu_save(fpu_ctx_t *);
extern void _fpu_restore(fpu_ctx_t *);

static inline unsigned long
rd_sstatus(void)
{
	unsigned long v;

	__asm__ __volatile__("csrr %0, sstatus" : "=r"(v));
	return (v);
}

static inline void
set_fs(unsigned long fs)
{
	unsigned long v = rd_sstatus();

	v = (v & ~SSTATUS_FS_MASK) | fs;
	__asm__ __volatile__("csrw sstatus, %0" :: "r"(v));
}

static inline unsigned long
get_fs(void)
{
	return (rd_sstatus() & SSTATUS_FS_MASK);
}

/*
 * Save the live FP registers into ctx, but only if they are dirty. Returns
 * whether a save actually happened (callers use it only for statistics).
 *
 * The FPU must be enabled to execute fsd at all, so enable it around the save
 * and leave FS Clean afterwards: the registers now match memory.
 */
int
fp_save(fpu_ctx_t *ctx)
{
	if (ctx == 0 || !fp_swtch_enabled)
		return (0);
	if (get_fs() != SSTATUS_FS_DIRTY)
		return (0);

	set_fs(SSTATUS_FS_CLEAN);	/* enabled, and about to match memory */
	_fpu_save(ctx);
	return (1);
}

/*
 * Load ctx into the live FP registers and mark them Clean (they match memory by
 * construction). A caller that then returns to userland leaves FS enabled,
 * which is what lets that thread use FP without trapping again.
 */
void
fp_restore(fpu_ctx_t *ctx)
{
	if (ctx == 0 || !fp_swtch_enabled)
		return;

	set_fs(SSTATUS_FS_CLEAN);
	_fpu_restore(ctx);
}

/*
 * Switch FP state from old to new, called from swtch() before rv_swtch.
 *
 * Threads that have never touched the FPU have a NULL context and cost nothing
 * here beyond a pointer test -- the whole point of the lazy scheme. The
 * incoming thread gets FS=Off unconditionally so its next FP instruction traps
 * into fp_fenflt() and restores lazily; that is cheaper than restoring eagerly
 * for a thread that may be switched away again before using FP.
 */
void
fp_switch(fpu_ctx_t *old, fpu_ctx_t *new)
{
	if (!fp_swtch_enabled)
		return;

	if (old != 0)
		(void) fp_save(old);

	/*
	 * Off regardless of whether `new` owns state: if it does, it faults
	 * once and we restore; if it does not, it faults once and we allocate.
	 * Either way the registers it sees are never another thread's.
	 */
	set_fs(SSTATUS_FS_OFF);
	(void) new;
}

/*
 * First-use trap. An FP instruction executed with FS=Off raises an illegal
 * instruction; when that comes from U-mode, this is the hook.
 *
 * Do NOT advance sepc: the faulting instruction has not executed and is meant
 * to run once the FPU is on, so returning with FS enabled re-executes it.
 */
int
fp_fenflt(fpu_ctx_t **ctxp, unsigned long *sstatusp)
{
	fpu_ctx_t *ctx;

	if (ctxp == 0 || sstatusp == 0)
		return (0);

	ctx = *ctxp;
	if (ctx == 0) {
		ctx = fp_ctx_alloc();
		if (ctx == 0)
			return (0);	/* no memory: let it fault for real */
		*ctxp = ctx;
		/*
		 * A fresh context is all zeroes, and Initial is exactly the FS
		 * encoding for "enabled, registers are zero".
		 */
		set_fs(SSTATUS_FS_INITIAL);
	} else {
		fp_restore(ctx);
	}

	/*
	 * The trap frame's copy of sstatus is what sret restores, so patch that
	 * too or userland resumes with the FPU still off and traps forever.
	 */
	*sstatusp = (*sstatusp & ~SSTATUS_FS_MASK) | SSTATUS_FS_CLEAN;
	return (1);
}

/*
 * fork: the child must get a COPY. Sharing the parent's context would
 * reintroduce exactly the bug this file exists to fix, one level down -- two
 * processes writing one register file.
 */
int
fp_fork(fpu_ctx_t *parent, fpu_ctx_t **childp)
{
	fpu_ctx_t *c;

	if (childp == 0)
		return (0);
	*childp = 0;
	if (parent == 0)
		return (1);		/* nothing to inherit: fine */

	/*
	 * The parent may be running with dirty registers its saved context does
	 * not yet reflect, so flush before copying.
	 */
	(void) fp_save(parent);

	c = fp_ctx_alloc();
	if (c == 0)
		return (0);
	fp_ctx_copy(c, parent);
	*childp = c;
	return (1);
}

/*
 * exec: the new program must not see the old one's registers. Zero rather than
 * free, so the allocation is reused; zero is a valid initial FP state.
 */
void
fp_exec_reset(fpu_ctx_t *ctx)
{
	if (ctx != 0)
		fp_ctx_zero(ctx);
	set_fs(SSTATUS_FS_OFF);
}
