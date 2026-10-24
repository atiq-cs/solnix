#!/usr/bin/env python3
# aa64e-observers.py <gate> <dboot_synth_fdt.c> : post-mount observers for c6g.metal.
# Output only.  After consconfig() the prom path drops every character
# (sysp_putchar with no polled putchar) and wcuwsrv() frees console text (no tem).
# These edits write the SPCR UART directly through a kernel-VA device mapping made
# at S1 (after vfs_mountroot, before release_bootstrap), echo what both drop points
# discard, print stage markers + a 15 s heartbeat, and report the SBSA watchdog
# READ-ONLY (control frame mapped PROT_READ, refresh frame never mapped).
import sys
G = sys.argv[1] + '/usr/src/uts/'
DBOOT = sys.argv[2]

def edit(path, fn):
    p = path if path.startswith('/') else G + path
    s = open(p).read(); t = fn(s)
    assert t != s, path; open(p, 'w').write(t)

def rep(s, a, b, n=1):
    assert s.count(a) == n, (a[:60], s.count(a))
    return s.replace(a, b)

# ---------------------------------------------------------------- machdep.c (unix)
MACHDEP = r'''
/*
 * NOTE: post-mount observer, output only.  consconfig() ends with
 * prom_io_use_kernel(), after which sysp_putchar() drops every character when
 * no polled putchar exists, and wcuwsrv() frees console text when there is no
 * tem.  The helpers below write the SPCR UART directly through a kernel-VA
 * device mapping made at S1 (before release_bootstrap() removes the boot
 * identity map), echo what the two drop points discard ("|D| " and "|W| "
 * prefixes), print stage markers and a 15 s heartbeat, and read the SBSA
 * generic watchdog control frame through a read-only mapping.  The refresh
 * frame is never mapped.
 */
extern uint_t nproc;			/* common/conf/param.c */
uint64_t aa64e_uart_pa;			/* set by bop_init() */
static volatile uint32_t *aa64e_uart;	/* UART KVA, NULL until S1 */
static volatile uint32_t aa64e_lock;
volatile uint32_t aa64e_stage;
volatile uint64_t aa64e_ndrop_d;
volatile uint64_t aa64e_ndrop_w;
static int aa64e_bol_d = 1;
static int aa64e_bol_w = 1;
volatile uint32_t *aa64e_ena_state;	/* ena0's ena_state, set by ena */
volatile int *aa64e_ena_link;		/* ena0's ena_link_state */
volatile int aa64e_ena_seq;		/* last completed ena0 attach step */
volatile int aa64e_ena_fail;		/* failed ena0 attach step + 1 */

#define	AA64E_NWD	2
static volatile uint32_t *aa64e_wd[AA64E_NWD];	/* control frames, RO */
static int aa64e_nwd;
static int aa64e_wd_dead;
static uint_t aa64e_hbn;

static void
aa64e_putc_raw(int c)
{
	volatile uint32_t *u = aa64e_uart;
	uint32_t cap;

	/* Same policy as boot_uart_putchar(): bounded TXFF wait, no drain. */
	for (cap = 0; (u[0x18 / 4] & (1u << 5)) && cap < 10000u; cap++)
		__asm__ volatile("isb sy":::"memory");
	u[0] = (uint32_t)(c & 0xff);
}

static void aa64e_write1(const char *, int *, const char *, size_t);

/* At most 32 characters per interrupts-off section. */
static void
aa64e_write(const char *tag, int *bol, const char *s, size_t n)
{
	while (n > 0) {
		size_t k = MIN(n, 32);

		aa64e_write1(tag, bol, s, k);
		s += k;
		n -= k;
	}
}

static void
aa64e_write1(const char *tag, int *bol, const char *s, size_t n)
{
	uint64_t daif, t0, lim;
	int held = 1;

	if (aa64e_uart == NULL)
		return;
	daif = disable_interrupts();
	t0 = arch_timer_count();
	lim = arch_timer_freq() / 20;
	while (atomic_cas_32(&aa64e_lock, 0, 1) != 0) {
		/* never hang the caller: after 50 ms write unlocked */
		if (arch_timer_count() - t0 > lim) {
			held = 0;
			break;
		}
	}
	for (; n > 0; n--, s++) {
		if (tag != NULL && bol != NULL && *bol) {
			const char *p;
			for (p = tag; *p != '\0'; p++)
				aa64e_putc_raw(*p);
			*bol = 0;
		}
		if (*s == '\n') {
			aa64e_putc_raw('\r');
			if (bol != NULL)
				*bol = 1;
		}
		aa64e_putc_raw(*s);
	}
	if (held) {
		membar_exit();
		aa64e_lock = 0;
	}
	restore_interrupts(daif);
}

void
aa64e_printf(const char *fmt, ...)
{
	char buf[256];
	va_list ap;
	size_t n;

	va_start(ap, fmt);
	n = vsnprintf(buf, sizeof (buf), fmt, ap);
	va_end(ap);
	if (n >= sizeof (buf))
		n = sizeof (buf) - 1;
	if (aa64e_uart != NULL)
		aa64e_write(NULL, NULL, buf, n);
	else
		prom_printf("%s", buf);
}

void
aa64e_echo_d(int c)
{
	char ch = (char)c;

	atomic_inc_64(&aa64e_ndrop_d);
	aa64e_write("|D| ", &aa64e_bol_d, &ch, 1);
}

void
aa64e_echo_w(const char *s, size_t n)
{
	atomic_add_64(&aa64e_ndrop_w, (int64_t)n);
	aa64e_write("|W| ", &aa64e_bol_w, s, n);
}

static uint32_t
aa64e_rd32(const uint8_t *p)
{
	uint32_t v;
	bcopy(p, &v, sizeof (v));
	return (v);
}

static uint64_t
aa64e_rd64(const uint8_t *p)
{
	uint64_t v;
	bcopy(p, &v, sizeof (v));
	return (v);
}

/* Append "wdN wcs/wor/wcv" for each mapped watchdog; READS ONLY. */
static size_t
aa64e_wd_fmt(char *b, size_t sz)
{
	size_t o = 0;
	int i;

	for (i = 0; i < aa64e_nwd && i < AA64E_NWD && o < sz; i++) {
		volatile uint32_t *w = aa64e_wd[i];
		on_trap_data_t otd;
		uint32_t wcs = 0, worl = 0, worh = 0, wcvl = 0, wcvh = 0;
		uint32_t iidr = 0;
		uint64_t cnt, wcv;

		if (w == NULL || aa64e_wd_dead) {
			o += snprintf(b + o, sz - o, " wd%d -", i);
			continue;
		}
		if (on_trap(&otd, OT_DATA_ACCESS) == 0) {
			wcs = w[0];
			worl = w[2];
			worh = w[3];
			wcvl = w[4];
			wcvh = w[5];
			iidr = w[0xfcc / 4];
			__asm__ volatile("dsb sy; isb":::"memory");
		} else {
			aa64e_wd_dead = 1;
		}
		no_trap();
		cnt = arch_timer_count();
		wcv = ((uint64_t)wcvh << 32) | wcvl;
		o += snprintf(b + o, sz - o,
		    " wd%d%s wcs %x wor %x:%x wcv-cnt %ld iidr %x", i,
		    aa64e_wd_dead ? " TRAPPED" : "", wcs, worh, worl,
		    (long)(wcv - cnt), iidr);
	}
	return (MIN(o, sz));
}

static void
aa64e_gtdt(void)
{
	pnode_t root = prom_rootnode();
	int len = prom_getproplen(root, "solnix,acpi-gtdt");
	uint8_t *t;
	uint32_t cnt, off, i, o;
	char b[200];

	if (len < 96) {
		aa64e_printf("[AA64E] GTDT none (len %d)\n", len);
		return;
	}
	t = kmem_zalloc(len, KM_SLEEP);
	(void) prom_getprop(root, "solnix,acpi-gtdt", (caddr_t)t);
	cnt = aa64e_rd32(t + 88);
	off = aa64e_rd32(t + 92);
	aa64e_printf("[AA64E] GTDT rev %u len %d ntimers %u off %u "
	    "gsiv s-el1 %u ns-el1 %u virt %u ns-el2 %u cntfrq %lu\n",
	    t[8], len, cnt, off, aa64e_rd32(t + 48), aa64e_rd32(t + 56),
	    aa64e_rd32(t + 64), aa64e_rd32(t + 72), read_cntfrq());
	for (i = 0, o = off; i < cnt && o + 3 <= (uint32_t)len; i++) {
		uint8_t type = t[o];
		uint32_t l = t[o + 1] | ((uint32_t)t[o + 2] << 8);

		if (l < 4 || o + l > (uint32_t)len)
			break;
		if (type == 1 && l >= 28) {
			uint64_t rf = aa64e_rd64(t + o + 4);
			uint64_t cf = aa64e_rd64(t + o + 12);
			uint32_t gsiv = aa64e_rd32(t + o + 20);
			uint32_t fl = aa64e_rd32(t + o + 24);

			aa64e_printf("[AA64E] GTDT wd%d refresh 0x%lx control "
			    "0x%lx gsiv %u flags 0x%x\n", aa64e_nwd, rf, cf,
			    gsiv, fl);
			if (aa64e_nwd < AA64E_NWD && cf != 0 &&
			    (fl & 4) == 0) {
				/* PROT_READ only: the PTE is read-only */
				aa64e_wd[aa64e_nwd] = (volatile uint32_t *)
				    psm_map_phys(cf, 0x1000, PROT_READ);
			}
			aa64e_nwd++;
		} else if (type == 0 && l >= 20) {
			aa64e_printf("[AA64E] GTDT timer-block 0x%lx n %u\n",
			    aa64e_rd64(t + o + 4), aa64e_rd32(t + o + 12));
		} else {
			aa64e_printf("[AA64E] GTDT type %u len %u\n", type, l);
		}
		o += l;
	}
	kmem_free(t, len);
	(void) aa64e_wd_fmt(b, sizeof (b));
	aa64e_printf("[AA64E] S1 watchdog:%s\n", b);
}

static void
aa64e_hb(void *arg __unused)
{
	char b[448];
	size_t o = 0, sz = sizeof (b) - 2;
	proc_t *p;
	int i;

#define	AA64E_AP(...)	do { if (o < sz) o += snprintf(b + o, sz - o, \
	__VA_ARGS__); } while (0)
	AA64E_AP("[AA64E-HB] #%u %lus S%u cpu %d/%d np %u fm %lu dD %lu "
	    "dW %lu pio %d%d tq %d rc %d", aa64e_hbn++,
	    (ulong_t)(gethrtime() / NANOSEC), aa64e_stage, ncpus_online,
	    ncpus, nproc, (ulong_t)freemem, (ulong_t)aa64e_ndrop_d,
	    (ulong_t)aa64e_ndrop_w, cons_polledio != NULL,
	    cons_polledio != NULL &&
	    cons_polledio->cons_polledio_putchar != NULL,
	    console_taskq != NULL, rconsvp != NULL);
	AA64E_AP(" ena0 seq %d fail %d st %x link %d", aa64e_ena_seq,
	    aa64e_ena_fail, aa64e_ena_state != NULL ? *aa64e_ena_state : 0xff,
	    aa64e_ena_link != NULL ? *aa64e_ena_link : -9);
	if (mutex_tryenter(&pidlock)) {
		proc_t *ip = proc_init;

		if (ip != NULL && mutex_tryenter(&ip->p_lock)) {
			if (ip->p_tlist != NULL) {
				AA64E_AP(" init %s ts %x sys %d",
				    PTOU(ip)->u_comm, ip->p_tlist->t_state,
				    ip->p_tlist->t_sysnum);
			}
			mutex_exit(&ip->p_lock);
		}
		AA64E_AP(" new");
		for (i = 0, p = practive; p != NULL && i < 4;
		    i++, p = p->p_next) {
			AA64E_AP(" %d:%s", p->p_pidp->pid_id,
			    PTOU(p)->u_comm);
		}
		mutex_exit(&pidlock);
	} else {
		AA64E_AP(" pidlock-busy");
	}
	if (o < sz)
		o += aa64e_wd_fmt(b + o, sz - o);
	o = MIN(o, sz);
	b[o++] = '\n';
	aa64e_write(NULL, NULL, b, o);
#undef	AA64E_AP
	(void) realtime_timeout(aa64e_hb, NULL, 15 * hz);
}

/* S1: called from main() right after vfs_mountroot(). */
void
aa64e_init(void)
{
	if (aa64e_uart_pa != 0) {
		aa64e_uart = (volatile uint32_t *)psm_map_phys(aa64e_uart_pa,
		    0x1000, PROT_READ | PROT_WRITE);
	}
	aa64e_printf("\n[AA64E] observer up: uart pa 0x%lx kva %p boot-el %lu "
	    "cntfrq %lu ncpus %d\n", aa64e_uart_pa, (void *)aa64e_uart,
	    CPU->cpu_m.mcpu_boot_el, read_cntfrq(), ncpus);
	aa64e_gtdt();
	(void) realtime_timeout(aa64e_hb, NULL, 15 * hz);
}

void
aa64e_mark(uint32_t n, const char *what)
{
	aa64e_stage = n;
	aa64e_printf("[AA64E] S%u %s t=%lums cpus %d np %u\n", n, what,
	    (ulong_t)(gethrtime() / 1000000), ncpus_online, nproc);
	/* control: the old prom path; dropped (and echoed |D|) after S6 */
	prom_printf("[AA64E-P] S%u\n", n);
}
'''

