/*
 * dwmmc.c -- R-P58/R-P59: a Synopsys DesignWare Mobile Storage Host (dw-mmc /
 * "snps,dw-mshc") SD/eMMC driver behind the bdev_strategy block seam.
 *
 * This is the real-hardware block backend the R-P57 BLOCK-BACKEND plan called
 * for (Option A -- SD/MMC, the near-universal RISC-V SoC root medium on the
 * StarFive VisionFive 2 / JH7110 and, with the same register family, most
 * dw-mshc parts).  qemu -machine virt has NO dw-mmc host -- its block device is
 * virtio-blk -- so this driver CANNOT be exercised under qemu.  It is a
 * COMPILE + link + structured driver for a real board.
 *
 * R-P58 landed the register/FSM SKELETON.  R-P59 fills the HW bring-up gaps the
 * ON-HARDWARE.md checklist flagged, so this is now a COMPLETE structured driver
 * (still compile-phase -- there is no dw-mmc under qemu to run it against):
 *
 *   - CLOCK: dwmmc_set_clock() programs CLKSRC/CLKDIV, gates+re-enables the
 *     card clock (CLKENA), and issues the dw-mmc clock-update command
 *     (CMD_UPDATE_CLOCK_ONLY) to latch it -- identification at ~400 kHz, then a
 *     switch to the ~25 MHz default-speed transfer clock after card select.
 *   - FIFO: CTRL FIFO_RESET as a discrete reset step + FIFOTH (RX/TX watermarks
 *     + the DMA multiple-transfer burst size) programmed before transfers.
 *   - POWER/BUS/VOLTAGE: PWREN, CTYPE bus width (1-bit for identification), and
 *     the UHS_REG 1.8V voltage-switch register defined (the CMD11 UHS switch is
 *     the documented board-specific follow-up; default-speed 3.3V needs none).
 *   - DMA-vs-PIO: a complete dw-mmc IDMAC descriptor-ring transfer path (BMOD /
 *     DBADDR / a FS|LD|OWN descriptor, PA via the kernel direct-map KVTOP) is
 *     compiled behind DWMMC_USE_DMA; PIO (drain/fill the FIFO) stays the default
 *     tested-shape path.  Both compile + link.
 *
 *   - the register layout (CTRL, PWREN, CLKDIV/CLKSRC/CLKENA, CMD, CMDARG,
 *     RINTSTS, STATUS, FIFO, FIFOTH, BLKSIZ, BYTCNT, BMOD/DBADDR/IDSTS ...);
 *   - the CMD FSM: write CMDARG, write CMD (with the start bit + response/data
 *     flags), poll RINTSTS for the command-done / data-transfer-over bits;
 *   - the card-init sequence CMD0 -> CMD8 -> ACMD41 -> CMD2 -> CMD3 -> CMD9 ->
 *     CMD7 -> CMD16 (set 512-byte block length), with the clock/FIFO/power
 *     bring-up around it;
 *   - a single-sector read (CMD17 READ_SINGLE_BLOCK) and write (CMD24
 *     WRITE_SINGLE_BLOCK) -- both with the SAME (blkno, buf, rw) shape as
 *     virtio_blk_strategy, so bdev_strategy dispatches to it identically.
 *
 * Runtime selection: dwmmc_set_base() binds the DTB-discovered controller MMIO
 * base (fdt_info.fi_mmc_base); dwmmc_probe() brings up the card.  Under qemu
 * fi_mmc_base is 0 (no mmc node) so dwmmc_present() stays 0 and bdev_strategy
 * keeps using virtio-blk -- REGRESSION-SAFE.  On a real board the FDT walker
 * finds the mmc@ node's reg base, dwmmc_probe() initializes the card, and the
 * existing blockfs / GPT / root-pivot boots off SD with NO changes above the
 * strategy seam.
 *
 * The FSM here uses busy-poll (no interrupt) -- an interrupt completion path is
 * the remaining on-HW follow-up documented in ON-HARDWARE.md.
 *
 * CRIB PROVENANCE: the dw-mmc register offsets (CTRL/PWREN/CLKENA/CLKSRC/CLKDIV/
 * CMD/CMDARG/RINTSTS/STATUS/FIFOTH/BLKSIZ/BYTCNT/RESP/DATA/BMOD/DBADDR/IDSTS) +
 * the clock-program (gate, set CLKDIV, update-clock command, ungate) + the
 * "write CMDARG, write CMD with start_cmd, poll for command-done, then poll
 * data-over" sequence + the IDMAC descriptor format are the Synopsys DesignWare
 * MMC databook as reflected in Linux drivers/mmc/host/dw_mmc.c (dw_mci_* map,
 * dw_mci_setup_bus, dw_mci_idmac_*) + U-Boot drivers/mmc/dw_mmc.c (a smaller PIO
 * reference); the SD command set (CMD0/CMD8/ACMD41/CMD2/CMD3/CMD9/CMD7/CMD16/
 * CMD17/CMD24) + the OCR/CID/RCA/CSD flow is the SD Physical Layer Simplified
 * Spec sec 4 (card init) + sec 7 (command reference); the illumos sdcard/sda
 * (usr/src/uts/common/io/sdcard) + sdhost nexus give the strategy(9E)-shaped
 * "one block per call" entry-point model this bdev_strategy seam mirrors.
 */

