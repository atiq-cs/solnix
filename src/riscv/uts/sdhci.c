/*
 * sdhci.c — illumos riscv64 SDHCI / eMMC block driver (R-P15).
 *
 * The SpaceMiT K1 root filesystem lives on an SD/eMMC card behind a Synopsys
 * DesignWare mobile-storage host controller (compatible="snps,dwcmshc-sdhci"),
 * which is SD Host Controller (SDHCI) register-compatible. R-P14 was an honest
 * register-level PROBE (decode HCVER/CAPS/PRESENT_STATE). R-P15 grows it into a
 * real block driver: SDHCI reset, the SD/MMC card init handshake, and a
 * single-block sector read (CMD17) — the path that actually mounts a root fs.
 *
 * ---------------------------------------------------------------------------
 * SD/MMC init sequence (SD Physical Layer Simplified Spec 6.00 §4.2, and the
 * SD Host Controller Simplified Spec 3.00 §3.7), the standard bring-up every
 * driver walks:
 *   CMD0   GO_IDLE_STATE       reset the card to idle
 *   CMD8   SEND_IF_COND        voltage handshake (SDHC/SDXC detect, 0x1AA)
 *   ACMD41 SD_SEND_OP_COND     (CMD55 then CMD41) negotiate OCR, poll BUSY,
 *                              read CCS (bit30) = high-capacity (block-addr)
 *   CMD2   ALL_SEND_CID        card identification (136-bit CID)
 *   CMD3   SEND_RELATIVE_ADDR  card publishes its RCA
 *   CMD7   SELECT_CARD         put the RCA'd card into transfer state
 *   CMD17  READ_SINGLE_BLOCK   read one 512-byte block (by block address)
 * ---------------------------------------------------------------------------
 *
 * SDHCI standard register map (byte offsets from the controller base):
 *   0x00  SDMA System Address / Argument2
 *   0x04  Block Size / Block Count
 *   0x08  Argument1
 *   0x0c  Transfer Mode (16b) / Command (16b) [CMD write triggers issue]
 *   0x10  Response0..3 (0x10,0x14,0x18,0x1c)
 *   0x20  Buffer Data Port (PIO read/write window)
 *   0x24  Present State (card inserted, cmd/dat inhibit, buffer rd/wr enable)
 *   0x28  Host Control 1 (8b) / Power Control (8b @0x29)
 *   0x2c  Clock Control (16b) / Timeout (8b @0x2e) / Software Reset (8b @0x2f)
 *   0x30  Normal Int Status (16b) / Error Int Status (16b @0x32)
 *   0x40  Capabilities (64b: base clock, max block len, bus widths...)
 *   0xfe  Host Controller Version (16b: [7:0] spec version, [15:8] vendor)
 *
 * ---------------------------------------------------------------------------
 * qemu-vs-real-silicon (READ THIS — the emulation honesty boundary)
 * ---------------------------------------------------------------------------
 * The qemu 'virt' machine has NO SDHCI controller. R-P15's hat now identity-
 * maps the K1 device gigapage (0xc0000000..0x100000000), so a load from
 * 0xd4281000 no longer faults — but on qemu-virt nothing is wired there, so a
 * live read returns 0. There is therefore NO real SDHCI/SD device we can drive
 * end-to-end under qemu-virt.
 *
 * So the R-P15 block driver is exercised against a FAITHFUL in-kernel SDHCI+SD
 * REGISTER MODEL (sdmodel_*), compiled in and clearly marked. The model
 * implements exactly the SDHCI registers and SD responses the driver touches:
 * SRST, the command/response FIFO, PRESENT_STATE inhibit/ready bits, the
 * Normal-Int command/transfer-complete + buffer-read-ready bits, and the
 * Buffer Data Port streaming one backing 512-byte sector 0 (a real MBR with the
 * 0x55aa signature). The DRIVER code (sdhci_*, mmc_*) is IDENTICAL on the model
 * and on silicon: only the mmio_rd/mmio_wr primitives switch between touching
 * the model's shadow registers and touching real K1 MMIO. On the physical K1
 * board (base 0xd4281000, real silicon) the same sdhci_reset/mmc_card_init/
 * mmc_read_sector run against the real dwcmshc-sdhci — the delta is ONLY the
 * mmio target, documented at each gate. Reimplemented from the public SD/SDHCI
 * simplified specs (no CDDL-incompatible source copied).
 */

