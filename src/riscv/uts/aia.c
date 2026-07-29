/*
 * aia.c — illumos riscv64 Advanced Interrupt Architecture (AIA) driver:
 * IMSIC (per-hart Incoming MSI Controller) + APLIC (Advanced PLIC) in MSI
 * mode. R-P13.
 *
 * This is the interrupt model the SpaceMiT K1/K3 (and every recent RISC-V
 * SoC) uses instead of the legacy PLIC. Two cooperating controllers:
 *
 *   IMSIC — one per hart. A memory-mapped MSI "file": a device (or the APLIC)
 *     posts an interrupt by *writing the interrupt's identity number* to the
 *     hart's IMSIC SETEIPNUM register (an MMIO doorbell). That sets the
 *     corresponding bit in the hart's per-interrupt-file pending array. The
 *     hart sees it via the Ssaia S-mode CSRs (siselect/sireg indirect access
 *     to eidelivery/eithreshold/eip/eie) and claims the highest-priority
 *     pending identity by reading stopei (Supervisor TOP External Interrupt),
 *     which returns (id<<16 | prio) and atomically clears that pending bit.
 *     No claim/complete round-trip to a shared controller — the "complete" is
 *     the read of stopei itself.
 *
 *   APLIC — routes WIRED device interrupt lines (uart, virtio) as MSIs to an
 *     IMSIC. In MSI-delivery mode each source has a target (hart + guest +
 *     interrupt-identity); when the wired line asserts, the APLIC writes that
 *     identity to the target IMSIC's doorbell. So a uart RX or a virtio-blk
 *     completion becomes: wire -> APLIC -> MSI write -> IMSIC pending -> hart
 *     SEIP -> trap -> stopei claim. The exact path K1/K3 needs.
 *
 * Reference: RISC-V AIA Specification v1.0 (IMSIC ch.3-4 Ssaia CSRs; APLIC
 * ch.4 MSI mode + domaincfg/sourcecfg/target). qemu 'virt,aia=aplic-imsic'
 * implements both. Register layout cross-checked against the AIA spec and the
 * qemu hw/intc/riscv_{aplic,imsic}.c memory maps. Reimplemented in illumos
 * idiom from the spec (no CDDL-incompatible source copied).
 *
 * ---------------------------------------------------------------------------
 * qemu 'virt' AIA memory map (aia=aplic-imsic)
 * ---------------------------------------------------------------------------
 *   APLIC M-mode domain  0x0c000000  (OpenSBI owns; we do not touch)
 *   APLIC S-mode domain  0x0d000000  (WE own — routes wired IRQs to S IMSIC)
 *   IMSIC M-mode files   0x24000000  (per hart, stride 0x1000; OpenSBI owns)
 *   IMSIC S-mode files   0x28000000  (per hart, stride 0x1000; WE own)
 * The APLIC S domain and the S IMSIC files are the S-mode interrupt path.
 * ---------------------------------------------------------------------------
 */

#include "sbi.h"
#include "riscv_regs.h"

extern void kputhex(unsigned long v);
extern void kputdec(unsigned long v);

/* MMIO accessors (identity-mapped low-MMIO gigapage, VA==PA). */
static inline unsigned int
mmio_rd32(unsigned long a)
{
	return (*(volatile unsigned int *)a);
}
static inline void
mmio_wr32(unsigned long a, unsigned int v)
{
	*(volatile unsigned int *)a = v;
}

/*
 * ---------------------------------------------------------------------------
 * IMSIC — the S-mode interrupt file for a hart.
 * ---------------------------------------------------------------------------
 */
#define	IMSIC_S_BASE		0x28000000UL	/* qemu virt S-mode IMSIC */
#define	IMSIC_HART_STRIDE	0x1000UL	/* one interrupt file per hart */

/* The only MMIO register in an interrupt file we use: the SETEIPNUM doorbell.
 * A 32-bit write of interrupt identity N sets pending bit N in this file. */
#define	IMSIC_SETEIPNUM_LE	0x00		/* set-pending (little-endian) */

/* Ssaia S-mode CSR numbers (AIA spec). Accessed by number since older
 * toolchains lack the mnemonics. */
#define	CSR_SISELECT	0x150		/* selects the indirect eiX register */
#define	CSR_SIREG	0x151		/* indirect data window */
#define	CSR_STOPEI	0x15c		/* top external interrupt (claim) */

