#!/usr/bin/env python3
# b1-05-mapping-attr-print.py <gate> : aa64f boot 1, concern 5 (observers only).
#  1. rootnex_map_regspec(): for every mapping that is NOT HAT_STRICTORDER, print the
#     driver, PA, size, hat flags and the MMU's own attribute byte (AT S1E1R -> PAR_EL1).
#  2. ena_llq_write_to_dev(): once, print a marker before the first LLQ store and one
#     after a dsb sy following it, so an SError from that store lands between the two.
# Both use cmn_err (console before S1) plus the weak aa64e_printf (direct UART after S1).
import sys
G = sys.argv[1] + '/usr/src/uts/'

def edit(path, fn):
    s = open(G + path).read(); t = fn(s)
    assert t != s, path; open(G + path, 'w').write(t)

def rep(s, a, b, n=1):
    assert s.count(a) == n, (a[:60], s.count(a))
    return s.replace(a, b)

WEAK = 'extern void aa64e_printf(const char *, ...) __attribute__((weak));\n'
PR = ('#define\tAA64F_PR(...) do { cmn_err(CE_CONT, __VA_ARGS__); '
      'if (&aa64e_printf != NULL) aa64e_printf(__VA_ARGS__); } while (0)\n')

MAP = r'''		*vaddrp = (caddr_t)cvaddr + pgoffset;
		if ((hat_acc_flags & HAT_ORDER_MASK) != HAT_STRICTORDER) {
			uint64_t mair, par, d;	/* aa64f: observer */

			/* measured: PAR_EL1.ATTR is the MAIR byte the MMU uses */
			d = disable_interrupts();
			__asm__ volatile("at s1e1r, %1; isb; mrs %0, par_el1"
			    : "=r"(par) : "r"(cvaddr) : "memory");
			restore_interrupts(d);
			__asm__ volatile("mrs %0, mair_el1" : "=r"(mair));
			AA64F_PR("[AA64F-MAP] %s%d pa 0x%lx size 0x%lx hat 0x%x "
			    "par 0x%lx attr 0x%02lx mair 0x%lx va %p\n",
			    hp != NULL ? ddi_driver_name(hp->ah_dip) : "-",
			    hp != NULL ? ddi_get_instance(hp->ah_dip) : -1,
			    (ulong_t)pbase, (ulong_t)rp->regspec_size,
			    hat_acc_flags, par, (par & 1) ? 0xffUL : par >> 56,
			    mair, (void *)cvaddr);
		}
'''

def rootnex(s):
    s = rep(s, '#include <sys/controlregs.h>\n',
            '#include <sys/controlregs.h>\n#include <sys/archsystm.h>\n' + WEAK + PR)
    return rep(s, '\t\t*vaddrp = (caddr_t)cvaddr + pgoffset;\n', MAP)
edit('armv8/io/rootnex.c', rootnex)

LLQ = r'''	for (i = 0; i < count; i++)
		dst[i] = src[i];
	if (aa64f_llq1 == 0 && atomic_cas_32(&aa64f_llq1, 0, 1) == 0) {
		__asm__ volatile("dsb sy" ::: "memory");
		AA64F_PR("[AA64F-LLQ] first write done cpu%d dst %p n %u\n",
		    CPU->cpu_id, (void *)dst, count);
	}
}
'''

def tx(s):
    s = rep(s, '#include "ena.h"\n', '#include "ena.h"\n#include <sys/cpuvar.h>\n'
            + WEAK + PR + 'static volatile uint32_t aa64f_llq1;\n')
    s = rep(s, '\tcount = entry_size / sizeof (uint64_t);\n\n',
            '\tcount = entry_size / sizeof (uint64_t);\n'
            '\tif (aa64f_llq1 == 0)\t/* aa64f: observer */\n'
            '\t\tAA64F_PR("[AA64F-LLQ] first write cpu%d dst %p n %u\\n",\n'
            '\t\t    CPU->cpu_id, (void *)dst, count);\n\n')
    return rep(s, '\tfor (i = 0; i < count; i++)\n\t\tdst[i] = src[i];\n}\n', LLQ)
edit('common/io/ena/ena_tx.c', tx)
print('b1-05 OK')
