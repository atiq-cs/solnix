/*
 * hidptp.c -- Windows Precision Touchpad reports to evdev multitouch events.
 *
 * ptp_parse_desc() walks a HID report descriptor and finds, in the Digitizer
 * / Touch Pad application collection (0x0D/0x05), each Finger collection's
 * Tip Switch, Confidence, Contact Id and X/Y, plus Contact Count, Scan Time
 * and the buttons; and, anywhere, the Input Mode (0x0D/0x52), Contact Count
 * Maximum / Pad Type (0x55/0x59) and Surface/Button Switch (0x57/0x58)
 * feature fields.
 *
 * ptp_input() turns one input report into evdev events, multitouch protocol
 * B with single-touch emulation, as Linux hid-multitouch and FreeBSD hmt(4)
 * do: a hybrid-mode frame (Contact Count in its first report, 0 in the
 * rest) ends when Contact Count contacts have been seen; then contacts not
 * reported in the frame are released (PTP reports every contact in every
 * frame), a contact with Confidence 0 is released (a palm), and BTN_TOUCH,
 * BTN_TOOL_*, ABS_X/ABS_Y, the buttons, MSC_TIMESTAMP and SYN_REPORT follow.
 * The frame logic follows FreeBSD sys/dev/hid/hmt.c (BSD-2-Clause,
 * Copyright (c) 2014-2020 Vladimir Kondratyev <wulf@FreeBSD.org>).
 *
 * No kernel or libc calls: the same file builds into ihid and into
 * hidptp_test.c, which runs it on lixi's real descriptor.
 */
#include "hidptp.h"
#include "evdev/input-event-codes.h"

#define	U(p, u)		(((uint32_t)(p) << 16) | (u))
#define	TOUCHPAD	U(0x0d, 0x05)
#define	DEVCONFIG	U(0x0d, 0x0e)
#define	FINGER		U(0x0d, 0x22)
#define	NUSAGE		32
#define	NRB		32

enum { K_IN, K_OUT, K_FEAT };

static void
setloc(ptp_loc_t *l, uint32_t pos, uint32_t size)
{
	if (pos + size <= 0xffff && size <= 32) {
		l->pos = pos;
		l->size = size;
	}
}

/* units per mm from the logical and physical ranges (HID 6.2.2.7) */
static int32_t
ptp_res(int32_t lmin, int32_t lmax, int32_t pmin, int32_t pmax, int e,
    uint32_t unit)
{
	uint64_t num, den;

	if (lmax <= lmin || pmax <= pmin)
		return (0);
	num = (uint64_t)(lmax - lmin);
	den = (uint64_t)(pmax - pmin);
	if (unit == 0x11) {		/* SI linear, cm */
		e += 1;
	} else if (unit == 0x13) {	/* English linear, inch = 254/10 mm */
		num *= 10;
		den *= 254;
	} else {
		return (0);
	}
	for (; e > 0; e--)
		den *= 10;
	for (; e < 0; e++)
		num *= 10;
	return ((int32_t)((num + den / 2) / den));
}

