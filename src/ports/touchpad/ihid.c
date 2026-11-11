/*
 * ihid -- HID over I2C (Microsoft HID-over-I2C protocol 1.0) transport, on a
 * dwiic controller. Polled. A STREAMS driver shaped like usb hid(4D): it
 * answers usbms's HID_GET_PARSER_HANDLE and sends each input report up as
 * M_DATA ([report id][payload]), so consconfig_dacf (dacf.conf rule on
 * ihid:internal_mouse, pushmod usbms) links it under consms beside
 * mouse8042. The HID/report descriptors are also exported as
 * properties.
 *
 * Precision touchpads (tpad4): if the report descriptor has a Windows
 * Precision Touchpad collection (hidptp.c), ihid also has an evdev minor,
 * "event" (/dev/input/event<N>), which libinput opens through seatd. While
 * at least one evdev client is open the device runs in PTP mode (Input Mode
 * feature = 3): its multitouch reports become evdev events (multitouch
 * protocol B) on every client, and the mouse collection goes quiet. When the
 * last client closes, ihid sets the mode back to mouse (0), and the
 * consms/usbms path carries the pointer again. So a compositor that never
 * opens the node (any older BE) keeps the mouse-mode touchpad, and a
 * compositor that crashes gives it back. ihid_ptp = 0 (/etc/system
 * "set ihid:ihid_ptp = 0") hides the minor and keeps mouse mode only. The device sequence (descriptor, SET_POWER, RESET and its
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
#include <sys/systm.h>
#include <sys/debug.h>
#include <sys/ksynch.h>
#include <sys/time.h>
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
#include "hidptp.h"
/* acpica.h has its own BUS_PCI/BUS_ISA (unused here); evdev/input.h wins */
#undef	BUS_PCI
#undef	BUS_ISA
#include "evdev/input.h"

/* genunix, not in a header (usb hid.c declares it the same way) */
extern int ddi_create_internal_pathname(dev_info_t *, char *, int, minor_t);

#define	IHID_DESC_LEN		30
#define	LE16(p)	((uint16_t)((p)[0] | ((p)[1] << 8)))
#define	IHID_RDESC_MAX		4096
#define	IHID_POLL_US		10000

/* HID-over-I2C opcodes (spec 7.2) */
#define	IHID_OP_RESET		1
#define	IHID_OP_GET_REPORT	2
#define	IHID_OP_SET_REPORT	3
#define	IHID_OP_SET_POWER	8
#define	IHID_POWER_ON		0
#define	IHID_POWER_SLEEP	1

/*
 * evdev minors: the attach minor is the instance (internal_mouse, under
 * consms) or IHID_EV_BIT | instance ("event", the node /dev/input/event<N>
 * links to). An open of "event" clones: each client gets its own minor,
 * IHID_EV_BIT | (client + 1) << 8 | instance, so clients are separate
 * streams and none has the node's own minor.
 */
#define	IHID_EV_BIT		0x80
#define	IHID_INST(m)		((m) & 0x7f)
#define	IHID_MAX_CLIENTS	16
#define	IHID_EV_QMAX		(64 * 1024)	/* bytes queued per client */

/* libevdev reads 24-byte events: an LP64 struct timeval + 8 bytes */
CTASSERT(sizeof (struct input_event) == 24);

int ihid_ptp = 1;		/* 0: no evdev minor, mouse mode only */
int ihid_ptp_release_ms = 100;	/* no report for this long: lift all */
int ihid_ptp_fast_us = 3000;	/* poll interval while fingers are down */

/* _DSM GUID 3cdff6f7-4267-4555-ad05-b30a3d8938de, ToUUID byte order */
static uint8_t ihid_dsm_uuid[16] = {
	0xf7, 0xf6, 0xdf, 0x3c, 0x67, 0x42, 0x55, 0x45,
	0xad, 0x05, 0xb3, 0x0a, 0x3d, 0x89, 0x38, 0xde
};

struct ihid;

/*
 * q_ptr of a stream: the ihid_t itself (kind 0, the consms stream) or an
 * evdev client (kind 1). Both start with the kind.
 */
typedef struct ihid_cl {
	int		cl_kind;	/* 1 */
	struct ihid	*cl_ih;
	int		cl_idx;
} ihid_cl_t;

