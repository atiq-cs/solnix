/*
 * ihid -- HID over I2C (Microsoft HID-over-I2C protocol 1.0) transport, on a
 * dwiic controller. Polled. A STREAMS driver shaped like usb hid(4D): it
 * answers usbms's HID_GET_PARSER_HANDLE and sends each input report up as
 * M_DATA ([report id][payload]), so consconfig_dacf (dacf.conf rule on
 * ihid:internal_mouse, pushmod usbms) links it under consms beside
 * mouse8042. The HID/report descriptors are also exported as
 * properties. The device sequence (descriptor, SET_POWER, RESET and its
 * response, report descriptor, input-register reads) follows OpenBSD
 * sys/dev/i2c/ihidev.c (rev 37a498de), which carries this notice:
 *
 * Copyright (c) 2015, 2016 joshua stein <jcs@openbsd.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
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
 * The device node is created by `i2cadm device add <ctrl>/0 ihid <addr>`
 * (binding by node name); ihid then finds its ACPI node under the
 * controller's by I2cSerialBus address and asks _DSM for the HID
 * descriptor register.
 */

#include <sys/types.h>
#include <sys/conf.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/modctl.h>
#include <sys/kmem.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/kstat.h>
#include <sys/proc.h>
#include <sys/disp.h>
#include <sys/cmn_err.h>
#include <sys/sysmacros.h>
#include <sys/stream.h>
#include <sys/stropts.h>
#include <sys/strsun.h>
#include <sys/usb/clients/hid/hid.h>
#include <sys/usb/clients/hidparser/hidparser.h>
#include <sys/usb/clients/hidparser/hid_parser_driver.h>
#include <sys/i2c/client.h>
#include <sys/i2c/controller.h>
#include <sys/acpi/acpi.h>
#include <sys/acpica.h>
#include "dwiic.h"

/* genunix, not in a header (usb hid.c declares it the same way) */
extern int ddi_create_internal_pathname(dev_info_t *, char *, int, minor_t);

#define	IHID_DESC_LEN		30
#define	IHID_RDESC_MAX		4096
#define	IHID_POLL_US		10000

/* HID-over-I2C opcodes (spec 7.2) */
#define	IHID_OP_RESET		1
#define	IHID_OP_SET_POWER	8
#define	IHID_POWER_ON		0
#define	IHID_POWER_SLEEP	1

/* _DSM GUID 3cdff6f7-4267-4555-ad05-b30a3d8938de, ToUUID byte order */
static uint8_t ihid_dsm_uuid[16] = {
	0xf7, 0xf6, 0xdf, 0x3c, 0x67, 0x42, 0x55, 0x45,
	0xad, 0x05, 0xb3, 0x0a, 0x3d, 0x89, 0x38, 0xde
};

typedef struct ihid {
	dev_info_t	*ih_dip;
	dev_info_t	*ih_ctrl_dip;	/* the dwiic instance */
	i2c_client_t	*ih_client;
	uint16_t	ih_addr;
	uint16_t	ih_desc_reg;
	uint8_t		ih_desc[IHID_DESC_LEN];
	uint16_t	ih_rdesc_len, ih_input_reg, ih_cmd_reg, ih_max_input;
	uint8_t		*ih_rdesc;
	uint8_t		*ih_ibuf;
	kmutex_t	ih_mutex;
	kcondvar_t	ih_cv;
	kthread_t	*ih_thread;
	kt_did_t	ih_tid;
	bool		ih_stop;
	bool		ih_open;
	bool		ih_busy;	/* poller is in putnext() */
	queue_t		*ih_rq;		/* read queue while open */
	usb_hid_descr_t	ih_hdesc;	/* for hidparser (country code) */
	hidparser_handle_t ih_hparse;	/* parsed report descriptor */
	kstat_t		*ih_ks;
	kstat_named_t	*ih_kn;		/* polls reports empty errors dropped */
} ihid_t;

enum { IHID_KS_POLLS, IHID_KS_REPORTS, IHID_KS_EMPTY, IHID_KS_ERRORS,
	IHID_KS_DROPPED, IHID_KS_N };