#include "k1.h"

extern void kputhex(unsigned long v);
extern void kputdec(unsigned long v);
extern void sbi_console_puts(const char *s);

/* The R-P15 hat identity-maps the K1 device gigapage at 0xc0000000. Bases in
 * [K1_DEV_LO, K1_DEV_HI) are now reachable via load/store (no fault). */
#define	K1_DEV_LO	0xc0000000UL
#define	K1_DEV_HI	0x100000000UL

/* ---- SDHCI register offsets ---- */
#define	SDHCI_ARG2		0x00
#define	SDHCI_BLOCK_SIZE	0x04	/* 16b */
#define	SDHCI_BLOCK_COUNT	0x06	/* 16b */
#define	SDHCI_ARG1		0x08	/* 32b */
#define	SDHCI_XFER_MODE		0x0c	/* 16b */
#define	SDHCI_CMD		0x0e	/* 16b (issue on write) */
#define	SDHCI_RESP0		0x10	/* 32b x4 (0x10/0x14/0x18/0x1c) */
#define	SDHCI_BUFFER		0x20	/* 32b PIO data port */
#define	SDHCI_PRESENT_STATE	0x24	/* 32b */
#define	SDHCI_HOST_CTRL1	0x28	/* 8b */
#define	SDHCI_POWER_CTRL	0x29	/* 8b */
#define	SDHCI_CLOCK_CTRL	0x2c	/* 16b */
#define	SDHCI_SOFT_RESET	0x2f	/* 8b */
#define	SDHCI_INT_STATUS	0x30	/* 16b normal */
#define	SDHCI_ERR_STATUS	0x32	/* 16b error */
#define	SDHCI_CAPABILITIES	0x40	/* 64b */
#define	SDHCI_HOST_VERSION	0xfe	/* 16b */

/* Present State bits. */
#define	PSTATE_CMD_INHIBIT	(1U << 0)
#define	PSTATE_DAT_INHIBIT	(1U << 1)
#define	PSTATE_BUF_RD_EN	(1U << 11)
#define	PSTATE_CARD_INSERTED	(1U << 16)

/* Software Reset bits (0x2f). */
#define	SRST_ALL		(1U << 0)
#define	SRST_CMD		(1U << 1)
#define	SRST_DAT		(1U << 2)

/* Normal Interrupt Status bits (0x30). */
#define	NINT_CMD_COMPLETE	(1U << 0)
#define	NINT_XFER_COMPLETE	(1U << 1)
#define	NINT_BUF_RD_READY	(1U << 5)

/* Command register (0x0e) field encodings. */
#define	CMD_RESP_NONE		0x0
#define	CMD_RESP_136		0x1	/* R2 (CID/CSD) */
#define	CMD_RESP_48		0x2	/* R1/R3/R6/R7 */
#define	CMD_RESP_48_BUSY	0x3	/* R1b */
#define	CMD_DATA_PRESENT	(1U << 5)
#define	CMD_IDX(i)		(((unsigned int)(i)) << 8)

/* Transfer Mode (0x0c). */
#define	XFER_READ		(1U << 4)	/* data direction: card->host */
#define	XFER_BLKCNT_EN		(1U << 1)

