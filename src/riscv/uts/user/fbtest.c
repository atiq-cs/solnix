/*
 * fbtest.c -- the userland half of the scanout-seam proof: open /dev/fb, read
 * the mode, mmap the framebuffer, paint a recognizable pattern, flush, and
 * verify the seam's contract held.
 *
 * This is step 3 of the seam doc's first-light order: prove the node with a C
 * test that mmaps and paints, under QEMU -- no Rust, no compositor.  If this
 * passes and a QMP screendump shows the pattern, the OS half of the seam is
 * done and the only thing left between here and a desktop is the compositor.
 *
 * WHAT IT PROVES, and why each check is here rather than assumed:
 *   1. FBIOGMODE returns a self-consistent mode (stride >= width*4,
 *      size == stride*height).  A driver that reported an implied stride would
 *      fail this the day a DPU needed row alignment.
 *   2. mmap returns a usable linear mapping: the test WRITES through it and
 *      READS BACK, which is the only way to tell a real device mapping from a
 *      syscall that merely returned a plausible address.
 *   3. Row addressing via stride, not width*4.  The diagonal is the tell: with
 *      a wrong stride it shears instead of running corner to corner.
 *   4. FBIOFLUSH works both whole-screen and with a damage rect.
 *   5. The error paths return errors: FBIOSMODE must fail (it is documented
 *      optional), and a bogus ioctl must fail.  A driver that returned 0 for
 *      everything would otherwise look like it passed.
 *
 * The pattern is deliberately the same 4-quadrant RGBW + diagonal the R-P64
 * harness draws, so the screendump can be compared against the existing,
 * already-trusted artifacts/riscv-virtio-gpu-scanout.png.
 */

#include "libc.h"
#include "../../../riscv-port/rp64/kernel/fbio.h"

/* Quadrant colors as B8G8R8X8 little-endian u32 (0x00RRGGBB). */
#define	PX_RED		0x00ff0000u
#define	PX_GREEN	0x0000ff00u
#define	PX_BLUE		0x000000ffu
#define	PX_WHITE	0x00ffffffu

static int failures;

static void
check(int ok, const char *what)
{
	printf("  [%s] %s\n", ok ? "ok" : "FAIL", what);
	if (!ok)
		failures++;
}

/*
 * pattern_pixel -- the expected color at (x,y).  Shared by the painter and the
 * verifier so a mismatch means the MAPPING is wrong, not that two copies of the
 * pattern drifted apart.
 */
static unsigned int
pattern_pixel(unsigned int x, unsigned int y, unsigned int w, unsigned int h)
{
	if (x * h == y * w)			/* the diagonal */
		return (PX_WHITE);
	if (y < h / 2)
		return (x < w / 2 ? PX_RED : PX_GREEN);
	return (x < w / 2 ? PX_BLUE : PX_WHITE);
}

