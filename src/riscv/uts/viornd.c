/*
 * viornd.c -- rvlogin: virtio-rng (VirtIO 1.2 section 5.4), the kernel's entropy
 * source, and getrandom(2) (Linux riscv number 278) on top of it.
 *
 * One request queue: the driver posts a device-writable buffer and the device fills
 * it from qemu's host RNG backend (rng-builtin = the host's getrandom). There is no
 * kernel DRBG and deliberately no fallback: without a virtio-rng device getrandom
 * fails ENOSYS, so a daemon that needs keys refuses to start instead of running on
 * guessable numbers (the timer CSR is not entropy).
 */
#include "sbi.h"
#include "riscv_regs.h"
#include "virtio.h"

extern unsigned long page_alloc(void);
extern long copyout(const void *kaddr, void *uaddr, unsigned long n);

#define	VIORND_CHUNK	256
#define	GRND_KNOWN	3	/* GRND_NONBLOCK | GRND_RANDOM: never blocks here */

static struct virtq viornd_q;
static unsigned long viornd_buf;	/* one DMA page, device-writable */
static int viornd_ready;
static volatile int viornd_lock;	/* one request in flight, any hart */

int
viornd_attach(void)
{
	struct virtio_dev *vd = virtio_find(VIRTIO_ID_RNG);

	if (vd == 0) {
		sbi_console_puts("[viornd] no virtio-rng device: getrandom is ENOSYS\n");
		return (0);
	}
	virtio_reset_ack(vd);
	(void) virtio_get_features(vd);
	if (!virtio_set_features(vd, 0) || !virtq_setup(vd, 0, &viornd_q) ||
	    (viornd_buf = page_alloc()) == 0) {
		sbi_console_puts("[viornd] attach FAILED\n");
		return (0);
	}
	virtio_driver_ok(vd);
	viornd_ready = 1;
	sbi_console_puts("[viornd] virtio-rng attached\n");
	return (1);
}

/*
 * One device request for up to VIORND_CHUNK bytes into kb; returns bytes, -5 EIO.
 * shortcut: polls the used ring with SIE off under a spinlock (one request in flight, any hart);
 * use the PLIC completion IRQ + a sleep when getrandom is hot enough to stall other harts.
 */
static long
viornd_read(unsigned char *kb, unsigned int n)
{
	unsigned long prev;
	unsigned int got, i;
	int old, d, id;

	__asm__ __volatile__("csrrc %0, sstatus, %1"
	    : "=r"(prev) : "r"((unsigned long)SSTATUS_SIE) : "memory");
	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, (%1)"
		    : "=&r"(old) : "r"(&viornd_lock), "r"(1) : "memory");
	} while (old != 0);
	got = 0;
	if ((d = virtq_alloc_desc(&viornd_q)) >= 0) {
		viornd_q.vq_desc[d].addr = viornd_buf;
		viornd_q.vq_desc[d].len = n;
		viornd_q.vq_desc[d].flags = VIRTQ_DESC_F_WRITE;
		viornd_q.vq_desc[d].next = 0;
		virtq_submit(&viornd_q, d);
		id = virtq_poll_used(&viornd_q);
		if (id == d) {
			got = viornd_q.vq_used->ring[(unsigned short)
			    (viornd_q.vq_last_used - 1) % viornd_q.vq_num].len;
			if (got > n)
				got = n;
			__asm__ __volatile__("fence r, r" ::: "memory");
			for (i = 0; i < got; i++)
				kb[i] = ((volatile unsigned char *)viornd_buf)[i];
			for (i = 0; i < got; i++)	/* do not leave the bytes behind */
				((volatile unsigned char *)viornd_buf)[i] = 0;
		}
		virtq_free_desc(&viornd_q, d);
	}
	__asm__ __volatile__("amoswap.w.rl zero, zero, (%0)"
	    :: "r"(&viornd_lock) : "memory");
	if (prev & SSTATUS_SIE)
		__asm__ __volatile__("csrs sstatus, %0" :: "r"(SSTATUS_SIE) : "memory");
	return (got > 0 ? (long)got : -5 /* EIO */);
}

/* getrandom(buf, len, flags): up to 4096 bytes per call (a short count is allowed). */
long
sys_getrandom(unsigned long ubuf, unsigned long len, unsigned int flags)
{
	unsigned char kb[VIORND_CHUNK];
	unsigned long done = 0;
	long r;

	if (flags & ~GRND_KNOWN)
		return (-22 /* EINVAL */);
	if (!viornd_ready)
		return (-38 /* ENOSYS */);
	if (len > 4096)
		len = 4096;
	while (done < len) {
		unsigned int n = (len - done > VIORND_CHUNK) ? VIORND_CHUNK :
		    (unsigned int)(len - done);

		if ((r = viornd_read(kb, n)) < 0)
			return (done > 0 ? (long)done : r);
		if (copyout(kb, (void *)(ubuf + done), (unsigned long)r) != 0)
			return (-14 /* EFAULT */);
		done += (unsigned long)r;
	}
	for (r = 0; r < VIORND_CHUNK; r++)
		((volatile unsigned char *)kb)[r] = 0;
	return ((long)done);
}