#include "dwmmc.h"
#include "mmu_riscv.h"

/* ---- dw-mmc register offsets (bytes from the controller base) ---------- */
#define	DWMMC_CTRL	0x000U	/* control (reset bits, int enable, use IDMAC) */
#define	DWMMC_PWREN	0x004U	/* power enable (per-card) */
#define	DWMMC_CLKDIV	0x008U	/* clock divider */
#define	DWMMC_CLKSRC	0x00cU	/* clock source (divider select, usually 0) */
#define	DWMMC_CLKENA	0x010U	/* clock enable (per-card) */
#define	DWMMC_TMOUT	0x014U	/* response/data timeout */
#define	DWMMC_CTYPE	0x018U	/* card type (bus width) */
#define	DWMMC_BLKSIZ	0x01cU	/* block size */
#define	DWMMC_BYTCNT	0x020U	/* byte count for the transfer */
#define	DWMMC_INTMASK	0x024U	/* interrupt mask */
#define	DWMMC_CMDARG	0x028U	/* command argument */
#define	DWMMC_CMD	0x02cU	/* command (start_cmd is bit 31) */
#define	DWMMC_RESP0	0x030U	/* response 0..3 */
#define	DWMMC_RESP1	0x034U
#define	DWMMC_RESP2	0x038U
#define	DWMMC_RESP3	0x03cU
#define	DWMMC_MINTSTS	0x040U	/* masked interrupt status */
#define	DWMMC_RINTSTS	0x044U	/* raw interrupt status (write-1-to-clear) */
#define	DWMMC_STATUS	0x048U	/* status (FIFO count, data-busy) */
#define	DWMMC_FIFOTH	0x04cU	/* FIFO threshold (RX/TX watermark + DMA burst) */
#define	DWMMC_UHS_REG	0x074U	/* UHS-1: voltage (bit0=VDD 1.8V) + DDR */
#define	DWMMC_BMOD	0x080U	/* IDMAC bus mode (SWR/FB/DE/DSL) */
#define	DWMMC_PLDMND	0x084U	/* IDMAC poll-demand (kick the DMA) */
#define	DWMMC_DBADDR	0x088U	/* IDMAC descriptor-list base address */
#define	DWMMC_IDSTS	0x08cU	/* IDMAC status */
#define	DWMMC_IDINTEN	0x090U	/* IDMAC interrupt enable */
#define	DWMMC_DATA	0x200U	/* the data FIFO (PIO read/write window) */

/* DWMMC_CTRL bits */
#define	CTRL_CONTROLLER_RESET	(1U << 0)
#define	CTRL_FIFO_RESET		(1U << 1)
#define	CTRL_DMA_RESET		(1U << 2)
#define	CTRL_INT_ENABLE		(1U << 4)
#define	CTRL_DMA_ENABLE		(1U << 5)	/* enable the (old) DMA interface */
#define	CTRL_USE_IDMAC		(1U << 25)	/* use the internal DMAC */