/* SD/MMC command indices. */
#define	MMC_GO_IDLE		0	/* CMD0  */
#define	MMC_SEND_IF_COND	8	/* CMD8  */
#define	MMC_ALL_SEND_CID	2	/* CMD2  */
#define	MMC_SEND_RCA		3	/* CMD3  */
#define	MMC_SELECT_CARD		7	/* CMD7  */
#define	MMC_READ_SINGLE		17	/* CMD17 */
#define	MMC_APP_CMD		55	/* CMD55 (ACMD prefix) */
#define	SD_APP_OP_COND		41	/* ACMD41 */

#define	CMD8_VHS_PATTERN	0x1AAU	/* 2.7-3.6V + check pattern 0xAA */
#define	OCR_HCS			(1U << 30)	/* host: request high capacity */
#define	OCR_BUSY		(1U << 31)	/* card: power-up done */
#define	OCR_CCS			(1U << 30)	/* card: high capacity (SDHC) */
#define	OCR_VOLT_WINDOW		0x00FF8000U	/* 2.7-3.6V voltage window */

#define	SECTOR_SIZE		512

/*
 * =====================================================================
 *  FAITHFUL SDHCI + SD register model (emulation-only; marked).
 *  Backs the MMIO when the base is NOT real K1 silicon we can reach.
 * =====================================================================
 */
struct sdmodel {
	int active;
	unsigned int pstate;
	unsigned int nint;		/* normal int status */
	unsigned int arg;
	unsigned int resp[4];
	unsigned int last_cmd_idx;
	int expect_acmd;		/* CMD55 seen -> next CMD is ACMD */
	int acmd41_polls;		/* model card busy for a few polls */
	unsigned int rca;
	/* PIO read window over one backing sector. */
	unsigned char sector0[SECTOR_SIZE];
	int buf_pos;			/* byte offset into sector0 while reading */
	int buf_open;			/* a read data window is open */
};
static struct sdmodel sdm;

/* Populate the model's backing sector 0 with a real MBR (55 aa signature). */
static void
sdmodel_init_sector0(void)
{
	int i;
	for (i = 0; i < SECTOR_SIZE; i++)
		sdm.sector0[i] = 0;
	/* A recognizable label + a valid MBR boot signature at 510/511. */
	{
		const char *lbl = "SOLNIX-K1-SDHCI-ROOTFS-R-P15";
		int j;
		for (j = 0; lbl[j] != '\0' && j < 64; j++)
			sdm.sector0[j] = (unsigned char)lbl[j];
	}
	sdm.sector0[510] = 0x55;
	sdm.sector0[511] = 0xaa;
}

static void
sdmodel_reset(void)
{
	int i;
	sdm.active = 1;
	sdm.pstate = PSTATE_CARD_INSERTED;	/* card present, no inhibit */
	sdm.nint = 0;
	sdm.arg = 0;
	for (i = 0; i < 4; i++)
		sdm.resp[i] = 0;
	sdm.last_cmd_idx = 0;
	sdm.expect_acmd = 0;
	sdm.acmd41_polls = 0;
	sdm.rca = 0;
	sdm.buf_pos = 0;
	sdm.buf_open = 0;
	sdmodel_init_sector0();
}

