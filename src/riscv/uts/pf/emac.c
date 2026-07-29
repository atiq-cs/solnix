/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or http://www.opensolaris.org/os/licensing.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */
/*
 * Copyright 2019 Hayashi Naoyuki
 *
 * Portions Copyright 2019 Hayashi Naoyuki; adapted for solnix from
 * n-hys/illumos-gate (usr/src/uts/riscv64pf/sun20i/io/emac.c).
 * TEMPLATE for the K1 dwmac (stmmac) NIC: GLDv3 skeleton + ddi_dma ring +
 * MII/PHY structure is the reference; the register layer (Allwinner EMAC,
 * emacreg.h) is to be REWRITTEN for the K1's Synopsys dwmac. NOT wired live.
 */

#include <stddef.h>
#include <sys/promif.h>
#include <sys/miiregs.h>
#include <sys/ethernet.h>
#include <sys/byteorder.h>
#include <sys/debug.h>
#include <sys/conf.h>
#include <sys/modctl.h>
#include <sys/vlan.h>
#include <sys/mac.h>
#include <sys/mac_ether.h>
#include <sys/strsun.h>
#include <sys/miiregs.h>
#include <sys/sunndi.h>
#include <sys/ndi_impldefs.h>
#include <sys/ddi_impldefs.h>
#include <sys/crc32.h>
#include <sys/sysmacros.h>
#include <sys/emacreg.h>
#include "emac.h"

#define	EMAC_DMA_BUFFER_SIZE	1536

static ddi_device_acc_attr_t mem_acc_attr = {
	DDI_DEVICE_ATTR_V0,
	DDI_NEVERSWAP_ACC,
	DDI_STORECACHING_OK_ACC,
};

static ddi_device_acc_attr_t desc_acc_attr = {
	DDI_DEVICE_ATTR_V0,
	DDI_NEVERSWAP_ACC,
	DDI_MERGING_OK_ACC,
};

static ddi_device_acc_attr_t reg_acc_attr = {
	DDI_DEVICE_ATTR_V0,
	DDI_NEVERSWAP_ACC,
	DDI_STRICTORDER_ACC,
};

static ddi_dma_attr_t dma_attr = {
	DMA_ATTR_V0,			/* dma_attr_version	*/
	0x0000000000000000ull,		/* dma_attr_addr_lo	*/
	0x00000000FFFFFFFFull,		/* dma_attr_addr_hi	*/
	0x00000000FFFFFFFFull,		/* dma_attr_count_max	*/
	0x0000000000000001ull,		/* dma_attr_align	*/
	0x00000FFF,			/* dma_attr_burstsizes	*/
	0x00000001,			/* dma_attr_minxfer	*/
	0x00000000FFFFFFFFull,		/* dma_attr_maxxfer	*/
	0x00000000FFFFFFFFull,		/* dma_attr_seg		*/
	1,				/* dma_attr_sgllen	*/
	0x00000001,			/* dma_attr_granular	*/
	DDI_DMA_FLAGERR			/* dma_attr_flags	*/
};

static void emac_destroy(struct emac_sc *sc);
static void emac_m_stop(void *arg);

static void
emac_reg_write(struct emac_sc *sc, int offset, uint32_t val)
{
	uint32_t *addr = sc->reg.addr + offset / 4;
	ddi_put32(sc->reg.handle, addr, val);
}

static uint32_t
emac_reg_read(struct emac_sc *sc, int offset)
{
	uint32_t *addr = sc->reg.addr + offset / 4;
	return ddi_get32(sc->reg.handle, addr);
}

static struct emac_txdesc *
emac_get_tx_desc(struct emac_sc *sc, int index)
{
	return (struct emac_txdesc *)(sc->tx_ring.desc.addr + index * sizeof(struct emac_txdesc));
}

static struct emac_rxdesc *
emac_get_rx_desc(struct emac_sc *sc, int index)
{
	return (struct emac_rxdesc *)(sc->rx_ring.desc.addr + index * sizeof(struct emac_rxdesc));
}

static paddr_t
emac_get_tx_desc_phys(struct emac_sc *sc, int index)
{
	return (sc->tx_ring.desc.dmac_addr + index * sizeof(struct emac_txdesc));
}

static paddr_t
emac_get_rx_desc_phys(struct emac_sc *sc, int index)
{
	return (sc->rx_ring.desc.dmac_addr + index * sizeof(struct emac_rxdesc));
}

static caddr_t
emac_get_tx_buffer(struct emac_sc *sc, int index)
{
	struct emac_packet *pkt = sc->tx_ring.pkt[index];
	return pkt->dma.addr;
}

static caddr_t
emac_get_rx_buffer(struct emac_sc *sc, int index)
{
	struct emac_packet *pkt = sc->rx_ring.pkt[index];
	return pkt->dma.addr;
}

static paddr_t
emac_get_tx_buffer_phys(struct emac_sc *sc, int index)
{
	struct emac_packet *pkt = sc->tx_ring.pkt[index];
	return pkt->dma.dmac_addr;
}

static paddr_t
emac_get_rx_buffer_phys(struct emac_sc *sc, int index)
{
	struct emac_packet *pkt = sc->rx_ring.pkt[index];
	return pkt->dma.dmac_addr;
}

static void
emac_usecwait(int usec)
{
	drv_usecwait(usec);
}

static pnode_t
emac_get_node(struct emac_sc *sc)
{
	return ddi_get_nodeid(sc->dip);
}

static void
emac_mutex_enter(struct emac_sc *sc)
{
	mutex_enter(&sc->intrlock);
}

static void
emac_mutex_exit(struct emac_sc *sc)
{
	mutex_exit(&sc->intrlock);
}

static void
emac_gmac_reset(struct emac_sc *sc)
{

}

