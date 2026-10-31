/*
 * dwiic -- Synopsys DesignWare I2C master on the Intel LPSS (PCI), as an
 * i2c controller provider for the illumos i2c framework (i2cnex).
 *
 * The controller sequence (LPSS un-reset, timing, FIFO, enable/disable and
 * the TX/RX command loop) follows OpenBSD sys/dev/ic/dwiic.c and
 * sys/dev/pci/dwiic_pci.c (rev 37a498de), which carry this notice:
 *
 * Copyright (c) 2015-2017 joshua stein <jcs@openbsd.org>
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 * Polled only: the controller's INTx is not used yet.
 */

#include <sys/types.h>
#include <sys/conf.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/modctl.h>
#include <sys/kmem.h>
#include <sys/pci.h>
#include <sys/cmn_err.h>
#include <sys/sysmacros.h>
#include <sys/i2c/controller.h>
#include "dwiic.h"

/* DesignWare registers (OpenBSD dwiicreg.h) */
#define	DW_CON		0x00
#define	DW_TAR		0x04
#define	DW_DATA_CMD	0x10
#define	DW_INTR_MASK	0x30
#define	DW_RAW_INTR	0x34
#define	DW_RX_TL	0x38
#define	DW_TX_TL	0x3c
#define	DW_CLR_INTR	0x40
#define	DW_CLR_TX_ABRT	0x54
#define	DW_ENABLE	0x6c
#define	DW_STATUS	0x70
#define	DW_TXFLR	0x74
#define	DW_RXFLR	0x78
#define	DW_ABRT_SRC	0x80
#define	DW_EN_STATUS	0x9c
#define	DW_PARAM_1	0xf4
#define	DW_COMP_TYPE	0xfc
#define	DW_COMP_TYPE_VALUE	0x44570140
#define	DW_CMD_READ	0x100
#define	DW_CMD_STOP	0x200
#define	DW_CMD_RESTART	0x400
#define	DW_INTR_TX_ABRT	0x040
#define	DW_INTR_STOP	0x200
/* master, fast speed, restart enabled, slave disabled */
#define	DW_CON_MASTER_FAST	0x65
/* LPSS private registers (OpenBSD lpssreg.h) */
#define	LPSS_RESETS	0x204
#define	LPSS_RESETS_DONE	0x7	/* FUNC | IDMA out of reset */
#define	LPSS_CAPS	0x2fc

#define	DWIIC_REGNO	1	/* reg[0] is config space, reg[1] is BAR0 */
#define	DWIIC_FIFO_MAX	64

typedef struct dwiic {
	dev_info_t		*dw_dip;
	ddi_acc_handle_t	dw_cfg;
	ddi_acc_handle_t	dw_regs;
	caddr_t			dw_base;
	i2c_ctrl_hdl_t		*dw_hdl;
	kmutex_t		dw_mutex;	/* one transfer at a time */
	kmutex_t		dw_napmu;	/* dw_nap()'s sleep, under dw_mutex */
	kcondvar_t		dw_napcv;	/* never signalled: a timed sleep */
	uint32_t		dw_txfifo;
	uint32_t		dw_rxfifo;
	uint32_t		dw_ss_hcnt, dw_ss_lcnt, dw_fs_hcnt, dw_fs_lcnt;
	uint32_t		dw_sda_hold;
	uint32_t		dw_init;
} dwiic_t;

#define	DWIIC_INIT_CFG	0x1
#define	DWIIC_INIT_REGS	0x2
#define	DWIIC_INIT_SYNC	0x4
#define	DWIIC_INIT_I2C	0x8

static void *dwiic_state;

static uint32_t
dw_rd(dwiic_t *dw, uint32_t off)
{
	return (ddi_get32(dw->dw_regs, (uint32_t *)(dw->dw_base + off)));
}

static void
dw_wr(dwiic_t *dw, uint32_t off, uint32_t val)
{
	ddi_put32(dw->dw_regs, (uint32_t *)(dw->dw_base + off), val);
}