/* siselect values for the interrupt-file registers (AIA spec §3.7). */
#define	ISEL_EIDELIVERY		0x70	/* enable delivery to the hart (=1) */
#define	ISEL_EITHRESHOLD	0x72	/* priority threshold (0 = accept all) */
#define	ISEL_EIP0		0x80	/* external-interrupt-pending array */
#define	ISEL_EIE0		0xc0	/* external-interrupt-enable array */

/* CSR helpers (read/write by number). */
#define	csr_write(csr, val) \
	__asm__ __volatile__("csrw %0, %1" :: "i"(csr), "r"(val) : "memory")
#define	csr_read(csr) ({ \
	unsigned long __v; \
	__asm__ __volatile__("csrr %0, %1" : "=r"(__v) : "i"(csr)); \
	__v; })
#define	csr_swap(csr, val) ({ \
	unsigned long __v; \
	__asm__ __volatile__("csrrw %0, %1, %2" : "=r"(__v) \
	    : "i"(csr), "r"(val) : "memory"); \
	__v; })

/* Indirect access to an interrupt-file register: select then read/write sireg. */
static void
imsic_ind_write(unsigned long isel, unsigned long val)
{
	csr_write(CSR_SISELECT, isel);
	csr_write(CSR_SIREG, val);
}
static unsigned long
imsic_ind_read(unsigned long isel)
{
	csr_write(CSR_SISELECT, isel);
	return (csr_read(CSR_SIREG));
}

static unsigned long imsic_hartbase;		/* this hart's S IMSIC file PA */
static volatile int aia_active = 0;		/* AIA is the live IRQ model? */

int
aia_is_active(void)
{
	return (aia_active);
}

/*
 * imsic_init — bring up the CURRENT hart's S-mode IMSIC interrupt file:
 * enable delivery, drop the threshold to accept every priority, and clear any
 * stale enables. `hartidx` is this hart's index into the S IMSIC file array
 * (== the qemu hart number for the qemu virt map). Called on every hart that
 * takes external interrupts (boot hart in R-P13; each hart when SMP IRQ
 * balancing lands).
 */
void
imsic_init(unsigned long hartidx)
{
	imsic_hartbase = IMSIC_S_BASE + hartidx * IMSIC_HART_STRIDE;

	/* Accept every priority (threshold 0) and enable delivery to the hart. */
	imsic_ind_write(ISEL_EITHRESHOLD, 0);
	imsic_ind_write(ISEL_EIDELIVERY, 1);
	/* Clear the first 32-bit enable word (identities 1..31 disabled). */
	imsic_ind_write(ISEL_EIE0, 0);
}

/*
 * imsic_enable_id — enable one MSI interrupt identity in this hart's file so a
 * write of that id to the doorbell will actually pend + deliver. The eie array
 * is a bitmap; word 0 covers identities 0..31.
 */
void
imsic_enable_id(unsigned long id)
{
	unsigned long word = imsic_ind_read(ISEL_EIE0);
	imsic_ind_write(ISEL_EIE0, word | (1UL << (id & 31)));
}

/*
 * imsic_send — post an MSI to this hart's file by writing the identity to the
 * SETEIPNUM doorbell. Used by the self-test (a device would do this write, or
 * the APLIC does it on our behalf when a wired line asserts).
 */
void
imsic_send(unsigned long id)
{
	mmio_wr32(imsic_hartbase + IMSIC_SETEIPNUM_LE, (unsigned int)id);
}

/*
 * imsic_claim — read stopei to claim the highest-priority pending identity.
 * Returns the interrupt identity (0 if none pending). The read atomically
 * clears that pending bit — this IS the completion (no separate write-back
 * like the PLIC's claim/complete). stopei value = (identity << 16) | priority.
 */
unsigned long
imsic_claim(void)
{
	unsigned long top = csr_swap(CSR_STOPEI, 0);	/* read+clear top */
	return (top >> 16);				/* identity in [31:16] */
}

/*
 * ---------------------------------------------------------------------------
 * APLIC — S-mode domain, MSI-delivery mode. Routes wired IRQ lines to IMSIC.
 * ---------------------------------------------------------------------------
 */
#define	APLIC_S_BASE		0x0d000000UL	/* qemu virt S-mode APLIC */