static void
emac_gmac_init(struct emac_sc *sc)
{
	// soft reset
	union emac_basic_ctl1 ctl1 = { emac_reg_read(sc, EMAC_BASIC_CTL1) };
	ctl1.soft_rst = 1;
	emac_reg_write(sc, EMAC_BASIC_CTL1, ctl1.dw);
	for (int i = 0; i < 1000; i++) {
		emac_usecwait(100);
		ctl1.dw = emac_reg_read(sc, EMAC_BASIC_CTL1);
		if (ctl1.soft_rst == 0)
			break;
	}

	// interrupt disable && clear
	emac_reg_write(sc, EMAC_INT_EN, 0);
	emac_reg_write(sc, EMAC_INT_STA, 0xffffffff);

	union emac_addr_low0 addr_low0 = {0};
	union emac_addr_high0 addr_high0 = {0};
	addr_low0.mac_addr_low0 = (sc->dev_addr[3] << 24) | (sc->dev_addr[2] << 16) | (sc->dev_addr[1] << 8) | sc->dev_addr[0];
	addr_high0.mac_addr_high0 = (sc->dev_addr[5] << 8) | sc->dev_addr[4];
	emac_reg_write(sc, EMAC_ADDR_LOW0, addr_low0.dw);
	emac_reg_write(sc, EMAC_ADDR_HIGH0, addr_high0.dw);

	union emac_tx_ctl1 tx_ctl1 = { .tx_md = 1 };
	emac_reg_write(sc, EMAC_TX_CTL1, tx_ctl1.dw);

	union emac_rx_ctl1 rx_ctl1 = { .rx_md = 1 };
	emac_reg_write(sc, EMAC_RX_CTL1, rx_ctl1.dw);

	ctl1.dw = 0;
	ctl1.burst_len = 8;
	ctl1.rx_tx_pri = 1;
	emac_reg_write(sc, EMAC_BASIC_CTL1, ctl1.dw);

	union emac_basic_ctl0 ctl0 = {0};
	emac_reg_write(sc, EMAC_BASIC_CTL0, ctl0.dw);

	union emac_int_en int_en = {
		.rx = 1, .rx_buf_ua = 1, .rx_dma_stopped = 1, .rx_timeout = 1, .rx_overflow = 1,
		.tx = 1, .tx_dma_stopped = 1, .tx_buf_ua = 1, .tx_timeout = 1, .tx_underflow = 1,
	};
	emac_reg_write(sc, EMAC_INT_EN, int_en.dw);

	emac_reg_write(sc, EMAC_TX_DMA_DESC_LIST, sc->tx_ring.desc.dmac_addr);
	emac_reg_write(sc, EMAC_RX_DMA_DESC_LIST, sc->rx_ring.desc.dmac_addr);
}

static void
emac_gmac_update(struct emac_sc *sc)
{
	union emac_basic_ctl0 ctl0 = { emac_reg_read(sc, EMAC_BASIC_CTL0) };

	if (sc->phy_duplex == LINK_DUPLEX_FULL)
		ctl0.duplex = 1;
	else
		ctl0.duplex = 0;

	switch (sc->phy_speed) {
	case 1000: ctl0.speed = 0; break;
	case  100: ctl0.speed = 3; break;
	case   10: ctl0.speed = 2; break;
	}

	emac_reg_write(sc, EMAC_BASIC_CTL0, ctl0.dw);
}


static void
emac_gmac_enable(struct emac_sc *sc)
{
	union emac_tx_ctl0 tx_ctl0 = { emac_reg_read(sc, EMAC_TX_CTL0) };
	union emac_tx_ctl1 tx_ctl1 = { emac_reg_read(sc, EMAC_TX_CTL1) };
	union emac_rx_ctl0 rx_ctl0 = { emac_reg_read(sc, EMAC_RX_CTL0) };
	union emac_rx_ctl1 rx_ctl1 = { emac_reg_read(sc, EMAC_RX_CTL1) };

	tx_ctl0.tx_en = 1;
	tx_ctl1.tx_dma_en = 1;
	rx_ctl0.rx_en = 1;
	rx_ctl1.rx_dma_en = 1;

	emac_reg_write(sc, EMAC_TX_CTL0, tx_ctl0.dw);
	emac_reg_write(sc, EMAC_TX_CTL1, tx_ctl1.dw);
	emac_reg_write(sc, EMAC_RX_CTL0, rx_ctl0.dw);
	emac_reg_write(sc, EMAC_RX_CTL1, rx_ctl1.dw);
}

static void
emac_gmac_disable(struct emac_sc *sc)
{
	union emac_tx_ctl0 tx_ctl0 = { emac_reg_read(sc, EMAC_TX_CTL0) };
	union emac_tx_ctl1 tx_ctl1 = { emac_reg_read(sc, EMAC_TX_CTL1) };
	union emac_rx_ctl0 rx_ctl0 = { emac_reg_read(sc, EMAC_RX_CTL0) };
	union emac_rx_ctl1 rx_ctl1 = { emac_reg_read(sc, EMAC_RX_CTL1) };

	tx_ctl0.tx_en = 0;
	tx_ctl1.tx_dma_en = 0;
	rx_ctl0.rx_en = 0;
	rx_ctl1.rx_dma_en = 0;

	emac_reg_write(sc, EMAC_TX_CTL0, tx_ctl0.dw);
	emac_reg_write(sc, EMAC_TX_CTL1, tx_ctl1.dw);
	emac_reg_write(sc, EMAC_RX_CTL0, rx_ctl0.dw);
	emac_reg_write(sc, EMAC_RX_CTL1, rx_ctl1.dw);
}

static void
emac_free_tx(struct emac_sc *sc, int idx)
{
	if (sc->tx_ring.mp[idx]) {
		freemsg(sc->tx_ring.mp[idx]);
		sc->tx_ring.mp[idx] = NULL;
	}
}