def machdep(s):
    s = rep(s, '#include <c2/audit.h>\n',
            '#include <c2/audit.h>\n#include <sys/proc.h>\n#include <sys/cpuvar.h>\n'
            '#include <sys/ontrap.h>\n#include <sys/mman.h>\n#include <sys/console.h>\n'
            '#include <sys/atomic.h>\n#include <sys/kmem.h>\n#include <sys/user.h>\n'
            '#include <sys/thread.h>\n#include <sys/varargs.h>\n#include <sys/cmn_err.h>\n')
    s = rep(s, '\nstatic int\nsysp_getchar(void)\n', MACHDEP + '\nstatic int\nsysp_getchar(void)\n')
    s = rep(s, '\tif (cons_polledio == NULL ||\n\t    cons_polledio->cons_polledio_putchar == NULL)\n\t\treturn;\n',
            '\tif (cons_polledio == NULL ||\n\t    cons_polledio->cons_polledio_putchar == NULL) {\n'
            '\t\taa64e_echo_d(c);\t/* NOTE: observer echo of the drop */\n\t\treturn;\n\t}\n')
    return s
edit('armv8/os/machdep.c', machdep)

# ---------------------------------------------------------------- fakebop.c (unix): keep the UART PA
def fakebop(s):
    return rep(s, '\tbsvc_init(xbp);\n',
               '\tbsvc_init(xbp);\n\t{\n\t\t/* NOTE: observer: UART PA for the post-mount mapping */\n'
               '\t\textern uint64_t aa64e_uart_pa;\n\t\tif (xbp != NULL)\n'
               '\t\t\taa64e_uart_pa = xbp->bi_bsvc_uart_mmio_base;\n\t}\n')
