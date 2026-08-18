/*
 * emac.c -- R-P63 (HEADLINE): a from-scratch illumos driver for the SpacemiT K1
 * `spacemit,k1x-emac` 1GbE MAC (the Milk-V Jupiter's on-board NIC).
 *
 * The k1x-emac is a Synopsys DesignWare GMAC-family MAC (the MAC + a DMA engine
 * with descriptor rings) wrapped with SpacemiT glue: a small block of
 * SpacemiT-specific registers (the PHY-interface select RGMII/RMII, the TX/RX
 * clock source + delay lines, a control/status register) sitting above the
 * standard DW-GMAC MAC (offset 0x0000) and DMA (offset 0x1000) register banks.
 * The register LAYOUT + init sequence + descriptor format are cribbed from the
 * Linux vendor driver drivers/net/ethernet/spacemit/k1x_emac.c (the SpacemiT k1
 * BSP kernel tree) -- NO BSD crib; the DW-GMAC MAC/DMA model is well-known and
 * this reimplements it against that public register model.
 *
 * qemu -machine virt has NO k1x-emac controller (its NIC is virtio-net), so
 * this driver CANNOT be exercised under qemu -- it is a COMPILE + link +
 * structured driver for the K1 board, exactly like sdhci.c/dwmmc.c are for
 * their boards.  Under qemu the FDT has no k1x-emac node (fi_net_kind is not
 * FDT_NET_K1X_EMAC), so emac_set_base() is never given the K1 base,
 * emac_present() stays 0, and no MMIO is ever touched -- DTB-selected off,
 * dormant, REGRESSION-SAFE.  On the Jupiter the FDT walker finds the
 * `spacemit,k1x-emac` node's reg base + PLIC IRQ, the k1.c CCU ungates the emac
 * clock, emac_probe() brings the MAC + PHY up, and emac_tx/emac_rx move frames.
 *
 * The seam is a minimal net-device abstraction (emac_set_base/probe/present/
 * tx/rx/intr) -- the same shape a later illumos GLDv3 mac-registration shim
 * would wrap (GLDv3 mac_register -> mc_start/mc_tx/mac_rx/mc_getcapab).  GLDv3
 * is not up in this port yet, so this net-device seam is what the block layer's
 * dwmmc/sdhci seam is for storage: a driver-shaped entry that a GLDv3 shim can
 * adopt with no change to the register/DMA core below.
 *
 * CRIB PROVENANCE: the DW-GMAC MAC register bank (GMAC_CONFIG / FRAME_FILTER /
 * GMII_ADDR|DATA for MDIO / ADDR_HIGH|LOW), the DW-GMAC DMA register bank
 * (BUS_MODE / TX|RX_POLL_DEMAND / RX|TX_DESC_LIST_ADDR / STATUS / OP_MODE /
 * INT_ENABLE) and the DW-GMAC "normal" (non-enhanced) TX/RX descriptor format
 * (des0 status/OWN, des1 control+length, des2 buffer ptr, des3 next ptr) are
 * the Synopsys DesignWare Ethernet MAC databook register model as implemented
 * by the mainline stmmac driver + the SpacemiT vendor k1x_emac.c; the SpacemiT
 * glue offsets (PHY-interface select, clk/reset control) are k1x_emac.c's
 * SpacemiT-specific block.  The exact SpacemiT glue bit fields + the RGMII
 * clock-delay tuning are the on-HW calibration knobs (see emac.h / the memory
 * map) -- a real board's PHY timing is never the ideal on paper.
 */

#include "emac.h"
#include "mmu_riscv.h"

extern void sbi_console_puts(const char *s);
extern void putdec_pub(unsigned long v);
extern void puthex_pub(unsigned long v);

/* ------------------------------------------------------------------------- *
 * DW-GMAC MAC register bank (bytes from the controller base, GMAC block).
 * ------------------------------------------------------------------------- */