/* Model a command issue: compute the response + set command-complete. */
static void
sdmodel_issue(unsigned int cmdreg)
{
	unsigned int idx = (cmdreg >> 8) & 0x3f;

	sdm.nint |= NINT_CMD_COMPLETE;
	sdm.last_cmd_idx = idx;

	if (sdm.expect_acmd && idx == SD_APP_OP_COND) {
		/* ACMD41: report busy for a couple polls, then powered-up SDHC. */
		if (sdm.acmd41_polls < 2) {
			sdm.acmd41_polls++;
			sdm.resp[0] = OCR_VOLT_WINDOW;		/* BUSY clear */
		} else {
			sdm.resp[0] = OCR_BUSY | OCR_CCS | OCR_VOLT_WINDOW;
		}
		sdm.expect_acmd = 0;
		return;
	}
	sdm.expect_acmd = 0;

	switch (idx) {
	case MMC_GO_IDLE:
		sdm.resp[0] = 0;
		break;
	case MMC_SEND_IF_COND:
		/* R7 echoes the check pattern + voltage-accepted nibble. */
		sdm.resp[0] = sdm.arg & 0xfff;
		break;
	case MMC_APP_CMD:
		sdm.expect_acmd = 1;
		sdm.resp[0] = 0;
		break;
	case MMC_ALL_SEND_CID:
		/* R2 136-bit CID: a plausible manufacturer/product blob. */
		sdm.resp[0] = 0x53303130;	/* "S010" */
		sdm.resp[1] = 0x4e495853;	/* "NIXS" */
		sdm.resp[2] = 0x4b31534f;	/* "K1SO" */
		sdm.resp[3] = 0x00035350;
		break;
	case MMC_SEND_RCA:
		sdm.rca = 0xaaaa;
		sdm.resp[0] = (sdm.rca << 16) | 0x0500;	/* RCA + status */
		break;
	case MMC_SELECT_CARD:
		sdm.resp[0] = 0x00000700;		/* transfer state */
		break;
	case MMC_READ_SINGLE:
		/* Open the PIO read window over sector 0; signal buffer ready. */
		sdm.buf_pos = 0;
		sdm.buf_open = 1;
		sdm.pstate |= PSTATE_BUF_RD_EN;
		sdm.nint |= NINT_BUF_RD_READY;
		sdm.resp[0] = 0x00000900;		/* ready-for-data */
		break;
	default:
		sdm.resp[0] = 0;
		break;
	}
}

/* Model MMIO read/write dispatch. Returns 1 if the model handled it. */
static int
sdmodel_rd(unsigned int off, unsigned int *out, int width)
{
	if (!sdm.active)
		return (0);
	switch (off) {
	case SDHCI_PRESENT_STATE:
		*out = sdm.pstate;
		return (1);
	case SDHCI_INT_STATUS:
		*out = sdm.nint & 0xffff;
		return (1);
	case SDHCI_RESP0:
		*out = sdm.resp[0];
		return (1);
	case SDHCI_RESP0 + 4:
		*out = sdm.resp[1];
		return (1);
	case SDHCI_RESP0 + 8:
		*out = sdm.resp[2];
		return (1);
	case SDHCI_RESP0 + 12:
		*out = sdm.resp[3];
		return (1);
	case SDHCI_HOST_VERSION:
		*out = 0x0002;		/* vendor 0, spec ver field 2 => 3.00 */
		return (1);
	case SDHCI_CAPABILITIES:
		*out = 0x016b0000;	/* plausible caps (base clk etc.) */
		return (1);
	case SDHCI_SOFT_RESET:
		*out = 0;		/* reset self-clears immediately */
		return (1);
	case SDHCI_BUFFER:
		/* Stream the next 4 bytes of sector 0 (little-endian word). */
		{
			unsigned int w = 0;
			int i;
			for (i = 0; i < 4; i++) {
				unsigned int b = 0;
				if (sdm.buf_open && sdm.buf_pos < SECTOR_SIZE)
					b = sdm.sector0[sdm.buf_pos++];
				w |= (b << (8 * i));
			}
			if (sdm.buf_pos >= SECTOR_SIZE) {
				sdm.buf_open = 0;
				sdm.pstate &= ~PSTATE_BUF_RD_EN;
				sdm.nint |= NINT_XFER_COMPLETE;
			}
			*out = w;
		}
		return (1);
	default:
		*out = 0;
		(void) width;
		return (1);	/* unknown reg: read as 0 (harmless) */
	}
}

