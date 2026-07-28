/*
 * virtio.c — illumos riscv64 virtio-mmio transport + virtqueue layer (R-P6).
 *
 * The device-discovery + DMA-ring substrate every virtio driver (blk, net)
 * sits on. On qemu 'virt' the virtio devices are exposed via the virtio-MMIO
 * transport: 8 device slots at PA 0x10001000 .. 0x10008000, stride 0x1000,
 * PLIC IRQ lines 1..8 (from the DTB). qemu populates them in reverse: the
 * first `-device virtio-blk-device` lands in the HIGHEST slot (0x10008000,
 * IRQ 8). Empty slots read DeviceID 0.
 *
 * Reference: VirtIO spec 1.2 §4.2 (MMIO transport) + §2.7 (split virtqueue),
 * cross-checked against NetBSD sys/dev/virtio/virtio_mmio.c and Linux
 * drivers/virtio/virtio_mmio.c for the register layout + init handshake.
 * Reimplemented in illumos idiom from the spec (no CDDL-incompatible copy).
 *
 * We implement the MODERN (version 2) transport that qemu 10.x defaults to.
 *
 * DMA is trivial here: the whole 0x80000000 RAM GiB is identity-mapped
 * (VA==PA) by the R-P3 boot HAT, and page_alloc() returns a zeroed PA that is
 * directly usable as a kernel pointer. So a virtqueue built in a page_alloc'd
 * frame is reachable by the device at that same physical address — no IOMMU,
 * no bounce buffers, no separate DMA map needed for R-P6.
 *
 * NOTE: R-P6 drives the queue by POLLING the used ring (the crux proof: DMA +
 * device I/O). The PLIC external-IRQ path (plic.c, IRQ lines 1..8) is proven
 * and ready; wiring virtio completions through plic_extintr is the R-P7
 * upgrade path when async/multi-request I/O matters.
 */

#include "sbi.h"
#include "riscv_regs.h"
#include "virtio.h"

/* Shared console helpers (startup.c). */
extern void kputdec(unsigned long v);
extern void kputhex(unsigned long v);

/* Physical page allocator (vm_page.c): zeroed PA == identity VA, DMA-reachable. */
extern unsigned long page_alloc(void);

/* qemu virt virtio-mmio window: 8 slots, stride 0x1000, IRQ = slot+1. */
#define	VIRTIO_MMIO_BASE	0x10001000UL
#define	VIRTIO_MMIO_STRIDE	0x1000UL
#define	VIRTIO_MMIO_COUNT	8

/* MMIO register accessors (identity-mapped low MMIO gigapage, VA==PA). */
static inline unsigned int
vmmio_rd(unsigned long base, unsigned long reg)
{
	return (*(volatile unsigned int *)(base + reg));
}
static inline void
vmmio_wr(unsigned long base, unsigned long reg, unsigned int v)
{
	*(volatile unsigned int *)(base + reg) = v;
}

/*
 * virtio_mmio_probe — read one slot's magic/version/device-id. Returns the
 * device id (0 = empty/unsupported) and fills *version.
 */
static unsigned int
virtio_mmio_probe(unsigned long base, unsigned int *version)
{
	if (vmmio_rd(base, VIRTIO_MMIO_MAGIC) != VIRTIO_MMIO_MAGIC_VALUE)
		return (0);
	*version = vmmio_rd(base, VIRTIO_MMIO_VERSION);
	return (vmmio_rd(base, VIRTIO_MMIO_DEVICE_ID));
}

static const char *
virtio_devname(unsigned int id)
{
	switch (id) {
	case VIRTIO_ID_NET:	return ("net");
	case VIRTIO_ID_BLOCK:	return ("blk");
	case VIRTIO_ID_CONSOLE:	return ("console");
	case VIRTIO_ID_RNG:	return ("rng");
	default:		return ("other");
	}
}

/* Discovered devices, filled by virtio_discover(). */
static struct virtio_dev virtio_devs[VIRTIO_MMIO_COUNT];
static int virtio_ndev;

/*
 * virtio_discover — walk the virtio-mmio window, record every populated slot.
 * PROVE gate: "virtio-mmio: found N devices (...)".
 */