/* OpenBSD dwiic_enable(): write IC_ENABLE until IC_ENABLE_STATUS follows */
static bool
dw_enable(dwiic_t *dw, uint32_t en)
{
	for (int i = 0; i < 100; i++) {
		dw_wr(dw, DW_ENABLE, en);
		if ((dw_rd(dw, DW_EN_STATUS) & 1) == en)
			return (true);
		drv_usecwait(25);
	}
	dev_err(dw->dw_dip, CE_WARN, "failed to %sable controller",
	    en ? "en" : "dis");
	return (false);
}

static i2c_ctrl_error_t
dw_abort_error(uint32_t src)
{
	if (src & (1 << 0))		/* ABRT_7B_ADDR_NOACK */
		return (I2C_CTRL_E_ADDR_NACK);
	if (src & (1 << 3))		/* ABRT_TXDATA_NOACK */
		return (I2C_CTRL_E_DATA_NACK);
	if (src & (1 << 12))		/* ARB_LOST */
		return (I2C_CTRL_E_ARB_LOST);
	return (I2C_CTRL_E_DRIVER);
}

/*
 * Sleep about DWIIC_NAP_US between FIFO polls instead of spinning, once
 * every command of the transfer is queued (a touchpad report read, 16 bytes,
 * always is), so the 10 ms touchpad poll stops costing ~0.4 ms of CPU each.
 * While commands are still being fed (a read longer than the FIFOs, e.g. the
 * 385-byte report descriptor) keep spinning: a core built without
 * IC_EMPTYFIFO_HOLD_MASTER_EN sends STOP when its TX FIFO runs dry, and a
 * long sleep there would cut the transfer. dw_mutex stays held throughout.
 */
#define	DWIIC_NAP_US	100

static void
dw_nap(dwiic_t *dw)
{
	mutex_enter(&dw->dw_napmu);
	(void) cv_timedwait_hires(&dw->dw_napcv, &dw->dw_napmu,
	    USEC2NSEC(DWIIC_NAP_US), USEC2NSEC(10), 0);
	mutex_exit(&dw->dw_napmu);
}

/*
 * One polled transfer: write wlen bytes, then (with a RESTART if wlen > 0)
 * read rlen bytes, STOP. The TX FIFO is refilled as it drains, and no more
 * read commands are queued than the RX FIFO can hold, so any length works.
 */
static i2c_ctrl_error_t
dw_xfer(dwiic_t *dw, uint16_t addr, const uint8_t *w, uint32_t wlen,
    uint8_t *r, uint32_t rlen)
{
	uint32_t ws = 0, rs = 0, got = 0, raw;
	i2c_ctrl_error_t ret = I2C_CTRL_E_OK;
	hrtime_t end;
	int i;

	ASSERT(MUTEX_HELD(&dw->dw_mutex));
	if (wlen == 0 && rlen == 0)
		return (I2C_CTRL_E_UNSUP_CMD);
	for (i = 0; i < 100 && (dw_rd(dw, DW_STATUS) & 1) != 0; i++)
		drv_usecwait(1000);
	if ((dw_rd(dw, DW_STATUS) & 1) != 0)
		return (I2C_CTRL_E_BUS_BUSY);
	if (!dw_enable(dw, 0))
		return (I2C_CTRL_E_DRIVER);
	dw_wr(dw, DW_CON, DW_CON_MASTER_FAST);
	dw_wr(dw, DW_TAR, addr);
	dw_wr(dw, DW_INTR_MASK, 0);
	(void) dw_rd(dw, DW_CLR_INTR);
	if (!dw_enable(dw, 1))
		return (I2C_CTRL_E_DRIVER);

	/* 100 ms plus 100 us a byte; a byte is 22.5 us at 400 kHz */
	end = gethrtime() + MSEC2NSEC(100) + USEC2NSEC(100) * (wlen + rlen);
	for (;;) {
		raw = dw_rd(dw, DW_RAW_INTR);
		if ((raw & DW_INTR_TX_ABRT) != 0) {
			ret = dw_abort_error(dw_rd(dw, DW_ABRT_SRC));
			(void) dw_rd(dw, DW_CLR_TX_ABRT);
			break;
		}
		while ((ws < wlen || rs < rlen) &&
		    dw_rd(dw, DW_TXFLR) < dw->dw_txfifo) {
			uint32_t cmd;
			if (ws < wlen) {
				cmd = w[ws++];
				if (ws == wlen && rlen == 0)
					cmd |= DW_CMD_STOP;
			} else {
				if (rs - got >= dw->dw_rxfifo)
					break;
				cmd = DW_CMD_READ;
				if (rs == 0 && wlen > 0)
					cmd |= DW_CMD_RESTART;
				if (++rs == rlen)
					cmd |= DW_CMD_STOP;
			}
			dw_wr(dw, DW_DATA_CMD, cmd);
		}
		while (got < rlen && dw_rd(dw, DW_RXFLR) > 0)
			r[got++] = dw_rd(dw, DW_DATA_CMD) & 0xff;
		if (ws == wlen && got == rlen && (raw & DW_INTR_STOP) != 0)
			break;
		if (gethrtime() > end) {
			ret = I2C_CTRL_E_REQ_TO;
			break;
		}
		if (ws == wlen && rs == rlen)
			dw_nap(dw);
		else
			drv_usecwait(10);
	}
	(void) dw_enable(dw, 0);
	return (ret);
}

