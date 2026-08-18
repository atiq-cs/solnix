/*
 * sdhci.c -- R-P62: an SDHCI-standard (SD Host Controller) SD/eMMC driver
 * behind the bdev_strategy block seam -- the real-hardware root medium on the
 * SpacemiT K1 (Milk-V Jupiter), whose MMC IP is `spacemit,k1-sdhci`, a STANDARD
 * SDHCI core (NOT the Synopsys dw-mmc the R-P58/59 dwmmc.c targets).  The
 * corrected K1 DTB (rp62 K1-MEMORY-MAP.md / the driver plan docs/riscv-jupiter-
 * driver-plan.md sec 5) puts SDHCI @ 0xd4280000; the FDT walker classifies it
 * FDT_MMC_SDHCI and this driver binds to it.
 *
 * qemu -machine virt has NO SDHCI controller (its block device is virtio-blk),
 * so this driver CANNOT be exercised under qemu -- it is a COMPILE + link +
 * structured driver for the K1 board, exactly like dwmmc.c is for dw-mmc
 * boards.  Under qemu fi_mmc_kind is not FDT_MMC_SDHCI (no such node) so
 * sdhci_set_base() is never called with the K1 base, sdhci_present() stays 0,
 * and bdev_strategy keeps dispatching to virtio-blk -- REGRESSION-SAFE.  On the
 * K1 the FDT walker finds the `spacemit,k1-sdhci` node's reg base, sdhci_probe()
 * initializes the card, and the existing blockfs / GPT / root-pivot boots off
 * SD with NO changes above the strategy seam.
 *
 * The core is the SDHCI-standard register model + the SD card-init handshake
 * and a single-block PIO read (CMD17) / write (CMD24), the smallest correct
 * path that mounts a root fs.  ADMA2/SDMA descriptor DMA + HS200/HS400 tuning
 * are the throughput/quirk follow-ups (add when a real fs on real K1 silicon
 * needs the bandwidth; the K1 `spacemit,k1-sdhci` quirks are deferred per the
 * driver plan -- default-speed 1-bit is enough to read root).
 *
 * The existing illumos `uts/sdhci.c` (R-P14/15) implemented this SDHCI-standard
 * register model + SD card-init + CMD17 read against a faithful in-kernel model;
 * this rp62 driver reuses that register map + command flow but is trimmed to the
 * kernel's dwmmc.c seam shape (direct-map MMIO via KVTOP/DMAP, sdhci_set_base/
 * present/probe/strategy) and adds the CMD24 write path.
 *
 * CRIB PROVENANCE: the SDHCI register offsets (BLOCK_SIZE/BLOCK_COUNT/ARG1/
 * XFER_MODE/CMD/RESP/BUFFER/PRESENT_STATE/POWER/CLOCK/SOFT_RESET/INT_STATUS/
 * CAPABILITIES/HOST_VERSION) + the SD init sequence (CMD0/8/ACMD41/2/3/7 +
 * CMD16) + single-block CMD17/CMD24 are the SD Host Controller Simplified Spec
 * 3.00 + the SD Physical Layer Simplified Spec 6.00 (reimplemented from the
 * public specs, as the existing uts/sdhci.c was); the strategy(9E)-shaped one-
 * block-per-call entry-point mirrors illumos sdcard/sda + this kernel's
 * dwmmc_strategy / virtio_blk_strategy.
 */

#include "sdhci.h"
#include "mmu_riscv.h"

/* ---- SDHCI-standard register offsets (bytes from the controller base) ---- */
#define	SDHCI_ARG2		0x00	/* 32b */
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
#define	NINT_BUF_WR_READY	(1U << 4)

/* Command register (0x0e) field encodings. */
#define	CMD_RESP_NONE		0x0
#define	CMD_RESP_136		0x1	/* R2 (CID/CSD) */
#define	CMD_RESP_48		0x2	/* R1/R3/R6/R7 */
#define	CMD_RESP_48_BUSY	0x3	/* R1b */
#define	CMD_DATA_PRESENT	(1U << 5)
#define	CMD_IDX(i)		(((unsigned int)(i)) << 8)

/* Transfer Mode (0x0c). */
#define	XFER_READ		(1U << 4)	/* data direction: card->host */
#define	XFER_WRITE		0U		/* host->card */
#define	XFER_BLKCNT_EN		(1U << 1)

/* SD/MMC command indices. */
#define	MMC_GO_IDLE		0	/* CMD0  */
#define	MMC_SEND_IF_COND	8	/* CMD8  */
#define	MMC_ALL_SEND_CID	2	/* CMD2  */
#define	MMC_SEND_RCA		3	/* CMD3  */
#define	MMC_SELECT_CARD		7	/* CMD7  */
#define	MMC_SET_BLOCKLEN	16	/* CMD16 */
#define	MMC_READ_SINGLE		17	/* CMD17 */
#define	MMC_WRITE_SINGLE	24	/* CMD24 */
#define	MMC_APP_CMD		55	/* CMD55 (ACMD prefix) */
#define	SD_APP_OP_COND		41	/* ACMD41 */

