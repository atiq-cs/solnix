/*
 * OpenBSD <dev/rasops/rasops.h>, types only. struct rasops_info is embedded
 * in struct inteldrm_softc (i915_drv.h); the rasops text console itself is
 * never used on illumos (the console stays vgatext / gfxp_bitmap), so only
 * the fields i915 and drm_fb_helper name are declared.
 */
#ifndef _OBSD_COMPAT_DEV_RASOPS_RASOPS_H
#define _OBSD_COMPAT_DEV_RASOPS_RASOPS_H
#include <obsd_prelude.h>
#include <dev/wscons/wsdisplayvar.h>
struct rasops_info {
	int	ri_flg;
	int	ri_depth;
	u_char	*ri_bits;
	int	ri_width;
	int	ri_height;
	int	ri_stride;
	struct wsdisplay_font *ri_font;
	int	ri_rows;
	int	ri_cols;
	int	ri_caps;
	u_char	ri_rnum, ri_gnum, ri_bnum;
	u_char	ri_rpos, ri_gpos, ri_bpos;
	void	*ri_hw;
	void	*ri_active;
	struct wsdisplay_emulops ri_ops;
	u_char	*ri_prime;
};
#define RI_CLEAR	0x01
#define RI_CENTER	0x02
#define RI_FULLCLEAR	0x04
#define RI_VCONS	0x0400
#define RI_WRONLY	0x0800
#define RI_ROTATE_CW	0x0010
#define RI_ROTATE_CCW	0x0400
struct wsscreen_descr;
struct wsdisplay_charcell;
extern int rasops_init(struct rasops_info *, int, int);
extern int rasops_alloc_screen(void *, void **, int *, int *, uint32_t *);
extern void rasops_free_screen(void *, void *);
extern int rasops_show_screen(void *, void *, int, void (*)(void *, int, int),
    void *);
extern int rasops_load_font(void *, void *, struct wsdisplay_font *);
extern int rasops_list_font(void *, struct wsdisplay_font *);
extern int rasops_getchar(void *, int, int, struct wsdisplay_charcell *);
extern void rasops_scrollback(void *, void *, int);
#endif