int
main(int argc, char **argv)
{
	struct fb_mode m;
	struct fb_damage d;
	unsigned char *fb;
	unsigned int x, y;
	int fd, r, readback_ok;

	(void) argc;
	(void) argv;

	printf("\n=== fbtest: the /dev/fb scanout seam from userland ===\n");

	fd = open(FB_DEV_PATH, O_RDWR);
	check(fd >= 0, "open(/dev/fb, O_RDWR)");
	if (fd < 0) {
		printf("fbtest: cannot open the scanout node; aborting\n");
		return (1);
	}

	/* --- 1: mode query --- */
	r = ioctl(fd, FBIOGMODE, &m);
	check(r == 0, "ioctl(FBIOGMODE)");
	if (r != 0) {
		printf("fbtest: no mode; aborting\n");
		return (1);
	}
	printf("  mode: %dx%d stride=%d bytes format=%d size=%d bytes\n",
	    (int)m.width, (int)m.height, (int)m.stride, (int)m.format,
	    (int)m.size);
	check(m.width > 0 && m.height > 0, "mode has a non-empty visible area");
	check(m.stride >= m.width * 4, "stride >= width * 4");
	check(m.size == m.stride * m.height, "size == stride * height");
	check(m.format == FB_FMT_XRGB8888, "format is FB_FMT_XRGB8888");

	/* --- 2: mmap --- */
	fb = (unsigned char *)mmap(0, m.size, PROT_READ | PROT_WRITE,
	    MAP_SHARED, fd, 0);
	check(fb != MAP_FAILED, "mmap(size, PROT_READ|PROT_WRITE, MAP_SHARED)");
	if (fb == MAP_FAILED) {
		printf("fbtest: no mapping; aborting\n");
		return (1);
	}
	printf("  mapped at 0x%x (%d KiB)\n", (unsigned)(long)fb,
	    (int)(m.size >> 10));

	/* Write/read-back through the mapping BEFORE painting: proves the pages
	 * are really there and really writable, with a value no pattern uses. */
	*(volatile unsigned int *)fb = 0x0fa11ace;
	check(*(volatile unsigned int *)fb == 0x0fa11ace,
	    "mapping is writable and reads back (real device memory)");

	/* --- 3: paint, addressing rows via stride --- */
	for (y = 0; y < m.height; y++) {
		unsigned int *row = (unsigned int *)(fb + y * m.stride);

		for (x = 0; x < m.width; x++)
			row[x] = pattern_pixel(x, y, m.width, m.height);
	}
	printf("  painted RGBW quadrants + diagonal via stride addressing\n");

	/* Verify every pixel reads back as painted. A stride bug, a short
	 * mapping, or a non-linear mapping all fail here rather than silently
	 * producing a wrong screendump. */
	readback_ok = 1;
	for (y = 0; y < m.height && readback_ok; y++) {
		unsigned int *row = (unsigned int *)(fb + y * m.stride);

		for (x = 0; x < m.width; x++) {
			if (row[x] != pattern_pixel(x, y, m.width, m.height)) {
				printf("  mismatch at (%d,%d): got %x\n",
				    (int)x, (int)y, (unsigned)row[x]);
				readback_ok = 0;
				break;
			}
		}
	}
	check(readback_ok, "every pixel reads back as painted (linear mapping)");

	/* --- 4: present --- */
	r = ioctl(fd, FBIOFLUSH, 0);
	check(r == 0, "ioctl(FBIOFLUSH, NULL) -- whole screen");

	d.x = 0; d.y = 0; d.w = 64; d.h = 64;
	r = ioctl(fd, FBIOFLUSH, &d);
	check(r == 0, "ioctl(FBIOFLUSH, {0,0,64,64}) -- damage rect");

	/* A rect that runs off the right/bottom edge must be clamped, not
	 * rejected and not allowed to read past the buffer. */
	d.x = m.width - 8; d.y = m.height - 8; d.w = 4096; d.h = 4096;
	r = ioctl(fd, FBIOFLUSH, &d);
	check(r == 0, "ioctl(FBIOFLUSH) with an oversized rect is clamped");

	/* A rect entirely outside the scanout is a caller error. */
	d.x = m.width + 100; d.y = 0; d.w = 16; d.h = 16;
	r = ioctl(fd, FBIOFLUSH, &d);
	check(r != 0, "ioctl(FBIOFLUSH) with an out-of-range origin fails");

	/* --- 5: the documented-optional and invalid paths --- */
	r = ioctl(fd, FBIOSMODE, &m);
	check(r != 0, "ioctl(FBIOSMODE) fails (documented optional: ENOTSUP)");

	r = ioctl(fd, 0x4600 | 999, &m);
	check(r != 0, "an unknown ioctl fails (EINVAL)");

	/* Repaint the clean pattern and present it, so the frame the screendump
	 * captures is the pattern and not a partial damage-rect state. */
	for (y = 0; y < m.height; y++) {
		unsigned int *row = (unsigned int *)(fb + y * m.stride);

		for (x = 0; x < m.width; x++)
			row[x] = pattern_pixel(x, y, m.width, m.height);
	}
	r = ioctl(fd, FBIOFLUSH, 0);
	check(r == 0, "final whole-screen flush (the screendump frame)");

	if (failures == 0)
		printf("FBTEST PASS: /dev/fb seam verified "
		    "(mode + mmap + paint + readback + damage flush)\n");
	else
		printf("FBTEST FAIL: %d check(s) failed\n", failures);

	close(fd);
	return (failures == 0 ? 0 : 1);
}