#define	CMD8_VHS_PATTERN	0x1AAU	/* 2.7-3.6V + check pattern 0xAA */
#define	OCR_HCS			(1U << 30)	/* host: request high capacity */
#define	OCR_BUSY		(1U << 31)	/* card: power-up done */
#define	OCR_CCS			(1U << 30)	/* card: high capacity (SDHC) */
#define	OCR_VOLT_WINDOW		0x00FF8000U	/* 2.7-3.6V voltage window */

#define	SECTOR_SIZE		512U
#define	POLL_LIMIT		1000000UL	/* busy-poll bound (dead-HW guard) */

/* ---- driver state ---- */
static unsigned long sdhci_base;	/* DTB-bound controller PA, 0 = unbound */
static int sdhci_ready;			/* 1 once sdhci_probe() succeeded */
static unsigned int sdhci_rca;		/* card relative address (CMD3) */
static int sdhci_high_capacity;		/* 1 = SDHC/SDXC (block-addressed) */

/*
 * MMIO through the kernel HIGH direct-map (KERNEL_DMAP_BASE + PA), exactly like
 * dwmmc.c's reg().  The K1 device MMIO is mapped by the boot/kernel HAT; a load
 * from KERNEL_DMAP_BASE + 0xd4280000 reaches the real SDHCI on the board.
 */
static inline volatile unsigned char *
reg8(unsigned int off)
{
	return ((volatile unsigned char *)(KERNEL_DMAP_BASE + sdhci_base + off));
}
static inline volatile unsigned short *
reg16(unsigned int off)
{
	return ((volatile unsigned short *)(KERNEL_DMAP_BASE + sdhci_base + off));
}
static inline volatile unsigned int *
reg32(unsigned int off)
{
	return ((volatile unsigned int *)(KERNEL_DMAP_BASE + sdhci_base + off));
}

/*
 * sdhci_set_base -- bind the driver to the DTB-discovered controller MMIO base
 * (fdt_info.fi_mmc_base when fi_mmc_kind == FDT_MMC_SDHCI).  A nonzero base
 * makes sdhci_present() eligible; the card-init probe still has to succeed.
 */
void
sdhci_set_base(unsigned long base)
{
	if (base != 0)
		sdhci_base = base;
}

/* sdhci_present -- 1 once sdhci_probe() succeeded, else 0 (0 under qemu). */
int
sdhci_present(void)
{
	return (sdhci_ready);
}

/* Bounded spin until CMD/DAT inhibit clears (controller ready for a command). */
static int
wait_ready(void)
{
	unsigned long spin;
	for (spin = 0; spin < POLL_LIMIT; spin++) {
		if ((*reg32(SDHCI_PRESENT_STATE) &
		    (PSTATE_CMD_INHIBIT | PSTATE_DAT_INHIBIT)) == 0)
			return (1);
	}
	return (0);
}

/* Bounded spin waiting for `mask` in Normal Int Status. */
static int
wait_nint(unsigned int mask)
{
	unsigned long spin;
	for (spin = 0; spin < POLL_LIMIT; spin++) {
		if (*reg16(SDHCI_INT_STATUS) & mask)
			return (1);
	}
	return (0);
}

/*
 * sdhci_send_cmd -- issue one SD command and wait for command-complete.
 * Response words land in RESP0..3.  Returns 1 on command-complete, 0 timeout.
 */
static int
sdhci_send_cmd(unsigned int idx, unsigned int arg, unsigned int resptype,
    unsigned int flags)
{
	unsigned int cmdreg;

	if (!wait_ready())
		return (0);
	/* Clear stale int status (W1C the bits we care about). */
	*reg16(SDHCI_INT_STATUS) = (unsigned short)(NINT_CMD_COMPLETE |
	    NINT_XFER_COMPLETE | NINT_BUF_RD_READY | NINT_BUF_WR_READY);
	*reg32(SDHCI_ARG1) = arg;
	cmdreg = CMD_IDX(idx) | (resptype & 0x3) | flags;
	*reg16(SDHCI_CMD) = (unsigned short)cmdreg;
	return (wait_nint(NINT_CMD_COMPLETE));
}

/*
 * sdhci_reset -- SDHCI software reset (SRST_ALL) + power/clock enable.
 */
static int
sdhci_reset(void)
{
	unsigned long spin;
	*reg8(SDHCI_SOFT_RESET) = (unsigned char)SRST_ALL;
	for (spin = 0; spin < POLL_LIMIT; spin++) {
		if ((*reg8(SDHCI_SOFT_RESET) & SRST_ALL) == 0)
			break;
	}
	/* Power on (3.3V) + enable internal clock. */
	*reg8(SDHCI_POWER_CTRL) = 0x0f;		/* bus power on, 3.3V */
	*reg16(SDHCI_CLOCK_CTRL) = 0x0005;	/* internal clk en + stable */
	return (spin < POLL_LIMIT);
}

/*
 * sdhci_card_init -- the standard SD/MMC bring-up (CMD0/8/ACMD41/2/3/7 + CMD16).
 * Returns 1 if a card was initialized + selected into transfer state.
 */