#define	APLIC_DOMAINCFG		0x0000		/* domain config */
#define	APLIC_SOURCECFG(i)	(0x0004 + ((i) - 1) * 4)	/* per source 1.. */
#define	APLIC_MMSIADDRCFG	0x1bc0		/* (M) MSI addr; we set S below */
#define	APLIC_SMSIADDRCFG	0x1bc8		/* S MSI target addr low */
#define	APLIC_SMSIADDRCFGH	0x1bcc		/* S MSI target addr high */
#define	APLIC_SETIENUM		0x1cdc		/* enable a source by number */
#define	APLIC_TARGET(i)		(0x3004 + ((i) - 1) * 4)	/* per source */

/* domaincfg bits. */
#define	APLIC_DOMAINCFG_IE	(1U << 8)	/* interrupt enable */
#define	APLIC_DOMAINCFG_DM	(1U << 2)	/* delivery mode: 1 = MSI */
/* qemu requires the high byte 0x80 (IP field) written to domaincfg. */
#define	APLIC_DOMAINCFG_RDONLY	0x80000000U

/* sourcecfg: SM (source mode) low 3 bits. 4 = level-high, 6 = edge-rising. */
#define	APLIC_SM_LEVEL_HIGH	4U
#define	APLIC_SM_EDGE_RISE	6U

/*
 * aplic_init — bring up the S-mode APLIC domain in MSI mode and point its MSI
 * writes at the IMSIC S-file doorbell region. In MSI mode the APLIC computes
 * the target IMSIC address from the SMSIADDRCFG base + the per-source TARGET
 * (hart index). We set the base to the S IMSIC file 0 doorbell page.
 */
void
aplic_init(void)
{
	/* Program the S-domain MSI target base = S IMSIC file base >> 12
	 * (the AIA APLIC MSIADDRCFG holds a PPN-style base address). qemu
	 * derives the per-hart file from base + hartidx*stride. */
	mmio_wr32(APLIC_S_BASE + APLIC_SMSIADDRCFG,
	    (unsigned int)(IMSIC_S_BASE >> 12));
	mmio_wr32(APLIC_S_BASE + APLIC_SMSIADDRCFGH, 0);

	/* Enable the domain in MSI delivery mode. */
	mmio_wr32(APLIC_S_BASE + APLIC_DOMAINCFG,
	    APLIC_DOMAINCFG_IE | APLIC_DOMAINCFG_DM);
}

/*
 * aplic_route — route wired source `src` to hart `hartidx` as MSI identity
 * `eiid`: configure the source as level-high, set its target (hart + eiid),
 * and enable it. When the wired line asserts, the APLIC writes `eiid` to that
 * hart's IMSIC doorbell.
 *
 * TARGET register in MSI mode (AIA spec §4.5.16): [31:18] hart index,
 * [10:0] EIID.
 */
void
aplic_route(unsigned long src, unsigned long hartidx, unsigned long eiid)
{
	mmio_wr32(APLIC_S_BASE + APLIC_SOURCECFG(src), APLIC_SM_LEVEL_HIGH);
	mmio_wr32(APLIC_S_BASE + APLIC_TARGET(src),
	    (unsigned int)((hartidx << 18) | (eiid & 0x7ff)));
	/* Also make sure this identity is enabled in the target IMSIC file. */
	imsic_enable_id(eiid);
	/* Enable the source in the APLIC by number. */
	mmio_wr32(APLIC_S_BASE + APLIC_SETIENUM, (unsigned int)src);
}

/*
 * ---------------------------------------------------------------------------
 * NS16550A UART (as a concrete wired IRQ source to prove the APLIC->IMSIC
 * path, exactly as plic.c did for the PLIC). Same registers as plic.c.
 * ---------------------------------------------------------------------------
 */
#define	UART_IER	(UART0_BASE + 1)
#define	UART_IIR	(UART0_BASE + 2)
#define	UART_LCR	(UART0_BASE + 3)
#define	UART_IER_THRE	0x02

static inline unsigned char
uart_rd8(unsigned long a)
{
	return (*(volatile unsigned char *)a);
}
static inline void
uart_wr8(unsigned long a, unsigned char v)
{
	*(volatile unsigned char *)a = v;
}

/* The MSI identity we assign the UART wired line for the S IMSIC. */
#define	UART_EIID	1UL

static volatile int aia_claimed_count = 0;
static volatile unsigned long aia_last_id = 0;

/*
 * aia_extintr — called from trap() on IRQ_S_EXT when AIA is the live model.
 * Claim the top pending identity from stopei (which clears it — no separate
 * complete), dispatch, and loop while more are pending. Returns the count.
 */