static void
dwiic_io_i2c(void *arg, uint32_t port, i2c_req_t *req)
{
	dwiic_t *dw = arg;
	i2c_ctrl_error_t e;

	if (req->ir_addr.ia_type != I2C_ADDR_7BIT) {
		i2c_ctrl_io_error(&req->ir_error, I2C_CORE_E_UNSUP_ADDR_TYPE,
		    0);
		return;
	}
	mutex_enter(&dw->dw_mutex);
	e = dw_xfer(dw, req->ir_addr.ia_addr, req->ir_wdata, req->ir_wlen,
	    req->ir_rdata, req->ir_rlen);
	mutex_exit(&dw->dw_mutex);
	if (e == I2C_CTRL_E_OK)
		i2c_ctrl_io_success(&req->ir_error);
	else
		i2c_ctrl_io_error(&req->ir_error, I2C_CORE_E_CONTROLLER, e);
}

/*
 * Private entry for ihid: a transfer of any length to a 7-bit address on the
 * dwiic instance dip. The caller holds the i2c framework's bus lock
 * (i2c_bus_lock) for the address it claimed. Returns an i2c_ctrl_error_t.
 * shortcut: exists because i2cnex's client API has no plain read and caps a
 * request at I2C_REQ_MAX (256) while the touchpad's report descriptor is 385
 * bytes; drop it when i2cnex grows a raw-transfer client call.
 */
int
dwiic_xfer(dev_info_t *dip, uint16_t addr, const uint8_t *w, uint32_t wlen,
    uint8_t *r, uint32_t rlen)
{
	dwiic_t *dw;
	i2c_ctrl_error_t e;

	if (dip == NULL || strcmp(ddi_driver_name(dip), "dwiic") != 0 ||
	    (dw = ddi_get_soft_state(dwiic_state, ddi_get_instance(dip))) ==
	    NULL || addr > 0x7f)
		return (I2C_CTRL_E_DRIVER);
	mutex_enter(&dw->dw_mutex);
	e = dw_xfer(dw, addr, w, wlen, r, rlen);
	mutex_exit(&dw->dw_mutex);
	return (e);
}

static i2c_errno_t
dwiic_prop_info(void *arg, i2c_prop_t prop, i2c_prop_info_t *info)
{
	switch (prop) {
	case I2C_PROP_BUS_SPEED:
		i2c_prop_info_set_def_u32(info, I2C_SPEED_FAST);
		i2c_prop_info_set_pos_bit32(info, I2C_SPEED_FAST);
		break;
	case I2C_PROP_MAX_READ:
	case I2C_PROP_MAX_WRITE:
		break;
	default:
		return (I2C_PROP_E_UNSUP);
	}
	i2c_prop_info_set_perm(info, I2C_PROP_PERM_RO);
	return (I2C_CORE_E_OK);
}