#define	GMAC_CONFIG		0x0000	/* MAC configuration (TE/RE, speed, duplex) */
#define	GMAC_FRAME_FILTER	0x0004	/* frame filter (promisc/bcast/mcast) */
#define	GMAC_HASH_HIGH		0x0008
#define	GMAC_HASH_LOW		0x000c
#define	GMAC_GMII_ADDR		0x0010	/* MDIO address/command (MII_ADDR) */
#define	GMAC_GMII_DATA		0x0014	/* MDIO data (MII_DATA) */
#define	GMAC_FLOW_CTRL		0x0018
#define	GMAC_VERSION		0x0020
#define	GMAC_INT_STATUS		0x0038
#define	GMAC_INT_MASK		0x003c
#define	GMAC_ADDR0_HIGH		0x0040	/* station MAC addr[47:32] */
#define	GMAC_ADDR0_LOW		0x0044	/* station MAC addr[31:0] */

/* GMAC_CONFIG bits. */
#define	GMAC_CFG_RE		(1U << 2)	/* receiver enable */
#define	GMAC_CFG_TE		(1U << 3)	/* transmitter enable */
#define	GMAC_CFG_DM		(1U << 11)	/* duplex mode (1=full) */
#define	GMAC_CFG_FES		(1U << 14)	/* speed 100 (with PS) */
#define	GMAC_CFG_PS		(1U << 15)	/* port select MII(1)/GMII(0) */
#define	GMAC_CFG_JD		(1U << 22)	/* jabber disable */
#define	GMAC_CFG_BE		(1U << 21)	/* frame burst enable */

/* GMAC_FRAME_FILTER bits. */
#define	GMAC_FF_PR		(1U << 0)	/* promiscuous */
#define	GMAC_FF_PM		(1U << 4)	/* pass all multicast */
#define	GMAC_FF_RA		(1U << 31)	/* receive all */

/* GMAC_GMII_ADDR (MDIO) bits. */
#define	MII_BUSY		(1U << 0)
#define	MII_WRITE		(1U << 1)
#define	MII_CLK_DIV_SHIFT	2		/* CSR clock range */
#define	MII_REG_SHIFT		6		/* PHY register [10:6]  */
#define	MII_ADDR_SHIFT		11		/* PHY address  [15:11] */

/* ------------------------------------------------------------------------- *
 * DW-GMAC DMA register bank (bytes from base + DMA_OFFSET).
 * ------------------------------------------------------------------------- */
#define	DMA_OFFSET		0x1000
#define	DMA_BUS_MODE		(DMA_OFFSET + 0x00)	/* SWR soft reset, burst */
#define	DMA_TX_POLL		(DMA_OFFSET + 0x04)	/* transmit poll demand */
#define	DMA_RX_POLL		(DMA_OFFSET + 0x08)	/* receive poll demand */
#define	DMA_RX_DESC_ADDR	(DMA_OFFSET + 0x0c)	/* RX descriptor list */
#define	DMA_TX_DESC_ADDR	(DMA_OFFSET + 0x10)	/* TX descriptor list */
#define	DMA_STATUS		(DMA_OFFSET + 0x14)	/* DMA status (w1c) */
#define	DMA_OP_MODE		(DMA_OFFSET + 0x18)	/* SR/ST start rx/tx */
#define	DMA_INT_ENABLE		(DMA_OFFSET + 0x1c)	/* interrupt enable */
#define	DMA_CUR_TX_DESC		(DMA_OFFSET + 0x48)
#define	DMA_CUR_RX_DESC		(DMA_OFFSET + 0x4c)

/* DMA_BUS_MODE bits. */
#define	DMA_BM_SWR		(1U << 0)	/* software reset (self-clears) */

/* DMA_OP_MODE bits. */
#define	DMA_OP_SR		(1U << 1)	/* start receive */
#define	DMA_OP_ST		(1U << 13)	/* start transmit */
#define	DMA_OP_TSF		(1U << 21)	/* transmit store-and-forward */
#define	DMA_OP_RSF		(1U << 25)	/* receive store-and-forward */

/* DMA_STATUS / DMA_INT_ENABLE bits. */
#define	DMA_INT_TI		(1U << 0)	/* transmit interrupt */
#define	DMA_INT_RI		(1U << 6)	/* receive interrupt */
#define	DMA_INT_NIS		(1U << 16)	/* normal interrupt summary */
#define	DMA_INT_AIS		(1U << 15)	/* abnormal interrupt summary */

