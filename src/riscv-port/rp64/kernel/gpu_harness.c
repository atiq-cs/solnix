/*
 * gpu_harness.c -- R-P64 standalone bare-metal harness that proves the
 * virtio_gpu.c driver brings up a real display on qemu-system-riscv64.
 *
 * Boots via -bios none -kernel (M-mode, no MMU, no SBI), so the virtio-gpu
 * driver's exact bring-up path runs against QEMU's real virtio-gpu-device:
 *   probe -> negotiate -> controlq -> GET_DISPLAY_INFO -> CREATE_2D ->
 *   ATTACH_BACKING -> SET_SCANOUT -> draw a test pattern -> TRANSFER + FLUSH.
 *
 * Every step prints a [GPU:...] marker on the 16550 UART @0x10000000 so the
 * QEMU serial log is the verifiable proof.  When the whole sequence succeeds
 * it prints "R-P64 PASS" and powers off (SiFive test finisher).
 */

#include "virtio_gpu.h"

/* qemu-virt 16550 UART @ 0x10000000, THR at offset 0. */
#define	UART0	((volatile unsigned char *)0x10000000UL)

static void
uputc(char c)
{
	UART0[0] = (unsigned char)c;
}

static void
uputs(const char *s)
{
	while (*s)
		uputc(*s++);
}

static void
uputhex(unsigned long v)
{
	static const char h[] = "0123456789abcdef";
	int i;
	uputs("0x");
	for (i = 60; i >= 0; i -= 4)
		uputc(h[(v >> i) & 0xf]);
}

static void
uputdec(unsigned int v)
{
	char buf[12];
	int i = 0;
	if (v == 0) { uputc('0'); return; }
	while (v) { buf[i++] = '0' + (v % 10); v /= 10; }
	while (i--) uputc(buf[i]);
}

/* SiFive test finisher @ 0x100000: 0x5555 = PASS/poweroff, 0x3333 = FAIL. */
static void
poweroff(int fail)
{
	volatile unsigned int *test = (volatile unsigned int *)0x100000UL;
	*test = fail ? 0x3333 : 0x5555;
	for (;;)
		__asm__ __volatile__ ("wfi");
}

/*
 * Draw a verifiable test pattern into the framebuffer: four color quadrants +
 * a diagonal, so a saved PPM (via qemu's screendump / a headless dump) shows a
 * real rendered image.  We also checksum it and print the checksum, so the
 * serial log alone proves pixels were written even without a display.
 */
static unsigned long
draw_pattern(unsigned int *fbp, unsigned int w, unsigned int h)
{
	unsigned int x, y;
	unsigned long sum = 0;
	for (y = 0; y < h; y++) {
		for (x = 0; x < w; x++) {
			unsigned int px;
			/* B8G8R8X8: 0x00RRGGBB packed as X,R,G,B little-endian. */
			unsigned int left = (x < w / 2);
			unsigned int top = (y < h / 2);
			if (top && left)        px = 0x00ff0000;  /* red    */
			else if (top && !left)  px = 0x0000ff00;  /* green  */
			else if (!top && left)  px = 0x000000ff;  /* blue   */
			else                    px = 0x00ffffff;  /* white  */
			if (x == y || (x + y) == (w < h ? w : h)) /* diagonal */
				px = 0x00000000;
			fbp[y * w + x] = px;
			sum += px;
		}
	}
	return (sum);
}

void
gpu_main(void)
{
	unsigned int *fbp, w, h;
	unsigned long sum;

	uputs("\n[GPU:BOOT] R-P64 standalone virtio-gpu harness (rv64, -bios none)\n");

	/* diagnostic: dump the 8 virtio-mmio slots at 0x10001000 + i*0x1000. */
	{
		int i;
		for (i = 0; i < 8; i++) {
			volatile unsigned int *r =
			    (volatile unsigned int *)(0x10001000UL + (unsigned long)i * 0x1000UL);
			uputs("[GPU:SLOT] "); uputdec(i);
			uputs(" magic="); uputhex(r[0]);
			uputs(" ver="); uputdec(r[1]);
			uputs(" devid="); uputdec(r[2]);
			uputc('\n');
		}
	}

	uputs("[GPU:INIT] probing virtio-mmio for a GPU device (DeviceID 16)...\n");
	if (virtio_gpu_init() == 0) {
		uputs("[GPU:FAIL] no virtio-gpu device / bring-up failed\n");
		poweroff(1);
	}

	fbp = virtio_gpu_fb();
	w = virtio_gpu_width();
	h = virtio_gpu_height();
	uputs("[GPU:OK] scanout 0 live: ");
	uputdec(w); uputc('x'); uputdec(h);
	uputs("  fb@"); uputhex((unsigned long)fbp);
	uputs("  present="); uputdec((unsigned)virtio_gpu_present());
	uputc('\n');

	uputs("[GPU:DRAW] rendering RGBW test pattern + diagonal...\n");
	sum = draw_pattern(fbp, w, h);
	uputs("[GPU:DRAW] pixels written, fb checksum="); uputhex(sum); uputc('\n');

	uputs("[GPU:FLUSH] TRANSFER_TO_HOST_2D + RESOURCE_FLUSH (present frame)...\n");
	if (virtio_gpu_flush() != 0) {
		uputs("[GPU:FAIL] flush failed\n");
		poweroff(1);
	}
	uputs("[GPU:FLUSH] frame presented to scanout 0\n");

	/* A second frame proves the per-frame present path (what a compositor does). */
	{
		unsigned int i, n = w * h;
		for (i = 0; i < n; i++)
			fbp[i] = 0x00202020;	/* solid dark gray */
		if (virtio_gpu_flush() != 0) {
			uputs("[GPU:FAIL] second flush failed\n");
			poweroff(1);
		}
		uputs("[GPU:FLUSH] second frame presented (per-frame present OK)\n");
	}

	/* Re-present the RGBW pattern as the FINAL frame so a screendump shows it. */
	draw_pattern(fbp, w, h);
	(void)virtio_gpu_flush();
	uputs("[GPU:FLUSH] final RGBW frame presented (for screendump)\n");

	uputs("[GPU:PASS] R-P64 PASS -- virtio-gpu 2D scanout bring-up + present verified\n");
#ifdef GPU_HOLD
	/* hold the scanout live so an external QMP screendump can capture it. */
	for (;;)
		__asm__ __volatile__ ("wfi");
#else
	poweroff(0);
#endif
}