static int
sdmodel_wr(unsigned int off, unsigned int val, int width)
{
	if (!sdm.active)
		return (0);
	(void) width;
	switch (off) {
	case SDHCI_SOFT_RESET:
		if (val & SRST_ALL)
			sdmodel_reset();
		return (1);
	case SDHCI_ARG1:
		sdm.arg = val;
		return (1);
	case SDHCI_INT_STATUS:
		sdm.nint &= ~(val & 0xffff);	/* W1C */
		return (1);
	case SDHCI_CMD:
		sdmodel_issue(val);
		return (1);
	default:
		return (1);	/* accept + ignore (clock/power/blocksz) */
	}
}

/*
 * =====================================================================
 *  MMIO primitives: real K1 silicon vs the emulation model.
 * =====================================================================
 * On a base we can actually reach on THIS platform (none under qemu-virt),
 * touch real MMIO. Otherwise route to the faithful model. The driver above
 * never knows the difference.
 */
static unsigned long sdhci_base;
static int sdhci_use_model;

/*
 * Runtime board-detect (R-P16): one image boots BOTH qemu-virt and physical
 * K1. sdhci_platform_k1 records whether we detected real K1 silicon (from the
 * boot DTB in startup.c — see sdhci_set_platform), so the driver targets live
 * MMIO on the board and the faithful in-kernel model under qemu-virt, WITHOUT
 * a recompile. -1 = not yet detected. K1_SILICON, if defined, forces silicon
 * (a build-time override for a board whose firmware DTB omits a signature
 * device); with it undefined the decision is 100% runtime.
 */
static int sdhci_platform_k1 = -1;

/*
 * sdhci_set_platform — called once from startup after board detection.
 * is_k1 != 0 => real K1 silicon (live MMIO); 0 => qemu-virt (faithful model).
 */
void
sdhci_set_platform(int is_k1)
{
	sdhci_platform_k1 = is_k1 ? 1 : 0;
}

static inline unsigned int
mmio_rd(unsigned int off, int width)
{
	if (sdhci_use_model) {
		unsigned int v = 0;
		(void) sdmodel_rd(off, &v, width);
		return (v);
	}
	if (width == 2)
		return (*(volatile unsigned short *)(sdhci_base + off));
	return (*(volatile unsigned int *)(sdhci_base + off));
}

static inline void
mmio_wr(unsigned int off, unsigned int val, int width)
{
	if (sdhci_use_model) {
		(void) sdmodel_wr(off, val, width);
		return;
	}
	if (width == 1)
		*(volatile unsigned char *)(sdhci_base + off) =
		    (unsigned char)val;
	else if (width == 2)
		*(volatile unsigned short *)(sdhci_base + off) =
		    (unsigned short)val;
	else
		*(volatile unsigned int *)(sdhci_base + off) = val;
}

/* Bounded spin waiting for `mask` to appear in Normal Int Status. */
static int
wait_nint(unsigned int mask)
{
	int spins;
	for (spins = 0; spins < 1000000; spins++) {
		if (mmio_rd(SDHCI_INT_STATUS, 2) & mask)
			return (1);
	}
	return (0);	/* timeout */
}

/* Bounded spin until CMD/DAT inhibit clears (controller ready for a command). */
static int
wait_ready(void)
{
	int spins;
	for (spins = 0; spins < 1000000; spins++) {
		if ((mmio_rd(SDHCI_PRESENT_STATE, 4) &
		    (PSTATE_CMD_INHIBIT | PSTATE_DAT_INHIBIT)) == 0)
			return (1);
	}
	return (0);
}

/*
 * sdhci_send_cmd — issue one SD command and wait for command-complete.
 * idx = command index, arg = 32-bit argument, resptype = CMD_RESP_*,
 * flags = extra CMD-register bits (e.g. CMD_DATA_PRESENT). Returns 1 on
 * command-complete, 0 on timeout. Response words land in RESP0..3.
 */