int
ptp_parse_desc(const uint8_t *d, uint32_t len, ptp_desc_t *pd)
{
	struct glob {
		uint32_t page, unit, rsize, rcount;
		int32_t lmin, lmax, pmin, pmax;
		int uexp;
		uint8_t rid;
	} g, gs[4];
	struct { uint8_t kind, rid; uint32_t bits; } rb[NRB];
	struct { uint32_t usage; int finger; } cs[8];
	uint32_t us[NUSAGE], umin = 0, umax = 0, i = 0, v, sz, k;
	int gsp = 0, nu = 0, range = 0, nrb = 0, csp = 0, finger = -1;
	uint32_t app = 0;
	int32_t sv;
	uint8_t *z = (uint8_t *)pd;

	for (k = 0; k < sizeof (*pd); k++)
		z[k] = 0;
	z = (uint8_t *)&g;
	for (k = 0; k < sizeof (g); k++)
		z[k] = 0;

	while (i < len) {
		uint8_t p = d[i], typ = (p >> 2) & 3, tag = p >> 4;

		if (p == 0xfe) {		/* long item: skip */
			if (i + 1 >= len)
				return (-1);
			i += 3 + d[i + 1];
			continue;
		}
		sz = (p & 3) == 3 ? 4 : (p & 3);
		if (i + 1 + sz > len)
			return (-1);
		v = 0;
		for (k = 0; k < sz; k++)
			v |= (uint32_t)d[i + 1 + k] << (8 * k);
		sv = (sz == 1) ? (int8_t)v : (sz == 2) ? (int16_t)v : (int32_t)v;
		i += 1 + sz;

		if (typ == 1) {			/* global */
			switch (tag) {
			case 0: g.page = v; break;
			case 1: g.lmin = sv; break;
			case 2: g.lmax = (g.lmin >= 0 && sv < 0) ? (int32_t)v : sv;
				break;
			case 3: g.pmin = sv; break;
			case 4: g.pmax = (g.pmin >= 0 && sv < 0) ? (int32_t)v : sv;
				break;
			case 5: g.uexp = (v & 0xf) > 7 ? (int)(v & 0xf) - 16 :
				    (int)(v & 0xf);
				break;
			case 6: g.unit = v; break;
			case 7: g.rsize = v; break;
			case 8: g.rid = v; break;
			case 9: g.rcount = v; break;
			case 10: if (gsp == 4) return (-1);
				gs[gsp++] = g;
				break;
			case 11: if (gsp == 0) return (-1);
				g = gs[--gsp];
				break;
			}
			continue;
		}
		if (typ == 2) {			/* local */
			uint32_t u = (sz == 4) ? v : U(g.page, v);
			if (tag == 0 && nu < NUSAGE)
				us[nu++] = u;
			else if (tag == 1) {
				umin = u;
				range = 1;
			} else if (tag == 2)
				umax = u;
			continue;
		}
		if (typ != 0)
			return (-1);

		/* main items */
		if (tag == 10) {		/* Collection */
			uint32_t u = nu ? us[0] : (range ? umin : 0);
			if (csp == 8)
				return (-1);
			if (csp == 0)
				app = u;
			cs[csp].usage = u;
			cs[csp].finger = -1;
			if (u == FINGER && app == TOUCHPAD && finger < 0 &&
			    pd->nfingers < PTP_MAX_FINGERS)
				finger = cs[csp].finger = pd->nfingers++;
			csp++;
		} else if (tag == 12) {		/* End Collection */
			if (csp == 0)
				return (-1);
			csp--;
			if (cs[csp].finger >= 0)
				finger = -1;
			if (csp == 0)
				app = 0;
		} else if (tag == 8 || tag == 9 || tag == 11) {
			int kind = tag == 8 ? K_IN : tag == 9 ? K_OUT : K_FEAT;
			uint32_t off, n;
			int r;

			if (g.rsize > 32 || g.rcount > 8192)
				return (-1);
			for (r = 0; r < nrb; r++)
				if (rb[r].kind == kind && rb[r].rid == g.rid)
					break;
			if (r == nrb) {
				if (nrb == NRB)
					return (-1);
				rb[r].kind = kind;
				rb[r].rid = g.rid;
				rb[r].bits = 0;
				nrb++;
			}
			off = rb[r].bits;
			rb[r].bits += g.rsize * g.rcount;
			/* constants and arrays carry no field we use */
			for (n = 0; !(v & 1) && (v & 2) && n < g.rcount; n++) {
				uint32_t u = range ? (umin + n > umax ? umax :
				    umin + n) : nu ? us[n < (uint32_t)nu ? n :
				    (uint32_t)nu - 1] : 0;
				uint32_t pos = off + n * g.rsize;

				if (kind == K_IN && app == TOUCHPAD) {
					if (pd->rid == 0)
						pd->rid = g.rid;
					if (g.rid != pd->rid)
						continue;
				}
				if (kind == K_IN && app == TOUCHPAD &&
				    finger >= 0) {
					switch (u) {
					case U(0x0d, 0x42):
						setloc(&pd->f[finger].tip, pos,
						    g.rsize);
						break;
					case U(0x0d, 0x47):
						setloc(&pd->f[finger].conf, pos,
						    g.rsize);
						break;
					case U(0x0d, 0x51):
						setloc(&pd->f[finger].cid, pos,
						    g.rsize);
						break;
					case U(0x01, 0x30):
						setloc(&pd->f[finger].x, pos,
						    g.rsize);
						if (finger == 0) {
							pd->xmin = g.lmin;
							pd->xmax = g.lmax;
							pd->xres = ptp_res(g.lmin,
							    g.lmax, g.pmin,
							    g.pmax, g.uexp,
							    g.unit);
						}
						break;
					case U(0x01, 0x31):
						setloc(&pd->f[finger].y, pos,
						    g.rsize);
						if (finger == 0) {
							pd->ymin = g.lmin;
							pd->ymax = g.lmax;
							pd->yres = ptp_res(g.lmin,
							    g.lmax, g.pmin,
							    g.pmax, g.uexp,
							    g.unit);
						}
						break;
					}
				} else if (kind == K_IN && app == TOUCHPAD) {
					if (u == U(0x0d, 0x54))
						setloc(&pd->ccount, pos, g.rsize);
					else if (u == U(0x0d, 0x56))
						setloc(&pd->scantime, pos,
						    g.rsize);
					else if (u >= U(0x09, 1) &&
					    u < U(0x09, 1 + PTP_MAX_BUTTONS)) {
						setloc(&pd->btn[u - U(0x09, 1)],
						    pos, g.rsize);
						if ((int)(u - U(0x09, 0)) >
						    pd->nbuttons)
							pd->nbuttons =
							    u - U(0x09, 0);
					}
				} else if (kind == K_FEAT) {
					switch (u) {
					case U(0x0d, 0x52):
						pd->mode_rid = g.rid;
						setloc(&pd->mode, pos, g.rsize);
						break;
					case U(0x0d, 0x55):
						pd->cmax_rid = g.rid;
						setloc(&pd->cmax, pos, g.rsize);
						break;
					case U(0x0d, 0x59):
						pd->cmax_rid = g.rid;
						setloc(&pd->padtype, pos,
						    g.rsize);
						break;
					case U(0x0d, 0x57):
						pd->sel_rid = g.rid;
						setloc(&pd->surface, pos,
						    g.rsize);
						break;
					case U(0x0d, 0x58):
						pd->sel_rid = g.rid;
						setloc(&pd->button, pos,
						    g.rsize);
						break;
					}
				}
			}
		}
		nu = 0;				/* locals end at a main item */
		range = 0;
		umin = umax = 0;
	}
	if (csp != 0 || gsp != 0)
		return (-1);
	for (k = 0; k < (uint32_t)nrb; k++) {
		uint16_t b = (rb[k].bits + 7) / 8;
		if (rb[k].kind == K_IN && rb[k].rid == pd->rid)
			pd->rlen = b;
		else if (rb[k].kind == K_FEAT && rb[k].rid == pd->mode_rid)
			pd->mode_len = b;
		if (rb[k].kind == K_FEAT && rb[k].rid == pd->cmax_rid)
			pd->cmax_len = b;
		if (rb[k].kind == K_FEAT && rb[k].rid == pd->sel_rid)
			pd->sel_len = b;
	}
	/* a touchpad: report id, finger 0 with tip and X/Y, input mode */
	if (pd->rid == 0 || pd->nfingers == 0 || pd->f[0].tip.size == 0 ||
	    pd->f[0].x.size == 0 || pd->f[0].y.size == 0 ||
	    pd->mode_rid == 0 || pd->mode.size == 0 || pd->xmax <= pd->xmin ||
	    pd->ymax <= pd->ymin)
		return (-1);
	return (0);
}