static const char *ihid_ks_names[IHID_KS_N] = { "polls", "reports",
	"empty", "errors", "dropped" };

static void *ihid_state;

/* One transfer to the device with the framework's bus lock held. */
static int
ihid_xfer(ihid_t *ih, const uint8_t *w, uint32_t wlen, uint8_t *r,
    uint32_t rlen)
{
	i2c_txn_t *txn;
	int e;

	if (i2c_bus_lock(ih->ih_client, 0, &txn) != I2C_CORE_E_OK)
		return (I2C_CTRL_E_BUS_BUSY);
	e = dwiic_xfer(ih->ih_ctrl_dip, ih->ih_addr, w, wlen, r, rlen);
	i2c_bus_unlock(txn);
	return (e);
}

static int
ihid_cmd(ihid_t *ih, uint8_t op, uint8_t arg)
{
	uint8_t w[4] = { ih->ih_cmd_reg & 0xff, ih->ih_cmd_reg >> 8,
	    arg, op };
	return (ihid_xfer(ih, w, sizeof (w), NULL, 0));
}

static int
ihid_read_reg(ihid_t *ih, uint16_t reg, uint8_t *buf, uint32_t len)
{
	uint8_t w[2] = { reg & 0xff, reg >> 8 };
	return (ihid_xfer(ih, w, sizeof (w), buf, len));
}

typedef struct ihid_crs {
	uint16_t	ic_addr;	/* wanted I2cSerialBus address */
	bool		ic_found;
	uint32_t	ic_speed;
	int		ic_irq;		/* first Interrupt() GSI, or -1 */
} ihid_crs_t;

static ACPI_STATUS
ihid_crs_cb(ACPI_RESOURCE *res, void *arg)
{
	ihid_crs_t *c = arg;

	if (res->Type == ACPI_RESOURCE_TYPE_SERIAL_BUS &&
	    res->Data.CommonSerialBus.Type == ACPI_RESOURCE_SERIAL_TYPE_I2C &&
	    res->Data.I2cSerialBus.SlaveAddress == c->ic_addr) {
		c->ic_found = true;
		c->ic_speed = res->Data.I2cSerialBus.ConnectionSpeed;
	} else if (res->Type == ACPI_RESOURCE_TYPE_EXTENDED_IRQ &&
	    res->Data.ExtendedIrq.InterruptCount > 0 && c->ic_irq < 0) {
		c->ic_irq = res->Data.ExtendedIrq.Interrupts[0];
	}
	return (AE_OK);
}

/* _DSM(HID-over-I2C GUID, rev 1, func 1): the HID descriptor register */
static bool
ihid_acpi_desc_reg(ACPI_HANDLE dev, uint16_t *regp)
{
	ACPI_OBJECT args[4], *o;
	ACPI_OBJECT_LIST al = { 4, args };
	ACPI_BUFFER rb = { ACPI_ALLOCATE_BUFFER, NULL };
	bool ok = false;

	bzero(args, sizeof (args));
	args[0].Type = ACPI_TYPE_BUFFER;
	args[0].Buffer.Length = sizeof (ihid_dsm_uuid);
	args[0].Buffer.Pointer = ihid_dsm_uuid;
	args[1].Type = ACPI_TYPE_INTEGER;
	args[1].Integer.Value = 1;
	args[2].Type = ACPI_TYPE_INTEGER;
	args[2].Integer.Value = 1;
	args[3].Type = ACPI_TYPE_PACKAGE;
	if (ACPI_FAILURE(AcpiEvaluateObject(dev, "_DSM", &al, &rb)))
		return (false);
	o = rb.Pointer;
	if (o != NULL && o->Type == ACPI_TYPE_INTEGER &&
	    o->Integer.Value <= UINT16_MAX) {
		*regp = (uint16_t)o->Integer.Value;
		ok = true;
	}
	AcpiOsFree(rb.Pointer);
	return (ok);
}

/*
 * Among the ACPI children of the controller's node, find the one whose _CRS
 * names our address; take its descriptor register (from _DSM) and IRQ.
 */