static i2c_errno_t
dwiic_prop_get(void *arg, i2c_prop_t prop, void *buf, size_t buflen)
{
	uint32_t val;

	switch (prop) {
	case I2C_PROP_BUS_SPEED:
		val = I2C_SPEED_FAST;
		break;
	case I2C_PROP_MAX_READ:
	case I2C_PROP_MAX_WRITE:
		val = I2C_REQ_MAX;
		break;
	default:
		return (I2C_PROP_E_UNSUP);
	}
	if (buflen < sizeof (val))
		return (I2C_PROP_E_SMALL_BUF);
	bcopy(&val, buf, sizeof (val));
	return (I2C_CORE_E_OK);
}

static const i2c_ctrl_ops_t dwiic_ctrl_ops = {
	.i2c_port_name_f = i2c_ctrl_port_name_portno,
	.i2c_io_i2c_f = dwiic_io_i2c,
	.i2c_prop_info_f = dwiic_prop_info,
	.i2c_prop_get_f = dwiic_prop_get,
};

/*
 * Bring the LPSS block out of reset and set up the DesignWare master, as
 * dwiic_pci_attach() + dwiic_init(). Timing: the controller's own counts
 * (OpenBSD's fallback when ACPI has no SSCN/FMCN, which lixi's DSDT lacks).
 */
static bool
dwiic_hw_init(dwiic_t *dw)
{
	uint32_t caps, p1;

	dw_wr(dw, LPSS_RESETS, LPSS_RESETS_DONE);
	caps = dw_rd(dw, LPSS_CAPS);
	if (((caps >> 4) & 0xf) != 0) {
		dev_err(dw->dw_dip, CE_WARN, "LPSS type %u is not I2C",
		    (caps >> 4) & 0xf);
		return (false);
	}
	if (dw_rd(dw, DW_COMP_TYPE) != DW_COMP_TYPE_VALUE) {
		dev_err(dw->dw_dip, CE_WARN, "not a DesignWare I2C: 0x%x",
		    dw_rd(dw, DW_COMP_TYPE));
		return (false);
	}
	if (!dw_enable(dw, 0))
		return (false);
	dw->dw_ss_hcnt = dw_rd(dw, 0x14);
	dw->dw_ss_lcnt = dw_rd(dw, 0x18);
	dw->dw_fs_hcnt = dw_rd(dw, 0x1c);
	dw->dw_fs_lcnt = dw_rd(dw, 0x20);
	dw->dw_sda_hold = dw_rd(dw, 0x7c);
	p1 = dw_rd(dw, DW_PARAM_1);
	dw->dw_txfifo = MIN(((p1 >> 16) & 0xff) + 1, DWIIC_FIFO_MAX);
	dw->dw_rxfifo = MIN(((p1 >> 8) & 0xff) + 1, DWIIC_FIFO_MAX);
	if (dw->dw_txfifo < 2 || dw->dw_rxfifo < 2) {
		dev_err(dw->dw_dip, CE_WARN, "bad FIFO depths 0x%x", p1);
		return (false);
	}
	dw_wr(dw, DW_TX_TL, dw->dw_txfifo / 2);
	dw_wr(dw, DW_RX_TL, 0);
	dw_wr(dw, DW_CON, DW_CON_MASTER_FAST);
	dw_wr(dw, DW_INTR_MASK, 0);
	(void) dw_rd(dw, DW_CLR_INTR);
	return (true);
}

static void
dwiic_cleanup(dwiic_t *dw)
{
	int inst = ddi_get_instance(dw->dw_dip);

	if (dw->dw_init & DWIIC_INIT_REGS) {
		dw_wr(dw, DW_ENABLE, 0);
		ddi_regs_map_free(&dw->dw_regs);
	}
	if (dw->dw_init & DWIIC_INIT_SYNC) {
		mutex_destroy(&dw->dw_mutex);
		mutex_destroy(&dw->dw_napmu);
		cv_destroy(&dw->dw_napcv);
	}
	if (dw->dw_init & DWIIC_INIT_CFG)
		pci_config_teardown(&dw->dw_cfg);
	ddi_soft_state_free(dwiic_state, inst);
}

