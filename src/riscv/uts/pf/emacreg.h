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
 * Copyright 2022 Hayashi Naoyuki
 *
 * Portions Copyright 2022 Hayashi Naoyuki; adapted for solnix from
 * n-hys/illumos-gate (usr/src/uts/riscv64pf/sun20i/sys/emacreg.h).
 * TEMPLATE: Allwinner EMAC register map — REPLACE with the K1 dwmac register
 * map (see pf/emac.c). NOT the K1 silicon layout.
 */

#pragma once

#include <sys/types.h>
#include <sys/platform.h>

#define EMAC_BASIC_CTL0		0x0000
#define EMAC_BASIC_CTL1		0x0004
#define EMAC_INT_STA		0x0008
#define EMAC_INT_EN		0x000C
#define EMAC_TX_CTL0		0x0010
#define EMAC_TX_CTL1		0x0014
#define EMAC_TX_FLOW_CTL	0x001C
#define EMAC_TX_DMA_DESC_LIST	0x0020
#define EMAC_RX_CTL0		0x0024
#define EMAC_RX_CTL1		0x0028
#define EMAC_RX_DMA_DESC_LIST	0x0034
#define EMAC_RX_FRM_FLT		0x0038
#define EMAC_RX_HASH0		0x0040
#define EMAC_RX_HASH1		0x0044
#define EMAC_MII_CMD		0x0048
#define EMAC_MII_DATA		0x004C
#define EMAC_ADDR_HIGH0		0x0050
#define EMAC_ADDR_LOW0		0x0054
#define EMAC_ADDR_HIGH(N)	(0x0050 + 0x08 * (N))
#define EMAC_ADDR_LOWN(N)	(0x0054 + 0x08 * (N))
#define EMAC_TX_DMA_STA		0x00B0
#define EMAC_TX_CUR_DESC	0x00B4
#define EMAC_TX_CUR_BUF		0x00B8
#define EMAC_RX_DMA_STA		0x00C0
#define EMAC_RX_CUR_DESC	0x00C4
#define EMAC_RX_CUR_BUF		0x00C8
#define EMAC_RGMII_STA		0x00D0


union emac_basic_ctl0 {
	uint32_t dw;
	struct {
		uint32_t duplex		:  1;
		uint32_t loopback	:  1;
		uint32_t speed		:  2;
		/*
		 * 0: 1000Mbps
		 * 3: 100Mbps
		 * 2: 10Mbps
		 */
		uint32_t		: 28;
	};
};

union emac_basic_ctl1 {
	uint32_t dw;
	struct {
		uint32_t soft_rst	:  1;
		uint32_t rx_tx_pri	:  1;
		uint32_t		: 20;
		uint32_t burst_len	:  6;
		uint32_t		:  2;
	};
};

union emac_int_sta {
	uint32_t dw;
	struct {
		uint32_t tx			:  1;
		uint32_t tx_dma_stopped		:  1;
		uint32_t tx_buf_ua		:  1;
		uint32_t tx_timeout		:  1;
		uint32_t tx_underflow		:  1;
		uint32_t tx_early		:  1;
		uint32_t			:  2;
		uint32_t rx			:  1;
		uint32_t rx_buf_ua		:  1;
		uint32_t rx_dma_stopped		:  1;
		uint32_t rx_timeout		:  1;
		uint32_t rx_overflow		:  1;
		uint32_t rx_early		:  1;
		uint32_t			:  2;
		uint32_t rgmii_link_sta		:  1;
		uint32_t			: 15;
	};
};

union emac_int_en {
	uint32_t dw;
	struct {
		uint32_t tx			:  1;
		uint32_t tx_dma_stopped		:  1;
		uint32_t tx_buf_ua		:  1;
		uint32_t tx_timeout		:  1;
		uint32_t tx_underflow		:  1;
		uint32_t tx_early		:  1;
		uint32_t			:  2;
		uint32_t rx			:  1;
		uint32_t rx_buf_ua		:  1;
		uint32_t rx_dma_stopped		:  1;
		uint32_t rx_timeout		:  1;
		uint32_t rx_overflow		:  1;
		uint32_t rx_early		:  1;
		uint32_t			: 18;
	};
};

union emac_tx_ctl0 {
	uint32_t dw;
	struct {
		uint32_t		: 30;
		uint32_t tx_frm_len_ctl	:  1;
		uint32_t tx_en		:  1;
	};
};

