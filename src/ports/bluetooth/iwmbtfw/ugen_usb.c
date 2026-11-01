/*
 * libusb-1.0 subset over illumos ugen(4D) (solnix, new code). See compat/libusb.h.
 *
 * ugen semantics this relies on (ugen.4d, usba_ugen.c at gate ac45d71fc2):
 *  - control: write(setup[8] + data) for OUT; write(setup) then read for IN.
 *  - interrupt-IN: polling starts at open and stops at close; packets are
 *    coalesced into one buffer; a blocking read waits for the FULL count, so
 *    we open O_NONBLOCK and wait with poll(2) (the only ugen node poll works on).
 *  - bulk: blocking read/write; ugen's own 10 s request timeout bounds them.
 */
#include <sys/types.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/usb/clients/ugen/usb_ugen.h>
#include "compat/libusb.h"
#include "ugen_evq.h"

struct libusb_device {
	char		dir[PATH_MAX - 32];
	uint16_t	vid, pid;
	int		refs;
};

struct libusb_device_handle {
	libusb_device	*dev;
	int		ctrl, intr, intrstat, bin, bout;
	struct ugen_evq	q;
};

/* Node paths are <dir>/<node> with node names up to 16 chars. */
static char ugen_dir[PATH_MAX - 32];

int
ugen_usb_set_dir(const char *dir)
{
	if (strlen(dir) >= sizeof (ugen_dir))
		return (-1);
	(void) strcpy(ugen_dir, dir);
	return (0);
}

int
libusb_init(libusb_context **ctx)
{
	*ctx = (libusb_context *)ugen_dir;	/* opaque, never dereferenced */
	return (ugen_dir[0] == '\0' ? LIBUSB_ERROR_NOT_FOUND : 0);
}

void
libusb_exit(libusb_context *ctx)
{
	(void) ctx;
}

/* "/dev/usb/8087.33/0" -> vid 0x8087, pid 0x0033 (ugen's <vid>.<pid> naming). */
static int
ugen_parse_ids(const char *dir, uint16_t *vid, uint16_t *pid)
{
	const char *s = strstr(dir, "/usb/");
	unsigned int v, p;

	if (s == NULL || sscanf(s + 5, "%x.%x", &v, &p) != 2 ||
	    v > 0xffff || p > 0xffff)
		return (-1);
	*vid = (uint16_t)v;
	*pid = (uint16_t)p;
	return (0);
}

/* One device: the ugen directory set with ugen_usb_set_dir(). */
ssize_t
libusb_get_device_list(libusb_context *ctx, libusb_device ***list)
{
	libusb_device **l;
	libusb_device *d;
	char path[PATH_MAX];

	(void) ctx;
	(void) snprintf(path, sizeof (path), "%s/cntrl0", ugen_dir);
	if (access(path, F_OK) != 0)
		return (LIBUSB_ERROR_NO_DEVICE);
	if ((l = calloc(2, sizeof (*l))) == NULL ||
	    (d = calloc(1, sizeof (*d))) == NULL) {
		free(l);
		return (LIBUSB_ERROR_OTHER);
	}
	(void) strcpy(d->dir, ugen_dir);
	if (ugen_parse_ids(d->dir, &d->vid, &d->pid) != 0) {
		free(d);
		free(l);
		return (LIBUSB_ERROR_INVALID_PARAM);
	}
	d->refs = 1;
	l[0] = d;
	*list = l;
	return (1);
}

void
libusb_free_device_list(libusb_device **list, int unref)
{
	if (list == NULL)
		return;
	if (unref)
		for (int i = 0; list[i] != NULL; i++)
			libusb_unref_device(list[i]);
	free(list);
}

libusb_device *
libusb_ref_device(libusb_device *d)
{
	d->refs++;
	return (d);
}

void
libusb_unref_device(libusb_device *d)
{
	if (d != NULL && --d->refs == 0)
		free(d);
}

/* iwmbtfw selects the device by bus.addr; our one device is "ugen0.0". */
uint8_t
libusb_get_bus_number(libusb_device *d)
{
	(void) d;
	return (0);
}

uint8_t
libusb_get_device_address(libusb_device *d)
{
	(void) d;
	return (0);
}

int
libusb_get_device_descriptor(libusb_device *d,
    struct libusb_device_descriptor *dd)
{
	(void) memset(dd, 0, sizeof (*dd));
	dd->bLength = 18;
	dd->bDescriptorType = 1;
	dd->idVendor = d->vid;
	dd->idProduct = d->pid;
	dd->bNumConfigurations = 1;
	return (0);
}

static int
ugen_open_node(const char *dir, const char *node, int flags)
{
	char path[PATH_MAX];

	(void) snprintf(path, sizeof (path), "%s/%s", dir, node);
	return (open(path, flags));
}

/*
 * Open every node iwmbtfw uses, interrupt-IN first: ugen starts polling it
 * at open, so no event that answers a later command can be missed.
 */