static void
emac_free_packet(struct emac_packet *pkt)
{
	struct emac_sc *sc = pkt->sc;
	if (sc->running && sc->rx_pkt_num < RX_PKT_NUM_MAX) {
		pkt->mp = desballoc((unsigned char *)pkt->dma.addr, EMAC_DMA_BUFFER_SIZE, BPRI_MED, &pkt->free_rtn);
	} else {
		pkt->mp = NULL;
	}
	if (pkt->mp == NULL) {
		ddi_dma_unbind_handle(pkt->dma.dma_handle);
		ddi_dma_mem_free(&pkt->dma.mem_handle);
		ddi_dma_free_handle(&pkt->dma.dma_handle);
		kmem_free(pkt, sizeof(struct emac_packet));
	} else {
		ddi_dma_sync(pkt->dma.dma_handle, 0, pkt->dma.size, DDI_DMA_SYNC_FORDEV);

		mutex_enter(&sc->rx_pkt_lock);
		pkt->next = sc->rx_pkt_free;
		sc->rx_pkt_free = pkt;
		sc->rx_pkt_num++;
		mutex_exit(&sc->rx_pkt_lock);
	}
}

static struct emac_packet *
emac_alloc_packet(struct emac_sc *sc)
{
	struct emac_packet *pkt;
	ddi_dma_attr_t buf_dma_attr = dma_attr;
	buf_dma_attr.dma_attr_align = DCACHE_LINE;

	mutex_enter(&sc->rx_pkt_lock);
	pkt = sc->rx_pkt_free;
	if (pkt) {
		sc->rx_pkt_free = pkt->next;
		sc->rx_pkt_num--;
	}
	mutex_exit(&sc->rx_pkt_lock);

	if (pkt == NULL) {
		pkt = (struct emac_packet *)kmem_zalloc(sizeof(struct emac_packet), KM_NOSLEEP);
		if (pkt) {
			if (ddi_dma_alloc_handle(sc->dip, &buf_dma_attr, DDI_DMA_SLEEP, 0, &pkt->dma.dma_handle) != DDI_SUCCESS) {
				kmem_free(pkt, sizeof(struct emac_packet));
				pkt = NULL;
			}
		}

		if (pkt) {
			if (ddi_dma_mem_alloc(pkt->dma.dma_handle, EMAC_DMA_BUFFER_SIZE, &mem_acc_attr, DDI_DMA_CONSISTENT, DDI_DMA_SLEEP, 0,
				    &pkt->dma.addr, &pkt->dma.size, &pkt->dma.mem_handle)) {
				ddi_dma_free_handle(&pkt->dma.dma_handle);
				kmem_free(pkt, sizeof(struct emac_packet));
				pkt = NULL;
			} else {
				ASSERT(pkt->dma.size >= EMAC_DMA_BUFFER_SIZE);
	 		}
		}

		if (pkt) {
			ddi_dma_cookie_t cookie;
			uint_t ccount;
			int result = ddi_dma_addr_bind_handle(pkt->dma.dma_handle, NULL, pkt->dma.addr, pkt->dma.size, DDI_DMA_RDWR | DDI_DMA_CONSISTENT,
			    DDI_DMA_SLEEP, NULL, &cookie, &ccount);
			if (result == DDI_DMA_MAPPED) {
				ASSERT(ccount == 1);
				pkt->dma.dmac_addr = cookie.dmac_laddress;
				ASSERT((cookie.dmac_laddress & (DCACHE_LINE - 1)) == 0);
				ASSERT(cookie.dmac_size >= EMAC_DMA_BUFFER_SIZE);
				pkt->sc = sc;
				pkt->free_rtn.free_func = emac_free_packet;
				pkt->free_rtn.free_arg = (char *)pkt;

				pkt->mp = desballoc((unsigned char *)pkt->dma.addr, EMAC_DMA_BUFFER_SIZE, BPRI_MED, &pkt->free_rtn);
				if (pkt->mp == NULL) {
					ddi_dma_unbind_handle(pkt->dma.dma_handle);
					ddi_dma_mem_free(&pkt->dma.mem_handle);
					ddi_dma_free_handle(&pkt->dma.dma_handle);
					kmem_free(pkt, sizeof(struct emac_packet));
					pkt = NULL;
				}
			} else {
				ddi_dma_mem_free(&pkt->dma.mem_handle);
				ddi_dma_free_handle(&pkt->dma.dma_handle);
				kmem_free(pkt, sizeof(struct emac_packet));
				pkt = NULL;
			}
		}
	}

	return pkt;
}

static bool
emac_alloc_desc_ring(struct emac_sc *sc, struct emac_dma *desc_dma, size_t size)
{
	ddi_dma_attr_t desc_dma_attr = dma_attr;
	desc_dma_attr.dma_attr_align = DCACHE_LINE;

	if (ddi_dma_alloc_handle(sc->dip, &desc_dma_attr, DDI_DMA_SLEEP, 0, &desc_dma->dma_handle) != DDI_SUCCESS) {
		return false;
	}

	if (ddi_dma_mem_alloc(desc_dma->dma_handle, size, &desc_acc_attr, DDI_DMA_CONSISTENT | IOMEM_DATA_UC_WR_COMBINE, DDI_DMA_SLEEP, 0,
		    &desc_dma->addr, &desc_dma->size, &desc_dma->mem_handle)) {
		return false;
	}

	ddi_dma_cookie_t cookie;
	uint_t ccount;
	int result = ddi_dma_addr_bind_handle(
	    desc_dma->dma_handle, NULL, desc_dma->addr, desc_dma->size, DDI_DMA_RDWR | DDI_DMA_CONSISTENT,
	    DDI_DMA_SLEEP, NULL, &cookie, &ccount);
	if (result == DDI_DMA_MAPPED) {
		ASSERT(ccount == 1);
	} else {
		return false;
	}
	ASSERT(desc_dma->size >= size);
	desc_dma->dmac_addr = cookie.dmac_laddress;

	return true;
}