uint32_t
ptp_get(const uint8_t *b, uint32_t len, ptp_loc_t l)
{
	uint32_t v = 0, i;

	if (l.size == 0 || l.pos + l.size > len * 8)
		return (0);
	for (i = 0; i < l.size; i++)
		v |= (uint32_t)((b[(l.pos + i) / 8] >> ((l.pos + i) % 8)) & 1)
		    << i;
	return (v);
}

void
ptp_put(uint8_t *b, uint32_t len, ptp_loc_t l, uint32_t v)
{
	uint32_t i, bit;

	if (l.size == 0 || l.pos + l.size > len * 8)
		return;
	for (i = 0; i < l.size; i++) {
		bit = l.pos + i;
		b[bit / 8] = (b[bit / 8] & ~(1 << (bit % 8))) |
		    (((v >> i) & 1) << (bit % 8));
	}
}

void
ptp_state_init(ptp_state_t *st, int nslots)
{
	uint8_t *z = (uint8_t *)st;
	uint32_t k;

	for (k = 0; k < sizeof (*st); k++)
		z[k] = 0;
	st->nslots = (nslots > 0 && nslots <= PTP_MAX_SLOTS) ? nslots :
	    PTP_MAX_SLOTS;
	for (k = 0; k < PTP_MAX_SLOTS; k++)
		st->s[k].tid = -1;
	st->st = -1;
}