/* ------------------------------------------------------------------------- *
 * SpacemiT glue register block (k1x_emac.c SpacemiT-specific, offset base+0x0).
 * These sit in a separate SpacemiT window in the vendor driver; here they are
 * modelled as controller-relative offsets in the high glue area.  The exact
 * offsets + bit fields are the k1x_emac.c PHY-interface/clk block and are an
 * on-HW calibration knob (RGMII tx/rx clock delay).
 * ------------------------------------------------------------------------- */
#define	EMAC_GLUE_CTRL		0x0800	/* SpacemiT control (clk/reset/phy-if) */
#define	EMAC_GLUE_PHY_INTF	0x0804	/* PHY interface select */
#define	EMAC_PHY_INTF_RGMII	1	/* RGMII (the Jupiter 1GbE PHY) */
#define	EMAC_PHY_INTF_RMII	4	/* RMII */

/* ------------------------------------------------------------------------- *
 * DW-GMAC "normal" TX/RX descriptor (16 bytes: des0..des3).  Ring in the
 * kernel image so its physical address is KVTOP(va) under the direct map (the
 * DW-GMAC DMA reads descriptors + buffers by physical address).
 * ------------------------------------------------------------------------- */
struct emac_desc {
	volatile unsigned int	des0;	/* status; bit31 OWN = owned by DMA */
	volatile unsigned int	des1;	/* control + buffer1 length [10:0] */
	volatile unsigned int	des2;	/* buffer1 physical address */
	volatile unsigned int	des3;	/* buffer2 / next-descriptor phys */
};

/* des0 (status). */
#define	DESC_OWN		(1U << 31)	/* owned by DMA (not CPU) */
#define	RDESC0_FL_SHIFT		16		/* RX frame length [29:16] */
#define	RDESC0_FL_MASK		0x3fffU
#define	RDESC0_LS		(1U << 8)	/* last descriptor of frame */
#define	RDESC0_FS		(1U << 9)	/* first descriptor of frame */
#define	RDESC0_ES		(1U << 15)	/* error summary */

/* des1 (control). */
#define	TDESC1_LS		(1U << 30)	/* last segment */
#define	TDESC1_FS		(1U << 29)	/* first segment */
#define	TDESC1_IC		(1U << 31)	/* interrupt on completion */
#define	DESC1_RCH		(1U << 24)	/* second addr = next desc (chained) */
#define	DESC1_TCH		(1U << 24)	/* (TX) second addr chained */
#define	DESC1_LEN_MASK		0x7ffU		/* buffer1 length [10:0] */

#define	EMAC_NRX		8		/* RX ring depth */
#define	EMAC_NTX		8		/* TX ring depth */
#define	EMAC_BUFSZ		2048		/* per-descriptor buffer (frame) */
#define	POLL_LIMIT		1000000UL	/* dead-HW busy-poll bound */

/*
 * Rings + DMA buffers, statically allocated in the kernel image (BSS).  Aligned
 * so the DW-GMAC descriptor-list base is 16-byte aligned; buffers are cache-
 * line-ish aligned.  The DMA sees KVTOP(va) (physical) via the direct map.
 * These are static single-MAC rings; a second k1x-emac (the K1 has two) or a
 * GLDv3 multi-instance shim would make these per-instance -- for a second NIC
 * or once GLDv3 lands.
 */
static struct emac_desc emac_rx_ring[EMAC_NRX] __attribute__((aligned(64)));
static struct emac_desc emac_tx_ring[EMAC_NTX] __attribute__((aligned(64)));
static unsigned char emac_rx_buf[EMAC_NRX][EMAC_BUFSZ] __attribute__((aligned(64)));
static unsigned char emac_tx_buf[EMAC_NTX][EMAC_BUFSZ] __attribute__((aligned(64)));

/* ---- driver state ---- */
static unsigned long emac_base;		/* DTB-bound controller PA, 0 = unbound */
static unsigned int emac_irq;		/* PLIC IRQ number from the DTB */
static int emac_ready;			/* 1 once emac_probe() succeeded */
static unsigned int emac_rx_cur;	/* next RX descriptor to inspect */
static unsigned int emac_tx_cur;	/* next TX descriptor to fill */
static unsigned char emac_mac[6];	/* station MAC address */
static int emac_phy_addr;		/* MDIO PHY address (scanned) */
static unsigned long emac_rx_frames;	/* RX frames handed up */
static unsigned long emac_tx_frames;	/* TX frames queued */