/* DWMMC_CMD bits */
#define	CMD_START		(1U << 31)	/* start command (self-clears) */
#define	CMD_USE_HOLD_REG	(1U << 29)
#define	CMD_UPDATE_CLOCK_ONLY	(1U << 21)	/* clock-sync, no card cmd */
#define	CMD_SEND_INIT		(1U << 15)	/* send 80-clock init seq */
#define	CMD_WAIT_PRVDATA	(1U << 13)	/* wait until data-not-busy */
#define	CMD_SEND_STOP		(1U << 14)
#define	CMD_DATA_EXPECTED	(1U << 9)	/* command has a data phase */
#define	CMD_WRITE		(1U << 10)	/* data phase is a write */
#define	CMD_RESP_LEN_LONG	(1U << 7)	/* 136-bit response (CID/CSD) */
#define	CMD_RESP_EXPECTED	(1U << 6)	/* a response is expected */

/* DWMMC_RINTSTS bits */
#define	INT_CMD_DONE		(1U << 2)	/* command complete */
#define	INT_DATA_OVER		(1U << 3)	/* data transfer over */
#define	INT_RXDR		(1U << 5)	/* RX FIFO data request */
#define	INT_TXDR		(1U << 4)	/* TX FIFO data request */
#define	INT_RESP_ERR		(1U << 1)
#define	INT_RCRC		(1U << 6)	/* response CRC error */
#define	INT_DCRC		(1U << 7)	/* data CRC error */
#define	INT_RTO			(1U << 8)	/* response timeout */
#define	INT_DRTO		(1U << 9)	/* data-read timeout */
#define	INT_ERROR	(INT_RESP_ERR | INT_RCRC | INT_DCRC | INT_RTO | INT_DRTO)

/* DWMMC_STATUS bits/fields */
#define	STATUS_DATA_BUSY	(1U << 9)
#define	STATUS_FIFO_COUNT(s)	(((s) >> 17) & 0x1fffU)	/* words in FIFO */

/* DWMMC_CTYPE (bus width) */
#define	CTYPE_1BIT		0x0U
#define	CTYPE_4BIT		(1U << 0)
#define	CTYPE_8BIT		(1U << 16)

/* DWMMC_CLKENA / clock-update */
#define	CLKENA_CCLK_ENABLE	(1U << 0)	/* enable card clock (card 0) */
#define	CLKENA_CCLK_LOWPWR	(1U << 16)	/* low-power (gate when idle) */

/*
 * Card clock divider.  The dw-mmc card clock = ciu_clk / (2 * CLKDIV) (CLKDIV=0
 * is bypass = ciu_clk).  With a typical ciu_clk (e.g. ~50 MHz on the JH7110)
 * CLKDIV_400K gives roughly the <=400 kHz identification clock; CLKDIV_25M the
 * ~25 MHz default-speed transfer clock.  The exact divisor is board/ciu_clk
 * dependent -- see ON-HARDWARE.md; these are the standard init/transfer targets.
 */
#define	CLKDIV_400K		0x40U	/* ~400 kHz identification clock */
#define	CLKDIV_25M		0x01U	/* ~25 MHz default-speed clock */

/*
 * DWMMC_FIFOTH: RX watermark [11:0], TX watermark [27:16], DMA multiple-transfer
 * size [30:28].  A 512-byte (128-word) transfer with a 128-word FIFO: RX wmark
 * = FIFO_DEPTH/2 - 1, TX wmark = FIFO_DEPTH/2, burst size = 8 xfers (msize 2).
 */
#define	FIFO_DEPTH		128U
#define	FIFOTH_MSIZE_8		(2U << 28)
#define	FIFOTH_VAL	(FIFOTH_MSIZE_8 | \
				((FIFO_DEPTH / 2U) << 16) | \
				((FIFO_DEPTH / 2U) - 1U))

/* DWMMC_UHS_REG: bit0 = card VDD 1.8V (UHS voltage switch) */
#define	UHS_VOLT_18		(1U << 0)

/* DWMMC_BMOD (IDMAC bus mode) */
#define	BMOD_SWR		(1U << 0)	/* software reset the IDMAC */
#define	BMOD_FB			(1U << 1)	/* fixed burst */
#define	BMOD_DE			(1U << 7)	/* DMA enable */

/*
 * IDMAC descriptor (dw-mmc "dual-buffer" descriptor, 32-bit-address form).  DES0
 * = control/status, DES1 = buffer sizes, DES2 = buffer-1 phys addr, DES3 =
 * buffer-2 phys addr OR next-descriptor phys addr when chained.
 */