union emac_tx_ctl1 {
	uint32_t dw;
	struct {
		uint32_t flush_tx_fifo	:  1;
		uint32_t tx_md		:  1;
		uint32_t		:  6;
		uint32_t tx_th		:  3;
		uint32_t		: 19;
		uint32_t tx_dma_en	:  1;
		uint32_t tx_dma_start	:  1;
	};
};

union emac_tx_flow_ctl {
	uint32_t dw;
	struct {
		uint32_t tx_flow_ctl_en		:  1;
		uint32_t zqp_frm_en		:  1;
		uint32_t			:  2;
		uint32_t pause_time		: 16;
		uint32_t tx_pause_frm_slot	:  2;
		uint32_t			:  9;
		uint32_t tx_flow_ctl_sta	:  1;
	};
};

union emac_tx_dma_desc_list {
	uint32_t dw;
	struct {
		uint32_t tx_desc_list		: 32;
	};
};

union emac_rx_ctl0 {
	uint32_t dw;
	struct {
		uint32_t			: 16;
		uint32_t rx_flow_ctl_en		:  1;
		uint32_t rx_pause_frm_md	:  1;
		uint32_t			:  9;
		uint32_t check_crc		:  1;
		uint32_t strip_fcs		:  1;
		uint32_t jumbo_frm_en		:  1;
		uint32_t rx_frm_len_ctl		:  1;
		uint32_t rx_en			:  1;
	};
};

union emac_rx_ctl1 {
	uint32_t dw;
	struct {
		uint32_t flush_rx_frm		:  1;
		uint32_t rx_md			:  1;
		uint32_t rx_runt_frm		:  1;
		uint32_t rx_err_frm		:  1;
		uint32_t rx_th			:  2;
		uint32_t			: 14;
		uint32_t rx_flow_ctl_th_act	:  2;
		uint32_t rx_flow_ctl_th_deact	:  2;
		uint32_t rx_fifo_flow_ctl	:  1;
		uint32_t			:  5;
		uint32_t rx_dma_en		:  1;
		uint32_t rx_dma_start		:  1;
	};
};

union emac_rx_dma_desc_list {
	uint32_t dw;
	struct {
		uint32_t rx_desc_list		: 32;
	};
};

union emac_rx_frm_flt {
	uint32_t dw;
	struct {
		uint32_t rx_all			:  1;
		uint32_t flt_md			:  1;
		uint32_t			:  2;
		uint32_t da_inv_filter		:  1;
		uint32_t sa_inv_filter		:  1;
		uint32_t sa_filter_en		:  1;
		uint32_t			:  1;
		uint32_t hash_unicast		:  1;
		uint32_t hash_multicast		:  1;
		uint32_t			:  2;
		uint32_t ctl_frm_filter		:  2;
		uint32_t			:  2;
		uint32_t rx_all_multicast	:  1;
		uint32_t dis_broadcast		:  1;
		uint32_t			: 13;
		uint32_t dis_addr_filter	:  1;
	};
};

union emac_rx_hash0 {
	uint32_t dw;
	struct {
		uint32_t hash_tab0		: 32;
	};
};

union emac_rx_hash1 {
	uint32_t dw;
	struct {
		uint32_t hash_tab1		: 32;
	};
};

union emac_mii_cmd {
	uint32_t dw;
	struct {
		uint32_t mii_busy		:  1;
		uint32_t mii_wr			:  1;
		uint32_t			:  2;
		uint32_t phy_reg_addr		:  5;
		uint32_t			:  3;
		uint32_t phy_addr		:  5;
		uint32_t			:  3;
		uint32_t mdc_div_ratio_m	:  3;
		uint32_t			:  9;
	};
};

union emac_mii_data {
	uint32_t dw;
	struct {
		uint32_t mii_data		: 16;
		uint32_t			: 16;
	};
};

union emac_addr_high0 {
	uint32_t dw;
	struct {
		uint32_t mac_addr_high0	: 16;
		uint32_t		: 16;
	};
};

union emac_addr_low0 {
	uint32_t dw;
	struct {
		uint32_t mac_addr_low0	: 32;
	};
};

union emac_addr_high {
	uint32_t dw;
	struct {
		uint32_t mac_addr_high		: 16;
		uint32_t			:  8;
		uint32_t mac_addr_byte_ctl	:  6;
		uint32_t mac_addr_type		:  1;
		uint32_t mac_addr_ctl		:  1;
	};
};