edit('armv8/os/fakebop.c', fakebop)

# ---------------------------------------------------------------- mp_startup.c (unix): per-cpu bring-up
def mps(s):
    s = rep(s, '\t\tif (start_cpu(ci) != 0)\n\t\t\tCPUSET_DEL(mp_cpus, ci->ci_id);\n',
            '\t\t{\n\t\t\textern void aa64e_printf(const char *, ...);\n\t\t\tint aa64e_rc;\n\n'
            '\t\t\taa64e_printf(">%d ", ci->ci_id);\n'
            '\t\t\tif ((aa64e_rc = start_cpu(ci)) != 0)\n\t\t\t\tCPUSET_DEL(mp_cpus, ci->ci_id);\n'
            '\t\t\taa64e_printf("<%d:%d ", ci->ci_id, aa64e_rc);\n\t\t}\n')
    return s
edit('armv8/os/mp_startup.c', mps)

# ---------------------------------------------------------------- main.c (genunix): stage markers
M = lambda n, w: '#if defined(__aarch64__)\n\taa64e_mark(%d, "%s");\n#endif\n' % (n, w)
def main(s):
    s = rep(s, '#include <sys/bootprops.h>\n', '#include <sys/bootprops.h>\n\n'
            '#if defined(__aarch64__)\n/* NOTE: post-mount observer (armv8/os/machdep.c) */\n'
            'extern void aa64e_init(void);\nextern void aa64e_mark(uint32_t, const char *);\n#endif\n')
    s = rep(s, '\tvfs_mountroot();\t/* Mount the root file system */\n',
            '\tvfs_mountroot();\t/* Mount the root file system */\n'
            '#if defined(__aarch64__)\n\taa64e_init();\n#endif\n' + M(1, 'root mounted'))
    s = rep(s, '\tpost_startup();\n\tswaploaded = 1;\n', '\tpost_startup();\n\tswaploaded = 1;\n' + M(2, 'post_startup done'))
    s = rep(s, '\tvmem_update(NULL);\n', '\tvmem_update(NULL);\n' + M(3, 'strplumb next'))
    s = rep(s, '\t\t(void) strplumb();\n', '\t\t(void) strplumb();\n' + M(4, 'strplumb done'))
    s = rep(s, '\tconsconfig();\n#if !defined(__sparc)\n\trelease_bootstrap();\n#endif\n',
            M(5, 'consconfig next') + '\tconsconfig();\n' + M(6, 'consconfig done') +
            '#if !defined(__sparc)\n\trelease_bootstrap();\n#endif\n' + M(7, 'release_bootstrap done'))
    s = rep(s, '\ti_ddi_forceattach_drivers();\n', '\ti_ddi_forceattach_drivers();\n' + M(8, 'forceattach done'))
    s = rep(s, '\tlgrp_init(LGRP_INIT_STAGE4);\n', '\tlgrp_init(LGRP_INIT_STAGE4);\n' + M(9, 'start_other_cpus next'))
    s = rep(s, '\tstart_other_cpus(0);\n', '\tstart_other_cpus(0);\n' + M(10, 'start_other_cpus done'))
    s = rep(s, '\tpm_cfb_setup_intr();\n', '\tpm_cfb_setup_intr();\n' + M(11, 'mp_init done, init next'))
    s = rep(s, '\t    FAMOUS_PID_INIT))\n\t\tpanic("main: unable to fork init.");\n',
            '\t    FAMOUS_PID_INIT))\n\t\tpanic("main: unable to fork init.");\n' + M(12, 'init forked'))
    s = rep(s, '\t    FAMOUS_PID_FSFLUSH))\n\t\tpanic("main: unable to fork fsflush()");\n',
            '\t    FAMOUS_PID_FSFLUSH))\n\t\tpanic("main: unable to fork fsflush()");\n' + M(13, 'pageout+fsflush forked'))
    s = rep(s, '\tpid_setmin();\n', '\tpid_setmin();\n' + M(14, 'sched'))
    return s