int
virtio_discover(void)
{
	int i;

	virtio_ndev = 0;
	sbi_console_puts("\n[virtio] scanning virtio-mmio window ");
	kputhex(VIRTIO_MMIO_BASE);
	sbi_console_puts(" .. ");
	kputhex(VIRTIO_MMIO_BASE + VIRTIO_MMIO_COUNT * VIRTIO_MMIO_STRIDE);
	sbi_console_puts(" (");
	kputdec(VIRTIO_MMIO_COUNT);
	sbi_console_puts(" slots)\n");

	for (i = 0; i < VIRTIO_MMIO_COUNT; i++) {
		unsigned long base = VIRTIO_MMIO_BASE + i * VIRTIO_MMIO_STRIDE;
		unsigned int ver = 0;
		unsigned int id = virtio_mmio_probe(base, &ver);
		struct virtio_dev *vd;

		if (id == 0)
			continue;

		vd = &virtio_devs[virtio_ndev++];
		vd->vd_base = base;
		vd->vd_irq = (unsigned long)(i + 1);	/* qemu virt: slot+1 */
		vd->vd_devid = id;
		vd->vd_version = ver;

		sbi_console_puts("[virtio]   slot ");
		kputdec(i);
		sbi_console_puts(" @");
		kputhex(base);
		sbi_console_puts(": device-id ");
		kputdec(id);
		sbi_console_puts(" (");
		sbi_console_puts(virtio_devname(id));
		sbi_console_puts("), v");
		kputdec(ver);
		sbi_console_puts(", irq ");
		kputdec(vd->vd_irq);
		sbi_console_puts("\n");
	}

	sbi_console_puts("virtio-mmio: found ");
	kputdec((unsigned long)virtio_ndev);
	sbi_console_puts(" devices (");
	{
		int j, first = 1;
		for (j = 0; j < virtio_ndev; j++) {
			if (!first)
				sbi_console_puts(", ");
			first = 0;
			sbi_console_puts(virtio_devname(virtio_devs[j].vd_devid));
			sbi_console_puts("@");
			kputhex(virtio_devs[j].vd_base);
		}
	}
	sbi_console_puts(")\n");

	return (virtio_ndev);
}

/* Return the first discovered device of the given id, or NULL. */
struct virtio_dev *
virtio_find(unsigned int devid)
{
	int i;
	for (i = 0; i < virtio_ndev; i++)
		if (virtio_devs[i].vd_devid == devid)
			return (&virtio_devs[i]);
	return (0);
}

/*
 * ---------------------------------------------------------------------------
 * Device init handshake (VirtIO spec 1.2 §3.1.1) + feature negotiation.
 * ---------------------------------------------------------------------------
 */

/* Reset device, then ACK + DRIVER (we know how to drive it). */
void
virtio_reset_ack(struct virtio_dev *vd)
{
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_STATUS, 0);		/* reset */
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_STATUS, VIRTIO_STATUS_ACK);
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_STATUS,
	    VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER);
}

/* Read device feature bits [0:63] (two 32-bit selects). */
unsigned long
virtio_get_features(struct virtio_dev *vd)
{
	unsigned int lo, hi;
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_DEVICE_FEATURES_SEL, 0);
	lo = vmmio_rd(vd->vd_base, VIRTIO_MMIO_DEVICE_FEATURES);
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_DEVICE_FEATURES_SEL, 1);
	hi = vmmio_rd(vd->vd_base, VIRTIO_MMIO_DEVICE_FEATURES);
	return (((unsigned long)hi << 32) | lo);
}

/*
 * Write the driver-accepted feature bits and set FEATURES_OK. We always accept
 * VIRTIO_F_VERSION_1 (modern), plus whatever the caller passes. Returns 1 if
 * the device confirms FEATURES_OK, 0 otherwise.
 */
int
virtio_set_features(struct virtio_dev *vd, unsigned long feat)
{
	unsigned int status;

	feat |= VIRTIO_F_VERSION_1;

	vmmio_wr(vd->vd_base, VIRTIO_MMIO_DRIVER_FEATURES_SEL, 0);
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_DRIVER_FEATURES,
	    (unsigned int)(feat & 0xffffffff));
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_DRIVER_FEATURES_SEL, 1);
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_DRIVER_FEATURES,
	    (unsigned int)(feat >> 32));

	vmmio_wr(vd->vd_base, VIRTIO_MMIO_STATUS,
	    VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK);
	status = vmmio_rd(vd->vd_base, VIRTIO_MMIO_STATUS);
	return ((status & VIRTIO_STATUS_FEATURES_OK) != 0);
}

/* Final handshake step: tell the device the driver is live. */
void
virtio_driver_ok(struct virtio_dev *vd)
{
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_STATUS,
	    VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER |
	    VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK);
}

/*
 * ---------------------------------------------------------------------------
 * Split virtqueue (VirtIO spec 1.2 §2.7). Layout in ONE page_alloc'd frame:
 *   desc[QSIZE]   (16 B each)  at offset 0
 *   avail ring                 packed after desc
 *   used ring                  page-aligned within the frame (spec allows any
 *                              alignment for MMIO v2 since we program the three
 *                              ring PAs independently)
 * We keep QSIZE small (8) so all three rings fit comfortably in one 4 KiB page.
 * ---------------------------------------------------------------------------
 */

/*
 * virtq_setup — program queue `qidx` of size QSIZE into the device and lay the
 * three rings out in a fresh DMA page. Returns 1 on success.
 */
