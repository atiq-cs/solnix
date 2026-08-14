/*
 * mach_externs22.c -- link substrate for the R-P22.3 larger MD partial-link.
 * Extends the R-P21 mach_externs.c with the C handlers the new R-P22 MD units
 * call: rv_interrupt / rv_syscall (from mach_trap.S rv_trap_dispatch) and
 * clock (from mach_clock.S rv_clock_intr).  Plus the R-P21 stubs so the FINAL
 * full link of the whole larger unix set resolves every reloc to an EM_RISCV
 * image.  Not a real kernel -- exactly enough to close the reloc graph.
 */

typedef unsigned long ulong_t;

struct regs;
struct rv_context { ulong_t c_ra, c_sp, c_tp, c_s[12], c_satp, c_lofault; };

/* R-P21 stubs */
ulong_t rv_lofault;
void rv_trap(struct regs *r) { (void)r; }
void trap_entry(void) {}
void *cpu_list[8];
volatile ulong_t hart_online_mask;

/* R-P22 trap-dispatch handlers (mach_trap.S) */
void rv_interrupt(struct regs *r) { (void)r; }
void rv_syscall(struct regs *r) { (void)r; }

/* R-P22 clock tick (mach_clock.S) */
void clock(void) {}