static void
emac_free_desc_ring(struct emac_dma *desc_dma)
{
	if (desc_dma->dmac_addr)
		ddi_dma_unbind_handle(desc_dma->dma_handle);
	desc_dma->dmac_addr = 0;

	if (desc_dma->mem_handle)
		ddi_dma_mem_free(&desc_dma->mem_handle);
	desc_dma->mem_handle = 0;

	if (desc_dma->dma_handle)
		ddi_dma_free_handle(&desc_dma->dma_handle);
	desc_dma->dma_handle = 0;
}


static bool
emac_alloc_buffer(struct emac_sc *sc)
{
	int len;

	for (int index = 0; index < RX_DESC_NUM; index++) {
		struct emac_packet *pkt = emac_alloc_packet(sc);
		if (!pkt)
			return false;
		sc->rx_ring.pkt[index] = pkt;
	}
	for (int index = 0; index < TX_DESC_NUM; index++) {
		struct emac_packet *pkt = emac_alloc_packet(sc);
		if (!pkt)
			return false;
		sc->tx_ring.pkt[index] = pkt;
	}
	for (int i = 0; i < RX_DESC_NUM; i++) {
		struct emac_rxdesc *desc = emac_get_rx_desc(sc, i);
		desc->rdesc0.dw = 0;
		desc->rdesc1.dw = 0;
		desc->rdesc2.dw = 0;
		desc->rdesc3.dw = 0;

		desc->rdesc0.rx_desc_ctl = 1;
		desc->rdesc1.buf_size = EMAC_DMA_BUFFER_SIZE;
		desc->rdesc2.buf_addr = emac_get_rx_buffer_phys(sc, i);
		desc->rdesc3.next_desc_addr = emac_get_rx_desc_phys(sc, (i + 1) % RX_DESC_NUM);
	}
	for (int i = 0; i < TX_DESC_NUM; i++) {
		struct emac_txdesc *desc = emac_get_tx_desc(sc, i);
		desc->tdesc0.dw = 0;
		desc->tdesc1.dw = 0;
		desc->tdesc2.dw = 0;
		desc->tdesc3.dw = 0;
		desc->tdesc2.buf_addr = emac_get_tx_buffer_phys(sc, i);
		desc->tdesc3.next_desc_addr = emac_get_tx_desc_phys(sc, (i + 1) % TX_DESC_NUM);
	}

	sc->rx_ring.index = 0;
	sc->tx_ring.head = 0;
	sc->tx_ring.tail = 0;

	return true;
}

static void
emac_free_buffer(struct emac_sc *sc)
{
	for (int i = 0; i < TX_DESC_NUM; i++) {
		struct emac_packet *pkt = sc->tx_ring.pkt[i];
		if (pkt) {
			freemsg(pkt->mp);
			sc->tx_ring.pkt[i] = NULL;
		}
		emac_free_tx(sc, i);
	}

	for (int i = 0; i < RX_DESC_NUM; i++) {
		struct emac_packet *pkt = sc->rx_ring.pkt[i];
		if (pkt) {
			freemsg(pkt->mp);
			sc->rx_ring.pkt[i] = NULL;
		}
	}

	mutex_enter(&sc->rx_pkt_lock);
	for (;;) {
		struct emac_packet *pkt = sc->rx_pkt_free;
		if (pkt == NULL)
			break;
		sc->rx_pkt_free = pkt->next;
		sc->rx_pkt_num--;
		mutex_exit(&sc->rx_pkt_lock);
		freemsg(pkt->mp);
		mutex_enter(&sc->rx_pkt_lock);
	}
	mutex_exit(&sc->rx_pkt_lock);
}

static bool
emac_get_macaddr(struct emac_sc *sc)
{
	pnode_t node = ddi_get_nodeid(sc->dip);
	if (node < 0)
		return (DDI_FAILURE);

	uint8_t mac[6] = {0};
	if (prom_getproplen(node, "mac-address") == 6) {
		prom_getprop(node, "mac-address", (caddr_t)mac);
	} else if (prom_getproplen(node, "local-mac-address") == 6) {
		prom_getprop(node, "local-mac-address", (caddr_t)mac);
	} else if (prom_getproplen(node, "address") == 6) {
		prom_getprop(node, "address", (caddr_t)mac);
	} else {
		return false;
	}
	for (int i = 0; i < 6; i++) {
		sc->dev_addr[i] = mac[i];
	}
	return true;
}

static void
emac_destroy(struct emac_sc *sc)
{
	if (sc->intr_handle) {
		ddi_intr_disable(sc->intr_handle);
		ddi_intr_remove_handler(sc->intr_handle);
		ddi_intr_free(sc->intr_handle);
	}
	sc->intr_handle = 0;

	if (sc->mii_handle)
		mii_free(sc->mii_handle);
	sc->mii_handle = 0;

	if (sc->mac_handle) {
		mac_unregister(sc->mac_handle);
		mac_free(sc->macp);
	}
	sc->mac_handle = 0;

	emac_free_buffer(sc);

	emac_free_desc_ring(&sc->tx_ring.desc);
	emac_free_desc_ring(&sc->rx_ring.desc);

	if (sc->reg.handle)
		ddi_regs_map_free(&sc->reg.handle);
	sc->reg.handle = 0;

	ddi_set_driver_private(sc->dip, NULL);
	struct emac_mcast *mc;
	while ((mc = list_head(&sc->mcast)) != NULL) {
		list_remove(&sc->mcast, mc);
		kmem_free(mc, sizeof (*mc));
	}
	list_destroy(&sc->mcast);
	mutex_destroy(&sc->intrlock);
	mutex_destroy(&sc->rx_pkt_lock);
	kmem_free(sc, sizeof (*sc));
}

static bool
emac_init(struct emac_sc *sc)
{
	emac_gmac_reset(sc);

	if (!emac_get_macaddr(sc))
		return false;

	if (!emac_alloc_desc_ring(sc, &sc->rx_ring.desc, sizeof(struct emac_rxdesc) * RX_DESC_NUM))
		return false;

	if (!emac_alloc_desc_ring(sc, &sc->tx_ring.desc, sizeof(struct emac_txdesc) * TX_DESC_NUM))
		return false;

	return true;
}