#define	IDMAC_DES0_OWN		(1U << 31)	/* owned by the DMA engine */
#define	IDMAC_DES0_CH		(1U << 4)	/* second address is chained-next */
#define	IDMAC_DES0_FS		(1U << 3)	/* first descriptor of a transfer */
#define	IDMAC_DES0_LD		(1U << 2)	/* last descriptor of a transfer */
#define	IDMAC_DES1_BS1(n)	((n) & 0x1fffU)	/* buffer-1 size (bytes) */

struct idmac_desc {
	unsigned int des0;	/* control/status */
	unsigned int des1;	/* buffer sizes */
	unsigned int des2;	/* buffer-1 physical address */
	unsigned int des3;	/* buffer-2 / next-descriptor physical address */
};

/*
 * Build the driver with PIO by default.  Define DWMMC_USE_DMA to compile the
 * IDMAC descriptor-ring transfer path instead (still needs a real board to
 * run).  Both paths compile + link; PIO is the tested-shape milestone path.
 */
#ifndef	DWMMC_USE_DMA
#define	DWMMC_USE_DMA	0
#endif

/* ---- SD command set (SD Physical Layer spec) --------------------------- */
#define	MMC_GO_IDLE_STATE	0	/* CMD0  */
#define	SD_SEND_IF_COND		8	/* CMD8  */
#define	MMC_APP_CMD		55	/* CMD55 (prefix for ACMDs) */
#define	SD_APP_OP_COND		41	/* ACMD41 */
#define	MMC_ALL_SEND_CID	2	/* CMD2  */
#define	SD_SEND_RELATIVE_ADDR	3	/* CMD3  */
#define	MMC_SEND_CSD		9	/* CMD9  */
#define	MMC_SELECT_CARD		7	/* CMD7  */
#define	MMC_SET_BLOCKLEN	16	/* CMD16 */
#define	MMC_READ_SINGLE_BLOCK	17	/* CMD17 */
#define	MMC_WRITE_SINGLE_BLOCK	24	/* CMD24 */

#define	SECTOR_BYTES	512U
#define	POLL_LIMIT	100000000UL	/* busy-poll bound (guards a dead HW) */

static unsigned long dwmmc_base;	/* DTB-bound controller PA, 0 = unbound */
static int dwmmc_ready;			/* 1 once dwmmc_probe() succeeded */
static unsigned int dwmmc_rca;		/* card relative address (from CMD3) */
static int dwmmc_sdhc;			/* 1 = SDHC/SDXC (block-addressed) */

/* one IDMAC descriptor, 8-byte aligned; used only on the DWMMC_USE_DMA path. */
static struct idmac_desc dwmmc_desc __attribute__((aligned(8)));

static volatile unsigned int *
reg(unsigned int off)
{
	return ((volatile unsigned int *)(KERNEL_DMAP_BASE + dwmmc_base + off));
}

void
dwmmc_set_base(unsigned long base)
{
	if (base != 0)
		dwmmc_base = base;
}

int
dwmmc_present(void)
{
	return (dwmmc_ready);
}

/*
 * dwmmc_cmd -- issue one command and wait for command-done.  Writes CMDARG then
 * CMD (with CMD_START); polls RINTSTS for INT_CMD_DONE (or an error/timeout).
 * Returns 0 on command-done, -1 on error/timeout.  Response words are read by
 * the caller from RESP0..3 after this returns 0.
 */
static int
dwmmc_cmd(unsigned int cmd_idx, unsigned int arg, unsigned int flags)
{
	unsigned long spin;
	unsigned int st;

	/* clear stale raw interrupt status (write-1-to-clear). */
	*reg(DWMMC_RINTSTS) = 0xffffffffU;

	*reg(DWMMC_CMDARG) = arg;
	*reg(DWMMC_CMD) = CMD_START | (cmd_idx & 0x3fU) | flags;

	/* CMD_START self-clears when the controller has accepted the command. */
	for (spin = 0; spin < POLL_LIMIT; spin++) {
		if ((*reg(DWMMC_CMD) & CMD_START) == 0)
			break;
	}
	if (spin >= POLL_LIMIT)
		return (-1);

	/* wait for command-done (or an error). */
	for (spin = 0; spin < POLL_LIMIT; spin++) {
		st = *reg(DWMMC_RINTSTS);
		if (st & INT_ERROR)
			return (-1);
		if (st & INT_CMD_DONE)
			return (0);
	}
	return (-1);
}