/*
 * MMIO through the kernel HIGH direct-map (KERNEL_DMAP_BASE + PA), exactly like
 * sdhci.c/dwmmc.c.  The K1 device MMIO is mapped by the boot/kernel HAT.
 */
static inline volatile unsigned int *
reg(unsigned int off)
{
	return ((volatile unsigned int *)(KERNEL_DMAP_BASE + emac_base + off));
}
static inline unsigned int
rd(unsigned int off)
{
	return (*reg(off));
}
static inline void
wr(unsigned int off, unsigned int v)
{
	*reg(off) = v;
}

/* KVTOP: kernel high-VA (direct map) -> physical, for the DMA descriptor/buffer
 * pointers the DW-GMAC reads.  A static kernel object at DMAP+PA maps back to
 * PA by subtracting KERNEL_DMAP_BASE. */
static inline unsigned long
kvtop(const void *va)
{
	return ((unsigned long)va - KERNEL_DMAP_BASE);
}

/*
 * emac_set_base -- bind the driver to the DTB-discovered k1x-emac MMIO base +
 * PLIC IRQ (fdt_info.fi_net_base / fi_net_irq when fi_net_kind ==
 * FDT_NET_K1X_EMAC).  A nonzero base makes emac_present() eligible; the MAC
 * bring-up still has to succeed in emac_probe().
 */
void
emac_set_base(unsigned long base, unsigned int irq)
{
	if (base != 0) {
		emac_base = base;
		emac_irq = irq;
	}
}

/* emac_present -- 1 once emac_probe() succeeded, else 0 (0 under qemu). */
int
emac_present(void)
{
	return (emac_ready);
}

/* ---- MDIO (MII) PHY access over GMAC_GMII_ADDR/DATA -------------------- */

/* Bounded spin until the MII busy bit clears. */
static int
mii_wait(void)
{
	unsigned long spin;
	for (spin = 0; spin < POLL_LIMIT; spin++) {
		if ((rd(GMAC_GMII_ADDR) & MII_BUSY) == 0)
			return (1);
	}
	return (0);
}

/* Read PHY register `reg_num` of PHY `phy` over MDIO.  Returns 16-bit value. */
static unsigned int
mdio_read(int phy, int reg_num)
{
	unsigned int cmd;
	if (!mii_wait())
		return (0xffff);
	cmd = MII_BUSY |
	    ((unsigned int)phy << MII_ADDR_SHIFT) |
	    ((unsigned int)reg_num << MII_REG_SHIFT) |
	    (1U << MII_CLK_DIV_SHIFT);		/* a mid CSR clock divider */
	wr(GMAC_GMII_ADDR, cmd);
	if (!mii_wait())
		return (0xffff);
	return (rd(GMAC_GMII_DATA) & 0xffff);
}

/* Write `val` to PHY register `reg_num` of PHY `phy` over MDIO. */
static void
mdio_write(int phy, int reg_num, unsigned int val)
{
	unsigned int cmd;
	if (!mii_wait())
		return;
	wr(GMAC_GMII_DATA, val & 0xffff);
	cmd = MII_BUSY | MII_WRITE |
	    ((unsigned int)phy << MII_ADDR_SHIFT) |
	    ((unsigned int)reg_num << MII_REG_SHIFT) |
	    (1U << MII_CLK_DIV_SHIFT);
	wr(GMAC_GMII_ADDR, cmd);
	(void) mii_wait();
}

/* Scan MDIO addresses 0..31 for a PHY answering with a plausible ID. */
static int
mdio_scan_phy(void)
{
	int a;
	for (a = 0; a < 32; a++) {
		unsigned int id = mdio_read(a, 2);	/* PHY ID reg 2 */
		if (id != 0x0000 && id != 0xffff)
			return (a);
	}
	return (-1);
}

/* ---- descriptor ring setup -------------------------------------------- */

