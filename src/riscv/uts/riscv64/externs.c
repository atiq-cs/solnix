/*
 * externs.c -- resolve mach_cpu.c's external references for the R-P20 link
 * proof.  Provides rv_swtch/trap_entry stubs and the cpu_list/hart_online_mask
 * data so the cross-ld can resolve every CALL_PLT + PCREL pair mach_cpu emits.
 * Not a real kernel -- a link substrate to exercise the R-P20 sgs relocs.
 */

typedef unsigned long ulong_t;

struct rv_context { ulong_t c_ra, c_sp, c_tp, c_s[12], c_satp, c_lofault; };

void
rv_swtch(struct rv_context *old, struct rv_context *new)
{
	(void)old; (void)new;			/* CALL_PLT target */
}

void
trap_entry(void)
{
}

/* cpu_list[] and hart_online_mask are the PCREL_HI20/LO12 data targets. */
void *cpu_list[8];
volatile ulong_t hart_online_mask;
