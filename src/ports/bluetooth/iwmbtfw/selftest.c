/*
 * btintelfw -t: self-test with no device (solnix, new code).
 *
 *  1. ugen_evq framing: HCI events split and coalesced at awkward points.
 *  2. End to end over a FAKE ugen directory (regular files): the bytes written
 *     to cntrl0 for Intel Read Version (0xfc05) and HCI_Read_Local_Version,
 *     and the parse of a coalesced interrupt-IN stream that holds a stray
 *     Command Status ahead of each Command Complete, ending in the firmware name.
 * Makefile.illumos `check` rebuilds with each mechanism sabotaged and requires
 * this test to FAIL (negative controls).
 */
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "compat/libusb.h"
#include "upstream/iwmbt_fw.h"
#include "ugen_evq.h"

int iwmbt_get_version_tlv(libusb_device_handle *, struct iwmbt_version_tlv *);
int btintel_read_local_version(libusb_device_handle *, uint8_t *);
int btintel_selftest(void);

static int fails;

#define	CHECK(c, what) do {						\
	if (!(c)) {							\
		fprintf(stderr, "selftest FAIL: %s\n", what);		\
		fails++;						\
	}								\
} while (0)

static void
evq_tests(void)
{
	static const uint8_t s[] = {
		0x0f, 0x04, 0x00, 0x01, 0x05, 0xfc,		/* Command Status */
		0x0e, 0x04, 0x01, 0x05, 0xfc, 0x00,		/* Command Complete */
		0xff, 0x01, 0x06,				/* vendor 0x06 */
	};
	struct ugen_evq q;
	uint8_t out[8];
	size_t full = 0;

	ugen_evq_init(&q);
	ugen_evq_push(&q, s, 1);
	CHECK(ugen_evq_pop(&q, out, sizeof (out), &full) == 0, "evq: 1 byte is no event");
	ugen_evq_push(&q, s + 1, 7);		/* first event + 2 bytes of the next */
	CHECK(ugen_evq_pop(&q, out, sizeof (out), &full) == 6 &&
	    out[0] == 0x0f && out[5] == 0xfc, "evq: first event");
	CHECK(ugen_evq_pop(&q, out, sizeof (out), &full) == 0, "evq: partial second");
	ugen_evq_push(&q, s + 8, sizeof (s) - 8);
	CHECK(ugen_evq_pop(&q, out, sizeof (out), &full) == 6 &&
	    out[0] == 0x0e && out[5] == 0x00, "evq: second event");
	CHECK(ugen_evq_pop(&q, out, 2, &full) == -1 && full == 3 &&
	    out[0] == 0xff, "evq: oversize event reports -1");
	CHECK(q.len == 0, "evq: drained");
}

static int
put(const char *dir, const char *node, const void *p, size_t n)
{
	char path[700];
	int fd;

	(void) snprintf(path, sizeof (path), "%s/%s", dir, node);
	if ((fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600)) < 0)
		return (-1);
	if (n > 0 && write(fd, p, n) != (ssize_t)n) {
		(void) close(fd);
		return (-1);
	}
	return (close(fd));
}

static ssize_t
get(const char *dir, const char *node, uint8_t *p, size_t n)
{
	char path[700];
	ssize_t r;
	int fd;

	(void) snprintf(path, sizeof (path), "%s/%s", dir, node);
	if ((fd = open(path, O_RDONLY)) < 0)
		return (-1);
	r = read(fd, p, n);
	(void) close(fd);
	return (r);
}

/* A fake ugen dir whose if0in1 holds `ev` and whose other nodes are empty. */
static libusb_device_handle *
fake_open(char *dir, const uint8_t *ev, size_t evlen)
{
	libusb_context *ctx;
	libusb_device **l;
	libusb_device_handle *h = NULL;
	static const char *nodes[] = { "cntrl0", "if0in1stat", "if0out2", "if0in2" };

	for (size_t i = 0; i < sizeof (nodes) / sizeof (nodes[0]); i++)
		if (put(dir, nodes[i], NULL, 0) != 0)
			return (NULL);
	if (put(dir, "if0in1", ev, evlen) != 0 || ugen_usb_set_dir(dir) != 0 ||
	    libusb_init(&ctx) != 0 || libusb_get_device_list(ctx, &l) != 1)
		return (NULL);
	if (libusb_open(l[0], &h) != 0)
		h = NULL;
	libusb_free_device_list(l, 1);
	return (h);
}