/* Alder Lake-P PCH Serial IO I2C #0..#3 (OpenBSD pcidevs 600SERIES_LP_I2C_0..3) */
static const uint16_t dwiic_devids[] = { 0x51e8, 0x51e9, 0x51ea, 0x51eb };

static bool
dwiic_supported(dwiic_t *dw)
{
	uint16_t ven = pci_config_get16(dw->dw_cfg, PCI_CONF_VENID);
	uint16_t dev = pci_config_get16(dw->dw_cfg, PCI_CONF_DEVID);

	if (ven == 0x8086) {
		for (uint_t i = 0; i < ARRAY_SIZE(dwiic_devids); i++) {
			if (dev == dwiic_devids[i])
				return (true);
		}
	}
	dev_err(dw->dw_dip, CE_WARN, "unsupported device %x,%x", ven, dev);
	return (false);
}

/*
 * Firmware leaves I2C0 with memory decode off (lixi: command 0x0000) and,
 * after a _PS3, in D3hot. Its _PS0 is empty, so D0 via PMCSR plus MAE is
 * the whole power-up.
 */
static void
dwiic_pci_power_up(dwiic_t *dw)
{
	uint8_t cap = pci_config_get8(dw->dw_cfg, PCI_CONF_CAP_PTR);
	uint16_t cmd;

	for (int n = 0; cap != 0 && cap != 0xff && n < 48; n++) {
		if (pci_config_get8(dw->dw_cfg, cap) == PCI_CAP_ID_PM) {
			uint16_t pmcsr = pci_config_get16(dw->dw_cfg,
			    cap + PCI_PMCSR);
			if ((pmcsr & PCI_PMCSR_STATE_MASK) != PCI_PMCSR_D0) {
				pci_config_put16(dw->dw_cfg, cap + PCI_PMCSR,
				    pmcsr & ~PCI_PMCSR_STATE_MASK);
				delay(drv_usectohz(10000));
			}
			break;
		}
		cap = pci_config_get8(dw->dw_cfg, cap + 1);
	}
	cmd = pci_config_get16(dw->dw_cfg, PCI_CONF_COMM);
	pci_config_put16(dw->dw_cfg, PCI_CONF_COMM,
	    cmd | PCI_COMM_MAE | PCI_COMM_ME);
}

static int
dwiic_attach(dev_info_t *dip, ddi_attach_cmd_t cmd)
{
	ddi_device_acc_attr_t da = {
		.devacc_attr_version = DDI_DEVICE_ATTR_V0,
		.devacc_attr_endian_flags = DDI_STRUCTURE_LE_ACC,
		.devacc_attr_dataorder = DDI_STRICTORDER_ACC,
	};
	i2c_ctrl_register_t *reg;
	i2c_ctrl_reg_error_t ret;
	int inst = ddi_get_instance(dip);
	dwiic_t *dw;

	if (cmd != DDI_ATTACH)
		return (DDI_FAILURE);
	if (ddi_soft_state_zalloc(dwiic_state, inst) != DDI_SUCCESS)
		return (DDI_FAILURE);
	dw = ddi_get_soft_state(dwiic_state, inst);
	dw->dw_dip = dip;

	if (pci_config_setup(dip, &dw->dw_cfg) != DDI_SUCCESS) {
		dev_err(dip, CE_WARN, "failed to set up config space");
		goto fail;
	}
	dw->dw_init |= DWIIC_INIT_CFG;
	if (!dwiic_supported(dw))
		goto fail;
	dwiic_pci_power_up(dw);
	if (ddi_regs_map_setup(dip, DWIIC_REGNO, &dw->dw_base, 0, 0, &da,
	    &dw->dw_regs) != DDI_SUCCESS) {
		dev_err(dip, CE_WARN, "failed to map BAR0");
		goto fail;
	}
	dw->dw_init |= DWIIC_INIT_REGS;
	mutex_init(&dw->dw_mutex, NULL, MUTEX_DRIVER, NULL);
	mutex_init(&dw->dw_napmu, NULL, MUTEX_DRIVER, NULL);
	cv_init(&dw->dw_napcv, NULL, CV_DRIVER, NULL);
	dw->dw_init |= DWIIC_INIT_SYNC;
	if (!dwiic_hw_init(dw))
		goto fail;

	if ((ret = i2c_ctrl_register_alloc(I2C_CTRL_PROVIDER, &reg)) != 0) {
		dev_err(dip, CE_WARN, "i2c_ctrl_register_alloc: 0x%x", ret);
		goto fail;
	}
	reg->ic_type = I2C_CTRL_TYPE_I2C;
	reg->ic_nports = 1;
	reg->ic_dip = dip;
	reg->ic_drv = dw;
	reg->ic_ops = &dwiic_ctrl_ops;
	ret = i2c_ctrl_register(reg, &dw->dw_hdl);
	i2c_ctrl_register_free(reg);
	if (ret != 0) {
		dev_err(dip, CE_WARN, "i2c_ctrl_register: 0x%x", ret);
		goto fail;
	}
	dw->dw_init |= DWIIC_INIT_I2C;
	dev_err(dip, CE_CONT, "?DesignWare I2C, FIFO %u/%u, fast %u/%u, "
	    "polled\n", dw->dw_txfifo, dw->dw_rxfifo, dw->dw_fs_hcnt,
	    dw->dw_fs_lcnt);
	return (DDI_SUCCESS);
fail:
	dwiic_cleanup(dw);
	return (DDI_FAILURE);
}

