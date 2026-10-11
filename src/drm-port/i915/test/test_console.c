/*
 * test_console.c -- userland characterization of two things the recovered
 * i915 console-handover code depends on:
 *
 *   PART A: the fbdev console draw arithmetic in the recovered i915_illumos.c
 *     (i915_cons_display / i915_cons_copy / i915_cons_clear). The kernel
 *     routines are static and draw into a device framebuffer; this test
 *     reimplements the SAME offset math against a RAM buffer and asserts the
 *     pixels land where the kernel code would put them.
 *
 *   PART B: tem's modechange-callback CONTRACT, so the claim "the console
 *     handover succeeded" is executable rather than merely logged. The
 *     recovered i915_cons_modeset_done hands tem a new vis_devinit through
 *     tems_modechange_callback and logs success. The runtime audit
 *     (docs/x1-gpu-runtime-audit.md section 4(b)) found this is WRONG for the
 *     common same-mode handover. Part B encodes tem's actual decision so that
 *     the wrong assumption fails a check instead of printing a success line.
 *
 *     tem.c is PINNED, not matched to the live kernel yet:
 *       reference /tmp/streamE5-illumos/tem.c
 *       sha256 3d925906b4534635795c16f5a96c0fd9080ae6709c6fb6084a7bbad614d301fa
 *     The tems_check_videomode comparison below is transcribed verbatim from
 *     that file's lines 538-558; the modechange control flow mirrors lines
 *     669-731; the fact that ts_fb_polledio is assigned ONLY in VIS_DEVINIT
 *     is from line 484 (it is NOT touched by the modechange path). This is a
 *     MODEL of tem, labelled as such: tem_impl.h (tem_state_t) is a private
 *     kernel header absent from the gate proto, so compiling tem's real body
 *     would need the whole tem emulator the audit said to avoid. The model
 *     reads the same five fields the real tems_check_videomode reads and
 *     applies the same comparison, so a wrong handover assumption is caught.
 *
 *   PART C: the VIS_DEVINIT ownership contract -- the CORRECT mechanism, the
 *     one the design (CONSOLE-HANDOVER-DESIGN.md) says is the ONLY path that
 *     sets up / takes over the tem console. Two facts, modelled verbatim from
 *     pinned source:
 *       (1) gfxp_fb.c do_gfx_ioctl L354-367: VIS_DEVINIT from userland (no
 *           FKIOCTL) returns ENXIO and captures NOTHING. This is the hole the
 *           recovered i915_cons_ioctl reopened (arbitrary modechg_cb from a
 *           userland arg = kernel code-exec); the model proves it stays shut.
 *       (2) tem.c L466/L484: a kernel (FKIOCTL) VIS_DEVINIT is the ONLY place
 *           ts_fb_polledio is set and the ONLY path that establishes/moves the
 *           console. Part B proves the modechange callback does NOT; Part C
 *           proves VIS_DEVINIT does, and that userland cannot reach it.
 *
 *   cc -m64 -O2 -Wall -o test_console test/test_console.c && ./test_console
 *   cc -DSABOTAGE         ... ./test_console  # draw-math control: must FAIL
 *   cc -DSABOTAGE_TEM     ... ./test_console  # tem-contract control: must FAIL
 *   cc -DSABOTAGE_DEVINIT ... ./test_console  # devinit-gate control: must FAIL
 *
 * Part A mirrors the geometry handling only (NULL/negative/clip, scan-line
 * advance, overlap direction); it does not need the kernel headers. Parts B
 * and C are MODELs of private-header kernel state, labelled as such.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

struct fb { uint8_t *bits; int w, h, stride, depth; };
struct disp { int row, col, width, height; const uint8_t *data; };
struct copy { int s_row, s_col, e_row, e_col, t_row, t_col; };

static int bpp(struct fb *f) { return ((f->depth + 7) / 8); }

/* Identical to i915_cons_display. */
static void
cons_display(struct fb *f, struct disp *da)
{
	int b = bpp(f), rowbytes = da->width * b, y, maxw, maxh;
	uint8_t *dst;
	const uint8_t *src = da->data;

	if (f->bits == NULL || src == NULL) return;
	if (da->row < 0 || da->col < 0) return;
	maxw = f->w - da->col; maxh = f->h - da->row;
	if (maxw <= 0 || maxh <= 0) return;
	if (da->width > maxw) rowbytes = maxw * b;
	dst = f->bits + (size_t)da->row * f->stride + (size_t)da->col * b;
	for (y = 0; y < da->height && y < maxh; y++) {
		memcpy(dst, src, rowbytes);
		dst += f->stride;
		src += da->width * b;
	}
}

