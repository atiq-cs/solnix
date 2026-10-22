#!/usr/bin/env python3
# aa-ecam-diag.py <gate-root> : bring-up DIAGNOSTIC on top of aa-ecam-ontrap-fix.sh.
# (1) trap.c records ec/esr/far of each on_trap()-recovered kernel abort;
# (2) ecam.c prints the first 4 recoveries, and every 1024 config accesses prints
#     count / elapsed ms / max single-access latency, so one metal boot tells
#     "sync abort recovered" from "slow (completion-timeout) accesses" from
#     "enumeration never started".
import re, sys
G = sys.argv[1] + '/usr/src/uts'
f = G + '/armv8/os/trap.c'; s = open(f).read()
if 'aa_ot_count' not in s:
    a = 'int\ntrap(uint16_t ec, uint64_t esr, caddr_t addr, struct regs *rp)\n{'
    assert a in s
    s = s.replace(a, '/* aa64 bring-up diag: last on_trap()-recovered kernel abort */\n'
        'volatile uint32_t aa_ot_ec;\nvolatile uint64_t aa_ot_esr;\n'
        'volatile uintptr_t aa_ot_far;\nvolatile uint32_t aa_ot_count;\n\n' + a, 1)
    pat = re.compile(r'(\n(\t+))(ct->t_ontrap->ot_trap \|= OT_DATA_ACCESS;)')
    s, n = pat.subn(lambda m: m.group(1) + 'aa_ot_ec = ec; aa_ot_esr = esr; aa_ot_far = (uintptr_t)addr; aa_ot_count++;' + m.group(1) + m.group(3), s)
    assert n == 2, n
    open(f, 'w').write(s)
f = G + '/aarch64/io/pciex/ecam/ecam.c'; s = open(f).read()
assert 'on_trap(&otd, OT_DATA_ACCESS)' in s, 'apply aa-ecam-ontrap-fix.sh first'
if 'aa_ecam_n' not in s:
    a = 'static void\necam_cfgspace_acc(pci_cfgacc_req_t *req)\n{'
    assert a in s
    s = s.replace(a, '''extern volatile uint32_t aa_ot_ec;
extern volatile uint64_t aa_ot_esr;
extern volatile uintptr_t aa_ot_far;
extern volatile uint32_t aa_ot_count;
static uint32_t aa_ecam_n, aa_ecam_rec;
static hrtime_t aa_ecam_t0, aa_ecam_maxns;

static void
ecam_cfgspace_acc_impl(pci_cfgacc_req_t *req)
{''', 1)
    a = '''		/* Took an external abort on the access below; recover. */
		no_trap();
'''
    assert a in s
    s = s.replace(a, a + '''		if (++aa_ecam_rec <= 4) {
			cmn_err(CE_CONT, "[AAECAM] recovered #%u bdf=%x:%x.%x "
			    "reg=0x%x sz=%d w=%d ec=0x%x esr=0x%lx far=0x%lx\\n",
			    aa_ecam_rec, bus, dev, func, reg, (int)req->size,
			    (int)req->write, aa_ot_ec, (ulong_t)aa_ot_esr,
			    (ulong_t)aa_ot_far);
		}
''', 1)
    a = 'pcie_rc_data_t ecam_pcie_rc_data = {'
    assert a in s
    s = s.replace(a, '''static void
ecam_cfgspace_acc(pci_cfgacc_req_t *req)
{
	hrtime_t t = gethrtime(), d;

	if (aa_ecam_n == 0) {
		cmn_err(CE_CONT, "[AAECAM] first cfg access %x:%x.%x reg=0x%x\\n",
		    PCI_CFGACC_BUS(req), PCI_CFGACC_DEV(req),
		    PCI_CFGACC_FUNC(req), req->offset);
	}
	ecam_cfgspace_acc_impl(req);
	d = gethrtime() - t;
	if (aa_ecam_n == 0)
		aa_ecam_t0 = t;
	if (d > aa_ecam_maxns)
		aa_ecam_maxns = d;
	if ((++aa_ecam_n & 1023) == 0 || aa_ecam_n == 1) {
		cmn_err(CE_CONT, "[AAECAM] n=%u ms=%lld maxus=%lld rec=%u "
		    "otc=%u last=%x:%x.%x\\n", aa_ecam_n,
		    (longlong_t)((t - aa_ecam_t0) / 1000000),
		    (longlong_t)(aa_ecam_maxns / 1000), aa_ecam_rec,
		    aa_ot_count, PCI_CFGACC_BUS(req), PCI_CFGACC_DEV(req),
		    PCI_CFGACC_FUNC(req));
	}
}

''' + a, 1)
    open(f, 'w').write(s)
print('diag applied')