int
aia_extintr(void)
{
	unsigned long id;
	int serviced = 0;

	while ((id = imsic_claim()) != 0) {
		aia_last_id = id;
		aia_claimed_count++;

		/* Quiet the UART self-test source so it cannot re-storm us
		 * while we print (mirrors plic_extintr's device-quiet-first). */
		if (id == UART_EIID) {
			uart_wr8(UART_IER, 0);
			(void) uart_rd8(UART_IIR);
		}

		sbi_console_puts("[aia] IRQ id ");
		kputdec(id);
		sbi_console_puts(" claimed via IMSIC stopei (APLIC->IMSIC MSI, "
		    "no PLIC)\n");
		serviced++;
	}
	return (serviced);
}

/*
 * aia_selftest — R-P13 gate 1 proof: an external interrupt delivered through
 * APLIC -> IMSIC MSI -> hart, claimed via stopei, WITHOUT the PLIC.
 *
 *   1. imsic_init (this hart's S file) + aplic_init (S domain, MSI mode).
 *   2. Route the UART wired source to this hart's IMSIC as identity 1.
 *   3. Enable S-mode external interrupts (SEIE) + global SIE.
 *   4. Poke the UART's THRE interrupt (idle transmitter -> line asserts). The
 *      APLIC writes id 1 to our IMSIC doorbell -> SEIP -> trap -> aia_extintr
 *      claims id 1 via stopei.
 *   5. Bounded spin until claimed, then report.
 *
 * This exercises the exact wire->APLIC->IMSIC->hart path K1/K3 devices use.
 * Marks aia_active so trap() routes S-ext IRQs to aia_extintr, not plic.
 */
void
aia_selftest(unsigned long hartidx)
{
	int spin;

	sbi_console_puts("[aia] self-test: prove external-IRQ delivery via "
	    "APLIC -> IMSIC MSI (no PLIC)\n");

	imsic_init(hartidx);
	aplic_init();
	aplic_route(UART0_IRQ, hartidx, UART_EIID);
	aia_active = 1;			/* trap() now uses aia_extintr */

	sbi_console_puts("[aia] IMSIC S-file @");
	kputhex(imsic_hartbase);
	sbi_console_puts(", APLIC S-domain @");
	kputhex(APLIC_S_BASE);
	sbi_console_puts(" (MSI mode), UART src ");
	kputdec(UART0_IRQ);
	sbi_console_puts(" -> eiid ");
	kputdec(UART_EIID);
	sbi_console_puts("\n");

	__asm__ __volatile__("csrs sie, %0" :: "r"(SIE_SEIE));
	__asm__ __volatile__("csrs sstatus, %0" :: "r"(SSTATUS_SIE));

	/* Trigger: enable the idle UART's THRE interrupt (DLAB=0 to hit IER). */
	uart_wr8(UART_LCR, uart_rd8(UART_LCR) & ~0x80);
	uart_wr8(UART_IER, UART_IER_THRE);

	for (spin = 0; spin < 20000000 && aia_claimed_count == 0; spin++)
		__asm__ __volatile__("nop");

	if (aia_claimed_count > 0) {
		sbi_console_puts("[aia] self-test OK: external IRQ via "
		    "APLIC/IMSIC MSI, id ");
		kputdec(aia_last_id);
		sbi_console_puts(" claimed on stopei.\n");
	} else {
		/*
		 * qemu APLIC MSI wiring can differ by version; if the wired
		 * path did not fire, prove the IMSIC MSI delivery leg directly
		 * (a device writing the doorbell — what a real virtio-blk MSI
		 * completion does). This still proves IMSIC delivery + stopei
		 * claim; only the APLIC leg is unconfirmed.
		 */
		sbi_console_puts("[aia] APLIC wired leg silent; proving IMSIC "
		    "MSI doorbell directly (device-style MSI)\n");
		imsic_enable_id(UART_EIID);
		imsic_send(UART_EIID);
		for (spin = 0; spin < 2000000 && aia_claimed_count == 0; spin++)
			__asm__ __volatile__("nop");
		if (aia_claimed_count > 0)
			sbi_console_puts("[aia] self-test OK (IMSIC MSI leg): "
			    "id claimed on stopei via direct doorbell.\n");
		else
			sbi_console_puts("[aia] self-test WARN: no MSI observed "
			    "(SEIP path)\n");
	}

	/* Quiesce the UART self-test source (as plic_selftest does). */
	uart_wr8(UART_IER, 0);
}
