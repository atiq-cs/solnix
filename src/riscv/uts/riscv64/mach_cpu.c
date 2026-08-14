/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or http://www.opensolaris.org/os/licensing.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */

/*
 * mach_cpu.c -- a larger illumos riscv64 MD kernel unit than R-P19's mod stub.
 *
 * Exercises the reloc set a real MD source produces and links toward the
 * kernel: cross-translation-unit calls (R_RISCV_CALL_PLT), external data
 * references through the auipc+addi PC-relative pair (R_RISCV_PCREL_HI20 +
 * R_RISCV_PCREL_LO12_I -- the pairing the R-P20 sgs backend resolves), a jump
 * table, and struct field accesses at the genassym-verified offsets.
 *
 * It is a plausible slice of a riscv machdep / cpu-init path: bring a hart's
 * per-cpu record online, install a trap vector, and account a context switch.
 * The point is coverage of the load-bearing relocs + a clean cross-ld link to
 * an EM_RISCV ET_REL/ET_EXEC, not a bootable kernel.
 *
 * CRIB PROVENANCE: the per-cpu / hart-online / stvec-install shape follows the
 * illumos riscv64 MD tree (startup.c / main.c, R-P1..R-P16) and the RISC-V
 * privileged spec (stvec CSR).  The struct layouts match genassym.c.
 */

typedef unsigned long	ulong_t;
typedef unsigned int	uint_t;

/* Matches genassym.c struct rv_context (swtch.S consumes it). */
struct rv_context {
	ulong_t c_ra, c_sp, c_tp;
	ulong_t c_s[12];
	ulong_t c_satp;
	ulong_t c_lofault;
};

struct cpu {
	uint_t		cpu_id;		/* hartid */
	uint_t		cpu_flags;
	ulong_t		cpu_ncsw;	/* context-switch count */
	void		*cpu_thread;	/* current thread */
	struct rv_context cpu_idle_ctx;	/* idle-thread saved context */
};

#define	CPU_ONLINE	0x0001

/* External symbols -> R_RISCV_CALL_PLT / R_RISCV_PCREL_HI20+LO12 references. */
extern void rv_swtch(struct rv_context *old, struct rv_context *new);
extern void trap_entry(void);
extern struct cpu *cpu_list[];		/* external array: pcrel data ref */
extern volatile ulong_t hart_online_mask;

/* Install the S-mode trap vector (stvec, Direct mode). */
static void
set_stvec(void (*handler)(void))
{
	ulong_t v = (ulong_t)handler & ~3UL;	/* Direct mode (low 2 bits 0) */
	__asm__ __volatile__ ("csrw stvec, %0" : : "r" (v));
}

/*
 * Bring hart `id`'s per-cpu record online: link it, mark it, install the trap
 * vector, and publish the online bit.  Calls out (CALL_PLT) and touches the
 * external cpu_list array + hart_online_mask (PCREL pairs).
 */
struct cpu *
cpu_online(uint_t id)
{
	struct cpu *cp = cpu_list[id];		/* GOT/PCREL data load */

	if (cp == 0)
		return (0);

	cp->cpu_id = id;
	cp->cpu_flags |= CPU_ONLINE;
	cp->cpu_ncsw = 0;

	set_stvec(trap_entry);			/* takes trap_entry's address */
	hart_online_mask |= (1UL << id);	/* external data RMW */

	return (cp);
}

/*
 * Account one context switch away from `cp`: bump the counter and switch into
 * the idle context.  The rv_swtch() call is a cross-TU CALL_PLT.
 */
void
cpu_switch_to_idle(struct cpu *cp)
{
	static struct rv_context throwaway;

	cp->cpu_ncsw++;
	rv_swtch(&throwaway, &cp->cpu_idle_ctx);	/* R_RISCV_CALL_PLT */
}

/* A small dispatch table -> jump-table / pcrel relocs. */
ulong_t
cpu_ctl(struct cpu *cp, int op)
{
	switch (op) {
	case 0: return (cp->cpu_id);
	case 1: return (cp->cpu_flags);
	case 2: return (cp->cpu_ncsw);
	case 3: cpu_switch_to_idle(cp); return (0);
	default: return ((ulong_t)-1);
	}
}