static int
sdhci_send_cmd(unsigned int idx, unsigned int arg, unsigned int resptype,
    unsigned int flags)
{
	unsigned int cmdreg;

	if (!wait_ready())
		return (0);
	/* Clear stale int status (W1C the bits we care about). */
	mmio_wr(SDHCI_INT_STATUS, NINT_CMD_COMPLETE | NINT_XFER_COMPLETE |
	    NINT_BUF_RD_READY, 2);
	mmio_wr(SDHCI_ARG1, arg, 4);
	cmdreg = CMD_IDX(idx) | (resptype & 0x3) | flags;
	mmio_wr(SDHCI_CMD, cmdreg, 2);
	return (wait_nint(NINT_CMD_COMPLETE));
}

/*
 * sdhci_reset — SDHCI software reset (SRST_ALL) + power/clock enable. The
 * first thing every driver does before talking to a card.
 */
static int
sdhci_reset(void)
{
	int spins;
	mmio_wr(SDHCI_SOFT_RESET, SRST_ALL, 1);
	for (spins = 0; spins < 1000000; spins++) {
		if ((mmio_rd(SDHCI_SOFT_RESET, 1) & SRST_ALL) == 0)
			break;
	}
	/* Power on (3.3V) + enable internal clock (model/real accept these). */
	mmio_wr(SDHCI_POWER_CTRL, 0x0f, 1);	/* bus power on, 3.3V */
	mmio_wr(SDHCI_CLOCK_CTRL, 0x0005, 2);	/* internal clk en + stable */
	return (spins < 1000000);
}

/* Card state discovered during init, for the completion banner. */
static unsigned int card_ocr;
static unsigned int card_cid[4];
static unsigned int card_rca;
static int card_high_capacity;
static int card_ready;

/*
 * mmc_card_init — the SD/MMC bring-up handshake (CMD0/8, ACMD41, CMD2/3/7).
 * Returns 1 with card_ocr/card_cid/card_rca populated on success.
 */
static int
mmc_card_init(void)
{
	int poll;

	/* CMD0: go idle. */
	if (!sdhci_send_cmd(MMC_GO_IDLE, 0, CMD_RESP_NONE, 0))
		return (0);

	/* CMD8: voltage handshake. R7 echoes 0x1AA if the card is SD 2.0+. */
	(void) sdhci_send_cmd(MMC_SEND_IF_COND, CMD8_VHS_PATTERN,
	    CMD_RESP_48, 0);

	/* ACMD41 loop: CMD55 (APP) then CMD41 (OP_COND), poll OCR BUSY. */
	for (poll = 0; poll < 100; poll++) {
		if (!sdhci_send_cmd(MMC_APP_CMD, 0, CMD_RESP_48, 0))
			return (0);
		if (!sdhci_send_cmd(SD_APP_OP_COND,
		    OCR_HCS | OCR_VOLT_WINDOW, CMD_RESP_48, 0))
			return (0);
		card_ocr = mmio_rd(SDHCI_RESP0, 4);
		if (card_ocr & OCR_BUSY)
			break;		/* power-up complete */
	}
	if ((card_ocr & OCR_BUSY) == 0)
		return (0);		/* card never left busy */
	card_high_capacity = (card_ocr & OCR_CCS) ? 1 : 0;

	/* CMD2: read the 136-bit CID. */
	if (!sdhci_send_cmd(MMC_ALL_SEND_CID, 0, CMD_RESP_136, 0))
		return (0);
	card_cid[0] = mmio_rd(SDHCI_RESP0, 4);
	card_cid[1] = mmio_rd(SDHCI_RESP0 + 4, 4);
	card_cid[2] = mmio_rd(SDHCI_RESP0 + 8, 4);
	card_cid[3] = mmio_rd(SDHCI_RESP0 + 12, 4);

	/* CMD3: card publishes its RCA (upper 16 bits of R6). */
	if (!sdhci_send_cmd(MMC_SEND_RCA, 0, CMD_RESP_48, 0))
		return (0);
	card_rca = (mmio_rd(SDHCI_RESP0, 4) >> 16) & 0xffff;

	/* CMD7: select the card (RCA in argument bits 31:16) -> transfer state. */
	if (!sdhci_send_cmd(MMC_SELECT_CARD, (unsigned int)card_rca << 16,
	    CMD_RESP_48_BUSY, 0))
		return (0);

	card_ready = 1;
	return (1);
}

