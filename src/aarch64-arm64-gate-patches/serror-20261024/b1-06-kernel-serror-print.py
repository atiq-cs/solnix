#!/usr/bin/env python3
# b1-06-kernel-serror-print.py <gate> : aa64f boot 1, concern 6 (observer).  After b1-04.
# With A unmasked in the kernel, an SError now arrives at EL1 (from_current_el_error ->
# trap(T_SERROR)).  Two of its three branches recover silently: on_trap(OT_DATA_ACCESS)
# and t_lofault (an async SError under copyin would become a quiet EFAULT).  Print the
# ESR, ELR + symbol, FAR, SPSR, CPU and branch for EVERY kernel T_SERROR before acting.
import sys
G = sys.argv[1] + '/usr/src/uts/'

def edit(path, fn):
    s = open(G + path).read(); t = fn(s)
    assert t != s, path; open(G + path, 'w').write(t)

def rep(s, a, b, n=1):
    assert s.count(a) == n, (a[:60], s.count(a))
    return s.replace(a, b)

DECL = r'''extern void aa64f_daif_rec(uint64_t);
extern void aa64e_printf(const char *, ...);
extern char *kobj_getsymname(uintptr_t, ulong_t *);

static void
aa64f_kserror(uint64_t esr, caddr_t addr, struct regs *rp, const char *br)
{
	ulong_t off = 0;
	char *sym = kobj_getsymname((uintptr_t)rp->r_pc, &off);

	aa64e_printf("\n[AA64F-KSERR] cpu%d esr 0x%lx elr 0x%lx %s+0x%lx far 0x%lx "
	    "spsr 0x%lx lr 0x%lx thread %p comm %s -> %s\n", CPU->cpu_id, esr,
	    (uint64_t)rp->r_pc, sym != NULL ? sym : "?", off, (uint64_t)addr,
	    (uint64_t)rp->r_spsr, (uint64_t)rp->r_lr, (void *)curthread,
	    PTOU(curproc)->u_comm, br);
}
'''

OLD = '''		case T_SERROR:
			if ((ct->t_ontrap != NULL) &&
			    (ct->t_ontrap->ot_prot & OT_DATA_ACCESS)) {
'''
NEW = '''		case T_SERROR:
			aa64f_kserror(esr, addr, rp,
			    (ct->t_ontrap != NULL &&
			    (ct->t_ontrap->ot_prot & OT_DATA_ACCESS)) ? "ontrap" :
			    ct->t_lofault != 0 ? "lofault" : "die");
			if ((ct->t_ontrap != NULL) &&
			    (ct->t_ontrap->ot_prot & OT_DATA_ACCESS)) {
'''

def trap(s):
    s = rep(s, 'extern void aa64f_daif_rec(uint64_t);\n', DECL)
    return rep(s, OLD, NEW)
edit('armv8/os/trap.c', trap)
print('b1-06 OK')