/*
 * dwmmc_set_clock -- program the card clock divider and (re)enable the card
 * clock.  The dw-mmc clock-programming sequence (databook / Linux
 * dw_mci_setup_bus) is:
 *   1. disable the card clock (CLKENA=0) + issue an "update clock registers"
 *      command (CMD with CMD_UPDATE_CLOCK_ONLY, no card command sent);
 *   2. set CLKSRC (divider select, 0) + CLKDIV (the divisor);
 *   3. issue the update-clock command again to latch CLKSRC/CLKDIV;
 *   4. enable the card clock (CLKENA) + update-clock once more.
 * The update-clock command is CMD_START|CMD_UPDATE_CLOCK_ONLY|CMD_WAIT_PRVDATA
 * and does NOT set INT_CMD_DONE, so we poll only for CMD_START self-clearing.
 * Returns 0 on success, -1 if the controller never accepts the update command.
 */
static int
dwmmc_update_clock(void)
{
	unsigned long spin;
	*reg(DWMMC_CMD) = CMD_START | CMD_UPDATE_CLOCK_ONLY | CMD_WAIT_PRVDATA;
	for (spin = 0; spin < POLL_LIMIT; spin++)
		if ((*reg(DWMMC_CMD) & CMD_START) == 0)
			return (0);
	return (-1);
}

static int
dwmmc_set_clock(unsigned int div)
{
	*reg(DWMMC_CLKENA) = 0;			/* gate the card clock */
	if (dwmmc_update_clock() != 0)
		return (-1);
	*reg(DWMMC_CLKSRC) = 0;			/* divider source 0 */
	*reg(DWMMC_CLKDIV) = div;		/* the divisor */
	if (dwmmc_update_clock() != 0)		/* latch CLKSRC/CLKDIV */
		return (-1);
	*reg(DWMMC_CLKENA) = CLKENA_CCLK_ENABLE;	/* ungate the card clock */
	if (dwmmc_update_clock() != 0)
		return (-1);
	return (0);
}

/*
 * dwmmc_probe -- bring up the SD card.  Reset the controller/FIFO, program the
 * clock/FIFO/power, run the card-init command sequence, switch to the transfer
 * clock, and mark the driver live.  Returns 1 on success, 0 if no base is bound
 * (always the case under qemu) or a step fails.
 */