/*
 * Interrupt-IN stream: Command Status (stray), Command Complete for 0xfc05
 * carrying a bootloader TLV set, Command Status, Command Complete for 0x1001.
 * cnvi_top 0x400 / cnvr_top 0x410 pack to "ibt-0040-0041".
 */
static const uint8_t ev_stream[] = {
	0x0f, 0x04, 0x00, 0x01, 0x05, 0xfc,
	0x0e, 0x24, 0x01, 0x05, 0xfc, 0x00,
	0x10, 0x04, 0x00, 0x04, 0x00, 0x00,		/* CNVI_TOP */
	0x11, 0x04, 0x10, 0x04, 0x00, 0x00,		/* CNVR_TOP */
	0x12, 0x04, 0x00, 0x00, 0x1d, 0x00,		/* CNVI_BT: variant 0x1d */
	0x1c, 0x01, 0x01,				/* IMAGE_TYPE bootloader */
	0x2f, 0x01, 0x01,				/* SBE_TYPE ECDSA */
	0x30, 0x06, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,	/* OTP_BDADDR */
	0x0f, 0x04, 0x00, 0x01, 0x01, 0x10,
	0x0e, 0x0c, 0x01, 0x01, 0x10, 0x00,
	0x0c, 0x00, 0x01, 0x0c, 0x02, 0x00, 0x00, 0x01,
};

/*
 * What cntrl0 must have received: CLEAR_FEATURE(ENDPOINT_HALT) on 0x81 (the
 * interrupt-IN toggle reset at open), then two class device control-OUTs.
 */
static const uint8_t ctrl_expect[] = {
	0x02, 0x01, 0x00, 0x00, 0x81, 0x00, 0x00, 0x00,
	0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x05, 0xfc, 0x01, 0xff,
	0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x10, 0x00,
};

static void
e2e_tests(void)
{
	char base[] = "/tmp/btintelfw-st.XXXXXX", dir[128], path[200];
	struct iwmbt_version_tlv vt;
	libusb_device_handle *h;
	uint8_t lv[9], got[64];
	char *fw;

	if (mkdtemp(base) == NULL) {
		CHECK(0, "e2e: mkdtemp");
		return;
	}
	(void) snprintf(dir, sizeof (dir), "%s/usb", base);
	(void) mkdir(dir, 0700);
	(void) snprintf(dir, sizeof (dir), "%s/usb/8087.33", base);
	(void) mkdir(dir, 0700);
	(void) snprintf(dir, sizeof (dir), "%s/usb/8087.33/0", base);
	(void) mkdir(dir, 0700);
	h = fake_open(dir, ev_stream, sizeof (ev_stream));
	CHECK(h != NULL, "e2e: open fake ugen");
	if (h != NULL) {
		(void) memset(&vt, 0, sizeof (vt));
		CHECK(iwmbt_get_version_tlv(h, &vt) == 0, "e2e: version tlv");
		CHECK(vt.img_type == 0x01 && vt.sbe_type == 1 &&
		    ((vt.cnvi_bt >> 16) & 0x3f) == 0x1d, "e2e: tlv fields");
		CHECK(vt.otp_bd_addr.b[0] == 0x11 && vt.otp_bd_addr.b[5] == 0x66,
		    "e2e: bdaddr");
		fw = iwmbt_get_fwname_tlv(&vt, "/fw", "sfi");
		CHECK(fw != NULL && strcmp(fw, "/fw/ibt-0040-0041.sfi") == 0,
		    "e2e: firmware name");
		free(fw);
		CHECK(btintel_read_local_version(h, lv) == 0 && lv[0] == 0 &&
		    lv[1] == 0x0c && lv[5] == 0x02 && lv[8] == 0x01,
		    "e2e: HCI_Read_Local_Version");
		libusb_close(h);
	}
	CHECK(get(dir, "cntrl0", got, sizeof (got)) == sizeof (ctrl_expect) &&
	    memcmp(got, ctrl_expect, sizeof (ctrl_expect)) == 0,
	    "e2e: control-OUT bytes");
	(void) snprintf(path, sizeof (path), "find %s -depth -delete", base);
	(void) system(path);
}

int
btintel_selftest(void)
{
	evq_tests();
	e2e_tests();
	printf("selftest: %s (%d failure%s)\n", fails ? "FAIL" : "PASS",
	    fails, fails == 1 ? "" : "s");
	return (fails ? 1 : 0);
}