int
virtq_setup(struct virtio_dev *vd, unsigned int qidx, struct virtq *vq)
{
	unsigned long page;
	unsigned int qmax;
	unsigned int i;

	/* Select the queue; check it is not already in use + has room. */
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_QUEUE_SEL, qidx);
	if (vd->vd_version < 2) {
		/*
		 * Legacy (v1) transport has a different ring-programming ABI
		 * (QueuePFN + guest page size) we deliberately do not implement.
		 * On qemu virt, force the modern transport with
		 * -global virtio-mmio.force-legacy=false. Refuse rather than
		 * silently write non-legacy registers the device ignores.
		 */
		sbi_console_puts("[virtio] queue setup: device is LEGACY (v1); "
		    "need modern (v2) transport \n");
		return (0);
	}
	if (vmmio_rd(vd->vd_base, VIRTIO_MMIO_QUEUE_READY) != 0)
		return (0);
	qmax = vmmio_rd(vd->vd_base, VIRTIO_MMIO_QUEUE_NUM_MAX);
	if (qmax == 0)
		return (0);
	if (qmax < VIRTQ_SIZE)
		return (0);

	/* One zeroed DMA page holds all three rings (VA==PA identity). */
	page = page_alloc();
	if (page == 0)
		return (0);

	vq->vq_dev = vd;
	vq->vq_idx = qidx;
	vq->vq_num = VIRTQ_SIZE;
	vq->vq_desc = (struct virtq_desc *)page;
	/* avail ring right after the desc table. */
	vq->vq_avail = (struct virtq_avail *)(page +
	    VIRTQ_SIZE * sizeof (struct virtq_desc));
	/* used ring at the second half of the page (well past avail). */
	vq->vq_used = (struct virtq_used *)(page + 2048);
	vq->vq_free_head = 0;
	vq->vq_last_used = 0;

	/* Thread the descriptor free list: 0->1->...->QSIZE-1. */
	for (i = 0; i < VIRTQ_SIZE; i++)
		vq->vq_desc[i].next = (unsigned short)(i + 1);

	/* Program queue size + the three ring physical addresses. */
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_QUEUE_NUM, VIRTQ_SIZE);

	vmmio_wr(vd->vd_base, VIRTIO_MMIO_QUEUE_DESC_LOW,
	    (unsigned int)((unsigned long)vq->vq_desc & 0xffffffff));
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_QUEUE_DESC_HIGH,
	    (unsigned int)((unsigned long)vq->vq_desc >> 32));
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_QUEUE_AVAIL_LOW,
	    (unsigned int)((unsigned long)vq->vq_avail & 0xffffffff));
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_QUEUE_AVAIL_HIGH,
	    (unsigned int)((unsigned long)vq->vq_avail >> 32));
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_QUEUE_USED_LOW,
	    (unsigned int)((unsigned long)vq->vq_used & 0xffffffff));
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_QUEUE_USED_HIGH,
	    (unsigned int)((unsigned long)vq->vq_used >> 32));

	/* Mark the queue ready. */
	vmmio_wr(vd->vd_base, VIRTIO_MMIO_QUEUE_READY, 1);
	return (1);
}

/*
 * virtq_alloc_desc — pop a descriptor index off the free list, or -1 if none.
 */
int
virtq_alloc_desc(struct virtq *vq)
{
	int d;

	if (vq->vq_free_head >= vq->vq_num)
		return (-1);
	d = (int)vq->vq_free_head;
	vq->vq_free_head = vq->vq_desc[d].next;
	return (d);
}

/* virtq_free_desc — push a descriptor index back on the free list. */
void
virtq_free_desc(struct virtq *vq, int d)
{
	vq->vq_desc[d].next = (unsigned short)vq->vq_free_head;
	vq->vq_free_head = (unsigned short)d;
}

/*
 * virtq_submit — publish descriptor head `head` into the avail ring and notify
 * the device. A memory fence orders the descriptor/ring writes before the
 * device sees the incremented avail->idx.
 */
void
virtq_submit(struct virtq *vq, int head)
{
	unsigned short slot = vq->vq_avail->idx % vq->vq_num;

	vq->vq_avail->ring[slot] = (unsigned short)head;
	__asm__ __volatile__("fence ow, ow" ::: "memory");
	vq->vq_avail->idx++;
	__asm__ __volatile__("fence ow, ow" ::: "memory");

	vmmio_wr(vq->vq_dev->vd_base, VIRTIO_MMIO_QUEUE_NOTIFY, vq->vq_idx);
}

/*
 * virtq_poll_used — spin (bounded) until the device advances the used ring past
 * our last-seen index. Returns the used-ring element's descriptor id, or -1 on
 * timeout. Polling is the R-P6 completion path (IRQ is the R-P7 upgrade).
 */
int
virtq_poll_used(struct virtq *vq)
{
	unsigned long spin;
	unsigned short uidx;
	struct virtq_used_elem *ue;
	int id;

	for (spin = 0; spin < 200000000UL; spin++) {
		__asm__ __volatile__("fence ir, ir" ::: "memory");
		uidx = vq->vq_used->idx;
		if (uidx != vq->vq_last_used)
			break;
		__asm__ __volatile__("nop");
	}
	if (vq->vq_used->idx == vq->vq_last_used)
		return (-1);	/* timeout */

	ue = &vq->vq_used->ring[vq->vq_last_used % vq->vq_num];
	id = (int)ue->id;
	vq->vq_last_used++;
	return (id);
}