int
libusb_open(libusb_device *d, libusb_device_handle **hp)
{
	libusb_device_handle *h;

	if ((h = calloc(1, sizeof (*h))) == NULL)
		return (LIBUSB_ERROR_OTHER);
	h->dev = libusb_ref_device(d);
	ugen_evq_init(&h->q);
	h->intrstat = ugen_open_node(d->dir, "if0in1stat", O_RDONLY);
	h->intr = ugen_open_node(d->dir, "if0in1", O_RDONLY | O_NONBLOCK);
	h->ctrl = ugen_open_node(d->dir, "cntrl0", O_RDWR);
	h->bout = ugen_open_node(d->dir, "if0out2", O_WRONLY);
	h->bin = ugen_open_node(d->dir, "if0in2", O_RDONLY);
	if (h->intrstat < 0 || h->intr < 0 || h->ctrl < 0 || h->bout < 0 ||
	    h->bin < 0) {
		int e = errno;

		libusb_close(h);
		return (e == EACCES || e == EPERM ? LIBUSB_ERROR_ACCESS :
		    LIBUSB_ERROR_IO);
	}
	*hp = h;
	return (0);
}

void
libusb_close(libusb_device_handle *h)
{
	if (h == NULL)
		return;
	if (h->bin >= 0)
		(void) close(h->bin);
	if (h->bout >= 0)
		(void) close(h->bout);
	if (h->ctrl >= 0)
		(void) close(h->ctrl);
	if (h->intr >= 0)
		(void) close(h->intr);
	if (h->intrstat >= 0)
		(void) close(h->intrstat);
	libusb_unref_device(h->dev);
	free(h);
}

/* No Bluetooth kernel driver exists on illumos; ugen (usb_mid) owns the device. */
int
libusb_kernel_driver_active(libusb_device_handle *h, int iface)
{
	(void) h;
	(void) iface;
	return (0);
}

/*
 * ugen has no userland reset. The Intel controller does not need one: the
 * Intel Reset command (0xfc01) boots the operational image in place, which
 * iwmbtfw confirms (vendor event 0x02) before it gets here.
 */
int
libusb_reset_device(libusb_device_handle *h)
{
	(void) h;
	return (LIBUSB_ERROR_NOT_SUPPORTED);
}

/* Map a ugen endpoint status (usb_ugen.h USB_LC_STAT_*) to libusb. */
static int
ugen_st2err(int st)
{
	switch (st) {
	case USB_LC_STAT_TIMEOUT:
		return (LIBUSB_ERROR_TIMEOUT);
	case USB_LC_STAT_STALL:
		return (LIBUSB_ERROR_PIPE);
	case USB_LC_STAT_DISCONNECTED:
		return (LIBUSB_ERROR_NO_DEVICE);
	case USB_LC_STAT_DATA_OVERRUN:
	case USB_LC_STAT_BUFFER_OVERRUN:
		return (LIBUSB_ERROR_OVERFLOW);
	default:
		return (LIBUSB_ERROR_IO);
	}
}

int
libusb_control_transfer(libusb_device_handle *h, uint8_t rt, uint8_t req,
    uint16_t val, uint16_t idx, unsigned char *data, uint16_t len,
    unsigned int timeout)
{
	unsigned char buf[8 + 65535];
	ssize_t n;

	(void) timeout;		/* ugen_ctrl_timeout (10 s) applies */
	buf[0] = rt;
	buf[1] = req;
	buf[2] = val & 0xff;
	buf[3] = val >> 8;
	buf[4] = idx & 0xff;
	buf[5] = idx >> 8;
	buf[6] = len & 0xff;
	buf[7] = len >> 8;
	if ((rt & LIBUSB_ENDPOINT_IN) == 0) {
		if (len > 0)
			(void) memcpy(buf + 8, data, len);
		n = write(h->ctrl, buf, 8 + (size_t)len);
		if (n != 8 + (ssize_t)len)
			return (LIBUSB_ERROR_IO);
		return (len);
	}
	if (write(h->ctrl, buf, 8) != 8)
		return (LIBUSB_ERROR_IO);
	n = read(h->ctrl, data, len);
	return (n < 0 ? LIBUSB_ERROR_IO : (int)n);
}

/* Bulk: endpoint 0x02 OUT / 0x82 IN only (iwmbtfw's two). ugen bounds both at 10 s. */
int
libusb_bulk_transfer(libusb_device_handle *h, unsigned char ep,
    unsigned char *data, int len, int *xfer, unsigned int timeout)
{
	ssize_t n;

	(void) timeout;
	*xfer = 0;
	if (ep == 0x02)
		n = write(h->bout, data, (size_t)len);
	else if (ep == 0x82)
		n = read(h->bin, data, (size_t)len);
	else
		return (LIBUSB_ERROR_INVALID_PARAM);
	if (n < 0)
		return (LIBUSB_ERROR_IO);
	*xfer = (int)n;
	return (0);
}