static bool
ihid_acpi_find(ihid_t *ih, ihid_crs_t *crs)
{
	ACPI_HANDLE ctrl, child = NULL;

	if (ACPI_FAILURE(acpica_get_handle(ih->ih_ctrl_dip, &ctrl))) {
		dev_err(ih->ih_dip, CE_WARN, "controller has no ACPI node");
		return (false);
	}
	while (ACPI_SUCCESS(AcpiGetNextObject(ACPI_TYPE_DEVICE, ctrl, child,
	    &child))) {
		bzero(crs, sizeof (*crs));
		crs->ic_addr = ih->ih_addr;
		crs->ic_irq = -1;
		(void) AcpiWalkResources(child, "_CRS", ihid_crs_cb, crs);
		if (!crs->ic_found)
			continue;
		if (ihid_acpi_desc_reg(child, &ih->ih_desc_reg))
			return (true);
		dev_err(ih->ih_dip, CE_WARN, "ACPI node for 0x%x has no "
		    "HID _DSM", ih->ih_addr);
		return (false);
	}
	dev_err(ih->ih_dip, CE_WARN, "no ACPI node for address 0x%x",
	    ih->ih_addr);
	return (false);
}

#define	LE16(p)	((uint16_t)((p)[0] | ((p)[1] << 8)))

/* HID descriptor (spec 5.1.1), then power on, reset, and report descriptor */
static bool
ihid_dev_init(ihid_t *ih)
{
	uint8_t ack[2];
	int e, i;

	if ((e = ihid_read_reg(ih, ih->ih_desc_reg, ih->ih_desc,
	    IHID_DESC_LEN)) != 0) {
		dev_err(ih->ih_dip, CE_WARN, "HID descriptor read: %d", e);
		return (false);
	}
	if (LE16(ih->ih_desc) != IHID_DESC_LEN ||
	    LE16(ih->ih_desc + 2) != 0x0100) {
		dev_err(ih->ih_dip, CE_WARN, "bad HID descriptor: length %u "
		    "version 0x%x", LE16(ih->ih_desc), LE16(ih->ih_desc + 2));
		return (false);
	}
	ih->ih_rdesc_len = LE16(ih->ih_desc + 4);
	ih->ih_input_reg = LE16(ih->ih_desc + 8);
	ih->ih_max_input = LE16(ih->ih_desc + 10);
	ih->ih_cmd_reg = LE16(ih->ih_desc + 16);
	if (ih->ih_rdesc_len == 0 || ih->ih_rdesc_len > IHID_RDESC_MAX ||
	    ih->ih_max_input < 3 || ih->ih_max_input > 1024) {
		dev_err(ih->ih_dip, CE_WARN, "unsupported sizes: report "
		    "descriptor %u, max input %u", ih->ih_rdesc_len,
		    ih->ih_max_input);
		return (false);
	}

	/* ihidev_reset(): power on, wait, RESET, wait for the 00 00 response */
	if ((e = ihid_cmd(ih, IHID_OP_SET_POWER, IHID_POWER_ON)) != 0) {
		dev_err(ih->ih_dip, CE_WARN, "SET_POWER ON: %d", e);
		return (false);
	}
	delay(drv_usectohz(100000));
	if ((e = ihid_cmd(ih, IHID_OP_RESET, 0)) != 0) {
		dev_err(ih->ih_dip, CE_WARN, "RESET: %d", e);
		return (false);
	}
	for (i = 0; i < 50; i++) {
		delay(drv_usectohz(100000));
		if (ihid_xfer(ih, NULL, 0, ack, sizeof (ack)) == 0 &&
		    ack[0] == 0 && ack[1] == 0)
			break;
	}
	if (i == 50) {
		dev_err(ih->ih_dip, CE_WARN, "no RESET response");
		return (false);
	}

	ih->ih_rdesc = kmem_zalloc(ih->ih_rdesc_len, KM_SLEEP);
	if ((e = ihid_read_reg(ih, LE16(ih->ih_desc + 6), ih->ih_rdesc,
	    ih->ih_rdesc_len)) != 0) {
		dev_err(ih->ih_dip, CE_WARN, "report descriptor read: %d", e);
		return (false);
	}
	return (true);
}

