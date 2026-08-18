/*
 * emac.h -- R-P63: the SpacemiT K1 `spacemit,k1x-emac` 1GbE MAC driver seam
 * (the Milk-V Jupiter's on-board NIC).  The k1x-emac is a Synopsys DesignWare
 * GMAC-family MAC with SpacemiT glue (its own PHY-interface / clock-mux config
 * registers on top of the standard DW-GMAC MAC + DMA blocks).  This driver is
 * from-scratch from the Linux vendor driver
 * (drivers/net/ethernet/spacemit/k1x_emac.c) -- NO BSD crib -- reusing the
 * well-known DW-GMAC register model + descriptor format.
 *
 * The seam is a minimal net-device abstraction (emac_set_base/emac_probe/
 * emac_present/emac_tx/emac_rx/emac_intr) that a later illumos GLDv3 mac shim
 * can adopt, mirroring the dwmmc/sdhci block seam.  qemu -machine virt has NO
 * k1x-emac node, so emac_set_base() is never called with the K1 base,
 * emac_present() stays 0, and no MMIO is touched -- DTB-selected off, dormant,
 * REGRESSION-SAFE (exactly like sdhci.c in R-P62).  On the Jupiter the FDT
 * walker's fi_net_base (fi_net_kind == FDT_NET_K1X_EMAC) binds this driver and
 * the CCU emac clock (k1.c) is ungated first.
 */
#ifndef	_RP63_EMAC_H
#define	_RP63_EMAC_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * emac_set_base -- bind the driver to the DTB-discovered k1x-emac MMIO base
 * (fdt_info.fi_net_base when fi_net_kind == FDT_NET_K1X_EMAC; the K1
 * ethernet@cac80000).  A nonzero base makes emac_present() eligible.  irq is
 * the PLIC interrupt number from the DTB (emac_intr routes through the PLIC).
 */
extern void emac_set_base(unsigned long base, unsigned int irq);

/*
 * emac_probe -- one-time MAC bring-up: soft-reset the DW-GMAC DMA, program the
 * station MAC address, set the GMII/RGMII PHY interface, build the TX + RX
 * descriptor rings, bring the PHY up over MDIO, and start the RX/TX DMA.
 * Returns 1 if the MAC came up (a live k1x-emac), 0 otherwise (no base bound,
 * or no MAC -- always 0 under qemu-virt, no k1x-emac node).
 */
extern int emac_probe(void);

/* emac_present -- 1 once emac_probe() succeeded, else 0 (0 under qemu). */
extern int emac_present(void);

/*
 * emac_tx -- queue ONE ethernet frame (len bytes at buf) on the TX ring and
 * kick the DW-GMAC TX DMA.  Returns 0 on success, -1 if not present / no free
 * descriptor.  (The same one-frame-per-call shape a GLDv3 mac_tx would wrap.)
 */
extern int emac_tx(const unsigned char *buf, unsigned int len);

/*
 * emac_rx -- poll the RX ring for ONE received frame; on a completed RX
 * descriptor copy up to cap bytes into buf and return the frame length,
 * recycle the descriptor.  Returns 0 if the ring is empty, -1 if not present.
 */
extern int emac_rx(unsigned char *buf, unsigned int cap);

/*
 * emac_intr -- the MAC interrupt handler (called from the PLIC dispatch for
 * fi_net_irq).  Acks the DW-GMAC DMA status (normal/abnormal), advances the
 * TX-reclaim + RX-complete bookkeeping.  Returns 1 if it handled an interrupt.
 */
extern int emac_intr(void);

#ifdef __cplusplus
}
#endif

#endif	/* _RP63_EMAC_H */
