/*
 * evcat.c -- tpad4 evdev probe for ihid's "event" minor. Does what
 * libevdev_set_fd() does (the EVIOCG* ioctls), prints the answers, then
 * reads events for N seconds and summarises them.
 *   evcat <node> <seconds> [quiet]
 * Prints "SUMMARY frames F max_down M tool2 T2 tool3 T3 btn_left B ..." last.
 * Exit 0 = the ioctl set answered as libevdev needs (not a touch verdict).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <time.h>
#include <stropts.h>
#include <sys/ioctl.h>
#include "evdev/input.h"

#define	NB(x)	(((x) + 7) / 8)
#define	TB(a, b)	(((a)[(b) / 8] >> ((b) % 8)) & 1)

static int bad;

static int
xioctl(int fd, int req, void *arg, const char *what, int okerr)
{
	int r = ioctl(fd, req, arg);
	if (r < 0 && errno != okerr) {
		printf("IOCTL %s: %s\n", what, strerror(errno));
		bad++;
	} else if (r < 0) {
		printf("ioctl %s: %s (expected)\n", what, strerror(errno));
	}
	return (r);
}

int
main(int argc, char **argv)
{
	uint8_t ev[NB(EV_CNT) + 8], key[NB(KEY_CNT) + 8], absb[NB(ABS_CNT) + 8],
	    props[NB(INPUT_PROP_CNT) + 8], tmp[NB(KEY_CNT) + 8];
	char name[256];
	struct input_id id;
	struct input_absinfo ai;
	struct { uint32_t code; int32_t val[16]; } mts;
	int fd, ver, i, secs, quiet, clk = CLOCK_MONOTONIC;
	long frames = 0, nev = 0, tracks = 0, tool[6] = { 0 }, left = 0,
	    maxdown = 0, down = 0, slot = 0, drops = 0, ts = 0;
	int tid[16];
	struct timespec t0, t;

	if (argc < 3) {
		fprintf(stderr, "usage: evcat node seconds [quiet]\n");
		return (2);
	}
	secs = atoi(argv[2]);
	quiet = argc > 3;
	if ((fd = open(argv[1], O_RDWR | O_NONBLOCK | O_NOCTTY)) < 0) {
		printf("OPEN %s: %s\n", argv[1], strerror(errno));
		return (1);
	}
	xioctl(fd, EVIOCGVERSION, &ver, "GVERSION", 0);
	printf("version 0x%x\n", ver);
	xioctl(fd, EVIOCGID, &id, "GID", 0);
	printf("id bus 0x%x vendor %04x product %04x version %04x\n",
	    id.bustype, id.vendor, id.product, id.version);
	memset(name, 0, sizeof (name));
	xioctl(fd, EVIOCGNAME(sizeof (name) - 1), name, "GNAME", 0);
	printf("name \"%s\"\n", name);
	memset(name, 0, sizeof (name));
	if (xioctl(fd, EVIOCGPHYS(sizeof (name) - 1), name, "GPHYS", ENOENT)
	    >= 0)
		printf("phys \"%s\"\n", name);
	xioctl(fd, EVIOCGUNIQ(sizeof (name) - 1), name, "GUNIQ", ENOENT);
	memset(props, 0, sizeof (props));
	xioctl(fd, EVIOCGPROP(sizeof (props)), props, "GPROP", 0);
	printf("props pointer %d buttonpad %d\n", TB(props, INPUT_PROP_POINTER),
	    TB(props, INPUT_PROP_BUTTONPAD));
	memset(ev, 0, sizeof (ev));
	xioctl(fd, EVIOCGBIT(0, sizeof (ev)), ev, "GBIT 0", 0);
	printf("types syn %d key %d rel %d abs %d msc %d\n", TB(ev, EV_SYN),
	    TB(ev, EV_KEY), TB(ev, EV_REL), TB(ev, EV_ABS), TB(ev, EV_MSC));
	memset(key, 0, sizeof (key));
	xioctl(fd, EVIOCGBIT(EV_KEY, sizeof (key)), key, "GBIT KEY", 0);
	printf("keys left %d right %d touch %d finger %d double %d triple %d "
	    "quad %d quint %d\n", TB(key, BTN_LEFT), TB(key, BTN_RIGHT),
	    TB(key, BTN_TOUCH), TB(key, BTN_TOOL_FINGER),
	    TB(key, BTN_TOOL_DOUBLETAP), TB(key, BTN_TOOL_TRIPLETAP),
	    TB(key, BTN_TOOL_QUADTAP), TB(key, BTN_TOOL_QUINTTAP));
	memset(absb, 0, sizeof (absb));
	xioctl(fd, EVIOCGBIT(EV_ABS, sizeof (absb)), absb, "GBIT ABS", 0);
	/* the rest of libevdev_set_fd's set */
	xioctl(fd, EVIOCGBIT(EV_REL, sizeof (tmp)), tmp, "GBIT REL", 0);
	xioctl(fd, EVIOCGBIT(EV_LED, sizeof (tmp)), tmp, "GBIT LED", 0);
	xioctl(fd, EVIOCGBIT(EV_SW, sizeof (tmp)), tmp, "GBIT SW", 0);
	xioctl(fd, EVIOCGBIT(EV_MSC, sizeof (tmp)), tmp, "GBIT MSC", 0);
	xioctl(fd, EVIOCGBIT(EV_FF, sizeof (tmp)), tmp, "GBIT FF", 0);
	xioctl(fd, EVIOCGBIT(EV_SND, sizeof (tmp)), tmp, "GBIT SND", 0);
	xioctl(fd, EVIOCGKEY(sizeof (tmp)), tmp, "GKEY", 0);
	xioctl(fd, EVIOCGLED(sizeof (tmp)), tmp, "GLED", 0);
	xioctl(fd, EVIOCGSW(sizeof (tmp)), tmp, "GSW", 0);
	for (i = 0; i < ABS_CNT; i++) {
		if (!TB(absb, i))
			continue;
		xioctl(fd, EVIOCGABS(i), &ai, "GABS", 0);
		printf("abs 0x%02x min %d max %d res %d value %d\n", i,
		    ai.minimum, ai.maximum, ai.resolution, ai.value);
	}
	mts.code = ABS_MT_TRACKING_ID;
	xioctl(fd, EVIOCGMTSLOTS(sizeof (mts)), &mts, "GMTSLOTS", 0);
	printf("mtslots code %u tid0 %d tid1 %d tid15 %d\n", mts.code,
	    mts.val[0], mts.val[1], mts.val[15]);
	xioctl(fd, EVIOCSCLOCKID, &clk, "SCLOCKID", 0);
	xioctl(fd, EVIOCGRAB, (void *)1, "GRAB", 0);
	xioctl(fd, EVIOCGRAB, (void *)0, "UNGRAB", 0);
	/* a bogus one must fail (negative control of the dispatcher) */
	if (ioctl(fd, EVIOCSABS(ABS_X), &ai) == 0) {
		printf("IOCTL SABS unexpectedly succeeded\n");
		bad++;
	}
	printf("IOCTLS %s (%d bad)\n", bad ? "FAIL" : "OK", bad);
	fflush(stdout);

	for (i = 0; i < 16; i++)
		tid[i] = -1;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	clock_gettime(CLOCK_REALTIME, &t);
	/* events are stamped CLOCK_MONOTONIC: this maps them to wall time */
	printf("CLOCKS mono %ld.%06ld real %ld.%06ld\n", (long)t0.tv_sec,
	    t0.tv_nsec / 1000, (long)t.tv_sec, t.tv_nsec / 1000);
	fflush(stdout);
	for (;;) {
		struct input_event e[64];
		struct pollfd p = { fd, POLLIN, 0 };
		ssize_t n;

		clock_gettime(CLOCK_MONOTONIC, &t);
		if (t.tv_sec - t0.tv_sec >= secs)
			break;
		if (poll(&p, 1, 1000) <= 0)
			continue;
		if ((n = read(fd, e, sizeof (e))) <= 0) {
			if (n < 0 && errno == EAGAIN)
				continue;
			printf("READ %zd %s\n", n, n < 0 ? strerror(errno) : "");
			break;
		}
		if (n % sizeof (e[0]) != 0) {
			printf("READ partial %zd\n", n);
			bad++;
		}
		for (i = 0; i < n / (ssize_t)sizeof (e[0]); i++) {
			nev++;
			if (!quiet)
				printf("%ld.%06ld %u %u %d\n",
				    (long)e[i].time.tv_sec,
				    (long)e[i].time.tv_usec, e[i].type,
				    e[i].code, e[i].value);
			switch (e[i].type) {
			case EV_SYN:
				if (e[i].code == SYN_REPORT)
					frames++;
				else if (e[i].code == SYN_DROPPED)
					drops++;
				break;
			case EV_MSC:
				ts++;
				break;
			case EV_KEY:
				if (e[i].code == BTN_LEFT && e[i].value)
					left++;
				if (e[i].value && e[i].code == BTN_TOOL_FINGER)
					tool[1]++;
				if (e[i].value && e[i].code == BTN_TOOL_DOUBLETAP)
					tool[2]++;
				if (e[i].value && e[i].code == BTN_TOOL_TRIPLETAP)
					tool[3]++;
				if (e[i].value && e[i].code == BTN_TOOL_QUADTAP)
					tool[4]++;
				if (e[i].value && e[i].code == BTN_TOOL_QUINTTAP)
					tool[5]++;
				break;
			case EV_ABS:
				if (e[i].code == ABS_MT_SLOT)
					slot = e[i].value;
				else if (e[i].code == ABS_MT_TRACKING_ID &&
				    slot >= 0 && slot < 16) {
					if (e[i].value >= 0 && tid[slot] < 0) {
						down++;
						tracks++;
					} else if (e[i].value < 0 &&
					    tid[slot] >= 0)
						down--;
					tid[slot] = e[i].value;
					if (down > maxdown)
						maxdown = down;
				}
				break;
			}
		}
	}
	printf("SUMMARY events %ld frames %ld tracks %ld max_down %ld "
	    "tool1 %ld tool2 %ld tool3 %ld tool4 %ld tool5 %ld left_clicks %ld "
	    "timestamps %ld dropped %ld\n", nev, frames, tracks, maxdown,
	    tool[1], tool[2], tool[3], tool[4], tool[5], left, ts, drops);
	close(fd);
	return (bad != 0);
}