static void
emac_mii_write(void *arg, uint8_t phy, uint8_t reg, uint16_t value)
{
	struct emac_sc *sc = arg;

	emac_mutex_enter(sc);

	union emac_mii_cmd mii_cmd = { emac_reg_read(sc, EMAC_MII_CMD) };
	if (mii_cmd.mii_busy == 0) {
		mii_cmd.dw = 0;
		mii_cmd.phy_addr = phy;
		mii_cmd.phy_reg_addr = reg;
		mii_cmd.mdc_div_ratio_m = 3;
		mii_cmd.mii_wr = 1;
		mii_cmd.mii_busy = 1;

		union emac_mii_data mii_data = {0};
		mii_data.mii_data = value;
		emac_reg_write(sc, EMAC_MII_DATA, mii_data.dw);
		emac_reg_write(sc, EMAC_MII_CMD, mii_cmd.dw);

		for (;;) {
			emac_usecwait(100);
			mii_cmd.dw = emac_reg_read(sc, EMAC_MII_CMD);
			if (!mii_cmd.mii_busy)
				break;
		}
	}
	emac_mutex_exit(sc);
}

static uint16_t
emac_mii_read(void *arg, uint8_t phy, uint8_t reg)
{
	struct emac_sc *sc = arg;

	uint16_t data = 0xffff;

	emac_mutex_enter(sc);

	union emac_mii_cmd mii_cmd = { emac_reg_read(sc, EMAC_MII_CMD) };
	if (mii_cmd.mii_busy == 0) {
		mii_cmd.dw = 0;
		mii_cmd.phy_addr = phy;
		mii_cmd.phy_reg_addr = reg;
		mii_cmd.mdc_div_ratio_m = 3;
		mii_cmd.mii_busy = 1;
		emac_reg_write(sc, EMAC_MII_CMD, mii_cmd.dw);

		for (;;) {
			emac_usecwait(100);
			mii_cmd.dw = emac_reg_read(sc, EMAC_MII_CMD);
			if (!mii_cmd.mii_busy)
				break;
		}
		if (mii_cmd.mii_busy == 0) {
			union emac_mii_data mii_data = { emac_reg_read(sc, EMAC_MII_DATA) };
			data = mii_data.mii_data;
		}
	}
	emac_mutex_exit(sc);

	return data;
}

static int
emac_probe(dev_info_t *dip)
{
	int len;
	char buf[80];
	pnode_t node = ddi_get_nodeid(dip);
	if (node < 0)
		return (DDI_PROBE_FAILURE);

	len = prom_getproplen(node, "status");
	if (len <= 0 || len >= sizeof(buf))
		return (DDI_PROBE_FAILURE);

	prom_getprop(node, "status", (caddr_t)buf);
	if (strcmp(buf, "ok") != 0 && (strcmp(buf, "okay") != 0))
		return (DDI_PROBE_FAILURE);

	return (DDI_PROBE_SUCCESS);
}

static void
emac_mii_notify(void *arg, link_state_t link)
{
	struct emac_sc *sc = arg;
	uint32_t gmac;
	uint32_t gpcr;
	link_flowctrl_t fc;
	link_duplex_t duplex;
	int speed;

	fc = mii_get_flowctrl(sc->mii_handle);
	duplex = mii_get_duplex(sc->mii_handle);
	speed = mii_get_speed(sc->mii_handle);

	emac_mutex_enter(sc);

	if (link == LINK_STATE_UP) {
		sc->phy_speed = speed;
		sc->phy_duplex = duplex;
		emac_gmac_update(sc);
	} else {
		sc->phy_speed = -1;
		sc->phy_duplex = LINK_DUPLEX_UNKNOWN;
	}

	emac_mutex_exit(sc);

	mac_link_update(sc->mac_handle, link);
}

static void
emac_mii_reset(void *arg)
{
	struct emac_sc *sc = arg;
	int phy = mii_get_addr(sc->mii_handle);

	emac_mii_write(sc, phy, 0x0d, 0x7);
	emac_mii_write(sc, phy, 0x0e, 0x3c);
	emac_mii_write(sc, phy, 0x0d, 0x4007);
	emac_mii_write(sc, phy, 0x0e, 0);

	uint16_t v = emac_mii_read(sc, phy, 9);
	emac_mii_write(sc, phy, 9, v & ~(1u << 9));
}

static mii_ops_t emac_mii_ops = {
	MII_OPS_VERSION,
	emac_mii_read,
	emac_mii_write,
	emac_mii_notify,
	emac_mii_reset	/* reset */
};

static int
emac_phy_install(struct emac_sc *sc)
{
	sc->mii_handle = mii_alloc(sc, sc->dip, &emac_mii_ops);
	if (sc->mii_handle == NULL) {
		return (DDI_FAILURE);
	}
	//mii_set_pauseable(sc->mii_handle, B_FALSE, B_FALSE);

	return DDI_SUCCESS;
}

static mblk_t *
emac_send(struct emac_sc *sc, mblk_t *mp)
{
	if (((sc->tx_ring.head - sc->tx_ring.tail + TX_DESC_NUM) % TX_DESC_NUM) == (TX_DESC_NUM - 2)) {
		return mp;
	}

	int index = sc->tx_ring.head;
	size_t mblen = 0;
	sc->tx_ring.mp[index] = mp;
	struct emac_packet *pkt = sc->tx_ring.pkt[index];

	caddr_t addr = pkt->dma.addr;
	for (mblk_t *bp = mp; bp != NULL; bp = bp->b_cont) {
		size_t frag_len = MBLKL(bp);
		if (frag_len == 0)
			continue;
		memcpy(addr, bp->b_rptr, frag_len);
		addr += frag_len;
		mblen += frag_len;
	}
	ddi_dma_sync(pkt->dma.dma_handle, 0, mblen, DDI_DMA_SYNC_FORDEV);

	volatile struct emac_txdesc *tx_desc = emac_get_tx_desc(sc, index);
	typeof(tx_desc->tdesc0) tdesc0 = { .tx_desc_ctl = 1 };
	typeof(tx_desc->tdesc1) tdesc1 = {
		.fir_desc = 1, .last_desc = 1, .tx_int_ctl = 1,
		.buf_size = ((mblen < ETHERMIN) ? ETHERMIN: mblen),
	};

	tx_desc->tdesc1.dw = tdesc1.dw;
	asm volatile ("fence":::"memory");
	tx_desc->tdesc0.dw = tdesc0.dw;

	sc->tx_ring.head = (index + 1) % TX_DESC_NUM;

	return (NULL);
}

