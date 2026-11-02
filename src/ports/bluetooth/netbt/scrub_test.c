/*
 * scrub_test.c: the transcript scrubber must keep OUI, class, RSSI and counts
 * and must not let a full remote address or EIR byte through (solnix, new code).
 * Run by `hcitest -t`.
 */
#include <stdio.h>
#include <string.h>
#include "xport.h"

int scrub_test(void);

static int fails;
#define	CHECK(c, what) do {						\
	if (!(c)) {							\
		fprintf(stderr, "selftest FAIL: scrub: %s\n", what);	\
		fails++;						\
	}								\
} while (0)

int
scrub_test(void)
{
	/* RSSI result, 2 responses: bdaddr psrm blank class[3] clock[2] rssi */
	uint8_t r[2 + 1 + 28] = { 0x22, 29, 2,
	    0x11, 0x22, 0x33, 0xaa, 0xbb, 0xcc, 1, 0, 0x0c, 0x01, 0x5a, 0x34, 0x12, 0xc4,
	    0x44, 0x55, 0x66, 0xdd, 0xee, 0xff, 1, 0, 0x04, 0x04, 0x24, 0x00, 0x00, 0xb0 };
	uint8_t x[2 + 255];
	uint8_t cc[] = { 0x0e, 0x0a, 0x01, 0x09, 0x10, 0x00, 1, 2, 3, 4, 5, 6 };
	uint8_t other[] = { 0x04, 0x0a, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
	uint8_t cc0[sizeof (cc)];

	rec_scrub(r, sizeof (r));
	CHECK(r[3] == 1 && r[4] == 0 && r[5] == 0, "first address NIC -> index 1");
	CHECK(r[6] == 0xaa && r[7] == 0xbb && r[8] == 0xcc, "first OUI kept");
	CHECK(r[11] == 0x0c && r[12] == 0x01 && r[13] == 0x5a && r[16] == 0xc4,
	    "first class + RSSI kept");
	CHECK(r[17] == 2 && r[18] == 0 && r[19] == 0, "second address NIC -> index 2");
	CHECK(r[30] == 0xb0, "second RSSI kept");

	memset(x, 0x77, sizeof (x));
	x[0] = 0x2f;
	x[1] = 255;
	x[2] = 1;
	rec_scrub(x, sizeof (x));
	CHECK(x[3] == 3 && x[4] == 0 && x[5] == 0 && x[6] == 0x77, "EIR address scrubbed, OUI kept");
	CHECK(x[2 + 15] == 0 && x[256] == 0, "EIR data zeroed");

	memcpy(cc0, cc, sizeof (cc));
	rec_scrub(cc, sizeof (cc));
	CHECK(memcmp(cc, cc0, sizeof (cc)) == 0, "Command Complete untouched (own bdaddr)");
	rec_scrub(other, sizeof (other));
	CHECK(other[0] == 0x04 && other[1] == 0x0a && other[2] == 0 && other[11] == 0,
	    "other events zeroed, length kept");
	return (fails);
}