/*
 * The poller: while the stream is open, read the input register every 10 ms
 * (a plain read with no register write, as ihidev_intr() does) and send each
 * non-empty report up as M_DATA without its 2 length bytes, i.e.
 * [report id][payload], which is what usbms expects from hid(4D). An empty
 * report has length 0 (spec 7.2.2).
 */
static void
ihid_poll_thread(void *arg)
{
	ihid_t *ih = arg;
	uint32_t n = ih->ih_max_input;
	uint16_t len;
	queue_t *rq;
	mblk_t *mp;
	int e;

	mutex_enter(&ih->ih_mutex);
	while (!ih->ih_stop) {
		if (!ih->ih_open) {
			cv_wait(&ih->ih_cv, &ih->ih_mutex);
			continue;
		}
		mutex_exit(&ih->ih_mutex);
		e = ihid_xfer(ih, NULL, 0, ih->ih_ibuf, n);
		len = LE16(ih->ih_ibuf);
		mp = (e == 0 && len > 2 && len <= n) ?
		    allocb(len - 2, BPRI_HI) : NULL;
		if (mp != NULL) {
			bcopy(ih->ih_ibuf + 2, mp->b_wptr, len - 2);
			mp->b_wptr += len - 2;
		}
		mutex_enter(&ih->ih_mutex);
		ih->ih_kn[IHID_KS_POLLS].value.ui64++;
		if (e != 0 || len > n) {
			ih->ih_kn[IHID_KS_ERRORS].value.ui64++;
		} else if (len <= 2) {
			ih->ih_kn[IHID_KS_EMPTY].value.ui64++;
		} else if (mp == NULL || (rq = ih->ih_rq) == NULL) {
			ih->ih_kn[IHID_KS_DROPPED].value.ui64++;
			freemsg(mp);
		} else {
			/* close waits for !ih_busy before qprocsoff */
			ih->ih_busy = true;
			mutex_exit(&ih->ih_mutex);
			if (canputnext(rq)) {
				putnext(rq, mp);
				mp = NULL;
			}
			mutex_enter(&ih->ih_mutex);
			ih->ih_busy = false;
			cv_broadcast(&ih->ih_cv);
			if (mp != NULL) {
				ih->ih_kn[IHID_KS_DROPPED].value.ui64++;
				freemsg(mp);
			} else {
				ih->ih_kn[IHID_KS_REPORTS].value.ui64++;
			}
		}
		(void) cv_reltimedwait(&ih->ih_cv, &ih->ih_mutex,
		    drv_usectohz(IHID_POLL_US), TR_CLOCK_TICK);
	}
	mutex_exit(&ih->ih_mutex);
	thread_exit();
}

/* minor number == instance: one (internal) minor per device */
static int
ihid_getinfo(dev_info_t *dip, ddi_info_cmd_t cmd, void *arg, void **rp)
{
	int inst = (int)getminor((dev_t)arg);
	ihid_t *ih;

	switch (cmd) {
	case DDI_INFO_DEVT2DEVINFO:
		if ((ih = ddi_get_soft_state(ihid_state, inst)) == NULL)
			return (DDI_FAILURE);
		*rp = ih->ih_dip;
		return (DDI_SUCCESS);
	case DDI_INFO_DEVT2INSTANCE:
		*rp = (void *)(uintptr_t)inst;
		return (DDI_SUCCESS);
	default:
		return (DDI_FAILURE);
	}
}

static int
ihid_open(queue_t *q, dev_t *devp, int flag, int sflag, cred_t *cr)
{
	ihid_t *ih = ddi_get_soft_state(ihid_state, getminor(*devp));

	if (ih == NULL)
		return (ENXIO);
	if (sflag != 0)		/* no clone or module opens */
		return (EINVAL);
	if (q->q_ptr != NULL)	/* already open: same stream */
		return (0);
	if (drv_priv(cr) != 0)
		return (EPERM);
	mutex_enter(&ih->ih_mutex);
	if (ih->ih_open) {
		mutex_exit(&ih->ih_mutex);
		return (EBUSY);
	}
	ih->ih_open = true;	/* claim it; reports drop until ih_rq is set */
	cv_broadcast(&ih->ih_cv);
	mutex_exit(&ih->ih_mutex);
	q->q_ptr = WR(q)->q_ptr = ih;
	qprocson(q);
	/* only now may the poller putnext() */
	mutex_enter(&ih->ih_mutex);
	ih->ih_rq = q;
	mutex_exit(&ih->ih_mutex);
	return (0);
}