static mblk_t *
emac_m_tx(void *arg, mblk_t *mp)
{
	struct emac_sc *sc = arg;
	mblk_t *nmp;

	emac_mutex_enter(sc);

	int count = 0;
	while (mp != NULL) {
		nmp = mp->b_next;
		mp->b_next = NULL;
		if ((mp = emac_send(sc, mp)) != NULL) {
			mp->b_next = nmp;
			break;
		}
		mp = nmp;
		count++;
	}

	if (count != 0) {
		union emac_tx_ctl1 tx_ctl1 = { emac_reg_read(sc, EMAC_TX_CTL1) };
		tx_ctl1.tx_dma_start = 1;
		emac_reg_write(sc, EMAC_TX_CTL1, tx_ctl1.dw);
	}

	emac_mutex_exit(sc);

	return (mp);
}


static mblk_t *
emac_rx_intr(struct emac_sc *sc)
{
	int index = sc->rx_ring.index;

	mblk_t *mblk_head = NULL;
	mblk_t **mblk_tail = &mblk_head;

	for (;;) {
		size_t len = 0;
		volatile struct emac_rxdesc *rx_desc = emac_get_rx_desc(sc, index);
		typeof(rx_desc->rdesc0) rdesc0 = { rx_desc->rdesc0.dw };
		asm volatile ("fence":::"memory");
		if (rdesc0.rx_desc_ctl)
			break;

		if (rdesc0.fir_desc &&
		    rdesc0.last_desc &&
		    rdesc0.rx_payload_err == 0 &&
		    rdesc0.rx_crc_err == 0 &&
		    rdesc0.rx_length_err == 0 &&
		    rdesc0.rx_header_err == 0 &&
		    rdesc0.rx_overflow_err == 0) {
			len = rdesc0.rx_frm_len;
		}

		if (len > 0) {
			struct emac_packet *pkt = emac_alloc_packet(sc);
			if (pkt) {
				mblk_t *mp = sc->rx_ring.pkt[index]->mp;
				*mblk_tail = mp;
				mblk_tail = &mp->b_next;
				ddi_dma_sync(sc->rx_ring.pkt[index]->dma.dma_handle, 0, len, DDI_DMA_SYNC_FORKERNEL);
				mp->b_wptr += len;
				sc->rx_ring.pkt[index] = pkt;
				rx_desc->rdesc2.buf_addr = pkt->dma.dmac_addr;
			}
		}

		{
			rdesc0.dw = 0;
			rdesc0.rx_desc_ctl = 1;
			asm volatile ("fence":::"memory");
			rx_desc->rdesc0.dw = rdesc0.dw;
		}
		index = ((index + 1) % RX_DESC_NUM);
	}

	sc->rx_ring.index = index;

	return mblk_head;
}


static int
emac_tx_intr(struct emac_sc *sc)
{
	int index = sc->tx_ring.tail;
	int ret = 0;
	while (index != sc->tx_ring.head) {
		volatile struct emac_txdesc *tx_desc = emac_get_tx_desc(sc, index);
		typeof(tx_desc->tdesc0) tdesc0 = { tx_desc->tdesc0.dw };
		asm volatile ("fence":::"memory");
		if (tdesc0.tx_desc_ctl)
			break;
		emac_free_tx(sc, index);
		index = (index + 1) % TX_DESC_NUM;
		ret++;
	}
	sc->tx_ring.tail = index;
	return ret;
}

static uint_t
emac_intr(caddr_t arg, caddr_t unused)
{
	struct emac_sc *sc = (struct emac_sc *)arg;

	emac_mutex_enter(sc);

	for (;;) {
		union emac_int_sta int_sta = { emac_reg_read(sc, EMAC_INT_STA) };
		emac_reg_write(sc, EMAC_INT_STA, int_sta.dw);

		if (int_sta.rx == 0 &&
		    int_sta.rx_buf_ua == 0 &&
		    int_sta.rx_dma_stopped == 0 &&
		    int_sta.rx_timeout == 0 &&
		    int_sta.rx_overflow == 0 &&
		    int_sta.tx == 0 &&
		    int_sta.tx_dma_stopped == 0 &&
		    int_sta.tx_buf_ua == 0 &&
		    int_sta.tx_timeout == 0 &&
		    int_sta.tx_underflow == 0) {
			break;
		}

		if (sc->running == 0)
			break;

		if (int_sta.rx ||
		    int_sta.rx_buf_ua ||
		    int_sta.rx_dma_stopped ||
		    int_sta.rx_timeout ||
		    int_sta.rx_overflow) {
			mblk_t *mp = emac_rx_intr(sc);
			if (mp) {
				emac_mutex_exit(sc);
				mac_rx(sc->mac_handle, NULL, mp);
				emac_mutex_enter(sc);
			}
		}

		if (sc->running == 0)
			break;

		if (int_sta.tx ||
		    int_sta.tx_dma_stopped ||
		    int_sta.tx_buf_ua ||
		    int_sta.tx_timeout ||
		    int_sta.tx_underflow) {
			int tx = 0;

			tx = emac_tx_intr(sc);

			if (tx) {
				emac_mutex_exit(sc);
				mac_tx_update(sc->mac_handle);
				emac_mutex_enter(sc);
			}
		}
	}

	emac_mutex_exit(sc);

	return (DDI_INTR_CLAIMED);
}


