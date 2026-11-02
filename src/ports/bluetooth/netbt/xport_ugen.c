/*
 * xport_ugen.c: the netbt core's transport over ugen(4D), through bt1's
 * libusb subset (../iwmbtfw/ugen_usb.c, with its interrupt-IN toggle reset at
 * open, docs/design-bluetooth.md 9). Commands: class request bRequest 0 on the
 * default pipe (ubt_xmit_cmd_start). Events: interrupt-IN 0x81, one HCI event
 * per call (ugen_evq.c rebuilds event boundaries).
 */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <libusb.h>	/* ../iwmbtfw/compat/libusb.h */
#include "xport.h"

struct ugen_x {
	const char		*dir;
	int			noclear;
	libusb_context		*ctx;
	libusb_device_handle	*h;
};

static int
ux_open(void *a)
{
	struct ugen_x *u = a;
	libusb_device **list = NULL;
	int r;

	if (u->h != NULL)
		return (0);
	ugen_usb_set_noclear(u->noclear);
	ugen_usb_set_quiet(1);
	if (ugen_usb_set_dir(u->dir) != 0 || libusb_init(&u->ctx) != 0)
		return (-1);
	if (libusb_get_device_list(u->ctx, &list) != 1) {
		libusb_free_device_list(list, 1);
		return (-1);
	}
	r = libusb_open(list[0], &u->h);
	libusb_free_device_list(list, 1);
	if (r != 0) {
		fprintf(stderr, "ugen open %s: %s\n", u->dir, libusb_strerror(r));
		u->h = NULL;
		return (-1);
	}
	return (0);
}

static void
ux_close(void *a)
{
	struct ugen_x *u = a;

	libusb_close(u->h);
	u->h = NULL;
}

static int
ux_send_cmd(void *a, const uint8_t *p, size_t n)
{
	struct ugen_x *u = a;
	uint8_t buf[3 + 255];

	if (u->h == NULL || n < 3 || n > sizeof (buf))
		return (-1);
	memcpy(buf, p, n);
	return (libusb_control_transfer(u->h, LIBUSB_REQUEST_TYPE_CLASS |
	    LIBUSB_RECIPIENT_DEVICE, 0, 0, 0, buf, (uint16_t)n, 2000) ==
	    (int)n ? 0 : -1);
}

static int
ux_recv_evt(void *a, uint8_t *p, size_t n, int ms)
{
	struct ugen_x *u = a;
	int got = 0, r;

	if (u->h == NULL)
		return (-1);
	/* ms 0 still reads once: the shim returns at once when nothing is queued */
	r = libusb_interrupt_transfer(u->h, 0x81, p, (int)n, &got,
	    (unsigned int)(ms > 0 ? ms : 1));
	if (r == LIBUSB_ERROR_TIMEOUT)
		return (0);
	return (r == 0 ? got : -1);
}

static uint64_t
ux_now_ms(void *a)
{
	struct timespec ts;

	(void) a;
	(void) clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000);
}

const struct xport *
xport_ugen(const char *dir, int noclear)
{
	static struct ugen_x u;
	static struct xport x = {
		"ugen", ux_open, ux_close, ux_send_cmd, ux_recv_evt, ux_now_ms, &u
	};

	u.dir = dir;
	u.noclear = noclear;
	return (&x);
}