/*
 * mmc_read_sector — read one 512-byte block via CMD17 (READ_SINGLE_BLOCK),
 * streaming the data through the SDHCI PIO Buffer Data Port. `sector` is a
 * block address for high-capacity (SDHC) cards, a byte address otherwise.
 * Returns 1 on success, buf filled with 512 bytes.
 *
 * NOTE: PIO (Buffer Data Port) not SDMA/ADMA — smallest correct read path.
 * ADMA2 descriptor DMA is the throughput upgrade; add when a real fs on real
 * K1 silicon needs the bandwidth.
 */
static int
mmc_read_sector(unsigned long sector, void *buf)
{
	unsigned int *out = (unsigned int *)buf;
	unsigned long addr = card_high_capacity ? sector : sector * SECTOR_SIZE;
	int i;

	if (!card_ready)
		return (0);

	/* One 512-byte block, read direction. */
	mmio_wr(SDHCI_BLOCK_SIZE, SECTOR_SIZE, 2);
	mmio_wr(SDHCI_BLOCK_COUNT, 1, 2);
	mmio_wr(SDHCI_XFER_MODE, XFER_READ, 2);

	if (!sdhci_send_cmd(MMC_READ_SINGLE, (unsigned int)addr,
	    CMD_RESP_48, CMD_DATA_PRESENT))
		return (0);

	/* Wait for the buffer-read-ready, then drain 128 words = 512 bytes. */
	if (!wait_nint(NINT_BUF_RD_READY))
		return (0);
	for (i = 0; i < SECTOR_SIZE / 4; i++)
		out[i] = mmio_rd(SDHCI_BUFFER, 4);

	(void) wait_nint(NINT_XFER_COMPLETE);
	return (1);
}

/*
 * sdhci_probe — bring up the SDHCI controller at `base`, initialize the card,
 * and read sector 0. Returns 1 on a full success (card init + sector read),
 * 0 otherwise. The R-P14 register-level decode is preserved as the first step.
 *
 * PROVE: "mmc: card initialized (OCR/CID/RCA), read sector 0 (MBR/512B)".
 */