static int emac_attach(dev_info_t *dip, ddi_attach_cmd_t cmd);
static int
emac_detach(dev_info_t *dip, ddi_detach_cmd_t cmd)
{
	switch (cmd) {
	case DDI_DETACH:
		break;
	default:
		return (DDI_FAILURE);
	}
	struct emac_sc *sc = ddi_get_driver_private(dip);

	emac_m_stop(sc);

	if (mac_disable(sc->mac_handle) != 0)
		return (DDI_FAILURE);

	emac_destroy(sc);

	return DDI_SUCCESS;
}

static int
emac_quiesce(dev_info_t *dip)
{
	cmn_err(CE_WARN, "%s%d: emac_quiesce is not implemented",
	    ddi_driver_name(dip), ddi_get_instance(dip));
	return DDI_FAILURE;
}

static uint32_t
bitreverse(uint32_t x)
{
	x = (((x & 0xaaaaaaaa) >> 1) | ((x & 0x55555555) << 1));
	x = (((x & 0xcccccccc) >> 2) | ((x & 0x33333333) << 2));
	x = (((x & 0xf0f0f0f0) >> 4) | ((x & 0x0f0f0f0f) << 4));
	x = (((x & 0xff00ff00) >> 8) | ((x & 0x00ff00ff) << 8));

	return (x >> 16) | (x << 16);
}

static void
emac_update_filter(struct emac_sc *sc)
{
	uint32_t hash[2] = {0};

	for (struct emac_mcast *mc = list_head(&sc->mcast); mc; mc = list_next(&sc->mcast, mc)) {
		uint32_t crc;
		CRC32(crc, mc->addr, sizeof(mc->addr), -1U, crc32_table);
		uint32_t val = (bitreverse(~crc) >> 26);
		hash[(val >> 5)] |= (1 << (val & 31));
	}

	emac_reg_write(sc, EMAC_RX_HASH0, hash[1]);
	emac_reg_write(sc, EMAC_RX_HASH1, hash[0]);
}

static int
emac_m_setpromisc(void *a, boolean_t b)
{
	struct emac_sc *sc = a;
	emac_mutex_enter(sc);

	union emac_rx_frm_flt rx_frm_flt = { emac_reg_read(sc, EMAC_RX_FRM_FLT) };

	if (b) {
		rx_frm_flt.dis_addr_filter = 1;
	} else {
		rx_frm_flt.dis_addr_filter = 0;
	}

	emac_reg_write(sc, EMAC_RX_FRM_FLT, rx_frm_flt.dw);
	emac_update_filter(sc);

	emac_mutex_exit(sc);

	return 0;
}

static int
emac_m_multicst(void *a, boolean_t b, const uint8_t *c)
{
	struct emac_sc *sc = a;
	struct emac_mcast *mc;

	emac_mutex_enter(sc);

	if (b) {
		mc = kmem_alloc(sizeof (*mc), KM_NOSLEEP);
		if (!mc) {
			emac_mutex_exit(sc);
			return ENOMEM;
		}

		memcpy(mc->addr, c, sizeof(mc->addr));
		list_insert_head(&sc->mcast, mc);
	} else {
		for (mc = list_head(&sc->mcast); mc; mc = list_next(&sc->mcast, mc)) {
			if (memcmp(mc->addr, c, sizeof(mc->addr)) == 0) {
				list_remove(&sc->mcast, mc);
				kmem_free(mc, sizeof (*mc));
				break;
			}
		}
	}

	union emac_rx_frm_flt rx_frm_flt = { emac_reg_read(sc, EMAC_RX_FRM_FLT) };
	rx_frm_flt.rx_all_multicast = 0;
	rx_frm_flt.hash_multicast = 1;
	emac_reg_write(sc, EMAC_RX_FRM_FLT, rx_frm_flt.dw);

	emac_update_filter(sc);

	emac_mutex_exit(sc);
	return 0;
}

static int
emac_m_unicst(void *arg, const uint8_t *dev_addr)
{
	struct emac_sc *sc = arg;

	emac_mutex_enter(sc);

	memcpy(sc->dev_addr, dev_addr, sizeof(sc->dev_addr));

	emac_gmac_disable(sc);

	union emac_addr_low0 addr_low0 = {0};
	union emac_addr_high0 addr_high0 = {0};
	addr_low0.mac_addr_low0 = (sc->dev_addr[3] << 24) | (sc->dev_addr[2] << 16) | (sc->dev_addr[1] << 8) | sc->dev_addr[0];
	addr_high0.mac_addr_high0 = (sc->dev_addr[5] << 8) | sc->dev_addr[4];
	emac_reg_write(sc, EMAC_ADDR_LOW0, addr_low0.dw);
	emac_reg_write(sc, EMAC_ADDR_HIGH0, addr_high0.dw);

	emac_gmac_enable(sc);

	emac_mutex_exit(sc);

	return 0;
}

static int
emac_m_start(void *arg)
{
	struct emac_sc *sc = arg;

	emac_mutex_enter(sc);

	if (!emac_alloc_buffer(sc)) {
		emac_mutex_exit(sc);
		return ENOMEM;
	}
	emac_gmac_init(sc);
	emac_gmac_enable(sc);

	sc->running = 1;

	if (ddi_intr_enable(sc->intr_handle) != DDI_SUCCESS) {
		sc->running = 0;
		emac_gmac_disable(sc);
		emac_free_buffer(sc);
		emac_mutex_exit(sc);
		return EIO;
	}

	emac_mutex_exit(sc);

	mii_start(sc->mii_handle);

	return 0;
}

