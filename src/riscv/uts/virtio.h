/*
 * virtio.h — virtio-mmio transport + split-virtqueue definitions (R-P6).
 *
 * Register offsets, status/feature bits, virtqueue ring layout, and the
 * driver-facing API implemented by virtio.c. Values from VirtIO spec 1.2
 * §4.2.2 (MMIO register layout) and §2.7 (split virtqueue), reimplemented in
 * illumos idiom (no CDDL-incompatible source copied).
 */

#ifndef	_VIRTIO_H
#define	_VIRTIO_H

/* virtio-mmio register offsets (VirtIO spec 1.2 §4.2.2). */
#define	VIRTIO_MMIO_MAGIC		0x000	/* "virt" */
#define	VIRTIO_MMIO_VERSION		0x004	/* 2 = modern */
#define	VIRTIO_MMIO_DEVICE_ID		0x008	/* 0=none 1=net 2=blk */
#define	VIRTIO_MMIO_VENDOR_ID		0x00c
#define	VIRTIO_MMIO_DEVICE_FEATURES	0x010
#define	VIRTIO_MMIO_DEVICE_FEATURES_SEL	0x014
#define	VIRTIO_MMIO_DRIVER_FEATURES	0x020
#define	VIRTIO_MMIO_DRIVER_FEATURES_SEL	0x024
#define	VIRTIO_MMIO_QUEUE_SEL		0x030
#define	VIRTIO_MMIO_QUEUE_NUM_MAX	0x034
#define	VIRTIO_MMIO_QUEUE_NUM		0x038
#define	VIRTIO_MMIO_QUEUE_READY		0x044
#define	VIRTIO_MMIO_QUEUE_NOTIFY	0x050
#define	VIRTIO_MMIO_INTERRUPT_STATUS	0x060
#define	VIRTIO_MMIO_INTERRUPT_ACK	0x064
#define	VIRTIO_MMIO_STATUS		0x070
#define	VIRTIO_MMIO_QUEUE_DESC_LOW	0x080
#define	VIRTIO_MMIO_QUEUE_DESC_HIGH	0x084
#define	VIRTIO_MMIO_QUEUE_AVAIL_LOW	0x090
#define	VIRTIO_MMIO_QUEUE_AVAIL_HIGH	0x094
#define	VIRTIO_MMIO_QUEUE_USED_LOW	0x0a0
#define	VIRTIO_MMIO_QUEUE_USED_HIGH	0x0a4
#define	VIRTIO_MMIO_CONFIG		0x100	/* device-specific config space */

#define	VIRTIO_MMIO_MAGIC_VALUE		0x74726976U	/* "virt" LE */

/* Device ids (VirtIO spec §5). */
#define	VIRTIO_ID_NET		1U
#define	VIRTIO_ID_BLOCK		2U
#define	VIRTIO_ID_CONSOLE	3U
#define	VIRTIO_ID_RNG		4U

/* Status bits (VirtIO spec §2.1). */
#define	VIRTIO_STATUS_ACK		1U
#define	VIRTIO_STATUS_DRIVER		2U
#define	VIRTIO_STATUS_DRIVER_OK		4U
#define	VIRTIO_STATUS_FEATURES_OK	8U
#define	VIRTIO_STATUS_FAILED		0x80U

/* Common feature bit: modern (v1) device. */
#define	VIRTIO_F_VERSION_1	(1UL << 32)

/* Descriptor flags (VirtIO spec §2.7.5). */
#define	VIRTQ_DESC_F_NEXT	1U	/* chains to .next */
#define	VIRTQ_DESC_F_WRITE	2U	/* device writes (driver reads) */

/* One page holds all three rings if the queue is small. */
#define	VIRTQ_SIZE	8U

/* Split-virtqueue ring structures (packed as the device expects). */
struct virtq_desc {
	unsigned long	addr;	/* physical address of the buffer */
	unsigned int	len;
	unsigned short	flags;
	unsigned short	next;
} __attribute__((packed));

struct virtq_avail {
	unsigned short	flags;
	unsigned short	idx;
	unsigned short	ring[VIRTQ_SIZE];
	unsigned short	used_event;
} __attribute__((packed));

struct virtq_used_elem {
	unsigned int	id;	/* descriptor head index */
	unsigned int	len;	/* bytes written by the device */
} __attribute__((packed));

struct virtq_used {
	unsigned short		flags;
	unsigned short		idx;
	struct virtq_used_elem	ring[VIRTQ_SIZE];
	unsigned short		avail_event;
} __attribute__((packed));

/* A discovered virtio-mmio device. */
struct virtio_dev {
	unsigned long	vd_base;	/* MMIO base PA (== VA, identity) */
	unsigned long	vd_irq;		/* PLIC source line */
	unsigned int	vd_devid;	/* VIRTIO_ID_* */
	unsigned int	vd_version;	/* mmio transport version */
};

/* A live virtqueue (rings in one DMA page). */
struct virtq {
	struct virtio_dev	*vq_dev;
	unsigned int		vq_idx;		/* queue index on the device */
	unsigned int		vq_num;		/* == VIRTQ_SIZE */
	struct virtq_desc	*vq_desc;
	struct virtq_avail	*vq_avail;
	struct virtq_used	*vq_used;
	unsigned short		vq_free_head;	/* desc free-list head */
	unsigned short		vq_last_used;	/* last consumed used idx */
};

/* Transport API (virtio.c). */
int virtio_discover(void);
struct virtio_dev *virtio_find(unsigned int devid);
void virtio_reset_ack(struct virtio_dev *vd);
unsigned long virtio_get_features(struct virtio_dev *vd);
int virtio_set_features(struct virtio_dev *vd, unsigned long feat);
void virtio_driver_ok(struct virtio_dev *vd);

/* Virtqueue API (virtio.c). */
int virtq_setup(struct virtio_dev *vd, unsigned int qidx, struct virtq *vq);
int virtq_alloc_desc(struct virtq *vq);
void virtq_free_desc(struct virtq *vq, int d);
void virtq_submit(struct virtq *vq, int head);
int virtq_poll_used(struct virtq *vq);

#endif	/* _VIRTIO_H */