typedef struct evb {
	ptp_ev_t	*ev;
	int		n, max;
} evb_t;

static void
emit(evb_t *b, uint16_t type, uint16_t code, int32_t value)
{
	if (b->n < b->max) {
		b->ev[b->n].type = type;
		b->ev[b->n].code = code;
		b->ev[b->n].value = value;
		b->n++;
	}
}

static void
selslot(ptp_state_t *st, evb_t *b, int s)
{
	if (st->slot != s) {
		emit(b, EV_ABS, ABS_MT_SLOT, s);
		st->slot = s;
	}
}

static void
lift(ptp_state_t *st, evb_t *b, int s)
{
	selslot(st, b, s);
	emit(b, EV_ABS, ABS_MT_TRACKING_ID, -1);
	st->s[s].tid = -1;
}

static const uint16_t ptp_tools[5] = { BTN_TOOL_FINGER, BTN_TOOL_DOUBLETAP,
	BTN_TOOL_TRIPLETAP, BTN_TOOL_QUADTAP, BTN_TOOL_QUINTTAP };
static const uint16_t ptp_btn[PTP_MAX_BUTTONS] = { BTN_LEFT, BTN_RIGHT,
	BTN_MIDDLE };

/* frame end: touch count, tool, pointer emulation, buttons, timestamp, sync */
static void
frame_end(ptp_state_t *st, evb_t *b, uint32_t btns, int stamp, uint16_t scan)
{
	int s, n = 0, oldest = -1, was = st->ntouch;

	for (s = 0; s < st->nslots; s++) {
		if (st->s[s].tid < 0)
			continue;
		n++;
		if (oldest < 0 ||
		    (int16_t)(st->s[s].tid - st->s[oldest].tid) < 0)
			oldest = s;
	}
	if ((n > 0) != (was > 0))
		emit(b, EV_KEY, BTN_TOUCH, n > 0);
	if (was != n) {
		if (was > 0)
			emit(b, EV_KEY, ptp_tools[(was > 5 ? 5 : was) - 1], 0);
		if (n > 0)
			emit(b, EV_KEY, ptp_tools[(n > 5 ? 5 : n) - 1], 1);
	}
	if (oldest >= 0) {
		if (st->stx != st->s[oldest].x || st->st != oldest)
			emit(b, EV_ABS, ABS_X, st->stx = st->s[oldest].x);
		if (st->sty != st->s[oldest].y || st->st != oldest)
			emit(b, EV_ABS, ABS_Y, st->sty = st->s[oldest].y);
	}
	st->st = oldest;
	for (s = 0; s < PTP_MAX_BUTTONS; s++)
		if (((btns ^ st->btns) >> s) & 1)
			emit(b, EV_KEY, ptp_btn[s], (btns >> s) & 1);
	st->btns = btns;
	if (stamp) {
		/* scan time is in 100 us units and wraps at 16 bits */
		st->ts = was > 0 ? st->ts + (uint16_t)(scan - st->scan) * 100 :
		    0;
		st->scan = scan;
		emit(b, EV_MSC, MSC_TIMESTAMP, (int32_t)st->ts);
	}
	emit(b, EV_SYN, SYN_REPORT, 0);
	st->ntouch = n;
	st->frames++;
	if ((uint64_t)n > st->maxcount)
		st->maxcount = n;
}