static void
emac_m_stop(void *arg)
{
	struct emac_sc *sc = arg;

	mii_stop(sc->mii_handle);

	emac_mutex_enter(sc);

	ddi_intr_disable(sc->intr_handle);

	sc->running = 0;
	emac_gmac_disable(sc);
	emac_free_buffer(sc);

	emac_mutex_exit(sc);
}

static int
emac_m_getstat(void *arg, uint_t stat, uint64_t *val)
{
	struct emac_sc *sc = arg;
	return mii_m_getstat(sc->mii_handle, stat, val);
}

static int
emac_m_setprop(void *arg, const char *name, mac_prop_id_t num, uint_t sz, const void *val)
{
	struct emac_sc *sc = arg;
	return mii_m_setprop(sc->mii_handle, name, num, sz, val);
}

static int
emac_m_getprop(void *arg, const char *name, mac_prop_id_t num, uint_t sz, void *val)
{
	struct emac_sc *sc = arg;
	return mii_m_getprop(sc->mii_handle, name, num, sz, val);
}

static void
emac_m_propinfo(void *arg, const char *name, mac_prop_id_t num, mac_prop_info_handle_t prh)
{
	struct emac_sc *sc = arg;
	mii_m_propinfo(sc->mii_handle, name, num, prh);
}

static void
emac_m_ioctl(void *arg, queue_t *wq, mblk_t *mp)
{
	struct emac_sc *sc = arg;
	if (mii_m_loop_ioctl(sc->mii_handle, wq, mp))
		return;

	miocnak(wq, mp, 0, EINVAL);
}

extern struct mod_ops mod_driverops;

DDI_DEFINE_STREAM_OPS(emac_devops, nulldev, emac_probe, emac_attach,
    emac_detach, nodev, NULL, D_MP, NULL, emac_quiesce);

static struct modldrv emac_modldrv = {
	&mod_driverops,		/* Type of module.  This one is a driver */
	"gem",			/* short description */
	&emac_devops		/* driver specific ops */
};

static struct modlinkage emac_modlinkage = {
	MODREV_1,		/* ml_rev */
	{ &emac_modldrv, NULL }	/* ml_linkage */
};

static mac_callbacks_t emac_m_callbacks = {
	MC_SETPROP | MC_GETPROP | MC_PROPINFO,	/* mc_callbacks */
	emac_m_getstat,	/* mc_getstat */
	emac_m_start,		/* mc_start */
	emac_m_stop,		/* mc_stop */
	emac_m_setpromisc,	/* mc_setpromisc */
	emac_m_multicst,	/* mc_multicst */
	emac_m_unicst,		/* mc_unicst */
	emac_m_tx,		/* mc_tx */
	NULL,
	emac_m_ioctl,		/* mc_ioctl */
	NULL,			/* mc_getcapab */
	NULL,			/* mc_open */
	NULL,			/* mc_close */
	emac_m_setprop,
	emac_m_getprop,
	emac_m_propinfo
};

static int
emac_attach(dev_info_t *dip, ddi_attach_cmd_t cmd)
{
	switch (cmd) {
	case DDI_ATTACH:
		break;
	default:
		return (DDI_FAILURE);
	}

	struct emac_sc *sc = kmem_zalloc(sizeof(struct emac_sc), KM_SLEEP);
	ddi_set_driver_private(dip, sc);
	sc->dip = dip;

	mutex_init(&sc->intrlock, NULL, MUTEX_DRIVER, NULL);
	mutex_init(&sc->rx_pkt_lock, NULL, MUTEX_DRIVER, NULL);
	list_create(&sc->mcast, sizeof (struct emac_mcast), offsetof(struct emac_mcast, node));

	if (ddi_regs_map_setup(sc->dip, 0, (caddr_t*)&sc->reg.addr, 0, 0, &reg_acc_attr, &sc->reg.handle) != DDI_SUCCESS) {
		goto err_exit;
	}

	emac_mutex_enter(sc);
	if (!emac_init(sc)) {
		emac_mutex_exit(sc);
		goto err_exit;
	}
	emac_mutex_exit(sc);

	mac_register_t *macp;
	if ((macp = mac_alloc(MAC_VERSION)) == NULL) {
		goto err_exit;
	}
	sc->macp = macp;

	macp->m_type_ident = MAC_PLUGIN_IDENT_ETHER;
	macp->m_driver = sc;
	macp->m_dip = dip;
	macp->m_src_addr = sc->dev_addr;
	macp->m_callbacks = &emac_m_callbacks;
	macp->m_min_sdu = 0;
	macp->m_max_sdu = ETHERMTU;
	macp->m_margin = VLAN_TAGSZ;

	if (mac_register(macp, &sc->mac_handle) != 0) {
		mac_free(sc->macp);
		sc->mac_handle = 0;
		goto err_exit;
	}

	if (emac_phy_install(sc) != DDI_SUCCESS) {
		goto err_exit;
	}

	int actual;
	if (ddi_intr_alloc(dip, &sc->intr_handle, DDI_INTR_TYPE_FIXED, 0, 1, &actual, DDI_INTR_ALLOC_STRICT) != DDI_SUCCESS) {
		goto err_exit;
	}

	if (ddi_intr_add_handler(sc->intr_handle, emac_intr, sc, NULL) != DDI_SUCCESS) {
		ddi_intr_free(sc->intr_handle);
		sc->intr_handle = 0;
		goto err_exit;
	}

	return DDI_SUCCESS;
err_exit:
	emac_destroy(sc);
	return (DDI_FAILURE);
}

int
_init(void)
{
	int i;

	mac_init_ops(&emac_devops, "platmac");

	if ((i = mod_install(&emac_modlinkage)) != 0) {
		mac_fini_ops(&emac_devops);
	}
	return (i);
}

int
_fini(void)
{
	int i;

	if ((i = mod_remove(&emac_modlinkage)) == 0) {
		mac_fini_ops(&emac_devops);
	}
	return (i);
}

int
_info(struct modinfo *modinfop)
{
	return (mod_info(&emac_modlinkage, modinfop));
}