static long
ugen_ms_left(const struct timespec *end)
{
	struct timespec now;

	(void) clock_gettime(CLOCK_MONOTONIC, &now);
	return ((end->tv_sec - now.tv_sec) * 1000 +
	    (end->tv_nsec - now.tv_nsec) / 1000000);
}

/*
 * Interrupt-IN 0x81: one HCI event per call (see ugen_evq.c), like libusb on
 * a real interrupt pipe. An event larger than len is LIBUSB_ERROR_OVERFLOW.
 */
int
libusb_interrupt_transfer(libusb_device_handle *h, unsigned char ep,
    unsigned char *data, int len, int *xfer, unsigned int timeout)
{
	struct timespec end;
	struct pollfd pfd;
	uint8_t tmp[sizeof (h->q.buf)];
	size_t full;
	ssize_t n;
	long ms;
	int r;

	*xfer = 0;
	if (ep != 0x81 || len <= 0)
		return (LIBUSB_ERROR_INVALID_PARAM);
	(void) clock_gettime(CLOCK_MONOTONIC, &end);
	end.tv_sec += timeout / 1000;
	end.tv_nsec += (long)(timeout % 1000) * 1000000;
	if (end.tv_nsec >= 1000000000L) {
		end.tv_sec++;
		end.tv_nsec -= 1000000000L;
	}
	for (;;) {
		r = ugen_evq_pop(&h->q, data, (size_t)len, &full);
		if (r != 0) {
			*xfer = r > 0 ? r : len;
			return (r > 0 ? 0 : LIBUSB_ERROR_OVERFLOW);
		}
		if ((ms = ugen_ms_left(&end)) <= 0) {
			ugen_usb_diag(h, "interrupt-IN timeout");
			return (LIBUSB_ERROR_TIMEOUT);
		}
		pfd.fd = h->intr;
		pfd.events = POLLIN;
		pfd.revents = 0;
		if (poll(&pfd, 1, (int)ms) < 0 && errno != EINTR)
			return (LIBUSB_ERROR_IO);
		n = read(h->intr, tmp, ugen_evq_room(&h->q));
		if (n > 0) {
			ugen_evq_push(&h->q, tmp, (size_t)n);
		} else if (n == 0) {
			(void) usleep(1000);	/* no data yet: don't spin */
		} else {
			/* buffer-full: ugen restarted polling; anything else is fatal */
			int st = 0;

			if (read(h->intrstat, &st, sizeof (st)) != sizeof (st))
				return (LIBUSB_ERROR_IO);
			if (st == USB_LC_STAT_INTR_BUF_FULL)
				continue;
			return (ugen_st2err(st));
		}
	}
}

const char *
libusb_strerror(int e)
{
	switch (e) {
	case LIBUSB_SUCCESS:
		return ("Success");
	case LIBUSB_ERROR_IO:
		return ("Input/Output Error");
	case LIBUSB_ERROR_INVALID_PARAM:
		return ("Invalid parameter");
	case LIBUSB_ERROR_ACCESS:
		return ("Access denied (insufficient permissions)");
	case LIBUSB_ERROR_NO_DEVICE:
		return ("No such device (it may have been disconnected)");
	case LIBUSB_ERROR_NOT_FOUND:
		return ("Entity not found");
	case LIBUSB_ERROR_TIMEOUT:
		return ("Operation timed out");
	case LIBUSB_ERROR_OVERFLOW:
		return ("Overflow");
	case LIBUSB_ERROR_PIPE:
		return ("Pipe error");
	case LIBUSB_ERROR_NOT_SUPPORTED:
		return ("Operation not supported or unimplemented on this platform");
	default:
		return ("Other error");
	}
}

/*
 * Non-blocking state dump. devstat is opened O_NONBLOCK: a blocking devstat
 * read waits for the NEXT state change (usba_ugen.c ugen_ds_req). intrstat
 * reads never block (ugen_eps_req returns ep_lcmd_status).
 */
void
ugen_usb_diag(libusb_device_handle *h, const char *why)
{
	char path[PATH_MAX];
	int fd, ds = -1, es = -1;

	(void) snprintf(path, sizeof (path), "%s/devstat", h->dev->dir);
	if ((fd = open(path, O_RDONLY | O_NONBLOCK)) >= 0) {
		if (read(fd, &ds, sizeof (ds)) != sizeof (ds))
			ds = -1;
		(void) close(fd);
	}
	if (read(h->intrstat, &es, sizeof (es)) != sizeof (es))
		es = -1;
	fprintf(stderr, "ugen-diag (%s): devstat=%d%s if0in1stat=0x%x "
	    "queued=%zu\n", why, ds, fd < 0 ? " (open failed: busy?)" : "",
	    es, h->q.len);
}