/* Identical to i915_cons_copy. */
static void
cons_copy(struct fb *f, struct copy *ca)
{
	int b = bpp(f), w = ca->e_col - ca->s_col + 1, h = ca->e_row - ca->s_row + 1;
	int rowbytes = w * b, y;
	uint8_t *base = f->bits;

	if (base == NULL || w <= 0 || h <= 0) return;
#ifdef SABOTAGE
	/* always top-down: wrong for a downward overlapping copy */
	for (y = 0; y < h; y++) {
#else
	if (ca->t_row <= ca->s_row) { for (y = 0; y < h; y++) {
#endif
		memmove(base + (size_t)(ca->t_row + y) * f->stride + (size_t)ca->t_col * b,
		    base + (size_t)(ca->s_row + y) * f->stride + (size_t)ca->s_col * b, rowbytes);
#ifdef SABOTAGE
	}
#else
	} } else { for (y = h - 1; y >= 0; y--) {
		memmove(base + (size_t)(ca->t_row + y) * f->stride + (size_t)ca->t_col * b,
		    base + (size_t)(ca->s_row + y) * f->stride + (size_t)ca->s_col * b, rowbytes);
	} }
#endif
}

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

/* ---------------------------------------------------------------- PART B
 * tem's modechange-callback contract, modelled from pinned tem.c.
 *
 * Only the state tems_check_videomode (tem.c:538) and the modechange path
 * (tem.c:669) actually read is modelled. The handover gives tem a vis_devinit
 * for the new (fbdev) buffer; tem decides whether to repaint and NEVER moves
 * its polled-I/O pointer in this path -- ts_fb_polledio is set only by
 * VIS_DEVINIT (tem.c:484), which the handover does not reissue.
 */
struct tem_dim { int width, height; };
struct tem_model {
	int ts_pdepth;			/* current pixel depth */
	struct tem_dim ts_c_dimension;	/* text (char) geometry */
	struct tem_dim ts_p_dimension;	/* pixel geometry */
	void *ts_fb_polledio;		/* panic/kmdb console pointer */
	int repainted;			/* set when tem reinits/repaints */
};

/* VIS_TEXT=0, VIS_PIXEL=1 (sys/visual_io.h). The handover uses VIS_PIXEL. */
struct tem_devinit { int depth, mode, width, height; void *polledio; };

#define TEMS_DEPTH_DIFF     0x01
#define TEMS_DIMENSION_DIFF 0x02

/* Transcribed verbatim from tem.c:538-558 (tems_check_videomode). */
static unsigned char
model_check_videomode(struct tem_model *tems, struct tem_devinit *tp)
{
	unsigned char result = 0;

	if (tems->ts_pdepth != tp->depth)
		result |= TEMS_DEPTH_DIFF;
	if (tp->mode == 0 /* VIS_TEXT */) {
		if (tems->ts_c_dimension.width != tp->width ||
		    tems->ts_c_dimension.height != tp->height)
			result |= TEMS_DIMENSION_DIFF;
	} else {
		if (tems->ts_p_dimension.width != tp->width ||
		    tems->ts_p_dimension.height != tp->height)
			result |= TEMS_DIMENSION_DIFF;
	}
	return (result);
}

/*
 * tem.c:669 tems_modechange_callback, control flow mirrored:
 *   diff = check_videomode(); if (diff == 0) return;         (no repaint)
 *   diff &= TEMS_DIMENSION_DIFF;
 *   if (diff == 0) { ts_pdepth = depth; reinit active; return; }  (depth-only)
 *   else { setup_terminal + reinit all; }                     (full repaint)
 * In NO branch is ts_fb_polledio reassigned -- that happens only at
 * VIS_DEVINIT (tem.c:484). SABOTAGE_TEM models the WRONG belief that a
 * same-mode callback repaints and swaps the polled pointer.
 */
