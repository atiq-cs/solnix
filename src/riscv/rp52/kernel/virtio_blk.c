/*
 * virtio_blk.c -- R-P52: a virtio-blk device over the qemu-virt MMIO transport.
 *
 * qemu invocation this driver binds against:
 *   -drive file=disk.img,if=none,format=raw,id=hd0 \
 *   -device virtio-blk-device,drive=hd0
 *
 * -machine virt exposes up to 8 virtio-mmio slots at 0x10001000 + i*0x1000.
 * We probe each slot for MagicValue/Version==2/DeviceID==2 (block).  Once we
 * find the block device we negotiate 0 features, set up ONE split virtqueue
 * (descriptor + avail + used rings, statically allocated in the kernel image so
 * their physical address is KVTOP(va) under the direct map), and issue a
 * 3-descriptor block request (header | data | status).  We KICK via QueueNotify
 * and POLL the used ring (no IRQ needed for the milestone).
 *
 * virtio_blk_strategy(blkno, buf, rw) has the same signature as bdev_strategy,
 * so the block layer routes blockfs I/O to a REAL disk instead of the RAM disk
 * (bdev_strategy tries virtio first, falls back to bdev0 when absent).
 *
 * CRIB PROVENANCE: virtio spec v1.0 sec 2.6 (split virtqueue), 4.2 (MMIO
 * transport), 5.2 (block device); xv6 kernel/virtio_disk.c (the canonical
 * split-virtqueue blk driver -- ring layout + 3-descriptor request + kick/poll)
 * adapted to the riscv64 direct map + qemu-virt MMIO addresses; illumos
 * uts/common/io/vioblk + io/virtio (the strategy(9E) entry point + virtq
 * alloc/push/sync framework).
 */

#include "sbi.h"
#include "mmu_riscv.h"

/* ---- virtio-mmio transport ---------------------------------------------- */
#define	VIRTIO_MMIO_BASE	0x10001000UL	/* qemu-virt slot 0 */
#define	VIRTIO_MMIO_STRIDE	0x1000UL
#define	VIRTIO_MMIO_NSLOT	8

#define	VMMIO_MAGIC		0x000	/* 0x74726976 */
#define	VMMIO_VERSION		0x004	/* 2 = modern */
#define	VMMIO_DEVICE_ID		0x008	/* 2 = block */
#define	VMMIO_VENDOR_ID		0x00c
#define	VMMIO_DEVICE_FEATURES	0x010
#define	VMMIO_DEVICE_FEATURES_SEL 0x014
#define	VMMIO_DRIVER_FEATURES	0x020
#define	VMMIO_DRIVER_FEATURES_SEL 0x024
#define	VMMIO_QUEUE_SEL		0x030
#define	VMMIO_QUEUE_NUM_MAX	0x034
#define	VMMIO_QUEUE_NUM		0x038
#define	VMMIO_QUEUE_READY	0x044
#define	VMMIO_QUEUE_NOTIFY	0x050
#define	VMMIO_INTERRUPT_STATUS	0x060
#define	VMMIO_INTERRUPT_ACK	0x064
#define	VMMIO_STATUS		0x070
#define	VMMIO_QUEUE_DESC_LOW	0x080
#define	VMMIO_QUEUE_DESC_HIGH	0x084
#define	VMMIO_QUEUE_DRIVER_LOW	0x090
#define	VMMIO_QUEUE_DRIVER_HIGH	0x094
#define	VMMIO_QUEUE_DEVICE_LOW	0x0a0
#define	VMMIO_QUEUE_DEVICE_HIGH	0x0a4
#define	VMMIO_CONFIG		0x100

#define	VIRTIO_MAGIC_VALUE	0x74726976UL
#define	VIRTIO_DEV_BLOCK	2UL

/* status bits */
#define	VSTATUS_ACKNOWLEDGE	1
#define	VSTATUS_DRIVER		2
#define	VSTATUS_DRIVER_OK	4
#define	VSTATUS_FEATURES_OK	8
#define	VSTATUS_FAILED		128

/* ---- split virtqueue ---------------------------------------------------- */
#define	VQ_N		8		/* queue size (power of two) */

#define	VRING_DESC_F_NEXT	1	/* chained */
#define	VRING_DESC_F_WRITE	2	/* device writes into the buffer */

struct virtq_desc {
	unsigned long	addr;		/* phys addr of buffer */
	unsigned int	len;
	unsigned short	flags;
	unsigned short	next;
};

struct virtq_avail {
	unsigned short	flags;
	unsigned short	idx;
	unsigned short	ring[VQ_N];
	unsigned short	used_event;
};

struct virtq_used_elem {
	unsigned int	id;
	unsigned int	len;
};

struct virtq_used {
	unsigned short	flags;
	unsigned short	idx;
	struct virtq_used_elem	ring[VQ_N];
	unsigned short	avail_event;
};

/*
 * The three rings, each in its own aligned static buffer (the kernel image
 * lives in direct-mapped DRAM, so KVTOP() gives the device the right PA).
 * v1.0 modern lets desc/avail/used be placed independently (three address
 * registers), so per-region 16-byte alignment is enough.
 */