int
dwmmc_probe(void)
{
	unsigned long spin;

	if (dwmmc_base == 0)
		return (0);		/* no DTB mmc node (qemu-virt) */

	/* reset the controller + FIFO + DMA; wait for the reset bits to clear. */
	*reg(DWMMC_CTRL) = CTRL_CONTROLLER_RESET | CTRL_FIFO_RESET |
	    CTRL_DMA_RESET;
	for (spin = 0; spin < POLL_LIMIT; spin++) {
		if ((*reg(DWMMC_CTRL) &
		    (CTRL_CONTROLLER_RESET | CTRL_FIFO_RESET |
		    CTRL_DMA_RESET)) == 0)
			break;
	}
	if (spin >= POLL_LIMIT)
		return (0);

	*reg(DWMMC_PWREN) = 1;		/* power the card slot */
	*reg(DWMMC_INTMASK) = 0;	/* poll mode: mask all interrupts */
	*reg(DWMMC_TMOUT) = 0xffffffffU;
	*reg(DWMMC_BLKSIZ) = SECTOR_BYTES;
	*reg(DWMMC_CTYPE) = CTYPE_1BIT;		/* 1-bit bus for identification */
	*reg(DWMMC_FIFOTH) = FIFOTH_VAL;	/* RX/TX watermarks + DMA burst size */

	/*
	 * Card clock: run identification at ~400 kHz (SD spec: <=400 kHz until the
	 * card is in the transfer state).  dwmmc_set_clock disables, sets CLKDIV,
	 * latches via the update-clock command, re-enables, updates again.
	 */
	if (dwmmc_set_clock(CLKDIV_400K) != 0)
		return (0);

	/* CMD0: go to idle (SEND_INIT sends the 80-clock init sequence). */
	if (dwmmc_cmd(MMC_GO_IDLE_STATE, 0, CMD_SEND_INIT) != 0)
		return (0);

	/*
	 * CMD8: voltage check (0x1AA = 2.7-3.6V, check pattern 0xAA).  A card
	 * that responds is SD v2+; the response echoes the pattern.
	 */
	if (dwmmc_cmd(SD_SEND_IF_COND, 0x1aa, CMD_RESP_EXPECTED) != 0)
		return (0);

	/*
	 * ACMD41: OCR + host-capacity-support (HCS bit 30).  Repeated
	 * CMD55+ACMD41 until the card leaves busy (OCR bit 31 = ready); OCR
	 * bit 30 (CCS) then tells SDHC (block-addressed) vs SDSC (byte).
	 */
	for (spin = 0; spin < 100000; spin++) {
		unsigned int ocr;
		if (dwmmc_cmd(MMC_APP_CMD, 0, CMD_RESP_EXPECTED) != 0)
			return (0);
		if (dwmmc_cmd(SD_APP_OP_COND, 0x40ff8000U,
		    CMD_RESP_EXPECTED) != 0)
			return (0);
		ocr = *reg(DWMMC_RESP0);
		if (ocr & 0x80000000U) {	/* card ready */
			dwmmc_sdhc = (ocr & 0x40000000U) ? 1 : 0;
			break;
		}
	}
	if (spin >= 100000)
		return (0);

	/* CMD2: ALL_SEND_CID (long response). */
	if (dwmmc_cmd(MMC_ALL_SEND_CID, 0,
	    CMD_RESP_EXPECTED | CMD_RESP_LEN_LONG) != 0)
		return (0);

	/* CMD3: publish the card's relative address (RCA in resp[31:16]). */
	if (dwmmc_cmd(SD_SEND_RELATIVE_ADDR, 0, CMD_RESP_EXPECTED) != 0)
		return (0);
	dwmmc_rca = (*reg(DWMMC_RESP0) >> 16) & 0xffffU;

	/* CMD9: read the CSD (capacity; long response) -- kept for completeness. */
	if (dwmmc_cmd(MMC_SEND_CSD, dwmmc_rca << 16,
	    CMD_RESP_EXPECTED | CMD_RESP_LEN_LONG) != 0)
		return (0);

	/* CMD7: select the card (move to the transfer state). */
	if (dwmmc_cmd(MMC_SELECT_CARD, dwmmc_rca << 16, CMD_RESP_EXPECTED) != 0)
		return (0);

	/* CMD16: set the block length to 512 (SDSC; SDHC ignores but harmless). */
	if (dwmmc_cmd(MMC_SET_BLOCKLEN, SECTOR_BYTES, CMD_RESP_EXPECTED) != 0)
		return (0);

	/*
	 * Card is now in the transfer state: switch to the ~25 MHz default-speed
	 * transfer clock (identification ran at ~400 kHz).  A UHS-I board would
	 * additionally do the CMD11 voltage switch to 1.8V here (set UHS_REG bit0
	 * + toggle the card clock); that is board/regulator-specific and left as
	 * the documented UHS follow-up -- default-speed 3.3V needs no switch.
	 */
	if (dwmmc_set_clock(CLKDIV_25M) != 0)
		return (0);

	dwmmc_ready = 1;
	return (1);
}

/*
 * dwmmc_strategy -- transfer ONE 512-byte sector via PIO.  The sector address
 * handed to the card is `blkno` for SDHC (block-addressed) or blkno*512 for
 * SDSC (byte-addressed).  rw==0 reads (CMD17) draining the RX FIFO; rw==1
 * writes (CMD24) filling the TX FIFO.  Returns 0 on success, -1 on error.
 */