static int
dwiic_detach(dev_info_t *dip, ddi_detach_cmd_t cmd)
{
	dwiic_t *dw = ddi_get_soft_state(dwiic_state, ddi_get_instance(dip));
	i2c_ctrl_reg_error_t ret;

	if (cmd != DDI_DETACH || dw == NULL)
		return (DDI_FAILURE);
	if ((ret = i2c_ctrl_unregister(dw->dw_hdl)) != 0) {
		dev_err(dip, CE_WARN, "i2c_ctrl_unregister: 0x%x", ret);
		return (DDI_FAILURE);
	}
	dwiic_cleanup(dw);
	return (DDI_SUCCESS);
}

static int
dwiic_quiesce(dev_info_t *dip)
{
	dwiic_t *dw = ddi_get_soft_state(dwiic_state, ddi_get_instance(dip));

	if (dw != NULL && (dw->dw_init & DWIIC_INIT_REGS) != 0)
		dw_wr(dw, DW_ENABLE, 0);
	return (DDI_SUCCESS);
}

static struct dev_ops dwiic_dev_ops = {
	.devo_rev = DEVO_REV,
	.devo_refcnt = 0,
	.devo_identify = nulldev,
	.devo_probe = nulldev,
	.devo_attach = dwiic_attach,
	.devo_detach = dwiic_detach,
	.devo_reset = nodev,
	.devo_quiesce = dwiic_quiesce,
};

static struct modldrv dwiic_modldrv = {
	.drv_modops = &mod_driverops,
	.drv_linkinfo = "DesignWare I2C (Intel LPSS)",
	.drv_dev_ops = &dwiic_dev_ops
};

static struct modlinkage dwiic_modlinkage = {
	.ml_rev = MODREV_1,
	.ml_linkage = { &dwiic_modldrv, NULL }
};

int
_init(void)
{
	int ret;

	if ((ret = ddi_soft_state_init(&dwiic_state, sizeof (dwiic_t), 1)) != 0)
		return (ret);
	i2c_ctrl_mod_init(&dwiic_dev_ops);
	if ((ret = mod_install(&dwiic_modlinkage)) != 0) {
		i2c_ctrl_mod_fini(&dwiic_dev_ops);
		ddi_soft_state_fini(&dwiic_state);
	}
	return (ret);
}

int
_info(struct modinfo *modinfop)
{
	return (mod_info(&dwiic_modlinkage, modinfop));
}

int
_fini(void)
{
	int ret;

	if ((ret = mod_remove(&dwiic_modlinkage)) == 0) {
		i2c_ctrl_mod_fini(&dwiic_dev_ops);
		ddi_soft_state_fini(&dwiic_state);
	}
	return (ret);
}