static void
model_modechange_callback(struct tem_model *tems, struct tem_devinit *di)
{
#ifdef SABOTAGE_TEM
	/* the refuted assumption: handover always repaints and takes over
	 * the panic/kmdb console. */
	tems->repainted = 1;
	tems->ts_fb_polledio = di->polledio;
	tems->ts_pdepth = di->depth;
	return;
#else
	unsigned char diff = model_check_videomode(tems, di);

	if (diff == 0)
		return;			/* same mode: tem returns, no repaint */
	diff &= TEMS_DIMENSION_DIFF;
	if (diff == 0) {
		tems->ts_pdepth = di->depth;	/* depth-only: reinit active */
		tems->repainted = 1;
		return;
	}
	/* dimension changed: full setup_terminal + reinit all */
	tems->ts_p_dimension.width = di->width;
	tems->ts_p_dimension.height = di->height;
	tems->ts_pdepth = di->depth;
	tems->repainted = 1;
#endif
}

/* VIS_DEVINIT (tem.c:460-484): the ONLY place ts_fb_polledio is set. */
static void
model_vis_devinit(struct tem_model *tems, struct tem_devinit *di)
{
	tems->ts_fb_polledio = di->polledio;
	tems->ts_pdepth = di->depth;
	tems->ts_p_dimension.width = di->width;
	tems->ts_p_dimension.height = di->height;
}

static void
test_tem_contract(void)
{
	/* GOP console established via VIS_DEVINIT at 3840x2160/32bpp pixel mode,
	 * polled console = the GOP (gfxp) buffer. */
	int gop_poll = 1, fbdev_poll = 2;
	struct tem_model tems = {0};
	struct tem_devinit gop = { 32, 1, 3840, 2160, &gop_poll };

	model_vis_devinit(&tems, &gop);
	CHECK(tems.ts_fb_polledio == &gop_poll);	/* polled = GOP buffer */

	/* CASE 1 -- the common handover: i915_cons_modeset_done passes tem a
	 * NEW buffer at the SAME 3840x2160/32bpp. tems_check_videomode == 0,
	 * so tem returns with NO repaint and the polled console STAYS on the
	 * GOP buffer. This is the handover the recovered code logs as success.
	 * The non-sabotage model must show the handover did NOT take effect. */
	tems.repainted = 0;
	{
		struct tem_devinit fbdev = { 32, 1, 3840, 2160, &fbdev_poll };
		model_modechange_callback(&tems, &fbdev);
		CHECK(tems.repainted == 0);		/* no repaint on same mode */
		CHECK(tems.ts_fb_polledio == &gop_poll);/* polled NOT moved */
		CHECK(tems.ts_fb_polledio != &fbdev_poll);
	}

	/* CASE 2 -- changed geometry: the dimension differs, so tem takes the
	 * full setup_terminal + reinit (repaint) branch. The point being checked
	 * is which BRANCH tem takes (repaint vs early return), not tem's exact
	 * recomputed geometry -- real tem derives ts_p_dimension inside
	 * tems_setup_terminal, which this model does not reproduce. It still does
	 * NOT move ts_fb_polledio. */
	tems.repainted = 0;
	{
		struct tem_devinit fbdev = { 32, 1, 1920, 1080, &fbdev_poll };
		CHECK((model_check_videomode(&tems, &fbdev) &
		    TEMS_DIMENSION_DIFF) != 0);		/* dimension differs */
		model_modechange_callback(&tems, &fbdev);
		CHECK(tems.repainted == 1);		/* -> repaint branch */
		CHECK(tems.ts_fb_polledio == &gop_poll);/* still not moved */
	}

	/* CASE 3 -- changed depth, same geometry: TEMS_DEPTH_DIFF only. tem
	 * reinits the active tem and updates ts_pdepth; dimension path skipped. */
	tems.ts_pdepth = 32;
	tems.ts_p_dimension.width = 1920; tems.ts_p_dimension.height = 1080;
	tems.repainted = 0;
	{
		struct tem_devinit fbdev = { 16, 1, 1920, 1080, &fbdev_poll };
		CHECK((model_check_videomode(&tems, &fbdev) & TEMS_DEPTH_DIFF) != 0);
		model_modechange_callback(&tems, &fbdev);
		CHECK(tems.ts_pdepth == 16);		/* depth adopted */
		CHECK(tems.repainted == 1);		/* active tem reinit */
	}

	/* CASE 4 -- the only safe way to move the polled console is a fresh
	 * VIS_DEVINIT, which the recovered handover does NOT issue. */
	{
		struct tem_devinit fbdev = { 32, 1, 3840, 2160, &fbdev_poll };
		model_vis_devinit(&tems, &fbdev);
		CHECK(tems.ts_fb_polledio == &fbdev_poll);	/* now moved */
	}
}

