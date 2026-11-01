#!/usr/bin/env python3
# aa64e-b2.py <gate> : boot-2 kernel additions on top of aa64e-observers.py.  Output only.
#  1. exceptions.S UNEXPECTED(): pass the vector index, ESR/ELR/FAR/SPSR/SP and print
#     them directly to the UART (plus this CPU's last 4 trap() entries) before panic.
#  2. trap(): record (ec, esr, far, pc) per CPU in a 4-entry ring for (1).
#  3. ena: before the Rx-queue allocation, print the sizing that drives it.
import sys
G = sys.argv[1] + '/usr/src/uts/'

def edit(path, fn):
    s = open(G + path).read(); t = fn(s)
    assert t != s, path; open(G + path, 'w').write(t)

def rep(s, a, b, n=1):
    assert s.count(a) == n, (a[:60], s.count(a))
    return s.replace(a, b)

VEC = ['from_current_el_sp0_sync', 'from_current_el_sp0_irq', 'from_current_el_sp0_fiq',
       'from_current_el_sp0_error', 'from_current_el_fiq', 'from_lower_el_aarch64_fiq',
       'from_lower_el_aarch64_error', 'from_lower_el_aarch32_sync', 'from_lower_el_aarch32_irq',
       'from_lower_el_aarch32_fiq', 'from_lower_el_aarch32_error']
# vector-table index (offset / 0x80) of each UNEXPECTED entry
VIDX = {'from_current_el_sp0_sync': 0, 'from_current_el_sp0_irq': 1, 'from_current_el_sp0_fiq': 2,
        'from_current_el_sp0_error': 3, 'from_current_el_fiq': 6, 'from_lower_el_aarch64_fiq': 10,
        'from_lower_el_aarch64_error': 11, 'from_lower_el_aarch32_sync': 12,
        'from_lower_el_aarch32_irq': 13, 'from_lower_el_aarch32_fiq': 14,
        'from_lower_el_aarch32_error': 15}

def exc(s):
    # NOTE: observer.  x0 = vector index; the C side reads the syndrome registers.
    s = rep(s, '#define UNEXPECTED()\t\t\t\t\\\n\tclrex;\t\t\t\t\t\\\n'
            '\tadrp x0, .unexpected_exception;\t\t\\\n'
            '\tadd x0, x0, :lo12:.unexpected_exception;\t\\\n\tbl panic\n',
            '#define UNEXPECTED_N(n)\t\t\t\t\\\n\tclrex;\t\t\t\t\t\\\n'
            '\tmov x0, #(n);\t\t\t\t\\\n\tmov x1, sp;\t\t\t\t\\\n'
            '\tbl aa64e_unexpected;\t\t\t\\\n'
            '\tadrp x0, .unexpected_exception;\t\t\\\n'
            '\tadd x0, x0, :lo12:.unexpected_exception;\t\\\n\tbl panic\n')
    for v in VEC:
        a = 'ALTENTRY(%s)\n\tUNEXPECTED()\n' % v
        s = rep(s, a, 'ALTENTRY(%s)\n\tUNEXPECTED_N(%d)\n' % (v, VIDX[v]))
    assert 'UNEXPECTED()' not in s
    return s
edit('armv8/ml/exceptions.S', exc)