static int
sdhci_card_init(void)
{
	unsigned int ocr = 0;
	int poll;

	/* CMD0: go idle. */
	if (!sdhci_send_cmd(MMC_GO_IDLE, 0, CMD_RESP_NONE, 0))
		return (0);

	/* CMD8: voltage handshake (R7 echoes 0x1AA on SD 2.0+). */
	(void) sdhci_send_cmd(MMC_SEND_IF_COND, CMD8_VHS_PATTERN, CMD_RESP_48, 0);

	/* ACMD41 loop: CMD55 (APP) then CMD41 (OP_COND), poll OCR BUSY. */
	for (poll = 0; poll < 1000; poll++) {
		if (!sdhci_send_cmd(MMC_APP_CMD, 0, CMD_RESP_48, 0))
			return (0);
		if (!sdhci_send_cmd(SD_APP_OP_COND, OCR_HCS | OCR_VOLT_WINDOW,
		    CMD_RESP_48, 0))
			return (0);
		ocr = *reg32(SDHCI_RESP0);
		if (ocr & OCR_BUSY)
			break;
	}
	if ((ocr & OCR_BUSY) == 0)
		return (0);
	sdhci_high_capacity = (ocr & OCR_CCS) ? 1 : 0;

	/* CMD2: read the 136-bit CID (response present, discard here). */
	if (!sdhci_send_cmd(MMC_ALL_SEND_CID, 0, CMD_RESP_136, 0))
		return (0);

	/* CMD3: card publishes its RCA (upper 16 bits of R6). */
	if (!sdhci_send_cmd(MMC_SEND_RCA, 0, CMD_RESP_48, 0))
		return (0);
	sdhci_rca = (*reg32(SDHCI_RESP0) >> 16) & 0xffff;

	/* CMD7: select the card (RCA in bits 31:16) -> transfer state. */
	if (!sdhci_send_cmd(MMC_SELECT_CARD, sdhci_rca << 16, CMD_RESP_48_BUSY, 0))
		return (0);

	/* CMD16: set the 512-byte block length (SDSC byte-addr needs it). */
	(void) sdhci_send_cmd(MMC_SET_BLOCKLEN, SECTOR_SIZE, CMD_RESP_48, 0);

	return (1);
}

/*
 * sdhci_probe -- bring up the SDHCI controller at the bound base + init the
 * card.  Returns 1 on success (card ready), 0 otherwise (no base bound, or no
 * card -- e.g. always under qemu-virt, where sdhci_set_base is never given the
 * K1 base).  Mirrors dwmmc_probe().
 */
int
sdhci_probe(void)
{
	if (sdhci_base == 0)
		return (0);		/* unbound (qemu-virt: no SDHCI node) */

	if (!sdhci_reset())
		return (0);
	if (!sdhci_card_init())
		return (0);

	sdhci_ready = 1;
	return (1);
}

/*
 * sdhci_strategy -- transfer ONE 512-byte sector.  rw==0 reads sector `blkno`
 * into buf (CMD17 READ_SINGLE_BLOCK), rw==1 writes buf to sector `blkno` (CMD24
 * WRITE_SINGLE_BLOCK), PIO through the SDHCI Buffer Data Port.  The SAME
 * (blkno, buf, rw) -> 0/-1 shape as dwmmc_strategy / virtio_blk_strategy so
 * bdev_strategy dispatches to it identically.  Returns 0 on success, -1 error.
 */
int
sdhci_strategy(unsigned long blkno, unsigned char *buf, int rw)
{
	unsigned int *w = (unsigned int *)buf;
	unsigned long addr;
	int i;

	if (!sdhci_ready)
		return (-1);

	/* SDHC/SDXC use a block address; SDSC uses a byte address. */
	addr = sdhci_high_capacity ? blkno : blkno * SECTOR_SIZE;

	*reg16(SDHCI_BLOCK_SIZE) = (unsigned short)SECTOR_SIZE;
	*reg16(SDHCI_BLOCK_COUNT) = 1;

	if (rw == 0) {
		*reg16(SDHCI_XFER_MODE) = (unsigned short)XFER_READ;
		if (!sdhci_send_cmd(MMC_READ_SINGLE, (unsigned int)addr,
		    CMD_RESP_48, CMD_DATA_PRESENT))
			return (-1);
		if (!wait_nint(NINT_BUF_RD_READY))
			return (-1);
		for (i = 0; i < (int)(SECTOR_SIZE / 4); i++)
			w[i] = *reg32(SDHCI_BUFFER);
		(void) wait_nint(NINT_XFER_COMPLETE);
		return (0);
	} else {
		*reg16(SDHCI_XFER_MODE) = (unsigned short)XFER_WRITE;
		if (!sdhci_send_cmd(MMC_WRITE_SINGLE, (unsigned int)addr,
		    CMD_RESP_48, CMD_DATA_PRESENT))
			return (-1);
		if (!wait_nint(NINT_BUF_WR_READY))
			return (-1);
		for (i = 0; i < (int)(SECTOR_SIZE / 4); i++)
			*reg32(SDHCI_BUFFER) = w[i];
		(void) wait_nint(NINT_XFER_COMPLETE);
		return (0);
	}
}
