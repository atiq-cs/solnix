/*
 * mach_externs.c -- link substrate for the R-P21.3 riscv64 MD partial-link
 * proof.  Provides the C symbols the genassym-driven MD .S units + mach_cpu.c
 * reference (rv_trap, rv_lofault, cpu_list, hart_online_mask, trap_entry) so
 * the FINAL full link (after the ld -r partial link) resolves every reloc to an
 * EM_RISCV image.  Not a real kernel -- exactly enough to exercise the sgs
 * reloc set end to end.
 */

typedef unsigned long ulong_t;

struct rv_context { ulong_t c_ra, c_sp, c_tp, c_s[12], c_satp, c_lofault; };

/*
 * the per-thread copy-fault snapshot mach_swtch.S loads/stores via a pcrel pair
 * (rv_swtch itself is now provided by mach_swtch.S, so it is NOT stubbed here)
 */
ulong_t rv_lofault;

/* the C trap handler mach_locore.S calls (R_RISCV_CALL_PLT) */
void
rv_trap(struct rv_context *r)
{
	(void)r;
}

void
trap_entry(void)
{
}

/* cpu_list[] and hart_online_mask are the PCREL_HI20/LO12 data targets. */
void *cpu_list[8];
volatile ulong_t hart_online_mask;