/* ---------------------------------------------------------------- PART C
 * The VIS_DEVINIT ownership gate (gfxp_fb.c do_gfx_ioctl, L354-367), modelled
 * verbatim. This is the SECURITY contract the recovered i915_cons_ioctl broke:
 * a userland VIS_DEVINIT must be refused with ENXIO and must capture no
 * pointer; only a kernel (FKIOCTL) VIS_DEVINIT may establish the console and
 * adopt the driver's polledio. Combined with Part B this is the whole truth:
 * the CORRECT mechanism (VIS_DEVINIT, kernel-only) both moves the polled
 * pointer and repaints; the modechange callback does neither.
 */
#define MODEL_FKIOCTL 0x80000000u	/* sys/file.h FKIOCTL, value irrelevant */
#define MODEL_ENXIO   6		/* value irrelevant; nonzero == rejected */

/*
 * model_gfx_devinit: returns 0 and installs polledio on success, or an errno
 * and installs NOTHING on rejection. Transcribed from gfxp_fb.c:
 *   case VIS_DEVINIT:
 *       if (!(mode & FKIOCTL)) { "kernel only"; return ENXIO; }
 *       err = devinit(...);  // installs data->polledio into the fb softc,
 *                            // tem then does ts_fb_polledio = data->polledio
 */
static int
model_gfx_devinit(struct tem_model *tems, struct tem_devinit *di, unsigned mode)
{
#ifdef SABOTAGE_DEVINIT
	/* the recovered bug: capture the caller's pointer BEFORE the FKIOCTL
	 * check (i915_cons_ioctl stored di.modechg_cb/arg unconditionally).
	 * A userland open thereby hands the kernel a pointer it later calls. */
	tems->ts_fb_polledio = di->polledio;
	if (!(mode & MODEL_FKIOCTL))
		return (MODEL_ENXIO);
	tems->repainted = 1;
	return (0);
#else
	if (!(mode & MODEL_FKIOCTL))
		return (MODEL_ENXIO);	/* userland: reject, capture nothing */
	/* kernel path: devinit installs polledio, tem adopts it and repaints */
	tems->ts_fb_polledio = di->polledio;
	tems->ts_pdepth = di->depth;
	tems->ts_p_dimension.width = di->width;
	tems->ts_p_dimension.height = di->height;
	tems->repainted = 1;
	return (0);
#endif
}

static void
test_devinit_gate(void)
{
	int gop_poll = 1, attacker_poll = 0xdead, kernel_poll = 2;
	struct tem_model tems = {0};
	struct tem_devinit gop = { 32, 1, 3840, 2160, &gop_poll };

	/* console already up on the GOP buffer (kernel VIS_DEVINIT at boot). */
	(void) model_gfx_devinit(&tems, &gop, MODEL_FKIOCTL);
	CHECK(tems.ts_fb_polledio == &gop_poll);

	/* ATTACK -- a userland process opens text-0 and issues VIS_DEVINIT with
	 * its own polledio pointer. gfxp rejects it: ENXIO, and the kernel's
	 * polled console pointer is NOT replaced by the attacker's. This is the
	 * exact RCE the recovered i915_cons_ioctl reopened; the model proves the
	 * supported path keeps it shut. (SABOTAGE_DEVINIT flips both checks.) */
	tems.repainted = 0;
	{
		struct tem_devinit evil = { 32, 1, 3840, 2160, &attacker_poll };
		int rv = model_gfx_devinit(&tems, &evil, 0 /* no FKIOCTL */);
		CHECK(rv == MODEL_ENXIO);		/* userland rejected */
		CHECK(tems.ts_fb_polledio == &gop_poll);/* pointer NOT captured */
		CHECK(tems.ts_fb_polledio != &attacker_poll);
		CHECK(tems.repainted == 0);		/* no console action */
	}

	/* KERNEL -- the supported takeover: a kernel-context VIS_DEVINIT (as tem
	 * issues from WC_OPEN_FB, FWRITE|FKIOCTL) DOES move the polled pointer and
	 * repaint. This is the only path that does both -- contrast Part B, where
	 * the modechange callback at the same mode does neither. */
	tems.repainted = 0;
	{
		struct tem_devinit kern = { 32, 1, 3840, 2160, &kernel_poll };
		int rv = model_gfx_devinit(&tems, &kern, MODEL_FKIOCTL);
		CHECK(rv == 0);				/* kernel accepted */
		CHECK(tems.ts_fb_polledio == &kernel_poll);/* polled moved */
		CHECK(tems.repainted == 1);		/* repaint happened */
	}
}

