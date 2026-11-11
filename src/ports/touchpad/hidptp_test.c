/*
 * hidptp_test.c -- run hidptp.c on a real report descriptor (argv[1]) and
 * check it against hand-built reports. Exit 0 = all checks passed.
 *   cc -I. -o hidptp_test hidptp_test.c hidptp.c && ./hidptp_test rdesc.bin
 * Expected on lixi's ELAN 04f3:320d: report 4, 11 bytes, 1 finger per report
 * (hybrid), X 0..3528 Y 0..2006, Input Mode in feature report 3.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "hidptp.h"
#include "evdev/input-event-codes.h"

static int fails;
#define	CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", \
	__FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static ptp_desc_t pd;
static ptp_state_t st;
static ptp_ev_t ev[PTP_MAX_EVENTS];

/* one finger in finger collection 0 of report pd.rid */
static int
rep(uint8_t *r, int tip, int conf, int cid, int x, int y, int cc, int btn,
    int scan)
{
	memset(r, 0, 1 + pd.rlen);
	r[0] = pd.rid;
	ptp_put(r + 1, pd.rlen, pd.f[0].tip, tip);
	ptp_put(r + 1, pd.rlen, pd.f[0].conf, conf);
	ptp_put(r + 1, pd.rlen, pd.f[0].cid, cid);
	ptp_put(r + 1, pd.rlen, pd.f[0].x, x);
	ptp_put(r + 1, pd.rlen, pd.f[0].y, y);
	ptp_put(r + 1, pd.rlen, pd.ccount, cc);
	ptp_put(r + 1, pd.rlen, pd.btn[0], btn);
	ptp_put(r + 1, pd.rlen, pd.scantime, scan);
	return (1 + pd.rlen);
}

static int
feed(uint8_t *r, int len, int show)
{
	int n = ptp_input(&pd, &st, r, len, ev, PTP_MAX_EVENTS), i;

	for (i = 0; show && i < n; i++)
		printf("    ev %u %u %d\n", ev[i].type, ev[i].code, ev[i].value);
	return (n);
}

static int
has(int n, int type, int code, int value)
{
	for (int i = 0; i < n; i++)
		if (ev[i].type == type && ev[i].code == code &&
		    ev[i].value == value)
			return (1);
	return (0);
}

/* active contacts in the tracker */
static int
active(void)
{
	int s, k = 0;
	for (s = 0; s < st.nslots; s++)
		k += st.s[s].tid >= 0;
	return (k);
}