int
sdhci_probe(unsigned long base)
{
	unsigned char sec0[SECTOR_SIZE];
	unsigned int ver, caps, pstate, specver;

	if (base == 0) {
		sbi_console_puts("[sdhci] no SDHCI node in DTB\n");
		return (0);
	}

	sdhci_base = base;
	/*
	 * Pick the MMIO backend at RUNTIME (R-P16 board-detect). On qemu-virt
	 * there is NO SDHCI wired at the K1 base, so route to the faithful model
	 * (marked). On real K1 silicon the base holds a live dwcmshc-sdhci and we
	 * touch real MMIO. sdhci_platform_k1 is set by sdhci_set_platform() from
	 * the boot DTB the firmware handed us (fdt_k1_summary): the same `unix`
	 * image flips itself to live MMIO on the board and to the model under
	 * qemu — no -DK1_SILICON recompile. This is the ONE honest emulation seam.
	 */
#ifdef K1_SILICON
	sdhci_use_model = 0;	/* build override: force live MMIO */
#else
	/* Default: undetected (-1) is treated as NOT-K1 (qemu-virt) -> model. */
	sdhci_use_model = (sdhci_platform_k1 == 1) ? 0 : 1;
#endif
	if (sdhci_use_model)
		sdmodel_reset();

	sbi_console_puts("[sdhci] probe @");
	kputhex(base);
	if (base >= K1_DEV_LO && base < K1_DEV_HI)
		sbi_console_puts(" (K1 device giga mapped, R-P15)");
	sbi_console_puts(sdhci_use_model ?
	    " [emulation: faithful SDHCI+SD model]\n" :
	    " [K1 silicon: live MMIO]\n");

	/* Step 1 (R-P14 legacy): register-level decode. */
	ver = mmio_rd(SDHCI_HOST_VERSION, 2);
	caps = mmio_rd(SDHCI_CAPABILITIES, 4);
	pstate = mmio_rd(SDHCI_PRESENT_STATE, 4);
	specver = ver & 0xff;
	sbi_console_puts("[sdhci] HCVER=");
	kputhex(ver);
	sbi_console_puts(" (SDHCI spec ");
	kputdec(specver + 1);
	sbi_console_puts(".00), caps=");
	kputhex(caps);
	sbi_console_puts(", card=");
	sbi_console_puts((pstate & PSTATE_CARD_INSERTED) ? "present" : "absent");
	sbi_console_puts("\n");

	/* Step 2: SDHCI reset + power/clock. */
	if (!sdhci_reset()) {
		sbi_console_puts("[sdhci] SRST_ALL did not clear (timeout)\n");
		return (0);
	}
	sbi_console_puts("[sdhci] reset OK (SRST_ALL cleared, power+clock on)\n");

	/* Step 3: SD/MMC card init handshake. */
	if (!mmc_card_init()) {
		sbi_console_puts("[mmc] card init FAILED (no card / no "
		    "controller at this base)\n");
		return (0);
	}
	sbi_console_puts("[mmc] card initialized: OCR=");
	kputhex(card_ocr);
	sbi_console_puts(card_high_capacity ? " (SDHC/high-capacity)" :
	    " (SDSC/byte-addr)");
	sbi_console_puts(" CID=");
	kputhex(((unsigned long)card_cid[3] << 32) | card_cid[2]);
	sbi_console_puts(" RCA=");
	kputhex(card_rca);
	sbi_console_puts("\n");

	/* Step 4: read sector 0 (CMD17) and check the MBR signature. */
	if (!mmc_read_sector(0, sec0)) {
		sbi_console_puts("[mmc] read sector 0 FAILED\n");
		return (0);
	}
	{
		unsigned int magic = sec0[510] | (sec0[511] << 8);
		sbi_console_puts("mmc: card initialized (OCR/CID/RCA), read "
		    "sector 0 (MBR/512B) magic=");
		kputhex(magic);
		sbi_console_puts(magic == 0xaa55 ? " (valid 0x55aa)\n" :
		    " (no MBR sig)\n");
	}
	return (1);
}

/*
 * sdhci_model_selftest — one runnable check that the driver logic is sound:
 * drive the full CMD0/8/ACMD41/2/3/7 + CMD17 path against the model and assert
 * the card came up SDHC and sector 0 carries the 0x55aa MBR signature. Fails
 * loudly on the console if the state machine breaks. Always compiled in (it is
 * a model-backed unit check, independent of the runtime platform); the real
 * on-hardware proof is the sdhci_probe banner in the boot log.
 */
void
sdhci_model_selftest(void)
{
	unsigned char sec0[SECTOR_SIZE];
	int ok;
	int save_platform = sdhci_platform_k1;

	sdhci_base = 0xd4281000UL;	/* K1 base; model backs it here */
	sdhci_use_model = 1;
	sdmodel_reset();
	card_ready = 0;

	ok = sdhci_reset() && mmc_card_init() &&
	    (card_ocr & OCR_CCS) && card_high_capacity &&
	    mmc_read_sector(0, sec0) &&
	    sec0[510] == 0x55 && sec0[511] == 0xaa;

	sdhci_platform_k1 = save_platform;	/* selftest must not perturb detect */
	sbi_console_puts("[sdhci] model selftest: ");
	sbi_console_puts(ok ?
	    "PASS (CMD0/8/ACMD41/2/3/7 init + CMD17 sector0 0x55aa)\n" :
	    "FAIL (driver state machine broke)\n");
}
