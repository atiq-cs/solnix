/*
 * xport.h: how the userland netbt core reaches a controller (solnix, new code).
 * One transport is active: the ugen device (xport_ugen.c, bt1's ugen_usb.c) or
 * a recorded transcript (xport_fixture.c). Both speak whole HCI packets
 * without the H4 type byte, as ubt does: commands go out as opcode+len+params
 * on the control pipe, events come back as code+len+params.
 */
#ifndef _SOLNIX_NETBT_XPORT_H
#define	_SOLNIX_NETBT_XPORT_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

struct xport {
	const char *name;
	int (*open)(void *);
	void (*close)(void *);
	/* one command packet (opcode, length, params): 0 or -1 */
	int (*send_cmd)(void *, const uint8_t *, size_t);
	/*
	 * Wait up to ms for one event (code, length, params). Returns its length,
	 * 0 on timeout, -1 on a transport error. ms 0 = poll.
	 */
	int (*recv_evt)(void *, uint8_t *, size_t, int);
	/* monotonic milliseconds (virtual for a fixture) */
	uint64_t (*now_ms)(void *);
	void *arg;
};

extern const struct xport *xport_cur;

/* the ugen transport (/dev/usb/8087.33/0); noclear = skip the toggle reset */
const struct xport *xport_ugen(const char *dir, int noclear);
/* a transcript (see xport_fixture.c for the format) */
const struct xport *xport_fixture(const char *path);
/* how the fixture ended: 0 all consumed, else the line that failed */
int xport_fixture_status(char *why, size_t len);

/*
 * Intel bootloader gate (gate.c): 0 operational, ENODEV in the bootloader (or
 * any other image), EIO no usable answer. Not EAGAIN: on illumos EAGAIN ==
 * EWOULDBLOCK, which hci_enable already returns for its 5 s init timeout.
 */
int gate_intel_operational(const struct xport *, uint8_t *img_type);

/*
 * rec.c: a transport that writes everything it carries to a transcript the
 * fixture can replay. Remote addresses are scrubbed before they are written:
 * OUI kept, the other 3 bytes replaced by a per-device index; EIR data and the
 * parameters of events that are neither command results nor inquiry results
 * are zeroed (lengths kept).
 */
const struct xport *xport_tee(const struct xport *, FILE *);
void rec_scrub(uint8_t *, size_t);

#endif
