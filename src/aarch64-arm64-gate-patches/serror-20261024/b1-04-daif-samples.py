#!/usr/bin/env python3
# b1-04-daif-samples.py <gate> : aa64f boot 1, concern 4.  Apply after aa64e-b2.py.
# Measure, not assume, that A is clear in the kernel after b1-01..03:
#  - trap(): record per CPU the live DAIF and the interrupted context's SPSR.DAIF
#    (one nibble each, (x >> 6) & 0xf: bit0 F, bit1 I, bit2 A, bit3 D; 0 = no sample;
#    HW always sets I on entry, so a real sample is never 0).
#  - every 15 s heartbeat: one [AA64F-DAIF] line with the heartbeat CPU's own DAIF and
#    the 64-nibble per-CPU strings.  Expect trap 3 (I|F) and hb A clear; 7 = A masked.
import sys
G = sys.argv[1] + '/usr/src/uts/'

def edit(path, fn):
    s = open(G + path).read(); t = fn(s)
    assert t != s, path; open(G + path, 'w').write(t)

def rep(s, a, b, n=1):
    assert s.count(a) == n, (a[:60], s.count(a))
    return s.replace(a, b)

REC = r'''/* aa64f: DAIF nibble at the last trap() entry per CPU (live, and SPSR) */
uint8_t aa64f_tdaif[NCPU], aa64f_tspsr[NCPU];

void
aa64f_daif_rec(uint64_t spsr)
{
	uint64_t d;
	int c = CPU->cpu_id;

	__asm__ volatile("mrs %0, daif" : "=r"(d));
	if (c >= 0 && c < NCPU) {
		aa64f_tdaif[c] = (d >> 6) & 0xf;
		aa64f_tspsr[c] = (spsr >> 6) & 0xf;
	}
}

void
aa64e_trap_rec('''

HB = r'''	aa64e_write(NULL, NULL, b, o);
	{	/* aa64f: DAIF samples */
		uint64_t d;
		__asm__ volatile("mrs %0, daif" : "=r"(d));
		o = 0;
		AA64E_AP("[AA64F-DAIF] #%u hb cpu%d daif 0x%lx trap", aa64e_hbn,
		    CPU->cpu_id, d);
		for (i = 0; i < ncpus && i < 64; i++)
			AA64E_AP("%x", aa64f_tdaif[i]);
		AA64E_AP(" spsr ");
		for (i = 0; i < ncpus && i < 64; i++)
			AA64E_AP("%x", aa64f_tspsr[i]);
		o = MIN(o, sz);
		b[o++] = '\n';
		aa64e_write(NULL, NULL, b, o);
	}
#undef	AA64E_AP
'''

def machdep(s):
    s = rep(s, 'void\naa64e_trap_rec(', REC)
    s = rep(s, '\taa64e_write(NULL, NULL, b, o);\n#undef\tAA64E_AP\n', HB)
    # the heartbeat function is defined before the recorder: forward-declare the arrays
    return rep(s, 'static void\naa64e_hb(void *arg __unused)\n',
               'extern uint8_t aa64f_tdaif[], aa64f_tspsr[];\n\n'
               'static void\naa64e_hb(void *arg __unused)\n')
edit('armv8/os/machdep.c', machdep)

def trap(s):
    s = rep(s, 'extern void aa64e_trap_rec(uint64_t, uint64_t, uint64_t);\n',
            'extern void aa64e_trap_rec(uint64_t, uint64_t, uint64_t);\n'
            'extern void aa64f_daif_rec(uint64_t);\n')
    a = '\taa64e_trap_rec(esr, (uint64_t)(uintptr_t)addr, rp->r_pc);\t/* NOTE: observer */\n'
    return rep(s, a, a + '\taa64f_daif_rec(rp->r_spsr);\t/* aa64f: observer */\n')
edit('armv8/os/trap.c', trap)
print('b1-04 OK')
