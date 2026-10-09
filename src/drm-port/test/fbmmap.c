/*
 * fbmmap.c -- rung 0 of the X1 graphics route (docs/x1-gpu-route.md):
 * map the firmware (GOP) linear framebuffer from userland through the
 * console's vgatext node, draw a test pattern, read it back, restore.
 *
 * Path exercised: open(/dev/fb) -> vgatext cb_devmap -> gfxp_fb_devmap ->
 * gfxp_bitmap.c bitmap_devmap -> gfxp_map_devmem(fb_info.paddr).
 * No module load, no mode change unless -g is given.
 *
 * Usage: fbmmap [-g] [-k] [-n] [dev]
 *   -g  switch the console to KD_GRAPHICS for the draw, back to KD_TEXT after
 *   -k  keep the pattern on screen (skip the restore) and print its offset
 *   -n  negative control: verify against a pattern that was NOT written,
 *       which must report FAIL
 *   -s N  hold the pattern N seconds before restoring, so an independent
 *       observer (mdb -k reading the kernel's own mapping fb_info.fb) can
 *       confirm the writes reached the device aperture, not a private page
 *   -b  bandwidth: time full-width writes and reads of the bottom BOX rows
 *       (3840x256x4 = 3.75 MiB on the X1) through the mapping, then restore
 *   -r  read-only observer: map the device and check for the pattern another
 *       fbmmap -s left there; writes nothing (PASS only if the mapping is
 *       the shared device aperture, not a per-process page)
 * Exit status: 0 = mapped, pattern verified, restored; 1 = any failure.
 */
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/fbio.h>
#include <sys/visual_io.h>
#include <sys/kd.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>

/* The test box: BOX x BOX pixels in the bottom-right corner, away from text. */
#define	BOX	256

static uint32_t
pat(uint32_t x, uint32_t y, uint32_t salt)
{
	/* XRGB8888: red ramps with x, green with y, blue = salt. */
	return (((x & 0xff) << 16) | ((y & 0xff) << 8) | (salt & 0xff));
}