int
main(int argc, char **argv)
{
	static uint8_t d[4096];
	uint8_t r[64];
	FILE *f;
	size_t dl;
	int n, len;

	if (argc != 2 || (f = fopen(argv[1], "rb")) == NULL) {
		fprintf(stderr, "usage: hidptp_test rdesc.bin\n");
		return (2);
	}
	dl = fread(d, 1, sizeof (d), f);
	fclose(f);

	CHECK(ptp_parse_desc(d, dl, &pd) == 0, "descriptor does not parse");
	printf("rid %u rlen %u fingers %d buttons %d x %d..%d (%d/mm) "
	    "y %d..%d (%d/mm)\n", pd.rid, pd.rlen, pd.nfingers, pd.nbuttons,
	    pd.xmin, pd.xmax, pd.xres, pd.ymin, pd.ymax, pd.yres);
	printf("tip %u/%u conf %u/%u cid %u/%u x %u/%u y %u/%u cc %u/%u "
	    "scan %u/%u btn0 %u/%u\n", pd.f[0].tip.pos, pd.f[0].tip.size,
	    pd.f[0].conf.pos, pd.f[0].conf.size, pd.f[0].cid.pos,
	    pd.f[0].cid.size, pd.f[0].x.pos, pd.f[0].x.size, pd.f[0].y.pos,
	    pd.f[0].y.size, pd.ccount.pos, pd.ccount.size, pd.scantime.pos,
	    pd.scantime.size, pd.btn[0].pos, pd.btn[0].size);
	printf("mode rid %u len %u at %u/%u; cmax rid %u len %u cmax %u/%u "
	    "padtype %u/%u; sel rid %u len %u\n", pd.mode_rid, pd.mode_len,
	    pd.mode.pos, pd.mode.size, pd.cmax_rid, pd.cmax_len, pd.cmax.pos,
	    pd.cmax.size, pd.padtype.pos, pd.padtype.size, pd.sel_rid,
	    pd.sel_len);

	/* the descriptor facts, read by hand from lixi's (tpad4 progress) */
	CHECK(pd.rid == 4 && pd.rlen == 11 && pd.nfingers == 1, "layout");
	CHECK(pd.f[0].conf.pos == 0 && pd.f[0].tip.pos == 1 &&
	    pd.f[0].cid.pos == 4 && pd.f[0].cid.size == 4, "finger bits");
	CHECK(pd.f[0].x.pos == 8 && pd.f[0].x.size == 16 &&
	    pd.f[0].y.pos == 24 && pd.f[0].y.size == 16, "x/y");
	CHECK(pd.xmax == 3528 && pd.ymax == 2006 && pd.xres == 31 &&
	    pd.yres == 31, "ranges");
	CHECK(pd.scantime.pos == 40 && pd.ccount.pos == 56 &&
	    pd.ccount.size == 8 && pd.btn[0].pos == 64 && pd.nbuttons == 1,
	    "scan/count/button");
	CHECK(pd.mode_rid == 3 && pd.mode_len == 2 && pd.mode.pos == 0 &&
	    pd.mode.size == 16, "input mode feature");
	CHECK(pd.cmax_rid == 2 && pd.cmax.size == 4 && pd.padtype.pos == 4,
	    "contact max feature");
	CHECK(pd.sel_rid == 5 && pd.surface.pos == 0 && pd.button.pos == 1,
	    "selective reporting feature");

	ptp_state_init(&st, 5);
	/* one finger down, moves, two-finger hybrid frame, palm, lift */
	printf("frame 1: one finger down\n");
	len = rep(r, 1, 1, 3, 1000, 500, 1, 0, 100);
	n = feed(r, len, 1);
	CHECK(has(n, EV_ABS, ABS_MT_TRACKING_ID, 0) &&
	    has(n, EV_KEY, BTN_TOUCH, 1) && has(n, EV_KEY, BTN_TOOL_FINGER, 1)
	    && has(n, EV_ABS, ABS_X, 1000) && has(n, EV_SYN, SYN_REPORT, 0),
	    "first touch");
	len = rep(r, 1, 1, 3, 1010, 500, 1, 0, 180);
	n = feed(r, len, 0);
	CHECK(has(n, EV_ABS, ABS_MT_POSITION_X, 1010) &&
	    !has(n, EV_ABS, ABS_MT_POSITION_Y, 500) &&
	    has(n, EV_MSC, MSC_TIMESTAMP, 8000), "motion + timestamp");

	printf("frame 3: hybrid, contact count 2 then 0\n");
	len = rep(r, 1, 1, 3, 1020, 500, 2, 0, 260);
	n = feed(r, len, 1);
	CHECK(n > 0 && !has(n, EV_SYN, SYN_REPORT, 0), "half frame: no sync");
	CHECK(st.todo == 1, "one contact still due");
	len = rep(r, 1, 1, 7, 2000, 900, 0, 0, 260);
	n = feed(r, len, 1);
	CHECK(has(n, EV_ABS, ABS_MT_SLOT, 1) &&
	    has(n, EV_ABS, ABS_MT_TRACKING_ID, 1) &&
	    has(n, EV_KEY, BTN_TOOL_DOUBLETAP, 1) &&
	    has(n, EV_KEY, BTN_TOOL_FINGER, 0) &&
	    has(n, EV_SYN, SYN_REPORT, 0), "second contact");
	CHECK(active() == 2 && st.maxcount == 2, "two contacts down");

	printf("frame 4: contact 7 turns into a palm (confidence 0)\n");
	len = rep(r, 1, 1, 3, 1020, 500, 2, 0, 340);
	feed(r, len, 0);
	len = rep(r, 1, 0, 7, 2000, 900, 0, 0, 340);
	n = feed(r, len, 1);
	CHECK(has(n, EV_ABS, ABS_MT_TRACKING_ID, -1) && active() == 1,
	    "palm lifted");

	printf("frame 5: contact 7 no longer reported -> nothing; "
	    "contact 3 lifts (tip 0)\n");
	len = rep(r, 0, 1, 3, 1020, 500, 1, 0, 420);
	n = feed(r, len, 1);
	CHECK(has(n, EV_KEY, BTN_TOUCH, 0) && active() == 0, "all up");

	printf("frame 6: click (button 1) with a finger\n");
	len = rep(r, 1, 1, 2, 300, 300, 1, 1, 500);
	n = feed(r, len, 0);
	CHECK(has(n, EV_KEY, BTN_LEFT, 1), "click");

	printf("timeout release\n");
	n = ptp_release_all(&st, ev, PTP_MAX_EVENTS);
	CHECK(has(n, EV_KEY, BTN_LEFT, 0) && has(n, EV_KEY, BTN_TOUCH, 0) &&
	    has(n, EV_SYN, SYN_REPORT, 0) && active() == 0, "release all");
	CHECK(ptp_release_all(&st, ev, PTP_MAX_EVENTS) == 0, "idempotent");

	/* negative controls: mouse-mode report 1, short report, bad desc */
	printf("negative: mouse-mode report id 1\n");
	{
		uint8_t m[9] = { 1, 1, 5, 0xfb, 0, 0, 0, 0, 0 };
		CHECK(ptp_input(&pd, &st, m, sizeof (m), ev, PTP_MAX_EVENTS)
		    == -1, "mouse report rejected");
		CHECK(ptp_input(&pd, &st, r, 5, ev, PTP_MAX_EVENTS) == -1,
		    "short report rejected");
	}
	{
		ptp_desc_t bad;
		CHECK(ptp_parse_desc(d, dl - 1, &bad) != 0,
		    "truncated descriptor rejected");
		CHECK(ptp_parse_desc(d, 0x86, &bad) != 0,
		    "mouse-only part rejected");
	}
	printf("%s: %d failed\n", fails ? "FAIL" : "PASS", fails);
	return (fails != 0);
}