static struct virtq_desc  vq_desc[VQ_N]  __attribute__((aligned(16)));
static struct virtq_avail vq_avail        __attribute__((aligned(16)));
static struct virtq_used  vq_used         __attribute__((aligned(16)));

/* ---- virtio-blk request ------------------------------------------------- */
#define	VIRTIO_BLK_T_IN		0	/* read */
#define	VIRTIO_BLK_T_OUT	1	/* write */

struct virtio_blk_req {
	unsigned int	type;
	unsigned int	reserved;
	unsigned long	sector;
};

/* the header, a 512B data sector, and the status byte -- device DMA targets. */
static struct virtio_blk_req vq_hdr    __attribute__((aligned(16)));
static unsigned char         vq_data[512] __attribute__((aligned(16)));
static volatile unsigned char vq_status __attribute__((aligned(16)));

static unsigned long virtio_base;	/* chosen slot base PA, 0 = none */
static int virtio_ready;		/* 1 once the queue is live */

static volatile unsigned int *
vreg(unsigned long off)
{
	return ((volatile unsigned int *)
	    (KERNEL_DMAP_BASE + virtio_base + off));
}

static void
fence(void)
{
	__asm__ __volatile__ ("fence" ::: "memory");
}

/*
 * virtio_blk_init -- probe the MMIO slots for a block device, negotiate, and
 * bring up the single virtqueue.  Returns 1 if a virtio-blk disk is live, 0 if
 * none is present (the RAM disk stays the backing store).
 */
int
virtio_blk_init(void)
{
	int slot;
	unsigned int status;
	unsigned int qmax;
	unsigned long pa;

	virtio_ready = 0;
	virtio_base = 0;

	for (slot = 0; slot < VIRTIO_MMIO_NSLOT; slot++) {
		unsigned long base = VIRTIO_MMIO_BASE +
		    (unsigned long)slot * VIRTIO_MMIO_STRIDE;
		volatile unsigned int *r =
		    (volatile unsigned int *)(KERNEL_DMAP_BASE + base);
		if (r[VMMIO_MAGIC / 4] != VIRTIO_MAGIC_VALUE)
			continue;
		if (r[VMMIO_VERSION / 4] != 2)
			continue;
		if (r[VMMIO_DEVICE_ID / 4] != VIRTIO_DEV_BLOCK)
			continue;
		virtio_base = base;
		break;
	}
	if (virtio_base == 0)
		return (0);		/* no virtio-blk device present */

	/* reset, then ACKNOWLEDGE + DRIVER. */
	*vreg(VMMIO_STATUS) = 0;
	fence();
	status = VSTATUS_ACKNOWLEDGE;
	*vreg(VMMIO_STATUS) = status;
	status |= VSTATUS_DRIVER;
	*vreg(VMMIO_STATUS) = status;

	/* negotiate 0 features (both windows). */
	*vreg(VMMIO_DEVICE_FEATURES_SEL) = 0;
	(void)*vreg(VMMIO_DEVICE_FEATURES);
	*vreg(VMMIO_DRIVER_FEATURES_SEL) = 0;
	*vreg(VMMIO_DRIVER_FEATURES) = 0;
	*vreg(VMMIO_DEVICE_FEATURES_SEL) = 1;
	(void)*vreg(VMMIO_DEVICE_FEATURES);
	*vreg(VMMIO_DRIVER_FEATURES_SEL) = 1;
	*vreg(VMMIO_DRIVER_FEATURES) = 0;

	status |= VSTATUS_FEATURES_OK;
	*vreg(VMMIO_STATUS) = status;
	fence();
	if ((*vreg(VMMIO_STATUS) & VSTATUS_FEATURES_OK) == 0) {
		*vreg(VMMIO_STATUS) = status | VSTATUS_FAILED;
		virtio_base = 0;
		return (0);
	}

	/* configure queue 0. */
	*vreg(VMMIO_QUEUE_SEL) = 0;
	qmax = *vreg(VMMIO_QUEUE_NUM_MAX);
	if (qmax == 0 || qmax < VQ_N) {
		*vreg(VMMIO_STATUS) = status | VSTATUS_FAILED;
		virtio_base = 0;
		return (0);
	}
	*vreg(VMMIO_QUEUE_NUM) = VQ_N;

	/* zero the rings, program the three ring physical addresses. */
	{
		unsigned int i;
		unsigned char *p;
		p = (unsigned char *)vq_desc;
		for (i = 0; i < sizeof (vq_desc); i++) p[i] = 0;
		p = (unsigned char *)&vq_avail;
		for (i = 0; i < sizeof (vq_avail); i++) p[i] = 0;
		p = (unsigned char *)&vq_used;
		for (i = 0; i < sizeof (vq_used); i++) p[i] = 0;
	}

	pa = KVTOP(vq_desc);
	*vreg(VMMIO_QUEUE_DESC_LOW)  = (unsigned int)(pa & 0xffffffffUL);
	*vreg(VMMIO_QUEUE_DESC_HIGH) = (unsigned int)(pa >> 32);
	pa = KVTOP(&vq_avail);
	*vreg(VMMIO_QUEUE_DRIVER_LOW)  = (unsigned int)(pa & 0xffffffffUL);
	*vreg(VMMIO_QUEUE_DRIVER_HIGH) = (unsigned int)(pa >> 32);
	pa = KVTOP(&vq_used);
	*vreg(VMMIO_QUEUE_DEVICE_LOW)  = (unsigned int)(pa & 0xffffffffUL);
	*vreg(VMMIO_QUEUE_DEVICE_HIGH) = (unsigned int)(pa >> 32);
	fence();

	*vreg(VMMIO_QUEUE_READY) = 1;

	status |= VSTATUS_DRIVER_OK;
	*vreg(VMMIO_STATUS) = status;
	fence();

	virtio_ready = 1;
	return (1);
}

