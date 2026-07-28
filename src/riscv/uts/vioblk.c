/*
 * vioblk.c — illumos riscv64 virtio-blk driver (R-P6).
 *
 * The R-P6 crux: prove DMA + real device I/O by reading a sector off a
 * qemu -drive through the virtio-blk device. A virtio-blk request is a 3-part
 * descriptor chain (VirtIO spec 1.2 §5.2):
 *   [0] header  (struct virtio_blk_req_hdr: type, reserved, sector) — dev reads
 *   [1] data    (512 * n bytes)                                     — dev writes
 *   [2] status  (1 byte: 0 = OK)                                    — dev writes
 * We build the chain in one DMA page, submit it on the single request queue,
 * notify, and POLL the used ring for completion.
 *
 * Reference: VirtIO spec 1.2 §5.2 (block device), cross-checked against NetBSD
 * sys/dev/virtio/ld_virtio.c + Linux drivers/block/virtio_blk.c. Reimplemented
 * in illumos idiom from the spec (no CDDL-incompatible source copied).
 *
 * PROVE gate: "vioblk: read sector 0 OK (512 bytes, MBR/magic=0x...)".
 */

#include "sbi.h"
#include "riscv_regs.h"
#include "virtio.h"

extern void kputdec(unsigned long v);
extern void kputhex(unsigned long v);
extern unsigned long page_alloc(void);

/* virtio-blk request types (spec §5.2.6). */
#define	VIRTIO_BLK_T_IN		0	/* read from device */
#define	VIRTIO_BLK_T_OUT	1	/* write to device */

/* Status byte values (spec §5.2.6). */
#define	VIRTIO_BLK_S_OK		0
#define	VIRTIO_BLK_S_IOERR	1
#define	VIRTIO_BLK_S_UNSUPP	2

#define	VIOBLK_SECTOR_SIZE	512

/* Request header the device reads (spec §5.2.6). */
struct virtio_blk_req_hdr {
	unsigned int	type;		/* VIRTIO_BLK_T_* */
	unsigned int	reserved;
	unsigned long	sector;		/* 512-byte sector index */
} __attribute__((packed));

static struct virtio_dev *vioblk_dev;
static struct virtq vioblk_vq;
static int vioblk_ready;

/* DMA scratch page: header at +0, status at +8, data buffer at +512. */
static unsigned long vioblk_dma;

/*
 * A SECOND virtio-blk instance for the on-disk root FS image (R-P9 gate 4).
 * Kept separate from the R-P6 test disk above so both can be read.
 */
static struct virtio_dev *vioblk_fs_dev;
static struct virtq vioblk_fs_vq;
static int vioblk_fs_ready;
static unsigned long vioblk_fs_dma;

/*
 * vioblk_read_sector — read one 512-byte sector into `buf` (a kernel pointer).
 * Returns 1 on success. Blocking (polls the used ring).
 */
int
vioblk_read_sector(unsigned long sector, void *buf)
{
	struct virtio_blk_req_hdr *hdr;
	volatile unsigned char *status;
	unsigned char *data;
	int dh, dd, ds;	/* descriptor indices: header, data, status */
	int used;
	int i;

	if (!vioblk_ready)
		return (0);

	hdr = (struct virtio_blk_req_hdr *)(vioblk_dma + 0);
	status = (volatile unsigned char *)(vioblk_dma + 256);
	data = (unsigned char *)(vioblk_dma + 512);

	hdr->type = VIRTIO_BLK_T_IN;
	hdr->reserved = 0;
	hdr->sector = sector;
	*status = 0xff;				/* device overwrites with 0 */

	dh = virtq_alloc_desc(&vioblk_vq);
	dd = virtq_alloc_desc(&vioblk_vq);
	ds = virtq_alloc_desc(&vioblk_vq);
	if (dh < 0 || dd < 0 || ds < 0)
		return (0);

	/* [0] header: device reads it, chains to data. */
	vioblk_vq.vq_desc[dh].addr = (unsigned long)hdr;
	vioblk_vq.vq_desc[dh].len = sizeof (*hdr);
	vioblk_vq.vq_desc[dh].flags = VIRTQ_DESC_F_NEXT;
	vioblk_vq.vq_desc[dh].next = (unsigned short)dd;

	/* [1] data: device WRITES the sector here, chains to status. */
	vioblk_vq.vq_desc[dd].addr = (unsigned long)data;
	vioblk_vq.vq_desc[dd].len = VIOBLK_SECTOR_SIZE;
	vioblk_vq.vq_desc[dd].flags = VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE;
	vioblk_vq.vq_desc[dd].next = (unsigned short)ds;

	/* [2] status: device WRITES the 1-byte result, end of chain. */
	vioblk_vq.vq_desc[ds].addr = (unsigned long)status;
	vioblk_vq.vq_desc[ds].len = 1;
	vioblk_vq.vq_desc[ds].flags = VIRTQ_DESC_F_WRITE;
	vioblk_vq.vq_desc[ds].next = 0;

	virtq_submit(&vioblk_vq, dh);

	used = virtq_poll_used(&vioblk_vq);

	/* Recycle the chain regardless. */
	virtq_free_desc(&vioblk_vq, dh);
	virtq_free_desc(&vioblk_vq, dd);
	virtq_free_desc(&vioblk_vq, ds);

	if (used < 0) {
		sbi_console_puts("[vioblk] request timed out (no used-ring "
		    "completion)\n");
		return (0);
	}
	if (*status != VIRTIO_BLK_S_OK) {
		sbi_console_puts("[vioblk] request status ");
		kputdec(*status);
		sbi_console_puts(" (not OK)\n");
		return (0);
	}

	/* Copy the data out (buf may be anywhere). */
	if (buf != 0) {
		unsigned char *out = buf;
		for (i = 0; i < VIOBLK_SECTOR_SIZE; i++)
			out[i] = data[i];
	}
	return (1);
}