int
main(int argc, char **argv)
{
	const char *dev = "/dev/fb";
	int gmode = 0, keep = 0, neg = 0, hold = 0, ro = 0, bw = 0, c, fd, mode = -1, rc = 1;
	struct vis_identifier ident;
	struct fbgattr ga;
	struct gfxfb_info *gi;
	uint32_t w, h, pitch, bpp, x, y, x0, y0, bad = 0;
	size_t size;
	uint8_t *fb;
	uint32_t *save;

	while ((c = getopt(argc, argv, "bgknrs:")) != -1) {
		switch (c) {
		case 'g': gmode = 1; break;
		case 'k': keep = 1; break;
		case 'n': neg = 1; break;
		case 'b': bw = 1; break;
		case 'r': ro = 1; break;
		case 's': hold = atoi(optarg); break;
		default: return (2);
		}
	}
	if (optind < argc)
		dev = argv[optind];

	if ((fd = open(dev, O_RDWR)) < 0) {
		printf("FAIL open %s: %s\n", dev, strerror(errno));
		return (1);
	}
	(void) memset(&ident, 0, sizeof (ident));
	if (ioctl(fd, VIS_GETIDENTIFIER, &ident) == 0)
		printf("ident=%s\n", ident.name);
	else
		printf("VIS_GETIDENTIFIER: %s\n", strerror(errno));
	if (ioctl(fd, KDGETMODE, &mode) == 0)
		printf("kdmode=%d (KD_TEXT=%d KD_GRAPHICS=%d)\n", mode,
		    KD_TEXT, KD_GRAPHICS);
	else
		printf("KDGETMODE: %s\n", strerror(errno));
	(void) memset(&ga, 0, sizeof (ga));
	if (ioctl(fd, FBIOGATTR, &ga) != 0) {
		printf("FAIL FBIOGATTR: %s\n", strerror(errno));
		return (1);
	}
	gi = (struct gfxfb_info *)ga.sattr.dev_specific;
	w = ga.fbtype.fb_width;
	h = ga.fbtype.fb_height;
	bpp = ga.fbtype.fb_depth;
	pitch = gi->pitch;
	size = ga.fbtype.fb_size;
	printf("fbgattr: type=%d %ux%u depth=%u size=0x%zx pitch=%u "
	    "r%u@%u g%u@%u b%u@%u\n", ga.real_type, w, h, bpp, size, pitch,
	    gi->red_mask_size, gi->red_field_position, gi->green_mask_size,
	    gi->green_field_position, gi->blue_mask_size,
	    gi->blue_field_position);
	if (bpp != 32 || w < BOX || h < BOX || pitch < w * 4 ||
	    (size_t)pitch * h > size) {
		printf("FAIL unsupported geometry for this test\n");
		return (1);
	}

	fb = mmap(NULL, size, ro ? PROT_READ : PROT_READ | PROT_WRITE,
	    MAP_SHARED, fd, 0);
	if (fb == MAP_FAILED) {
		printf("FAIL mmap(len=0x%zx): %s (errno %d)\n", size,
		    strerror(errno), errno);
		return (1);
	}
	printf("mmap ok: va=%p len=0x%zx\n", (void *)fb, size);

	x0 = w - BOX;
	y0 = h - BOX;
	if (ro) {
		for (y = 0; y < BOX; y++)
			for (x = 0; x < BOX; x++)
				if ((*(volatile uint32_t *)(fb + (size_t)(y0 +
				    y) * pitch + (x0 + x) * 4) & 0xffffff) !=
				    pat(x, y, neg ? 0x5a : 0xa5))
					bad++;
		printf("observer: %u/%u pixels differ from the pattern -> %s\n",
		    bad, BOX * BOX, bad == 0 ? "PASS" : "FAIL");
		return (bad == 0 ? 0 : 1);
	}

	if (bw) {
		size_t band = (size_t)BOX * pitch, i;
		uint8_t *bp = fb + (size_t)(h - BOX) * pitch, *copy, *src;
		hrtime_t t0, t1;
		volatile uint64_t sum = 0;
		int it, n = 20;

		if ((copy = malloc(band)) == NULL || (src = malloc(band)) == NULL)
			return (1);
		(void) memcpy(copy, bp, band);
		for (i = 0; i < band; i++)
			src[i] = (uint8_t)(i * 7);
		t0 = gethrtime();
		for (it = 0; it < n; it++)
			(void) memcpy(bp, src, band);
		t1 = gethrtime();
		printf("write: %d x %zu B in %.1f ms = %.0f MB/s\n", n, band,
		    (t1 - t0) / 1e6, (double)n * band / ((t1 - t0) / 1e3));
		t0 = gethrtime();
		for (it = 0; it < 4; it++)
			for (i = 0; i < band; i += 8)
				sum += *(volatile uint64_t *)(bp + i);
		t1 = gethrtime();
		printf("read:  4 x %zu B in %.1f ms = %.0f MB/s\n", band,
		    (t1 - t0) / 1e6, 4.0 * band / ((t1 - t0) / 1e3));
		rc = memcmp(bp, src, band) == 0 ? 0 : 1;
		printf("bandwidth band verify -> %s\n", rc == 0 ? "PASS" : "FAIL");
		(void) memcpy(bp, copy, band);
		printf("restore -> %s\n", memcmp(bp, copy, band) == 0 ?
		    "PASS" : "FAIL");
		return (rc);
	}

	if (gmode) {
		if (ioctl(fd, KDSETMODE, KD_GRAPHICS) != 0)
			printf("KDSETMODE KD_GRAPHICS: %s\n", strerror(errno));
		else
			printf("KDSETMODE KD_GRAPHICS ok\n");
	}

	if ((save = malloc(BOX * BOX * 4)) == NULL)
		return (1);
	for (y = 0; y < BOX; y++)
		(void) memcpy(&save[y * BOX], fb + (size_t)(y0 + y) * pitch +
		    x0 * 4, BOX * 4);
	for (bad = 0, y = 0; y < BOX * BOX; y++)
		bad += save[y] != 0;
	printf("saved box: %u/%u pixels non-zero\n", bad, BOX * BOX);
	bad = 0;
	for (y = 0; y < BOX; y++)
		for (x = 0; x < BOX; x++)
			*(volatile uint32_t *)(fb + (size_t)(y0 + y) * pitch +
			    (x0 + x) * 4) = pat(x, y, 0xa5);
	/* Read back through the same mapping; -n checks a different salt. */
	for (y = 0; y < BOX; y++)
		for (x = 0; x < BOX; x++) {
			uint32_t v = *(volatile uint32_t *)(fb +
			    (size_t)(y0 + y) * pitch + (x0 + x) * 4);
			if ((v & 0xffffff) != pat(x, y, neg ? 0x5a : 0xa5))
				bad++;
		}
	printf("pattern box at (%u,%u) %ux%u, fb byte offset 0x%zx: "
	    "%u/%u pixels mismatched -> %s\n", x0, y0, BOX, BOX,
	    (size_t)y0 * pitch + x0 * 4, bad, BOX * BOX,
	    bad == 0 ? "PASS" : "FAIL");
	rc = bad == 0 ? 0 : 1;
	if (hold > 0) {
		printf("holding %d s; pixel (0,0) of box = 0x%08x\n", hold,
		    *(volatile uint32_t *)(fb + (size_t)y0 * pitch + x0 * 4));
		(void) fflush(stdout);
		(void) sleep(hold);
	}

	if (keep) {
		printf("kept on screen (no restore)\n");
	} else {
		for (y = 0; y < BOX; y++)
			(void) memcpy(fb + (size_t)(y0 + y) * pitch + x0 * 4,
			    &save[y * BOX], BOX * 4);
		for (bad = 0, y = 0; y < BOX; y++)
			if (memcmp(fb + (size_t)(y0 + y) * pitch + x0 * 4,
			    &save[y * BOX], BOX * 4) != 0)
				bad++;
		printf("restore: %u/%u rows differ -> %s\n", bad, BOX,
		    bad == 0 ? "PASS" : "FAIL");
		if (bad != 0)
			rc = 1;
	}
	if (gmode && ioctl(fd, KDSETMODE, KD_TEXT) != 0)
		printf("KDSETMODE KD_TEXT: %s\n", strerror(errno));
	(void) munmap(fb, size);
	(void) close(fd);
	return (rc);
}