int
dwmmc_strategy(unsigned long blkno, unsigned char *buf, int rw)
{
	unsigned int *w = (unsigned int *)buf;	/* 512 bytes = 128 words */
	unsigned int arg = dwmmc_sdhc ? (unsigned int)blkno :
	    (unsigned int)(blkno * SECTOR_BYTES);
	unsigned long spin;
	unsigned int i, st;
	unsigned int flags = CMD_RESP_EXPECTED | CMD_DATA_EXPECTED |
	    CMD_WAIT_PRVDATA;

	if (!dwmmc_ready)
		return (-1);

	*reg(DWMMC_BLKSIZ) = SECTOR_BYTES;
	*reg(DWMMC_BYTCNT) = SECTOR_BYTES;
	*reg(DWMMC_RINTSTS) = 0xffffffffU;

#if DWMMC_USE_DMA
	/*
	 * IDMAC descriptor-ring path.  One descriptor describes the whole 512-byte
	 * buffer (FS|LD|OWN), no chain (buffer-2 unused).  Reset the FIFO + the
	 * IDMAC, program FIFOTH, point DBADDR at the descriptor's PHYSICAL address,
	 * set CTRL USE_IDMAC|DMA_ENABLE, issue the read/write command, kick with
	 * PLDMND, then poll RINTSTS for data-over.  The kernel direct-map turns a
	 * kernel VA into the PA the DMA engine needs via KVTOP().
	 */
	dwmmc_desc.des0 = IDMAC_DES0_OWN | IDMAC_DES0_FS | IDMAC_DES0_LD;
	dwmmc_desc.des1 = IDMAC_DES1_BS1(SECTOR_BYTES);
	dwmmc_desc.des2 = (unsigned int)KVTOP(buf);	/* buffer-1 phys addr */
	dwmmc_desc.des3 = 0;				/* no buffer-2 / no chain */

	*reg(DWMMC_CTRL) |= CTRL_FIFO_RESET;
	for (spin = 0; spin < POLL_LIMIT; spin++)
		if ((*reg(DWMMC_CTRL) & CTRL_FIFO_RESET) == 0)
			break;
	*reg(DWMMC_BMOD) = BMOD_SWR;			/* reset the IDMAC */
	*reg(DWMMC_FIFOTH) = FIFOTH_VAL;
	*reg(DWMMC_DBADDR) = (unsigned int)KVTOP(&dwmmc_desc);
	*reg(DWMMC_CTRL) |= CTRL_USE_IDMAC | CTRL_DMA_ENABLE;
	*reg(DWMMC_BMOD) |= BMOD_FB | BMOD_DE;		/* enable the DMA */

	if (dwmmc_cmd(rw == 0 ? MMC_READ_SINGLE_BLOCK : MMC_WRITE_SINGLE_BLOCK,
	    arg, rw == 0 ? flags : (flags | CMD_WRITE)) != 0)
		return (-1);
	*reg(DWMMC_PLDMND) = 1;				/* poll-demand: kick the DMA */
	(void) w;
	(void) i;
	for (spin = 0; spin < POLL_LIMIT; spin++) {
		st = *reg(DWMMC_RINTSTS);
		if (st & INT_ERROR)
			return (-1);
		if (st & INT_DATA_OVER) {
			*reg(DWMMC_CTRL) &= ~(CTRL_USE_IDMAC | CTRL_DMA_ENABLE);
			return (0);
		}
	}
	return (-1);
#else
	/* PIO path (default; the tested-shape milestone driver). */
	if (rw == 0) {
		/* CMD17 READ_SINGLE_BLOCK. */
		if (dwmmc_cmd(MMC_READ_SINGLE_BLOCK, arg, flags) != 0)
			return (-1);
		/* drain 128 words from the RX FIFO as they arrive. */
		for (i = 0; i < SECTOR_BYTES / 4; ) {
			st = *reg(DWMMC_STATUS);
			if (STATUS_FIFO_COUNT(st) > 0) {
				w[i++] = *reg(DWMMC_DATA);
				continue;
			}
			/* no words yet: bail if the transfer errored/finished. */
			st = *reg(DWMMC_RINTSTS);
			if (st & INT_ERROR)
				return (-1);
			if (st & INT_DATA_OVER)
				break;
		}
	} else {
		/* CMD24 WRITE_SINGLE_BLOCK. */
		if (dwmmc_cmd(MMC_WRITE_SINGLE_BLOCK, arg,
		    flags | CMD_WRITE) != 0)
			return (-1);
		/* push 128 words into the TX FIFO. */
		for (i = 0; i < SECTOR_BYTES / 4; i++)
			*reg(DWMMC_DATA) = w[i];
	}

	/* wait for data-transfer-over. */
	for (spin = 0; spin < POLL_LIMIT; spin++) {
		st = *reg(DWMMC_RINTSTS);
		if (st & INT_ERROR)
			return (-1);
		if (st & INT_DATA_OVER)
			return (0);
	}
	return (-1);
#endif
}