/* Build the RX ring: each descriptor points at its buffer, chained, OWN=DMA. */
static void
emac_setup_rx_ring(void)
{
	unsigned int i;
	for (i = 0; i < EMAC_NRX; i++) {
		emac_rx_ring[i].des1 = DESC1_RCH | (EMAC_BUFSZ & DESC1_LEN_MASK);
		emac_rx_ring[i].des2 = (unsigned int)kvtop(emac_rx_buf[i]);
		emac_rx_ring[i].des3 = (unsigned int)kvtop(
		    &emac_rx_ring[(i + 1) % EMAC_NRX]);
		emac_rx_ring[i].des0 = DESC_OWN;	/* hand to DMA */
	}
	emac_rx_cur = 0;
	wr(DMA_RX_DESC_ADDR, (unsigned int)kvtop(&emac_rx_ring[0]));
}

/* Build the TX ring: chained, buffers empty, OWN=CPU (we fill on tx). */
static void
emac_setup_tx_ring(void)
{
	unsigned int i;
	for (i = 0; i < EMAC_NTX; i++) {
		emac_tx_ring[i].des0 = 0;		/* owned by CPU */
		emac_tx_ring[i].des1 = DESC1_TCH;
		emac_tx_ring[i].des2 = (unsigned int)kvtop(emac_tx_buf[i]);
		emac_tx_ring[i].des3 = (unsigned int)kvtop(
		    &emac_tx_ring[(i + 1) % EMAC_NTX]);
	}
	emac_tx_cur = 0;
	wr(DMA_TX_DESC_ADDR, (unsigned int)kvtop(&emac_tx_ring[0]));
}

/* ---- MAC bring-up ----------------------------------------------------- */

/*
 * emac_probe -- one-time k1x-emac bring-up:
 *   1. SpacemiT glue: select the RGMII PHY interface (the Jupiter 1GbE PHY).
 *   2. DW-GMAC DMA soft reset (BUS_MODE.SWR, self-clearing).
 *   3. Program the station MAC address (ADDR0_HIGH/LOW).
 *   4. MAC config: full-duplex GMII, receiver + transmitter enable.
 *   5. Build the TX + RX descriptor rings, hand RX to the DMA.
 *   6. Bring the PHY up over MDIO (scan for the PHY, read its status).
 *   7. Start the RX + TX DMA (OP_MODE.SR|ST) + enable the DMA interrupts.
 * Returns 1 on a live MAC, 0 if no base bound (always 0 under qemu).
 */
int
emac_probe(void)
{
	unsigned long spin;
	unsigned int cfg;

	if (emac_base == 0)
		return (0);		/* unbound: no k1x-emac (qemu-virt) */

	/* A default station MAC (locally-administered) until DTB/OTP supplies one;
	 * the board OTP / the DTB `local-mac-address` is the real per-board address,
	 * read once the Jupiter is in hand. */
	emac_mac[0] = 0x02; emac_mac[1] = 0x00; emac_mac[2] = 0x53; /* 'S' */
	emac_mac[3] = 0x4f; emac_mac[4] = 0x4c; emac_mac[5] = 0x01; /* OL.1 */

	/* 1. SpacemiT glue: RGMII PHY interface. */
	wr(EMAC_GLUE_PHY_INTF, EMAC_PHY_INTF_RGMII);

	/* 2. DW-GMAC DMA soft reset -- SWR self-clears when the reset completes. */
	wr(DMA_BUS_MODE, DMA_BM_SWR);
	for (spin = 0; spin < POLL_LIMIT; spin++) {
		if ((rd(DMA_BUS_MODE) & DMA_BM_SWR) == 0)
			break;
	}
	if (spin >= POLL_LIMIT)
		return (0);		/* reset never completed -- dead MAC */

	/* 3. station MAC address into ADDR0. */
	wr(GMAC_ADDR0_HIGH, ((unsigned int)emac_mac[5] << 8) | emac_mac[4]);
	wr(GMAC_ADDR0_LOW, ((unsigned int)emac_mac[3] << 24) |
	    ((unsigned int)emac_mac[2] << 16) |
	    ((unsigned int)emac_mac[1] << 8) | emac_mac[0]);

	/* 4. MAC config: full-duplex, RX+TX enable (speed set after PHY link). */
	cfg = GMAC_CFG_DM | GMAC_CFG_RE | GMAC_CFG_TE | GMAC_CFG_JD | GMAC_CFG_BE;
	wr(GMAC_CONFIG, cfg);
	/* accept broadcast + our unicast; promisc off (a filtered NIC). */
	wr(GMAC_FRAME_FILTER, 0);

	/* 5. descriptor rings. */
	emac_setup_rx_ring();
	emac_setup_tx_ring();

	/* 6. PHY over MDIO: scan for the PHY, kick auto-negotiation. */
	emac_phy_addr = mdio_scan_phy();
	if (emac_phy_addr >= 0) {
		unsigned int bmcr = mdio_read(emac_phy_addr, 0);	/* BMCR */
		mdio_write(emac_phy_addr, 0, bmcr | (1U << 12) | (1U << 9));
		/* bit12 = AN enable, bit9 = restart AN. */
	}

	/* 7. store-and-forward + start RX/TX DMA, enable DMA interrupts. */
	wr(DMA_OP_MODE, DMA_OP_TSF | DMA_OP_RSF | DMA_OP_SR | DMA_OP_ST);
	wr(DMA_INT_ENABLE, DMA_INT_NIS | DMA_INT_TI | DMA_INT_RI | DMA_INT_AIS);

	emac_ready = 1;
	return (1);
}

