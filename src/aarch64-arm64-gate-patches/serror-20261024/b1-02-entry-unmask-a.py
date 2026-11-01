#!/usr/bin/env python3
# b1-02-entry-unmask-a.py <gate> : aa64f boot 1, concern 2.
# HW sets PSTATE.A on every exception entry to EL1; the entry paths clear only I/D, so
# every CPU runs syscalls, traps and interrupt handlers with SError masked.  Unmask A
# once the frame is saved:
#  - EL0 entry (sync -> trap/syscall, and IRQ): widen the existing one-instruction
#    "DAIFClr #DEBUG" to "#(DEBUG|SERROR)" -- no new instruction, so the 32-insn
#    lower-EL IRQ vector slot does not grow.  EL0 always runs with A=0.
#  - EL1 entry (sync, IRQ): unmask only if the interrupted context had A=0 (SPSR bit 8);
#    x9 is free here (all GPRs saved).  The EL1 SError handler keeps A masked.
import sys
G = sys.argv[1] + '/usr/src/uts/'

def edit(path, fn):
    s = open(G + path).read(); t = fn(s)
    assert t != s, path; open(G + path, 'w').write(t)

def rep(s, a, b, n=1):
    assert s.count(a) == n, (a[:60], s.count(a))
    return s.replace(a, b)

COND = ('\tldr\tx9, [sp, #REGOFF_SPSR]\t// aa64f: unmask A if interrupted ctx had A=0\n'
        '\ttbnz\tx9, #8, 7f\t\t// SPSR.A is bit 8 (PSR_A)\n'
        '\tmsr\tDAIFClr, #DAIF_SETCLEAR_SERROR\n7:\n')

def exc(s):
    s = rep(s, '\tmsr DAIFClr, #DAIF_SETCLEAR_DEBUG\n',
            '\tmsr DAIFClr, #(DAIF_SETCLEAR_DEBUG | DAIF_SETCLEAR_SERROR)\n', n=2)
    s = rep(s, 'ENTRY(from_current_el_sync_handler)\n',
            'ENTRY(from_current_el_sync_handler)\n' + COND)
    s = rep(s, 'ENTRY(from_current_el_irq_handler)\n\t__SAVE_REGS_EL1\n\t__SAVE_FRAME\n',
            'ENTRY(from_current_el_irq_handler)\n\t__SAVE_REGS_EL1\n\t__SAVE_FRAME\n' + COND)
    return s
edit('armv8/ml/exceptions.S', exc)
print('b1-02 OK')