MD = r'''
/* NOTE: observer.  Last 4 trap() entries per CPU, printed by aa64e_unexpected(). */
typedef struct aa64e_tr {
	uint64_t	at_esr;
	uint64_t	at_far;
	uint64_t	at_pc;
	uint64_t	at_t;
} aa64e_tr_t;
aa64e_tr_t aa64e_trace[NCPU][4];
uint8_t aa64e_trace_i[NCPU];

void
aa64e_trap_rec(uint64_t esr, uint64_t far, uint64_t pc)
{
	int c = CPU->cpu_id;
	aa64e_tr_t *t;

	if (c < 0 || c >= NCPU)
		return;
	t = &aa64e_trace[c][aa64e_trace_i[c]++ & 3];
	t->at_esr = esr;
	t->at_far = far;
	t->at_pc = pc;
	t->at_t = arch_timer_count();
}

static const char *aa64e_vname[16] = {
	"cur-sp0-sync", "cur-sp0-irq", "cur-sp0-fiq", "cur-sp0-serror",
	"cur-spx-sync", "cur-spx-irq", "cur-spx-fiq", "cur-spx-serror",
	"low64-sync", "low64-irq", "low64-fiq", "low64-serror",
	"low32-sync", "low32-irq", "low32-fiq", "low32-serror"
};

void
aa64e_unexpected(uint64_t vec, uint64_t sp)
{
	uint64_t esr, elr, far, spsr, daif, isr;
	int c = CPU->cpu_id, i;

	__asm__ volatile("mrs %0, esr_el1" : "=r"(esr));
	__asm__ volatile("mrs %0, elr_el1" : "=r"(elr));
	__asm__ volatile("mrs %0, far_el1" : "=r"(far));
	__asm__ volatile("mrs %0, spsr_el1" : "=r"(spsr));
	__asm__ volatile("mrs %0, daif" : "=r"(daif));
	__asm__ volatile("mrs %0, isr_el1" : "=r"(isr));
	aa64e_printf("\n[AA64E-UNEXP] cpu%d vec %lu %s esr 0x%lx (ec 0x%lx iss 0x%lx) "
	    "elr 0x%lx far 0x%lx spsr 0x%lx sp 0x%lx daif 0x%lx isr 0x%lx "
	    "thread %p comm %s\n", c, vec, aa64e_vname[vec & 15], esr,
	    (esr >> 26) & 0x3f, esr & 0x1ffffff, elr, far, spsr, sp, daif, isr,
	    (void *)curthread, PTOU(curproc)->u_comm);
	if (c >= 0 && c < NCPU) {
		for (i = 1; i <= 4; i++) {
			aa64e_tr_t *t =
			    &aa64e_trace[c][(aa64e_trace_i[c] - i) & 3];
			aa64e_printf("[AA64E-UNEXP] cpu%d trap-%d esr 0x%lx far "
			    "0x%lx pc 0x%lx t %lu\n", c, i, t->at_esr,
			    t->at_far, t->at_pc, t->at_t);
		}
	}
}
'''

def machdep(s):
    return rep(s, '\nstatic int\nsysp_getchar(void)\n', MD + '\nstatic int\nsysp_getchar(void)\n')
edit('armv8/os/machdep.c', machdep)

def trap(s):
    a = ('int\ntrap(uint16_t ec, uint64_t esr, caddr_t addr, struct regs *rp)\n{\n'
         '\tkthread_t *ct = curthread;\n')
    return rep(s, a, 'extern void aa64e_trap_rec(uint64_t, uint64_t, uint64_t);\n\n' + a +
               '\n\taa64e_trap_rec(esr, (uint64_t)(uintptr_t)addr, rp->r_pc);\t/* NOTE: observer */\n')
edit('armv8/os/trap.c', trap)

def ena(s):
    a = '\tfor (uint_t i = 0; i < ena->ena_num_rxqs; i++) {\n\t\tena_rxq_t *rxq = &ena->ena_rxqs[i];\n\n\t\trxq->er_rxqs_idx = i;\n'
    return rep(s, a,
        '#if defined(__aarch64__)\n\tif (AA64E_HAVE)\n'
        '\t\taa64e_printf("[AA64E] ena%d rx sizing: rxqs %u descs %u (dev max %u) "\n'
        '\t\t    "buf %u B mtu %u (max %u) sgl %u page %lu -> %lu bytes of "\n'
        '\t\t    "streaming DMA via ddi_dma_mem_alloc/kalloca; txqs %u descs %u "\n'
        '\t\t    "buf %u B\\n", ena->ena_instance, ena->ena_num_rxqs,\n'
        '\t\t    ena->ena_rxq_num_descs, ena->ena_rx_max_sq_num_descs,\n'
        '\t\t    ena->ena_rx_buf_sz, ena->ena_mtu, ena->ena_max_mtu,\n'
        '\t\t    ena->ena_rx_sgl_max_sz, (ulong_t)ena->ena_page_sz,\n'
        '\t\t    (ulong_t)ena->ena_num_rxqs * ena->ena_rxq_num_descs *\n'
        '\t\t    ena->ena_rx_buf_sz, ena->ena_num_txqs,\n'
        '\t\t    ena->ena_txq_num_descs, ena->ena_tx_buf_sz);\n#endif\n' + a)
edit('common/io/ena/ena.c', ena)
print('AA64E_B2_KERNEL_OK')