/*
 * One input report, [report id][payload]. Returns the number of events put
 * in ev (0 while a hybrid frame is incomplete), or -1 for a report that is
 * not the touchpad's.
 */
int
ptp_input(const ptp_desc_t *pd, ptp_state_t *st, const uint8_t *r,
    uint32_t len, ptp_ev_t *ev, int max)
{
	evb_t b = { ev, 0, max };
	const uint8_t *p = r + 1;
	uint32_t plen = len - 1, cc, btns = 0;
	int i, s, n;

	if (len < 1 || r[0] != pd->rid || plen < pd->rlen)
		return (-1);
	cc = pd->ccount.size ? ptp_get(p, plen, pd->ccount) : 1;
	if (cc != 0) {
		st->todo = cc;
		if (cc > st->maxcount)
			st->maxcount = cc;
	}
	n = st->todo < pd->nfingers ? st->todo : pd->nfingers;
	for (i = 0; i < n; i++) {
		uint8_t hw = ptp_get(p, plen, pd->f[i].cid);
		int down = ptp_get(p, plen, pd->f[i].tip) != 0 &&
		    (pd->f[i].conf.size == 0 ||
		    ptp_get(p, plen, pd->f[i].conf) != 0);
		int32_t x = ptp_get(p, plen, pd->f[i].x);
		int32_t y = ptp_get(p, plen, pd->f[i].y);
		int isnew = 0;

		for (s = 0; s < st->nslots; s++)
			if (st->s[s].tid >= 0 && st->s[s].hwid == hw)
				break;
		if (s == st->nslots) {
			if (!down)
				continue;
			for (s = 0; s < st->nslots; s++)
				if (st->s[s].tid < 0)
					break;
			if (s == st->nslots)
				continue;	/* more contacts than slots */
			isnew = 1;
		}
		if (!down) {
			lift(st, &b, s);
			continue;
		}
		selslot(st, &b, s);
		if (isnew) {
			st->s[s].tid = st->next_tid;
			st->next_tid = (st->next_tid + 1) & 0xffff;
			st->s[s].hwid = hw;
			emit(&b, EV_ABS, ABS_MT_TRACKING_ID, st->s[s].tid);
			st->contacts++;
		}
		if (isnew || st->s[s].x != x)
			emit(&b, EV_ABS, ABS_MT_POSITION_X, st->s[s].x = x);
		if (isnew || st->s[s].y != y)
			emit(&b, EV_ABS, ABS_MT_POSITION_Y, st->s[s].y = y);
		st->s[s].seen = 1;
	}
	st->todo -= n;
	if (st->todo > 0)
		return (b.n);

	for (s = 0; s < st->nslots; s++) {
		if (st->s[s].tid >= 0 && !st->s[s].seen)
			lift(st, &b, s);
		st->s[s].seen = 0;
	}
	for (i = 0; i < pd->nbuttons; i++)
		btns |= (ptp_get(p, plen, pd->btn[i]) != 0) << i;
	frame_end(st, &b, btns, pd->scantime.size != 0,
	    ptp_get(p, plen, pd->scantime));
	return (b.n);
}

/* Lift everything (stuck-contact timeout, close): a full frame. */
int
ptp_release_all(ptp_state_t *st, ptp_ev_t *ev, int max)
{
	evb_t b = { ev, 0, max };
	int s;

	if (st->ntouch == 0 && st->btns == 0)
		return (0);
	for (s = 0; s < st->nslots; s++) {
		if (st->s[s].tid >= 0)
			lift(st, &b, s);
		st->s[s].seen = 0;
	}
	st->todo = 0;
	frame_end(st, &b, 0, 0, 0);
	return (b.n);
}