static int
ihid_close(queue_t *q, int flag, cred_t *cr)
{
	ihid_t *ih = q->q_ptr;

	mutex_enter(&ih->ih_mutex);
	ih->ih_open = false;
	ih->ih_rq = NULL;
	while (ih->ih_busy)
		cv_wait(&ih->ih_cv, &ih->ih_mutex);
	mutex_exit(&ih->ih_mutex);
	qprocsoff(q);
	q->q_ptr = WR(q)->q_ptr = NULL;
	return (0);
}

/*
 * Write side: canonical M_FLUSH; M_CTL HID_GET_PARSER_HANDLE answered as
 * hid_mctl_receive() does (usbms's open waits for it); other M_CTLs are
 * dropped; ioctls are NAKed (usbms answers the mouse ioctls itself).
 */
static int
ihid_wput(queue_t *q, mblk_t *mp)
{
	ihid_t *ih = q->q_ptr;
	struct iocblk *iocp;

	switch (DB_TYPE(mp)) {
	case M_FLUSH:
		if (*mp->b_rptr & FLUSHW)
			flushq(q, FLUSHDATA);
		if (*mp->b_rptr & FLUSHR) {
			flushq(RD(q), FLUSHDATA);
			*mp->b_rptr &= ~FLUSHW;
			qreply(q, mp);
		} else {
			freemsg(mp);
		}
		break;
	case M_CTL:
		iocp = (struct iocblk *)mp->b_rptr;
		if (MBLKL(mp) < sizeof (*iocp) ||
		    iocp->ioc_cmd != HID_GET_PARSER_HANDLE) {
			freemsg(mp);
			break;
		}
		freemsg(mp->b_cont);
		mp->b_cont = allocb(sizeof (hidparser_handle_t), BPRI_HI);
		if (mp->b_cont != NULL) {
			bcopy(&ih->ih_hparse, mp->b_cont->b_wptr,
			    sizeof (hidparser_handle_t));
			mp->b_cont->b_wptr += sizeof (hidparser_handle_t);
			iocp->ioc_count = sizeof (hidparser_handle_t);
		} else {
			iocp->ioc_count = 0;
		}
		qreply(q, mp);
		break;
	case M_IOCTL:
		miocnak(q, mp, 0, EINVAL);
		break;
	default:
		freemsg(mp);
		break;
	}
	return (0);
}

static void
ihid_cleanup(ihid_t *ih)
{
	int inst = ddi_get_instance(ih->ih_dip);

	if (ih->ih_thread != NULL) {
		mutex_enter(&ih->ih_mutex);
		ih->ih_stop = true;
		cv_broadcast(&ih->ih_cv);
		mutex_exit(&ih->ih_mutex);
		thread_join(ih->ih_tid);
	}
	if (ih->ih_client != NULL && ih->ih_rdesc != NULL)
		(void) ihid_cmd(ih, IHID_OP_SET_POWER, IHID_POWER_SLEEP);
	if (ih->ih_ks != NULL)
		kstat_delete(ih->ih_ks);
	ddi_remove_minor_node(ih->ih_dip, NULL);
	if (ih->ih_client != NULL)
		i2c_client_destroy(ih->ih_client);
	if (ih->ih_rdesc != NULL)
		kmem_free(ih->ih_rdesc, ih->ih_rdesc_len);
	if (ih->ih_ibuf != NULL)
		kmem_free(ih->ih_ibuf, ih->ih_max_input);
	if (ih->ih_hparse != NULL)
		(void) hidparser_free_report_descriptor_handle(ih->ih_hparse);
	mutex_destroy(&ih->ih_mutex);
	cv_destroy(&ih->ih_cv);
	ddi_soft_state_free(ihid_state, inst);
}

