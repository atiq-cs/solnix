/*
 * hidptp.h -- Windows Precision Touchpad (PTP) support for ihid: find the
 * touchpad's fields in a HID report descriptor, and turn its input reports
 * into evdev multitouch events (protocol B, as Linux hid-multitouch and
 * FreeBSD hmt(4) emit them). Plain C with no kernel or libc calls, so the
 * same file builds into ihid and into its userland test (hidptp_test.c).
 */
#ifndef	_HIDPTP_H
#define	_HIDPTP_H

#include <sys/types.h>

#define	PTP_MAX_FINGERS	5	/* finger collections in one report */
#define	PTP_MAX_SLOTS	10	/* contacts tracked at once */
#define	PTP_MAX_BUTTONS	3
#define	PTP_MAX_EVENTS	96	/* bound on what one report can produce */

/* HID-over-I2C report types (spec 7.2.2) and PTP Input Mode values */
#define	PTP_RT_INPUT	1
#define	PTP_RT_FEATURE	3
#define	PTP_MODE_MOUSE	0
#define	PTP_MODE_PTP	3

typedef struct ptp_loc {
	uint16_t	pos;	/* bit offset after the report id byte */
	uint8_t		size;	/* bits; 0 = absent */
} ptp_loc_t;

typedef struct ptp_desc {
	uint8_t		rid;		/* input report id; 0 = no touchpad */
	uint16_t	rlen;		/* input report bytes, without the id */
	int		nfingers;
	struct {
		ptp_loc_t tip, conf, cid, x, y;
	} f[PTP_MAX_FINGERS];
	ptp_loc_t	ccount, scantime, btn[PTP_MAX_BUTTONS];
	int		nbuttons;
	int32_t		xmin, xmax, ymin, ymax;
	int32_t		xres, yres;	/* units per mm; 0 = unknown */
	/* feature reports (rid 0 = absent); *len = bytes without the id */
	uint8_t		mode_rid, cmax_rid, sel_rid;
	uint16_t	mode_len, cmax_len, sel_len;
	ptp_loc_t	mode, cmax, padtype, surface, button;
} ptp_desc_t;

typedef struct ptp_ev {
	uint16_t	type, code;
	int32_t		value;
} ptp_ev_t;

typedef struct ptp_state {
	int		nslots;
	struct {
		int32_t	tid;		/* evdev tracking id; -1 = free */
		uint8_t	hwid;		/* the device's contact id */
		uint8_t	seen;		/* reported in the current frame */
		int32_t	x, y;
	} s[PTP_MAX_SLOTS];
	int32_t		next_tid;
	int		todo;		/* contacts still due in this frame */
	int		slot;		/* current ABS_MT_SLOT (evdev starts at 0) */
	int		ntouch;		/* contacts down after the last frame */
	int		st;		/* slot behind ABS_X/ABS_Y; -1 = none */
	int32_t		stx, sty;
	uint32_t	btns;
	uint16_t	scan;		/* last scan time, 100 us units */
	uint32_t	ts;		/* MSC_TIMESTAMP, us */
	/* counters for kstats and the test */
	uint64_t	frames, contacts, maxcount;
} ptp_state_t;

int ptp_parse_desc(const uint8_t *, uint32_t, ptp_desc_t *);
uint32_t ptp_get(const uint8_t *, uint32_t, ptp_loc_t);
void ptp_put(uint8_t *, uint32_t, ptp_loc_t, uint32_t);
void ptp_state_init(ptp_state_t *, int);
int ptp_input(const ptp_desc_t *, ptp_state_t *, const uint8_t *, uint32_t,
    ptp_ev_t *, int);
int ptp_release_all(ptp_state_t *, ptp_ev_t *, int);

#endif	/* _HIDPTP_H */