/*
 * virtio_blk_rw -- transfer ONE 512-byte sector: rw==0 reads sector into buf,
 * rw==1 writes buf to sector.  Builds a 3-descriptor chain (hdr | data |
 * status), kicks the device, and polls the used ring.  Returns 0 on OK, -1 on
 * error / no device.
 */
static int
virtio_blk_rw(unsigned long sector, unsigned char *buf, int rw)
{
	unsigned short last_used;
	unsigned int i;
	volatile unsigned short *used_idx = &vq_used.idx;

	if (!virtio_ready)
		return (-1);

	/* header (read-only by device). */
	vq_hdr.type = (rw == 0) ? VIRTIO_BLK_T_IN : VIRTIO_BLK_T_OUT;
	vq_hdr.reserved = 0;
	vq_hdr.sector = sector;

	/* on a WRITE, copy caller bytes into the DMA sector buffer. */
	if (rw != 0)
		for (i = 0; i < 512; i++)
			vq_data[i] = buf[i];

	vq_status = 0xff;		/* sentinel: device writes 0/1/2 */

	/* desc[0] = header, RO, chained -> 1. */
	vq_desc[0].addr = KVTOP(&vq_hdr);
	vq_desc[0].len = sizeof (vq_hdr);
	vq_desc[0].flags = VRING_DESC_F_NEXT;
	vq_desc[0].next = 1;

	/* desc[1] = data.  read: device WRITEs it; write: device reads it. */
	vq_desc[1].addr = KVTOP(vq_data);
	vq_desc[1].len = 512;
	vq_desc[1].flags = VRING_DESC_F_NEXT |
	    ((rw == 0) ? VRING_DESC_F_WRITE : 0);
	vq_desc[1].next = 2;

	/* desc[2] = status byte, device WRITEs it. */
	vq_desc[2].addr = KVTOP((void *)&vq_status);
	vq_desc[2].len = 1;
	vq_desc[2].flags = VRING_DESC_F_WRITE;
	vq_desc[2].next = 0;

	last_used = vq_used.idx;

	/* publish the chain head to the avail ring. */
	vq_avail.ring[vq_avail.idx % VQ_N] = 0;
	fence();
	vq_avail.idx++;
	fence();

	/* kick queue 0. */
	*vreg(VMMIO_QUEUE_NOTIFY) = 0;

	/* poll the used ring until the device completes our chain. */
	{
		unsigned long spins = 0;
		while (*used_idx == last_used) {
			fence();
			if (++spins > 100000000UL)
				return (-1);	/* device wedged */
		}
	}
	fence();

	/* ACK any interrupt the device raised (poll mode, but keep it clean). */
	{
		unsigned int is = *vreg(VMMIO_INTERRUPT_STATUS);
		if (is != 0)
			*vreg(VMMIO_INTERRUPT_ACK) = is;
	}

	if (vq_status != 0)
		return (-1);		/* VIRTIO_BLK_S_IOERR/UNSUPP */

	/* on a READ, hand the sector back to the caller. */
	if (rw == 0)
		for (i = 0; i < 512; i++)
			buf[i] = vq_data[i];

	return (0);
}

/*
 * virtio_blk_strategy -- the strategy(9E)-style entry point, same signature as
 * bdev_strategy: transfer one 512-byte block.  bdev_strategy routes here when a
 * virtio disk is live.
 */
int
virtio_blk_strategy(unsigned long blkno, unsigned char *buf, int rw)
{
	return (virtio_blk_rw(blkno, buf, rw));
}

/* is a real virtio-blk disk backing the block layer? */
int
virtio_blk_present(void)
{
	return (virtio_ready);
}

/* disk capacity in 512B sectors (virtio_blk_config.capacity at Config+0). */
unsigned long
virtio_blk_capacity(void)
{
	if (!virtio_ready)
		return (0);
	{
		volatile unsigned int *c = vreg(VMMIO_CONFIG);
		unsigned long lo = c[0];
		unsigned long hi = c[1];
		return (lo | (hi << 32));
	}
}