static int
ihid_attach(dev_info_t *dip, ddi_attach_cmd_t cmd)
{
	int inst = ddi_get_instance(dip);
	const i2c_addr_t *a;
	ihid_crs_t crs;
	dev_info_t *p;
	ihid_t *ih;
	i2c_errno_t ie;

	if (cmd != DDI_ATTACH)
		return (DDI_FAILURE);
	if (ddi_soft_state_zalloc(ihid_state, inst) != DDI_SUCCESS)
		return (DDI_FAILURE);
	ih = ddi_get_soft_state(ihid_state, inst);
	ih->ih_dip = dip;
	mutex_init(&ih->ih_mutex, NULL, MUTEX_DRIVER, NULL);
	cv_init(&ih->ih_cv, NULL, CV_DRIVER, NULL);

	/* device -> port nexus -> controller nexus -> the dwiic node */
	p = ddi_get_parent(dip);
	p = (p != NULL) ? ddi_get_parent(p) : NULL;
	p = (p != NULL) ? ddi_get_parent(p) : NULL;
	if (p == NULL || strcmp(ddi_driver_name(p), "dwiic") != 0) {
		dev_err(dip, CE_WARN, "not on a dwiic controller");
		goto fail;
	}
	ih->ih_ctrl_dip = p;
	if ((ie = i2c_client_init(dip, 0, &ih->ih_client)) != I2C_CORE_E_OK) {
		dev_err(dip, CE_WARN, "i2c_client_init: 0x%x", ie);
		goto fail;
	}
	a = i2c_client_addr(ih->ih_client);
	if (a->ia_type != I2C_ADDR_7BIT) {
		dev_err(dip, CE_WARN, "10-bit address unsupported");
		goto fail;
	}
	ih->ih_addr = a->ia_addr;
	if (!ihid_acpi_find(ih, &crs) || !ihid_dev_init(ih))
		goto fail;

	(void) ddi_prop_update_byte_array(DDI_DEV_T_NONE, dip,
	    "hid-descriptor", ih->ih_desc, IHID_DESC_LEN);
	(void) ddi_prop_update_byte_array(DDI_DEV_T_NONE, dip,
	    "hid-report-descriptor", ih->ih_rdesc, ih->ih_rdesc_len);
	(void) ddi_prop_update_int(DDI_DEV_T_NONE, dip, "acpi-irq", crs.ic_irq);
	(void) ddi_prop_update_int(DDI_DEV_T_NONE, dip, "acpi-i2c-speed",
	    crs.ic_speed);

	ih->ih_ibuf = kmem_zalloc(ih->ih_max_input, KM_SLEEP);
	/* usbms decodes reports against this; hidparser keeps &ih_hdesc */
	ih->ih_hdesc.bLength = USB_HID_DESCR_SIZE;
	ih->ih_hdesc.bDescriptorType = USB_DESCR_TYPE_HID;
	ih->ih_hdesc.wReportDescriptorLength = ih->ih_rdesc_len;
	if (hidparser_parse_report_descriptor(ih->ih_rdesc, ih->ih_rdesc_len,
	    &ih->ih_hdesc, &ih->ih_hparse) != HIDPARSER_SUCCESS) {
		dev_err(dip, CE_WARN, "report descriptor does not parse");
		ih->ih_hparse = NULL;
		goto fail;
	}
	ih->ih_ks = kstat_create("ihid", inst, "stats", "misc",
	    KSTAT_TYPE_NAMED, IHID_KS_N, 0);
	if (ih->ih_ks == NULL)
		goto fail;
	ih->ih_kn = ih->ih_ks->ks_data;
	for (int i = 0; i < IHID_KS_N; i++)
		kstat_named_init(&ih->ih_kn[i], ihid_ks_names[i],
		    KSTAT_DATA_UINT64);
	kstat_install(ih->ih_ks);
	/* dacf.conf: ihid:internal_mouse -> ms_config pushmod=usbms */
	if (ddi_create_internal_pathname(dip, "internal_mouse", S_IFCHR,
	    inst) != DDI_SUCCESS)
		goto fail;
	ih->ih_thread = thread_create(NULL, 0, ihid_poll_thread, ih, 0, &p0,
	    TS_RUN, minclsyspri);
	ih->ih_tid = ih->ih_thread->t_did;

	dev_err(dip, CE_CONT, "?HID over I2C 0x%x: vid %04x pid %04x, "
	    "report descriptor %u bytes, input %u bytes, irq %d (polled)\n",
	    ih->ih_addr, LE16(ih->ih_desc + 20), LE16(ih->ih_desc + 22),
	    ih->ih_rdesc_len, ih->ih_max_input, crs.ic_irq);
	return (DDI_SUCCESS);
fail:
	ihid_cleanup(ih);
	return (DDI_FAILURE);
}