typedef struct ihid {
	int		ih_kind;	/* 0 */
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
	/* precision touchpad (ih_ptp_ok) and its evdev clients */
	bool		ih_ptp_ok;
	ptp_desc_t	ih_pd;
	ptp_state_t	ih_ps;		/* poller only, or under ih_mutex */
	int		ih_mode;	/* Input Mode last set: 0 mouse, 3 ptp */
	int		ih_cmax;	/* Contact Count Maximum (feature 2) */
	bool		ih_buttonpad;	/* Pad Type 0: the whole pad clicks */
	queue_t		*ih_ev[IHID_MAX_CLIENTS];	/* evdev client rqs */
	ihid_cl_t	ih_cl[IHID_MAX_CLIENTS];	/* their q_ptrs */
	bool		ih_revoked[IHID_MAX_CLIENTS];	/* EVIOCREVOKE'd */
	bool		ih_drop[IHID_MAX_CLIENTS];	/* owes SYN_DROPPED */
	int		ih_nev;		/* open clients */
	int		ih_evbusy;	/* poller putnext()s in flight */
	ksema_t		ih_modesem;	/* serialises opens, closes, mode */
	hrtime_t	ih_lastrep;	/* last PTP report */
	ptp_ev_t	ih_evbuf[PTP_MAX_EVENTS];	/* poller only */
} ihid_t;

enum { IHID_KS_POLLS, IHID_KS_REPORTS, IHID_KS_EMPTY, IHID_KS_ERRORS,
	IHID_KS_DROPPED, IHID_KS_MODE, IHID_KS_PTP_REPORTS, IHID_KS_FRAMES,
	IHID_KS_CONTACTS, IHID_KS_MAXCOUNT, IHID_KS_EVENTS, IHID_KS_EV_DROPPED,
	IHID_KS_CLIENTS, IHID_KS_IDLE_LIFTS, IHID_KS_N };
static const char *ihid_ks_names[IHID_KS_N] = { "polls", "reports",
	"empty", "errors", "dropped", "input_mode", "ptp_reports",
	"ptp_frames", "ptp_contacts", "ptp_max_contact_count", "ev_events",
	"ev_dropped", "ev_clients", "ptp_idle_lifts" };

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

/*
 * SET_REPORT / GET_REPORT of a feature report on the command register, data
 * through the data register (spec 7.2.2-7.2.3; framing as OpenBSD
 * ihidev_hid_command()). buf/len = the report without its id byte.
 */
static int
ihid_set_feature(ihid_t *ih, uint8_t id, const uint8_t *buf, uint16_t len)
{
	uint8_t w[16];
	uint16_t dreg = LE16(ih->ih_desc + 18), rl = 2 + 1 + len;
	int n = 0;

	if (len > sizeof (w) - 10)
		return (EINVAL);
	w[n++] = ih->ih_cmd_reg & 0xff;
	w[n++] = ih->ih_cmd_reg >> 8;
	w[n++] = (PTP_RT_FEATURE << 4) | (id >= 15 ? 15 : id);
	w[n++] = IHID_OP_SET_REPORT;
	if (id >= 15)
		w[n++] = id;
	w[n++] = dreg & 0xff;
	w[n++] = dreg >> 8;
	w[n++] = rl & 0xff;
	w[n++] = rl >> 8;
	w[n++] = id;
	bcopy(buf, w + n, len);
	return (ihid_xfer(ih, w, n + len, NULL, 0));
}

static int
ihid_get_feature(ihid_t *ih, uint8_t id, uint8_t *buf, uint16_t len)
{
	uint8_t w[8], r[24];
	uint16_t dreg = LE16(ih->ih_desc + 18);
	int n = 0, e;

	if (len > sizeof (r) - 3)
		return (EINVAL);
	w[n++] = ih->ih_cmd_reg & 0xff;
	w[n++] = ih->ih_cmd_reg >> 8;
	w[n++] = (PTP_RT_FEATURE << 4) | (id >= 15 ? 15 : id);
	w[n++] = IHID_OP_GET_REPORT;
	if (id >= 15)
		w[n++] = id;
	w[n++] = dreg & 0xff;
	w[n++] = dreg >> 8;
	if ((e = ihid_xfer(ih, w, n, r, 3 + len)) != 0)
		return (e);
	if (LE16(r) < 3 || r[2] != id)
		return (EIO);
	bcopy(r + 3, buf, len);
	return (0);
}

