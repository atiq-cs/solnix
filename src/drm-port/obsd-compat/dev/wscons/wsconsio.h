/*
 * OpenBSD <dev/wscons/wsconsio.h>, the subset inteldrm and drm_fb_helper
 * name. The ioctl numbers are OpenBSD's; they are only ever compared
 * against inside the (unused on illumos) wsdisplay ioctl handler.
 */
#ifndef _OBSD_COMPAT_DEV_WSCONS_WSCONSIO_H
#define _OBSD_COMPAT_DEV_WSCONS_WSCONSIO_H
#include <obsd_prelude.h>
struct wsdisplay_charcell {
	int cc_uc;
	uint32_t cc_attr;
};
struct wsdisplay_fbinfo {
	u_int height, width, depth, stride, offset, cmsize;
};
struct wsdisplay_param {
	int param;
	int min, max, curval;
	int reserved[4];
};
#define WSDISPLAYIO_PARAM_BACKLIGHT	1
#define WSDISPLAYIO_PARAM_BRIGHTNESS	2
#define WSDISPLAYIO_PARAM_CONTRAST	3
struct wsdisplay_font {
	char name[32];
	int index;
	int firstchar, numchars;
	int encoding;
	u_int fontwidth, fontheight, stride;
	int bitorder, byteorder;
	void *cookie;
	void *data;
};
#define WSDISPLAY_TYPE_INTELDRM	69
#define WSDISPLAYIO_GTYPE	_IOR('W', 64, u_int)
#define WSDISPLAYIO_GINFO	_IOR('W', 65, struct wsdisplay_fbinfo)
#define WSDISPLAYIO_GVIDEO	_IOR('W', 68, u_int)
#define WSDISPLAYIO_SVIDEO	_IOW('W', 69, u_int)
#define WSDISPLAYIO_VIDEO_OFF	0
#define WSDISPLAYIO_VIDEO_ON	1
#define WSDISPLAYIO_GETPARAM	_IOWR('W', 89, struct wsdisplay_param)
#define WSDISPLAYIO_SETPARAM	_IOWR('W', 90, struct wsdisplay_param)
#define WSDISPLAYIO_LINEBYTES	_IOR('W', 95, u_int)
#endif