static uint32_t
px(struct fb *f, int x, int y)
{
	uint32_t v = 0;
	memcpy(&v, f->bits + (size_t)y * f->stride + (size_t)x * 4, 4);
	return v;
}

int
main(void)
{
	int W = 64, H = 48, S = W * 4;
	struct fb f = { calloc(H, S), W, H, S, 32 };
	uint32_t *data;
	struct disp da;
	struct copy ca;
	int i;

	/* display a 4x2 block of 0xaabbccdd at (row=3,col=5) */
	data = malloc(4 * 2 * 4);
	for (i = 0; i < 8; i++) data[i] = 0xaabbccdd;
	da.row = 3; da.col = 5; da.width = 4; da.height = 2; da.data = (uint8_t *)data;
	cons_display(&f, &da);
	CHECK(px(&f, 5, 3) == 0xaabbccdd);
	CHECK(px(&f, 8, 4) == 0xaabbccdd);	/* last pixel of the block */
	CHECK(px(&f, 9, 3) == 0);		/* just past the block */
	CHECK(px(&f, 4, 3) == 0);		/* just before */

	/* clip: a block wider/taller than the fb must not run past it */
	da.row = H - 1; da.col = W - 2; da.width = 10; da.height = 10;
	cons_display(&f, &da);			/* must not crash / overrun */
	CHECK(px(&f, W - 2, H - 1) == 0xaabbccdd);
	CHECK(px(&f, W - 1, H - 1) == 0xaabbccdd);

	/* copy a downward overlapping scroll where direction MATTERS: give rows
	 * 10,11,12 distinct markers, then copy rows 10..12 down to 11..13. A
	 * correct bottom-up copy yields rows 11,12,13 = {m10,m11,m12}. A wrong
	 * top-down copy smears m10 downward (row 11 reads back m10 after it was
	 * just written, so rows 11,12,13 all become m10). */
	{
		uint32_t m10 = 0x0a0a0a0a, m11 = 0x0b0b0b0b, m12 = 0x0c0c0c0c;
		for (i = 0; i < W; i++) {
			memcpy(f.bits + (size_t)10 * S + (size_t)i * 4, &m10, 4);
			memcpy(f.bits + (size_t)11 * S + (size_t)i * 4, &m11, 4);
			memcpy(f.bits + (size_t)12 * S + (size_t)i * 4, &m12, 4);
		}
		ca.s_row = 10; ca.s_col = 0; ca.e_row = 12; ca.e_col = W - 1;
		ca.t_row = 11; ca.t_col = 0;
		cons_copy(&f, &ca);
		/* correct: row 11<-m10, row 12<-m11, row 13<-m12 */
		CHECK(px(&f, 0, 11) == m10);
		CHECK(px(&f, 0, 12) == m11);	/* top-down smear would make this m10 */
		CHECK(px(&f, 0, 13) == m12);
	}

	/* PART B: tem's modechange-callback contract (refutes the recovered
	 * handover). PART C: the VIS_DEVINIT ownership gate (the correct,
	 * FKIOCTL-only mechanism; proves userland cannot inject a pointer). */
	test_tem_contract();
	test_devinit_gate();

	if (fails == 0) printf("PASS: console draw math + tem handover contract + devinit gate\n");
	else printf("%d CHECK(s) FAILED\n", fails);
	free(f.bits); free(data);
	return (fails != 0);
}