edit('common/os/main.c', main)

# ---------------------------------------------------------------- wscons.c (wc): echo the no-tem drop
def wscons(s):
    s = rep(s, '#include <sys/vt_impl.h>\n', '#include <sys/vt_impl.h>\n\n#if defined(__aarch64__)\n'
            '/* NOTE: post-mount observer (armv8/os/machdep.c) */\nextern void aa64e_echo_w(const char *, size_t);\n#endif\n')
    s = rep(s, '\t\t\tif (ptem == NULL) {\n\t\t\t\tfreemsg(mp);\n\t\t\t\tcontinue;\n\t\t\t}\n',
            '\t\t\tif (ptem == NULL) {\n#if defined(__aarch64__)\n'
            '\t\t\t\tfor (mblk_t *nbp = mp; nbp != NULL;\n\t\t\t\t    nbp = nbp->b_cont) {\n'
            '\t\t\t\t\tif (nbp->b_wptr > nbp->b_rptr)\n\t\t\t\t\t\taa64e_echo_w(\n'
            '\t\t\t\t\t\t    (const char *)nbp->b_rptr,\n'
            '\t\t\t\t\t\t    nbp->b_wptr - nbp->b_rptr);\n\t\t\t\t}\n#endif\n'
            '\t\t\t\tfreemsg(mp);\n\t\t\t\tcontinue;\n\t\t\t}\n')
    return s
