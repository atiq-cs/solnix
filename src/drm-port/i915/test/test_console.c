/*
 * test_console.c -- userland self-check of the fbdev console draw arithmetic
 * in i915_illumos.c (i915_cons_display / i915_cons_copy / i915_cons_clear).
 * The kernel routines are static and draw into a device framebuffer; this
 * test reimplements the SAME offset math against a RAM buffer and asserts
 * the pixels land where the kernel code would put them, with a negative
 * control (SABOTAGE) that must FAIL.
 *
 *   cc -m64 -O2 -Wall -o test_console test/test_console.c && ./test_console
 *   cc -DSABOTAGE ... ./test_console   # must report FAIL
 *
 * This mirrors the geometry handling only (NULL/negative/clip, scan-line
 * advance, overlap direction); it does not need the kernel headers.
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

	if (fails == 0) printf("PASS: console draw math (9 checks)\n");
	else printf("%d CHECK(s) FAILED\n", fails);
	free(f.bits); free(data);
	return (fails != 0);
}