union emac_addr_low {
	uint32_t dw;
	struct {
		uint32_t mac_addr_low	: 32;
	};
};

union emac_tx_dma_sta {
	uint32_t dw;
	struct {
		uint32_t tx_dma_sta	:  3;
		uint32_t		: 29;
	};
};

union emac_tx_cur_desc {
	uint32_t dw;
	struct {
		uint32_t tx_dma_cur_desc	: 32;
	};
};

union emac_tx_cur_buf {
	uint32_t dw;
	struct {
		uint32_t tx_dma_cur_buf	: 32;
	};
};

union emac_rx_dma_sta {
	uint32_t dw;
	struct {
		uint32_t rx_dma_sta	:  3;
		uint32_t		: 29;
	};
};

union emac_rx_cur_desc {
	uint32_t dw;
	struct {
		uint32_t rx_dma_cur_desc	: 32;
	};
};

union emac_rx_cur_buf {
	uint32_t dw;
	struct {
		uint32_t rx_dma_cur_buf	: 32;
	};
};

union emac_rgmii_sta {
	uint32_t dw;
	struct {
		uint32_t rgmii_link_md	:  1;
		uint32_t rgmii_link_spd	:  2;
		uint32_t rgmii_link	:  1;
		uint32_t		: 28;
	};
};

struct emac_txdesc {
	union {
		uint32_t dw;
		struct {
			uint32_t tx_defer		:  1;
			uint32_t tx_underflow_err	:  1;
			uint32_t tx_defer_err		:  1;
			uint32_t tx_col_cnt		:  4;
			uint32_t			:  1;
			uint32_t tx_col_err_0		:  1;
			uint32_t tx_col_err_1		:  1;
			uint32_t tx_crs_err		:  1;
			uint32_t			:  1;
			uint32_t tx_payload_err		:  1;
			uint32_t			:  1;
			uint32_t tx_lenght_err		:  1;
			uint32_t			:  1;
			uint32_t tx_header_err		:  1;
			uint32_t			: 14;
			uint32_t tx_desc_ctl		:  1;
		};
	} tdesc0;
	union {
		uint32_t dw;
		struct {
			uint32_t buf_size		: 11;
			uint32_t			: 15;
			uint32_t crc_ctl		:  1;
			uint32_t checksum_ctl		:  2;
			uint32_t fir_desc		:  1;
			uint32_t last_desc		:  1;
			uint32_t tx_int_ctl		:  1;
		};
	} tdesc1;
	union {
		uint32_t dw;
		struct {
			uint32_t buf_addr		: 32;
		};
	} tdesc2;
	union {
		uint32_t dw;
		struct {
			uint32_t next_desc_addr		: 32;
		};
	} tdesc3;
} __attribute__ ((aligned(DCACHE_LINE)));

struct emac_rxdesc {
	union {
		uint32_t dw;
		struct {
			uint32_t rx_payload_err		:  1;
			uint32_t rx_crc_err		:  1;
			uint32_t			:  1;
			uint32_t rx_phy_err		:  1;
			uint32_t rx_length_err		:  1;
			uint32_t			:  1;
			uint32_t rx_col_err		:  1;
			uint32_t rx_header_err		:  1;
			uint32_t last_desc		:  1;
			uint32_t fir_desc		:  1;
			uint32_t			:  1;
			uint32_t rx_overflow_err	:  1;
			uint32_t			:  1;
			uint32_t rx_saf_fail		:  1;
			uint32_t rx_no_enough_buf_err	:  1;
			uint32_t			:  1;
			uint32_t rx_frm_len		: 14;
			uint32_t rx_daf_fail		:  1;
			uint32_t rx_desc_ctl		:  1;
		};
	} rdesc0;
	union {
		uint32_t dw;
		struct {
			uint32_t buf_size		: 11;
			uint32_t			: 20;
			uint32_t rx_int_ctl		:  1;
		};
	} rdesc1;
	union {
		uint32_t dw;
		struct {
			uint32_t buf_addr		: 32;
		};
	} rdesc2;
	union {
		uint32_t dw;
		struct {
			uint32_t next_desc_addr		: 32;
		};
	} rdesc3;
} __attribute__ ((aligned(DCACHE_LINE)));
