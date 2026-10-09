/*
 * OpenBSD <dev/wscons/wsdisplayvar.h>, the subset inteldrm's wsdisplay
 * attach names (i915_driver.c). Types and declarations only: the illumos
 * console stays vgatext / gfxp_bitmap and the wsdisplay attach is replaced
 * by an illumos attach, so none of these functions is ever implemented.
 * Field layouts follow OpenBSD so the designated initialisers compile.
 */
#ifndef _OBSD_COMPAT_DEV_WSCONS_WSDISPLAYVAR_H
#define _OBSD_COMPAT_DEV_WSCONS_WSDISPLAYVAR_H
#include <obsd_prelude.h>
#include <dev/wscons/wsconsio.h>
struct wsdisplay_emulops {
	int	(*cursor)(void *, int, int, int);
	int	(*mapchar)(void *, int, unsigned int *);
	int	(*putchar)(void *, int, int, u_int, uint32_t);
	int	(*copycols)(void *, int, int, int, int);
	int	(*erasecols)(void *, int, int, int, uint32_t);
	int	(*copyrows)(void *, int, int, int);
	int	(*eraserows)(void *, int, int, uint32_t);
	int	(*pack_attr)(void *, int, int, int, uint32_t *);
	void	(*unpack_attr)(void *, uint32_t, int *, int *, int *);
};
#define WSSCREEN_NAME_SIZE	16
struct wsscreen_descr {
	char name[WSSCREEN_NAME_SIZE];
	int ncols, nrows;
	const struct wsdisplay_emulops *textops;
	int fontwidth, fontheight;
	int capabilities;
};
#define WSSCREEN_WSCOLORS	1
#define WSSCREEN_REVERSE	2
#define WSSCREEN_HILIT		4
#define WSSCREEN_BLINK		8
#define WSSCREEN_UNDERLINE	16
struct wsscreen_list {
	int nscreens;
	const struct wsscreen_descr **screens;
};
struct wsdisplay_accessops {
	int	(*ioctl)(void *, u_long, caddr_t, int, struct proc *);
	paddr_t	(*mmap)(void *, off_t, int);
	int	(*alloc_screen)(void *, const struct wsscreen_descr *, void **,
		    int *, int *, uint32_t *);
	void	(*free_screen)(void *, void *);
	int	(*show_screen)(void *, void *, int, void (*)(void *, int, int),
		    void *);
	int	(*load_font)(void *, void *, struct wsdisplay_font *);
	int	(*list_font)(void *, struct wsdisplay_font *);
	void	(*scrollback)(void *, void *, int);
	int	(*getchar)(void *, int, int, struct wsdisplay_charcell *);
	void	(*burn_screen)(void *, u_int, u_int);
	void	(*pollc)(void *, int);
	void	(*enter_ddb)(void *, void *);
};
struct wsemuldisplaydev_attach_args {
	int	console;
	int	primary;
	const struct wsscreen_list *scrdata;
	const struct wsdisplay_accessops *accessops;
	void	*accesscookie;
	u_int	defaultscreens;
};
#define WSDISPLAY_BURN_VBLANK	0x0001
#define WSDISPLAY_BURN_KBD	0x0002
#define WSDISPLAY_BURN_MOUSE	0x0004
#define WSDISPLAY_BURN_OUTPUT	0x0008
extern int (*ws_get_param)(struct wsdisplay_param *);
extern int (*ws_set_param)(struct wsdisplay_param *);
extern void wsdisplay_cnattach(const struct wsscreen_descr *, void *, int,
    int, uint32_t);
extern int wsemuldisplaydevprint(void *, const char *);
extern int wsemuldisplaydevsubmatch(struct device *, void *, void *);
#endif