/*
 * vioblk_attach — find the virtio-blk device, run the init handshake, set up
 * the request queue, and do the R-P6 test read of sector 0.
 * Returns 1 if the device is attached and readable.
 */
int
vioblk_attach(void)
{
	struct virtio_dev *vd;
	unsigned long feat;
	unsigned char sec0[VIOBLK_SECTOR_SIZE];
	unsigned int magic;

	vd = virtio_find(VIRTIO_ID_BLOCK);
	if (vd == 0) {
		sbi_console_puts("[vioblk] no virtio-blk device found\n");
		return (0);
	}

	sbi_console_puts("\n[vioblk] attaching virtio-blk @");
	kputhex(vd->vd_base);
	sbi_console_puts(" (irq ");
	kputdec(vd->vd_irq);
	sbi_console_puts(")\n");

	/* Handshake: reset -> ACK -> DRIVER. */
	virtio_reset_ack(vd);

	feat = virtio_get_features(vd);
	sbi_console_puts("[vioblk] device features ");
	kputhex(feat);
	sbi_console_puts("\n");

	/* We negotiate no optional blk features (bare read path); just v1. */
	if (!virtio_set_features(vd, 0)) {
		sbi_console_puts("[vioblk] FEATURES_OK rejected by device\n");
		return (0);
	}

	/* virtio-blk has a single request queue: index 0. */
	if (!virtq_setup(vd, 0, &vioblk_vq)) {
		sbi_console_puts("[vioblk] queue 0 setup FAILED\n");
		return (0);
	}

	virtio_driver_ok(vd);

	/* One DMA page for header/status/data scratch. */
	vioblk_dma = page_alloc();
	if (vioblk_dma == 0) {
		sbi_console_puts("[vioblk] DMA page alloc FAILED\n");
		return (0);
	}

	vioblk_dev = vd;
	vioblk_ready = 1;
	sbi_console_puts("[vioblk] request queue online (QSIZE ");
	kputdec(VIRTQ_SIZE);
	sbi_console_puts("), DRIVER_OK set\n");

	/* R-P6 test read: sector 0. */
	if (!vioblk_read_sector(0, sec0)) {
		sbi_console_puts("[vioblk] test read of sector 0 FAILED\n");
		return (0);
	}

	/* MBR/boot-sector magic is the last two bytes: 0x55 0xaa (LE 0xaa55). */
	magic = (unsigned int)sec0[510] | ((unsigned int)sec0[511] << 8);

	sbi_console_puts("vioblk: read sector 0 OK (512 bytes, MBR/magic=");
	kputhex(magic);
	sbi_console_puts(", first8=");
	{
		int i;
		for (i = 0; i < 8; i++) {
			static const char hx[] = "0123456789abcdef";
			sbi_console_putchar(hx[(sec0[i] >> 4) & 0xf]);
			sbi_console_putchar(hx[sec0[i] & 0xf]);
		}
	}
	sbi_console_puts(")\n");

	return (1);
}

/* Is the block device attached + readable? (used by rootfs.) */
int
vioblk_present(void)
{
	return (vioblk_ready);
}

/* virtio.c: find the n-th block device (R-P9 gate 4 needs the second one). */
extern struct virtio_dev *virtio_find_nth(unsigned int devid, int n);

/*
 * vioblk_fs_read_sector — read one 512-byte sector from the SECOND virtio-blk
 * (the on-disk root FS image) into `buf`. Mirrors vioblk_read_sector but drives
 * the vioblk_fs_* instance. Returns 1 on success.
 */