edit('common/io/wscons.c', wscons)

# ---------------------------------------------------------------- ena.c / ena_dma.c: ena0 attach state
def ena(s):
    s = rep(s, '#include "ena.h"\n', '#include "ena.h"\n\n#if defined(__aarch64__)\n'
            '/*\n * NOTE: post-mount observer (armv8/os/machdep.c).  Weak: ena links\n'
            ' * with -z defs and the DDI mapfiles; krtld binds these from unix.\n */\n'
            'extern volatile uint32_t *aa64e_ena_state __attribute__((weak));\n'
            'extern volatile int *aa64e_ena_link __attribute__((weak));\n'
            'extern volatile int aa64e_ena_seq __attribute__((weak));\n'
            'extern volatile int aa64e_ena_fail __attribute__((weak));\n'
            'extern void aa64e_printf(const char *, ...) __attribute__((weak));\n'
            '#define\tAA64E_HAVE\t(&aa64e_ena_seq != NULL && &aa64e_printf != NULL)\n#endif\n')
    s = rep(s, '\t\t\tena_err(ena, "attach sequence failed: %s (%d)",\n\t\t\t    desc->ead_name, i);\n',
            '\t\t\tena_err(ena, "attach sequence failed: %s (%d)",\n\t\t\t    desc->ead_name, i);\n'
            '#if defined(__aarch64__)\n\t\t\tif (AA64E_HAVE && ena->ena_instance == 0)\n\t\t\t\taa64e_ena_fail = i + 1;\n#endif\n')
    s = rep(s, '\t\tena->ena_attach_seq = desc->ead_seq;\n',
            '\t\tena->ena_attach_seq = desc->ead_seq;\n#if defined(__aarch64__)\n'
            '\t\tif (AA64E_HAVE) {\n\t\t\taa64e_printf("[AA64E] ena%d attach %d %s ok\\n",\n'
            '\t\t\t    ena->ena_instance, i, desc->ead_name);\n'
            '\t\t\tif (ena->ena_instance == 0)\n\t\t\t\taa64e_ena_seq = desc->ead_seq;\n\t\t}\n#endif\n')
    s = rep(s, '\tddi_set_driver_private(dip, ena);\n',
            '\tddi_set_driver_private(dip, ena);\n#if defined(__aarch64__)\n\tif (AA64E_HAVE && ena->ena_instance == 0) {\n'
            '\t\taa64e_ena_link = (volatile int *)&ena->ena_link_state;\n'
            '\t\taa64e_ena_state = &ena->ena_state;\n\t}\n#endif\n')
    s = rep(s, '\tddi_set_driver_private(dip, NULL);\n\tkmem_free(ena, sizeof (ena_t));\n',
            '#if defined(__aarch64__)\n\tif (AA64E_HAVE && ena->ena_instance == 0) {\n\t\taa64e_ena_state = NULL;\n'
            '\t\taa64e_ena_link = NULL;\n\t}\n#endif\n'
            '\tddi_set_driver_private(dip, NULL);\n\tkmem_free(ena, sizeof (ena_t));\n')
    return s