/* ---- TX / RX paths ---------------------------------------------------- */

/*
 * emac_tx -- copy one frame into the current TX buffer, mark the descriptor
 * first+last+own-DMA, and poke the TX poll demand so the DW-GMAC DMA fetches it.
 */
int
emac_tx(const unsigned char *buf, unsigned int len)
{
	struct emac_desc *d;
	unsigned int i;

	if (!emac_ready)
		return (-1);
	if (len == 0 || len > EMAC_BUFSZ)
		return (-1);

	d = &emac_tx_ring[emac_tx_cur];
	if (d->des0 & DESC_OWN)
		return (-1);		/* ring full: DMA still owns this slot */

	for (i = 0; i < len; i++)
		emac_tx_buf[emac_tx_cur][i] = buf[i];

	d->des1 = DESC1_TCH | TDESC1_FS | TDESC1_LS | TDESC1_IC |
	    (len & DESC1_LEN_MASK);
	d->des0 = DESC_OWN;		/* hand to DMA */

	wr(DMA_TX_POLL, 1);		/* transmit poll demand */
	emac_tx_cur = (emac_tx_cur + 1) % EMAC_NTX;
	emac_tx_frames++;
	return (0);
}

/*
 * emac_rx -- if the current RX descriptor is owned by the CPU (DMA finished),
 * copy the frame out, recycle the descriptor back to the DMA, advance.  Returns
 * the frame length, 0 if the ring is empty, -1 if not present.
 */
int
emac_rx(unsigned char *buf, unsigned int cap)
{
	struct emac_desc *d;
	unsigned int fl, i;

	if (!emac_ready)
		return (-1);

	d = &emac_rx_ring[emac_rx_cur];
	if (d->des0 & DESC_OWN)
		return (0);		/* still owned by DMA: nothing yet */

	if (d->des0 & RDESC0_ES) {
		fl = 0;			/* error frame -- drop, recycle */
	} else {
		fl = (d->des0 >> RDESC0_FL_SHIFT) & RDESC0_FL_MASK;
		if (fl > cap)
			fl = cap;
		for (i = 0; i < fl; i++)
			buf[i] = emac_rx_buf[emac_rx_cur][i];
	}

	/* recycle the descriptor back to the DMA. */
	d->des0 = DESC_OWN;
	wr(DMA_RX_POLL, 1);		/* receive poll demand */
	emac_rx_cur = (emac_rx_cur + 1) % EMAC_NRX;
	if (fl > 0)
		emac_rx_frames++;
	return ((int)fl);
}

/*
 * emac_intr -- the DW-GMAC DMA interrupt handler (PLIC dispatch for emac_irq).
 * Acks the DMA status write-1-clear, so the PLIC line deasserts; the TX-reclaim
 * + RX-complete work is picked up by emac_tx/emac_rx polling the rings (the
 * milestone path).  Returns 1 if an interrupt was pending.
 */
int
emac_intr(void)
{
	unsigned int status;
	if (!emac_ready)
		return (0);
	status = rd(DMA_STATUS);
	if ((status & (DMA_INT_NIS | DMA_INT_AIS)) == 0)
		return (0);
	wr(DMA_STATUS, status);		/* write-1-clear the pending bits */
	return (1);
}