/* Input Mode feature: 0 = mouse, 3 = precision touchpad */
static int
ihid_set_mode(ihid_t *ih, int mode)
{
	uint8_t b[8] = { 0 };
	int e;

	if (ih->ih_pd.mode_len > sizeof (b))
		return (EINVAL);
	ptp_put(b, ih->ih_pd.mode_len, ih->ih_pd.mode, mode);
	e = ihid_set_feature(ih, ih->ih_pd.mode_rid, b, ih->ih_pd.mode_len);
	if (e == 0 && ih->ih_pd.sel_rid != 0 && mode == PTP_MODE_PTP &&
	    ih->ih_pd.sel_len <= sizeof (b)) {
		/* Surface and Button reporting on (the spec's default) */
		bzero(b, sizeof (b));
		ptp_put(b, ih->ih_pd.sel_len, ih->ih_pd.surface, 1);
		ptp_put(b, ih->ih_pd.sel_len, ih->ih_pd.button, 1);
		(void) ihid_set_feature(ih, ih->ih_pd.sel_rid, b,
		    ih->ih_pd.sel_len);
	}
	return (e);
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
 * evdev: events go to every client as 24-byte struct input_event M_DATA,
 * stamped with gethrtime() (CLOCK_MONOTONIC, the clock libinput asks for
 * with EVIOCSCLOCKID). A client that cannot take more is sent SYN_DROPPED
 * once its queue drains (libevdev then resyncs with the EVIOCG* ioctls).
 */
static void
ihid_ev_send(ihid_t *ih, const ptp_ev_t *ev, int n)
{
	hrtime_t now = gethrtime();
	queue_t *q, *qs[IHID_MAX_CLIENTS];
	mblk_t *mp, *ms[IHID_MAX_CLIENTS];
	int c, i, k = 0;

	if (n <= 0)
		return;
	mutex_enter(&ih->ih_mutex);
	for (c = 0; c < IHID_MAX_CLIENTS; c++) {
		struct input_event *ie;

		int d;

		if ((q = ih->ih_ev[c]) == NULL || ih->ih_revoked[c])
			continue;
		d = ih->ih_drop[c] ? 1 : 0;
		if (!canputnext(q) || (mp = allocb((d + n) * sizeof (*ie),
		    BPRI_HI)) == NULL) {
			ih->ih_drop[c] = true;
			ih->ih_kn[IHID_KS_EV_DROPPED].value.ui64 += n;
			continue;
		}
		/* after a drop: SYN_DROPPED, then libevdev resyncs (EVIOCG*) */
		for (i = -d; i < n; i++) {
			const ptp_ev_t drop = { EV_SYN, SYN_DROPPED, 0 };
			const ptp_ev_t *e = i < 0 ? &drop : &ev[i];
			ie = (struct input_event *)mp->b_wptr;
			ie->time.tv_sec = now / NANOSEC;
			ie->time.tv_usec = (now % NANOSEC) / 1000;
			ie->type = e->type;
			ie->code = e->code;
			ie->value = e->value;
			mp->b_wptr += sizeof (*ie);
		}
		ih->ih_drop[c] = false;
		ih->ih_kn[IHID_KS_EVENTS].value.ui64 += n;
		qs[k] = q;
		ms[k++] = mp;
	}
	/* no lock across putnext; close waits for ih_evbusy == 0 */
	ih->ih_evbusy++;
	mutex_exit(&ih->ih_mutex);
	for (i = 0; i < k; i++)
		putnext(qs[i], ms[i]);
	mutex_enter(&ih->ih_mutex);
	ih->ih_evbusy--;
	cv_broadcast(&ih->ih_cv);
	mutex_exit(&ih->ih_mutex);
}

static void
ihid_ptp_kstats(ihid_t *ih)
{
	ih->ih_kn[IHID_KS_FRAMES].value.ui64 = ih->ih_ps.frames;
	ih->ih_kn[IHID_KS_CONTACTS].value.ui64 = ih->ih_ps.contacts;
	ih->ih_kn[IHID_KS_MAXCOUNT].value.ui64 = ih->ih_ps.maxcount;
}

/* poller: one PTP report ([id][payload]) */
static void
ihid_ptp_report(ihid_t *ih, const uint8_t *r, uint32_t len)
{
	int n;

	mutex_enter(&ih->ih_mutex);
	ih->ih_lastrep = gethrtime();
	ih->ih_kn[IHID_KS_PTP_REPORTS].value.ui64++;
	n = ptp_input(&ih->ih_pd, &ih->ih_ps, r, len, ih->ih_evbuf,
	    PTP_MAX_EVENTS);
	ihid_ptp_kstats(ih);
	mutex_exit(&ih->ih_mutex);
	ihid_ev_send(ih, ih->ih_evbuf, n);
}

/*
 * poller: an empty poll. Polled, a lift can be missed (FreeBSD iichid adds
 * a zero-length "inactivity" report for the same reason): with contacts
 * down and no report for ihid_ptp_release_ms, lift them all.
 */
static void
ihid_ptp_idle(ihid_t *ih)
{
	int n = 0;

	mutex_enter(&ih->ih_mutex);
	if ((ih->ih_ps.ntouch > 0 || ih->ih_ps.btns != 0) &&
	    gethrtime() - ih->ih_lastrep > MSEC2NSEC(ihid_ptp_release_ms)) {
		n = ptp_release_all(&ih->ih_ps, ih->ih_evbuf, PTP_MAX_EVENTS);
		ih->ih_kn[IHID_KS_IDLE_LIFTS].value.ui64++;
		ihid_ptp_kstats(ih);
	}
	mutex_exit(&ih->ih_mutex);
	ihid_ev_send(ih, ih->ih_evbuf, n);
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
	bool fast;

	mutex_enter(&ih->ih_mutex);
	while (!ih->ih_stop) {
		if (!ih->ih_open && ih->ih_nev == 0) {
			cv_wait(&ih->ih_cv, &ih->ih_mutex);
			continue;
		}
		mutex_exit(&ih->ih_mutex);
		fast = false;
		e = ihid_xfer(ih, NULL, 0, ih->ih_ibuf, n);
		len = LE16(ih->ih_ibuf);
		/* PTP reports go to the evdev clients, not to usbms */
		if (ih->ih_ptp_ok && e == 0 && len > 2 && len <= n &&
		    ih->ih_ibuf[2] == ih->ih_pd.rid) {
			ihid_ptp_report(ih, ih->ih_ibuf + 2, len - 2);
			mutex_enter(&ih->ih_mutex);
			ih->ih_kn[IHID_KS_POLLS].value.ui64++;
			fast = true;	/* a hybrid frame is 1 report per finger */
			goto next;
		}
		if (ih->ih_ptp_ok && (e != 0 || len <= 2)) {
			ihid_ptp_idle(ih);
			/* fingers down: the next frame is due within ~8 ms */
			fast = ih->ih_ps.ntouch > 0;
		}
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
next:
		if (fast)
			(void) cv_timedwait_hires(&ih->ih_cv, &ih->ih_mutex,
			    USEC2NSEC(ihid_ptp_fast_us), USEC2NSEC(100), 0);
		else
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
	int inst = IHID_INST(getminor((dev_t)arg));
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

/*
 * An evdev open: a new client stream. The first client switches the device
 * to PTP mode (an I2C SET_REPORT, so the open may sleep ~1 ms).
 */
static int
ihid_ev_open(ihid_t *ih, queue_t *q, dev_t *devp, int flag, cred_t *cr)
{
	mblk_t *op;
	int c, e = 0;

	if (drv_priv(cr) != 0)
		return (EPERM);
	sema_p(&ih->ih_modesem);
	mutex_enter(&ih->ih_mutex);
	for (c = 0; c < IHID_MAX_CLIENTS && ih->ih_ev[c] != NULL; c++)
		;
	if (c == IHID_MAX_CLIENTS) {
		mutex_exit(&ih->ih_mutex);
		sema_v(&ih->ih_modesem);
		return (EBUSY);
	}
	mutex_exit(&ih->ih_mutex);
	if (ih->ih_mode != PTP_MODE_PTP) {
		if ((e = ihid_set_mode(ih, PTP_MODE_PTP)) != 0) {
			dev_err(ih->ih_dip, CE_WARN, "input mode 3: %d", e);
			sema_v(&ih->ih_modesem);
			return (EIO);
		}
		ih->ih_mode = PTP_MODE_PTP;
	}
	ih->ih_cl[c].cl_kind = 1;
	ih->ih_cl[c].cl_ih = ih;
	ih->ih_cl[c].cl_idx = c;
	q->q_ptr = WR(q)->q_ptr = &ih->ih_cl[c];
	*devp = makedevice(getmajor(*devp), IHID_EV_BIT | ((c + 1) << 8) |
	    ddi_get_instance(ih->ih_dip));
	qprocson(q);
	/* room for ~1 s of events if the compositor stalls */
	if ((op = allocb(sizeof (struct stroptions), BPRI_MED)) != NULL) {
		struct stroptions *so = (struct stroptions *)op->b_wptr;

		DB_TYPE(op) = M_SETOPTS;
		so->so_flags = SO_HIWAT | SO_LOWAT;
		so->so_hiwat = IHID_EV_QMAX;
		so->so_lowat = 1024;
		op->b_wptr += sizeof (*so);
		putnext(q, op);
	}
	mutex_enter(&ih->ih_mutex);
	ih->ih_ev[c] = q;
	ih->ih_revoked[c] = false;
	ih->ih_drop[c] = false;
	ih->ih_nev++;
	ih->ih_kn[IHID_KS_MODE].value.ui64 = ih->ih_mode;
	ih->ih_kn[IHID_KS_CLIENTS].value.ui64 = ih->ih_nev;
	cv_broadcast(&ih->ih_cv);	/* wake the poller */
	mutex_exit(&ih->ih_mutex);
	sema_v(&ih->ih_modesem);
	return (0);
}

static int
ihid_ev_close(ihid_t *ih, queue_t *q, int c)
{
	sema_p(&ih->ih_modesem);
	mutex_enter(&ih->ih_mutex);
	ASSERT(ih->ih_ev[c] == q);
	ih->ih_ev[c] = NULL;
	ih->ih_nev--;
	while (ih->ih_evbusy > 0)	/* a putnext to q may be in flight */
		cv_wait(&ih->ih_cv, &ih->ih_mutex);
	ih->ih_kn[IHID_KS_CLIENTS].value.ui64 = ih->ih_nev;
	mutex_exit(&ih->ih_mutex);
	qprocsoff(q);
	q->q_ptr = WR(q)->q_ptr = NULL;
	if (ih->ih_nev == 0 && ih->ih_mode != PTP_MODE_MOUSE) {
		/* back to mouse mode: consms carries the pointer again */
		(void) ihid_set_mode(ih, PTP_MODE_MOUSE);
		ih->ih_mode = PTP_MODE_MOUSE;
		mutex_enter(&ih->ih_mutex);
		ptp_state_init(&ih->ih_ps, ih->ih_cmax);	/* no client left */
		ih->ih_kn[IHID_KS_MODE].value.ui64 = ih->ih_mode;
		mutex_exit(&ih->ih_mutex);
	}
	sema_v(&ih->ih_modesem);
	return (0);
}

static int
ihid_open(queue_t *q, dev_t *devp, int flag, int sflag, cred_t *cr)
{
	minor_t m = getminor(*devp);
	ihid_t *ih = ddi_get_soft_state(ihid_state, IHID_INST(m));

	if (ih == NULL)
		return (ENXIO);
	if (m & IHID_EV_BIT) {
		if (sflag != 0 || !ih->ih_ptp_ok)
			return (ENXIO);
		if (q->q_ptr != NULL)	/* a re-open of a client's minor */
			return (0);
		return (ihid_ev_open(ih, q, devp, flag, cr));
	}
	if (m != (minor_t)ddi_get_instance(ih->ih_dip))
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
	ihid_cl_t *cl = q->q_ptr;

	if (cl->cl_kind == 1)
		return (ihid_ev_close(cl->cl_ih, q, cl->cl_idx));
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

/* EVIOCGMTSLOTS state between its copyin and copyout */
typedef struct ihid_mts {
	size_t		ulen;
	caddr_t		uaddr;
} ihid_mts_t;
#define	IHID_MTS_MAX	(sizeof (uint32_t) + 256 * sizeof (int32_t))

/* bit helpers for the EVIOCGBIT/GPROP/GKEY answers */
#define	IHID_SETBIT(a, b)	((a)[(b) / 8] |= 1 << ((b) % 8))

static size_t
ihid_ev_bits(ihid_t *ih, int ev, uint8_t *b, size_t max)
{
	bzero(b, max);
	switch (ev) {
	case 0:
		IHID_SETBIT(b, EV_SYN);
		IHID_SETBIT(b, EV_KEY);
		IHID_SETBIT(b, EV_ABS);
		if (ih->ih_pd.scantime.size)
			IHID_SETBIT(b, EV_MSC);
		return (EV_CNT / 8);
	case EV_KEY:
		IHID_SETBIT(b, BTN_LEFT);
		if (ih->ih_pd.nbuttons > 1)
			IHID_SETBIT(b, BTN_RIGHT);
		if (ih->ih_pd.nbuttons > 2)
			IHID_SETBIT(b, BTN_MIDDLE);
		IHID_SETBIT(b, BTN_TOUCH);
		IHID_SETBIT(b, BTN_TOOL_FINGER);
		IHID_SETBIT(b, BTN_TOOL_DOUBLETAP);
		IHID_SETBIT(b, BTN_TOOL_TRIPLETAP);
		IHID_SETBIT(b, BTN_TOOL_QUADTAP);
		IHID_SETBIT(b, BTN_TOOL_QUINTTAP);
		return (KEY_CNT / 8);
	case EV_ABS:
		IHID_SETBIT(b, ABS_X);
		IHID_SETBIT(b, ABS_Y);
		IHID_SETBIT(b, ABS_MT_SLOT);
		IHID_SETBIT(b, ABS_MT_POSITION_X);
		IHID_SETBIT(b, ABS_MT_POSITION_Y);
		IHID_SETBIT(b, ABS_MT_TRACKING_ID);
		return (ABS_CNT / 8);
	case EV_MSC:
		if (ih->ih_pd.scantime.size)
			IHID_SETBIT(b, MSC_TIMESTAMP);
		return (MSC_CNT / 8);
	case EV_REL:
		return (REL_CNT / 8);
	case EV_LED:
		return (LED_CNT / 8);
	case EV_SW:
		return (SW_CNT / 8);
	case EV_SND:
		return (SND_CNT / 8);
	case EV_FF:
		return (FF_CNT / 8);
	default:
		return (0);
	}
}

static bool
ihid_ev_absinfo(ihid_t *ih, int code, struct input_absinfo *ai)
{
	ptp_state_t *ps = &ih->ih_ps;

	bzero(ai, sizeof (*ai));
	switch (code) {
	case ABS_X:
	case ABS_MT_POSITION_X:
		ai->minimum = ih->ih_pd.xmin;
		ai->maximum = ih->ih_pd.xmax;
		ai->resolution = ih->ih_pd.xres;
		ai->value = code == ABS_X ? ps->stx : 0;
		return (true);
	case ABS_Y:
	case ABS_MT_POSITION_Y:
		ai->minimum = ih->ih_pd.ymin;
		ai->maximum = ih->ih_pd.ymax;
		ai->resolution = ih->ih_pd.yres;
		ai->value = code == ABS_Y ? ps->sty : 0;
		return (true);
	case ABS_MT_SLOT:
		ai->maximum = ps->nslots - 1;
		ai->value = ps->slot;
		return (true);
	case ABS_MT_TRACKING_ID:
		ai->minimum = -1;
		ai->maximum = 0xffff;
		return (true);
	default:
		return (false);
	}
}

/* copy `len` bytes of `src` out to the TRANSPARENT ioctl's user address */
static void
ihid_ev_copyout(queue_t *q, mblk_t *mp, const void *src, size_t len)
{
	mblk_t *dp;

	if (len == 0) {		/* nothing to copy (EVIOCGBIT of an unused type) */
		miocack(q, mp, 0, 0);
		return;
	}
	if ((dp = allocb(len, BPRI_HI)) == NULL) {
		miocnak(q, mp, 0, ENOMEM);
		return;
	}
	bcopy(src, dp->b_wptr, len);
	mcopyout(mp, NULL, len, NULL, dp);
	qreply(q, mp);
}

/*
 * evdev ioctls. STREAMS delivers them TRANSPARENT; the size bits of the
 * command (FreeBSD layout, evdev/input.h) give the user buffer length for
 * the variable-length ones. ioctls that change nothing on a touchpad
 * (EVIOCGRAB, EVIOCSCLOCKID) are ACKed.
 */
static void
ihid_ev_ioctl(ihid_t *ih, int c, queue_t *q, mblk_t *mp)
{
	struct iocblk *iocp = (struct iocblk *)mp->b_rptr;
	int cmd = iocp->ioc_cmd, nr = cmd & 0xff, i;
	size_t ulen = ((uint32_t)cmd >> 16) & 0x1fff, n;
	uint8_t buf[KEY_CNT / 8];
	char name[64];
	struct input_id id;
	struct input_absinfo ai;
	int ver = EV_VERSION;

	if (iocp->ioc_count != TRANSPARENT || ((cmd >> 8) & 0xff) != 'E') {
		miocnak(q, mp, 0, EINVAL);
		return;
	}
	switch (cmd) {
	case EVIOCGVERSION:
		ihid_ev_copyout(q, mp, &ver, sizeof (ver));
		return;
	case EVIOCGID:
		id.bustype = BUS_I2C;
		id.vendor = LE16(ih->ih_desc + 20);
		id.product = LE16(ih->ih_desc + 22);
		id.version = LE16(ih->ih_desc + 24);
		ihid_ev_copyout(q, mp, &id, sizeof (id));
		return;
	case EVIOCGRAB:
	case EVIOCSCLOCKID:
		miocack(q, mp, 0, 0);
		return;
	case EVIOCREVOKE:
		/* seatd: this client loses the device (session switch) */
		mutex_enter(&ih->ih_mutex);
		ih->ih_revoked[c] = true;
		mutex_exit(&ih->ih_mutex);
		miocack(q, mp, 0, 0);
		(void) putnextctl1(RD(q), M_ERROR, ENODEV);
		return;
	}
	switch (nr) {
	case 0x06:	/* EVIOCGNAME */
		n = snprintf(name, sizeof (name), "ELAN %04X:%04X Touchpad",
		    LE16(ih->ih_desc + 20), LE16(ih->ih_desc + 22)) + 1;
		ihid_ev_copyout(q, mp, name, MIN(n, ulen));
		return;
	case 0x07:	/* EVIOCGPHYS */
		n = snprintf(name, sizeof (name), "i2c-dwiic/0x%x",
		    ih->ih_addr) + 1;
		ihid_ev_copyout(q, mp, name, MIN(n, ulen));
		return;
	case 0x08:	/* EVIOCGUNIQ: none */
		miocnak(q, mp, 0, ENOENT);
		return;
	case 0x09:	/* EVIOCGPROP */
		bzero(buf, sizeof (buf));
		IHID_SETBIT(buf, INPUT_PROP_POINTER);
		if (ih->ih_buttonpad)
			IHID_SETBIT(buf, INPUT_PROP_BUTTONPAD);
		ihid_ev_copyout(q, mp, buf, MIN(INPUT_PROP_CNT / 8, ulen));
		return;
	case 0x18:	/* EVIOCGKEY: key state */
		bzero(buf, sizeof (buf));
		mutex_enter(&ih->ih_mutex);
		if (ih->ih_ps.btns & 1)
			IHID_SETBIT(buf, BTN_LEFT);
		if (ih->ih_ps.ntouch > 0) {
			static const uint16_t t[5] = { BTN_TOOL_FINGER,
			    BTN_TOOL_DOUBLETAP, BTN_TOOL_TRIPLETAP,
			    BTN_TOOL_QUADTAP, BTN_TOOL_QUINTTAP };
			IHID_SETBIT(buf, BTN_TOUCH);
			IHID_SETBIT(buf, t[MIN(ih->ih_ps.ntouch, 5) - 1]);
		}
		mutex_exit(&ih->ih_mutex);
		ihid_ev_copyout(q, mp, buf, MIN(KEY_CNT / 8, ulen));
		return;
	case 0x19:	/* EVIOCGLED */
	case 0x1a:	/* EVIOCGSND */
	case 0x1b:	/* EVIOCGSW */
		bzero(buf, sizeof (buf));
		ihid_ev_copyout(q, mp, buf, MIN(sizeof (buf), ulen));
		return;
	case 0x0a: {	/* EVIOCGMTSLOTS: copy in the code first */
		mblk_t *pm;
		ihid_mts_t *mts;

		if (ulen < sizeof (uint32_t) || ulen > IHID_MTS_MAX ||
		    mp->b_cont == NULL ||
		    (pm = allocb(sizeof (*mts), BPRI_HI)) == NULL) {
			miocnak(q, mp, 0, EINVAL);
			return;
		}
		mts = (ihid_mts_t *)pm->b_rptr;
		mts->ulen = ulen;
		mts->uaddr = *(caddr_t *)mp->b_cont->b_rptr;
		pm->b_wptr += sizeof (*mts);
		mcopyin(mp, pm, sizeof (uint32_t), NULL);
		qreply(q, mp);
		return;
	}
	}
	if (nr >= 0x20 && nr < 0x20 + EV_CNT) {	/* EVIOCGBIT */
		n = ihid_ev_bits(ih, nr - 0x20, buf, sizeof (buf));
		ihid_ev_copyout(q, mp, buf, MIN(n, ulen));
		return;
	}
	if (nr >= 0x40 && nr < 0x40 + ABS_CNT &&
	    ulen == sizeof (struct input_absinfo)) {	/* EVIOCGABS */
		mutex_enter(&ih->ih_mutex);
		i = ihid_ev_absinfo(ih, nr - 0x40, &ai);
		mutex_exit(&ih->ih_mutex);
		if (!i) {
			miocnak(q, mp, 0, EINVAL);
			return;
		}
		ihid_ev_copyout(q, mp, &ai, sizeof (ai));
		return;
	}
	miocnak(q, mp, 0, EINVAL);	/* EVIOCSABS, EVIOCSFF, keymaps, ... */
}

/*
 * M_IOCDATA: the stream head's answer to our M_COPYIN or M_COPYOUT.
 * cp_private is the ihid_mts_t of an EVIOCGMTSLOTS whose code has just
 * been copied in, or NULL at the end of every copyout.
 */
static void
ihid_ev_iocdata(ihid_t *ih, queue_t *q, mblk_t *mp)
{
	struct copyresp *cp = (struct copyresp *)mp->b_rptr;
	mblk_t *pm = cp->cp_private;
	size_t ulen;
	caddr_t uaddr;
	uint32_t code;
	int32_t *v;
	mblk_t *dp;
	int s, ns;

	if (cp->cp_rval != 0) {
		freemsg(pm);
		freemsg(mp);	/* copy failed: the stream head returns EFAULT */
		return;
	}
	if (pm == NULL) {	/* a copyout finished */
		miocack(q, mp, 0, 0);
		return;
	}
	ulen = ((ihid_mts_t *)pm->b_rptr)->ulen;
	uaddr = ((ihid_mts_t *)pm->b_rptr)->uaddr;
	freemsg(pm);
	cp->cp_private = NULL;
	/* the EVIOCGMTSLOTS code arrived: answer with the slot values */
	if (mp->b_cont == NULL || MBLKL(mp->b_cont) < sizeof (code)) {
		miocnak(q, mp, 0, EINVAL);
		return;
	}
	bcopy(mp->b_cont->b_rptr, &code, sizeof (code));
	if ((dp = allocb(ulen, BPRI_HI)) == NULL) {
		miocnak(q, mp, 0, ENOMEM);
		return;
	}
	bzero(dp->b_wptr, ulen);
	bcopy(&code, dp->b_wptr, sizeof (code));
	v = (int32_t *)(dp->b_wptr + sizeof (code));
	ns = (ulen - sizeof (code)) / sizeof (int32_t);
	mutex_enter(&ih->ih_mutex);
	for (s = 0; s < ns; s++) {
		if (s >= ih->ih_ps.nslots) {
			v[s] = code == ABS_MT_TRACKING_ID ? -1 : 0;
			continue;
		}
		switch (code) {
		case ABS_MT_TRACKING_ID:
			v[s] = ih->ih_ps.s[s].tid;
			break;
		case ABS_MT_POSITION_X:
			v[s] = ih->ih_ps.s[s].x;
			break;
		case ABS_MT_POSITION_Y:
			v[s] = ih->ih_ps.s[s].y;
			break;
		}
	}
	mutex_exit(&ih->ih_mutex);
	mcopyout(mp, NULL, ulen, uaddr, dp);
	qreply(q, mp);
}

/* the evdev clients' write side */
static void
ihid_ev_wput(ihid_t *ih, int c, queue_t *q, mblk_t *mp)
{
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
	case M_IOCTL:
		ihid_ev_ioctl(ih, c, q, mp);
		break;
	case M_IOCDATA:
		ihid_ev_iocdata(ih, q, mp);
		break;
	default:
		freemsg(mp);	/* writes (uinput-style injection) unsupported */
		break;
	}
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
	ihid_cl_t *cl = q->q_ptr;
	struct iocblk *iocp;

	if (cl->cl_kind == 1) {
		ihid_ev_wput(cl->cl_ih, cl->cl_idx, q, mp);
		return (0);
	}
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
	sema_destroy(&ih->ih_modesem);
	ddi_soft_state_free(ihid_state, inst);
}

/*
 * Is this a precision touchpad? Parse the descriptor; read Contact Count
 * Maximum and Pad Type (feature report, GET_REPORT); the device stays in
 * mouse mode (its power-on default) until an evdev client opens.
 */
static void
ihid_ptp_attach(ihid_t *ih)
{
	uint8_t b[8];

	if (ptp_parse_desc(ih->ih_rdesc, ih->ih_rdesc_len, &ih->ih_pd) != 0 ||
	    1 + ih->ih_pd.rlen > ih->ih_max_input - 2)
		return;
	ih->ih_cmax = PTP_MAX_FINGERS;
	ih->ih_buttonpad = true;
	if (ih->ih_pd.cmax_rid != 0 && ih->ih_pd.cmax_len <= sizeof (b) &&
	    ihid_get_feature(ih, ih->ih_pd.cmax_rid, b,
	    ih->ih_pd.cmax_len) == 0) {
		int cm = ptp_get(b, ih->ih_pd.cmax_len, ih->ih_pd.cmax);
		if (cm > 0 && cm <= PTP_MAX_SLOTS)
			ih->ih_cmax = cm;
		if (ih->ih_pd.padtype.size)	/* 0 = depressible (clickpad) */
			ih->ih_buttonpad = ptp_get(b, ih->ih_pd.cmax_len,
			    ih->ih_pd.padtype) == 0;
	}
	ptp_state_init(&ih->ih_ps, ih->ih_cmax);
	ih->ih_mode = PTP_MODE_MOUSE;
	ih->ih_ptp_ok = true;
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
	sema_init(&ih->ih_modesem, 1, NULL, SEMA_DRIVER, NULL);

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
	ihid_ptp_attach(ih);
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
	if (ih->ih_ptp_ok && ihid_ptp) {
		static char *props[] = { "ID_INPUT=1", "ID_INPUT_TOUCHPAD=1" };
		/* /dev/input/event<N> (devlink.tab: ddi_input:evdev) */
		if (ddi_create_minor_node(dip, "event", S_IFCHR,
		    IHID_EV_BIT | inst, "ddi_input:evdev", 0) != DDI_SUCCESS)
			goto fail;
		/* what the solnix libudev reports for the node */
		(void) ddi_prop_update_string_array(DDI_DEV_T_NONE, dip,
		    "udev-properties", props, 2);
	}
	ih->ih_thread = thread_create(NULL, 0, ihid_poll_thread, ih, 0, &p0,
	    TS_RUN, minclsyspri);
	ih->ih_tid = ih->ih_thread->t_did;

	dev_err(dip, CE_CONT, "?HID over I2C 0x%x: vid %04x pid %04x, "
	    "report descriptor %u bytes, input %u bytes, irq %d (polled)\n",
	    ih->ih_addr, LE16(ih->ih_desc + 20), LE16(ih->ih_desc + 22),
	    ih->ih_rdesc_len, ih->ih_max_input, crs.ic_irq);
	if (ih->ih_ptp_ok)
		dev_err(dip, CE_CONT, "?precision touchpad: report %u, %d "
		    "contacts, %s, x 0..%d y 0..%d%s\n", ih->ih_pd.rid,
		    ih->ih_cmax, ih->ih_buttonpad ? "clickpad" : "buttons",
		    ih->ih_pd.xmax, ih->ih_pd.ymax,
		    ihid_ptp ? "" : " (evdev off: ihid_ptp = 0)");
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
	if (ih->ih_open || ih->ih_nev > 0) {
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
	.drv_linkinfo = "HID over I2C (polled, PTP)",
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