edit('common/io/ena/ena.c', ena)
def enadma(s):
    return rep(s, 'ena_err(ena, "!', 'ena_err(ena, "', 3)
edit('common/io/ena/ena_dma.c', enadma)

# ---------------------------------------------------------------- dboot: raw GTDT on the root node
def dboot(s):
    a = '\t(void) fdt_property_string(fdt, "compatible", "solnix,acpi-synth");\n'
    return rep(s, a, a +
        '\t{\n\t\t/*\n\t\t * NOTE: diagnostic.  Copy the raw ACPI GTDT so the kernel can\n'
        '\t\t * report the SBSA watchdog read-only.  Capped at 1 KiB.\n\t\t */\n'
        '\t\tconst ACPI_TABLE_HEADER *gtdt =\n\t\t    synth_find_table(ACPI_SIG_GTDT);\n'
        '\t\tif (gtdt != NULL) {\n\t\t\tUINT32 glen;\n\t\t\tmemcpy(&glen, &gtdt->Length, sizeof (glen));\n'
        '\t\t\tif (glen > 1024)\n\t\t\t\tglen = 1024;\n'
        '\t\t\t(void) fdt_property(fdt, "solnix,acpi-gtdt",\n\t\t\t    gtdt, (int)glen);\n\t\t}\n\t}\n')
edit(DBOOT, dboot)
print('AA64E_OBSERVERS_OK')