int
vioblk_fs_read_sector(unsigned long sector, void *buf)
{
	struct virtio_blk_req_hdr *hdr;
	volatile unsigned char *status;
	unsigned char *data;
	int dh, dd, ds, used, i;

	if (!vioblk_fs_ready)
		return (0);

	hdr = (struct virtio_blk_req_hdr *)(vioblk_fs_dma + 0);
	status = (volatile unsigned char *)(vioblk_fs_dma + 256);
	data = (unsigned char *)(vioblk_fs_dma + 512);

	hdr->type = VIRTIO_BLK_T_IN;
	hdr->reserved = 0;
	hdr->sector = sector;
	*status = 0xff;

	dh = virtq_alloc_desc(&vioblk_fs_vq);
	dd = virtq_alloc_desc(&vioblk_fs_vq);
	ds = virtq_alloc_desc(&vioblk_fs_vq);
	if (dh < 0 || dd < 0 || ds < 0)
		return (0);

	vioblk_fs_vq.vq_desc[dh].addr = (unsigned long)hdr;
	vioblk_fs_vq.vq_desc[dh].len = sizeof (*hdr);
	vioblk_fs_vq.vq_desc[dh].flags = VIRTQ_DESC_F_NEXT;
	vioblk_fs_vq.vq_desc[dh].next = (unsigned short)dd;

	vioblk_fs_vq.vq_desc[dd].addr = (unsigned long)data;
	vioblk_fs_vq.vq_desc[dd].len = VIOBLK_SECTOR_SIZE;
	vioblk_fs_vq.vq_desc[dd].flags = VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE;
	vioblk_fs_vq.vq_desc[dd].next = (unsigned short)ds;

	vioblk_fs_vq.vq_desc[ds].addr = (unsigned long)status;
	vioblk_fs_vq.vq_desc[ds].len = 1;
	vioblk_fs_vq.vq_desc[ds].flags = VIRTQ_DESC_F_WRITE;
	vioblk_fs_vq.vq_desc[ds].next = 0;

	virtq_submit(&vioblk_fs_vq, dh);
	used = virtq_poll_used(&vioblk_fs_vq);
	virtq_free_desc(&vioblk_fs_vq, dh);
	virtq_free_desc(&vioblk_fs_vq, dd);
	virtq_free_desc(&vioblk_fs_vq, ds);

	if (used < 0 || *status != VIRTIO_BLK_S_OK)
		return (0);
	if (buf != 0) {
		unsigned char *out = buf;
		for (i = 0; i < VIOBLK_SECTOR_SIZE; i++)
			out[i] = data[i];
	}
	return (1);
}

/*
 * vioblk_fs_attach — find and attach the virtio-blk device that carries the
 * ustar root FS image (R-P9 gate 4). qemu's slot ordering is not fixed, so we
 * do NOT assume "the second blk device": we probe EACH blk device's sector 0
 * for the ustar magic ("ustar" at byte offset 257) and keep the one that
 * matches. Returns 1 if a ustar disk was found + its queue is online. If none
 * matches (no FS image attached), returns 0 and the kernel serves the embedded
 * ELFs.
 */
int
vioblk_fs_attach(void)
{
	int n;

	for (n = 0; ; n++) {
		struct virtio_dev *vd = virtio_find_nth(VIRTIO_ID_BLOCK, n);
		unsigned char sec0[VIOBLK_SECTOR_SIZE];

		if (vd == 0)
			break;		/* no more blk devices */

		/* Bring this candidate online in the fs slot. */
		virtio_reset_ack(vd);
		(void) virtio_get_features(vd);
		if (!virtio_set_features(vd, 0))
			continue;
		if (!virtq_setup(vd, 0, &vioblk_fs_vq))
			continue;
		virtio_driver_ok(vd);
		if (vioblk_fs_dma == 0) {
			vioblk_fs_dma = page_alloc();
			if (vioblk_fs_dma == 0)
				return (0);
		}
		vioblk_fs_dev = vd;
		vioblk_fs_ready = 1;

		/* Probe sector 0 for the ustar magic. */
		if (vioblk_fs_read_sector(0, sec0) &&
		    sec0[257] == 'u' && sec0[258] == 's' && sec0[259] == 't' &&
		    sec0[260] == 'a' && sec0[261] == 'r') {
			sbi_console_puts("\n[vioblk-fs] root-FS (ustar) disk @");
			kputhex(vd->vd_base);
			sbi_console_puts(" online\n");
			return (1);
		}
		/* Not the FS disk: leave it initialized but keep scanning. */
		vioblk_fs_ready = 0;
	}
	vioblk_fs_ready = 0;
	return (0);
}

int
vioblk_fs_present(void)
{
	return (vioblk_fs_ready);
}