static int
ihid_detach(dev_info_t *dip, ddi_detach_cmd_t cmd)
{
	ihid_t *ih = ddi_get_soft_state(ihid_state, ddi_get_instance(dip));

	if (cmd != DDI_DETACH || ih == NULL)
		return (DDI_FAILURE);
	mutex_enter(&ih->ih_mutex);
	if (ih->ih_open) {
		mutex_exit(&ih->ih_mutex);
		return (DDI_FAILURE);
	}
	mutex_exit(&ih->ih_mutex);
	ihid_cleanup(ih);
	return (DDI_SUCCESS);
}

static struct module_info ihid_minfo = {
	.mi_idnum = 0,
	.mi_idname = "ihid",
	.mi_minpsz = 0,
	.mi_maxpsz = INFPSZ,
	.mi_hiwat = 256,
	.mi_lowat = 128
};

static struct qinit ihid_rinit = {
	.qi_qopen = ihid_open,
	.qi_qclose = ihid_close,
	.qi_minfo = &ihid_minfo
};

static struct qinit ihid_winit = {
	.qi_putp = ihid_wput,
	.qi_minfo = &ihid_minfo
};

static struct streamtab ihid_streamtab = {
	.st_rdinit = &ihid_rinit,
	.st_wrinit = &ihid_winit
};

static struct cb_ops ihid_cb_ops = {
	.cb_open = nodev,
	.cb_close = nodev,
	.cb_strategy = nodev,
	.cb_print = nodev,
	.cb_dump = nodev,
	.cb_read = nodev,
	.cb_write = nodev,
	.cb_ioctl = nodev,
	.cb_devmap = nodev,
	.cb_mmap = nodev,
	.cb_segmap = nodev,
	.cb_chpoll = nochpoll,
	.cb_prop_op = ddi_prop_op,
	.cb_str = &ihid_streamtab,
	.cb_flag = D_MP | D_NEW,
	.cb_rev = CB_REV,
	.cb_aread = nodev,
	.cb_awrite = nodev
};

static struct dev_ops ihid_dev_ops = {
	.devo_rev = DEVO_REV,
	.devo_refcnt = 0,
	.devo_getinfo = ihid_getinfo,
	.devo_identify = nulldev,
	.devo_probe = nulldev,
	.devo_attach = ihid_attach,
	.devo_detach = ihid_detach,
	.devo_reset = nodev,
	.devo_cb_ops = &ihid_cb_ops,
	.devo_quiesce = ddi_quiesce_not_needed,
};

static struct modldrv ihid_modldrv = {
	.drv_modops = &mod_driverops,
	.drv_linkinfo = "HID over I2C (polled)",
	.drv_dev_ops = &ihid_dev_ops
};

static struct modlinkage ihid_modlinkage = {
	.ml_rev = MODREV_1,
	.ml_linkage = { &ihid_modldrv, NULL }
};

int
_init(void)
{
	int ret;

	if ((ret = ddi_soft_state_init(&ihid_state, sizeof (ihid_t), 1)) != 0)
		return (ret);
	if ((ret = mod_install(&ihid_modlinkage)) != 0)
		ddi_soft_state_fini(&ihid_state);
	return (ret);
}

int
_info(struct modinfo *modinfop)
{
	return (mod_info(&ihid_modlinkage, modinfop));
}

int
_fini(void)
{
	int ret;

	if ((ret = mod_remove(&ihid_modlinkage)) == 0)
		ddi_soft_state_fini(&ihid_state);
	return (ret);
}
