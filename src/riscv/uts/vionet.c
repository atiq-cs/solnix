/*
 * vionet.c — illumos riscv64 virtio-net driver (R-P6 optional gate).
 *
 * Proves the second virtio device class: set up the receive (queue 0) and
 * transmit (queue 1) virtqueues, post an RX buffer, and TRANSMIT one raw
 * Ethernet frame — taking the TX completion off the used ring proves the
 * net TX DMA path end to end. RX is best-effort: qemu -netdev user (slirp)
 * only replies to frames it understands, so we post a buffer and poll briefly;
 * we report RX only if a frame actually lands.
 *
 * A virtio-net buffer is prefixed by a 12-byte struct virtio_net_hdr (spec
 * 1.2 §5.1.6) that the device reads (TX) / writes (RX). We negotiate no
 * offload features (bare frames), so the header is all zero on TX.
 *
 * Reference: VirtIO spec 1.2 §5.1 (network device), cross-checked against
 * NetBSD if_vioif.c + Linux drivers/net/virtio_net.c. Reimplemented in
 * illumos idiom from the spec (no CDDL-incompatible source copied).
 *
 * PROVE gate: "vionet: TX/RX OK" (TX always; RX if a frame arrived).
 *
 * NOTE: polled completions, one static RX/TX buffer, no mac9F/GLDv3 binding,
 * no multi-buffer/mergeable-rx. It is the honest "the net device moves a
 * frame" proof; a real GLDv3 nic driver is post-R-P7.
 */

#include "sbi.h"
#include "riscv_regs.h"
#include "virtio.h"

extern void kputdec(unsigned long v);
extern void kputhex(unsigned long v);
extern unsigned long page_alloc(void);

/* virtio-net config space (spec §5.1.4): first 6 bytes = MAC. */
#define	VIRTIO_NET_CFG_MAC	(VIRTIO_MMIO_CONFIG + 0)

/* Feature bits we care about (spec §5.1.3). */
#define	VIRTIO_NET_F_MAC	(1UL << 5)	/* device reports a MAC */

/* The 12-byte header prefixed to every buffer (no-offload layout). */
struct virtio_net_hdr {
	unsigned char	flags;
	unsigned char	gso_type;
	unsigned short	hdr_len;
	unsigned short	gso_size;
	unsigned short	csum_start;
	unsigned short	csum_offset;
	unsigned short	num_buffers;	/* used only if MRG_RXBUF negotiated */
} __attribute__((packed));

/*
 * 12, not 10. With VIRTIO_F_VERSION_1 negotiated (virtio_set_features always
 * sets it) the header ALWAYS includes num_buffers (spec 1.2 §5.1.6: "the
 * num_buffers field is ... present with VIRTIO_F_VERSION_1"); the 10-byte form
 * is legacy-only. rvsrv found this with a qemu filter-dump pcap: at 10, qemu
 * read 2 frame bytes as header, so the attach ARP left the guest as 58 bytes
 * with dst ff:ff:ff:ff:52:54 -- every TX frame since R-P6 was malformed, which
 * is why slirp "may not reply" (it never could).
 */
#define	VIONET_HDR_LEN	12

static struct virtio_dev *vionet_dev;
static struct virtq vionet_rxq;		/* queue 0 */
static struct virtq vionet_txq;		/* queue 1 */
static int vionet_ready;

static unsigned long vionet_txbuf;	/* DMA page for the TX frame */
static unsigned long vionet_rxbuf;	/* DMA page for the RX frame */
static unsigned char vionet_mac[6];

/*
 * vionet_post_rx — hand one receive buffer (hdr + frame space) to the device
 * on the RX queue so it has somewhere to write an incoming frame.
 */
static int
vionet_post_rx(void)
{
	int d = virtq_alloc_desc(&vionet_rxq);
	if (d < 0)
		return (0);
	vionet_rxq.vq_desc[d].addr = vionet_rxbuf;
	vionet_rxq.vq_desc[d].len = 2048;	/* hdr + a full frame */
	vionet_rxq.vq_desc[d].flags = VIRTQ_DESC_F_WRITE;	/* device writes */
	vionet_rxq.vq_desc[d].next = 0;
	virtq_submit(&vionet_rxq, d);
	return (1);
}

/*
 * vionet_tx_frame — transmit one raw Ethernet frame (already built at
 * vionet_txbuf + VIONET_HDR_LEN). Returns 1 if the device took the buffer
 * (TX used-ring completion).
 */
static int
vionet_tx_frame(unsigned int framelen)
{
	struct virtio_net_hdr *h = (struct virtio_net_hdr *)vionet_txbuf;
	int d;
	int used;
	unsigned int i;

	/* Zero the net header (no offloads). */
	{
		unsigned char *p = (unsigned char *)h;
		for (i = 0; i < VIONET_HDR_LEN; i++)
			p[i] = 0;
	}

	d = virtq_alloc_desc(&vionet_txq);
	if (d < 0)
		return (0);
	vionet_txq.vq_desc[d].addr = vionet_txbuf;
	vionet_txq.vq_desc[d].len = VIONET_HDR_LEN + framelen;
	vionet_txq.vq_desc[d].flags = 0;	/* device reads */
	vionet_txq.vq_desc[d].next = 0;

	virtq_submit(&vionet_txq, d);
	used = virtq_poll_used(&vionet_txq);
	virtq_free_desc(&vionet_txq, d);

	return (used >= 0);
}

/*
 * vionet_attach — find virtio-net, handshake, set up RX/TX queues, post an RX
 * buffer, build + transmit one broadcast ARP-ish frame, and take the TX
 * completion. Best-effort poll for an RX frame afterward.
 */
int
vionet_attach(void)
{
	struct virtio_dev *vd;
	unsigned long feat;
	unsigned char *frame;
	unsigned int flen;
	int tx_ok, rx_ok = 0;
	int i;

	vd = virtio_find(VIRTIO_ID_NET);
	if (vd == 0) {
		sbi_console_puts("[vionet] no virtio-net device found\n");
		return (0);
	}

	sbi_console_puts("\n[vionet] attaching virtio-net @");
	kputhex(vd->vd_base);
	sbi_console_puts(" (irq ");
	kputdec(vd->vd_irq);
	sbi_console_puts(")\n");

	virtio_reset_ack(vd);
	feat = virtio_get_features(vd);
	sbi_console_puts("[vionet] device features ");
	kputhex(feat);
	sbi_console_puts("\n");

	/* Accept only the MAC feature (bare frames, no offloads / no mrg-rx). */
	if (!virtio_set_features(vd, VIRTIO_NET_F_MAC)) {
		sbi_console_puts("[vionet] FEATURES_OK rejected\n");
		return (0);
	}

	/* Read the device MAC from config space. */
	for (i = 0; i < 6; i++)
		vionet_mac[i] =
		    *(volatile unsigned char *)(vd->vd_base + VIRTIO_NET_CFG_MAC + i);

	/* RX = queue 0, TX = queue 1. */
	if (!virtq_setup(vd, 0, &vionet_rxq) ||
	    !virtq_setup(vd, 1, &vionet_txq)) {
		sbi_console_puts("[vionet] queue setup FAILED\n");
		return (0);
	}

	virtio_driver_ok(vd);

	vionet_txbuf = page_alloc();
	vionet_rxbuf = page_alloc();
	if (vionet_txbuf == 0 || vionet_rxbuf == 0) {
		sbi_console_puts("[vionet] DMA buffer alloc FAILED\n");
		return (0);
	}
	vionet_dev = vd;
	vionet_ready = 1;

	sbi_console_puts("[vionet] MAC ");
	for (i = 0; i < 6; i++) {
		static const char hx[] = "0123456789abcdef";
		if (i)
			sbi_console_putchar(':');
		sbi_console_putchar(hx[(vionet_mac[i] >> 4) & 0xf]);
		sbi_console_putchar(hx[vionet_mac[i] & 0xf]);
	}
	sbi_console_puts(", RX+TX queues online, DRIVER_OK set\n");

	/* Give the device a receive buffer. */
	(void) vionet_post_rx();

	/*
	 * Build a broadcast Ethernet frame at txbuf + hdr: dst = ff:ff:ff:ff:ff:ff,
	 * src = our MAC, ethertype 0x0806 (ARP), then a minimal ARP request for
	 * 10.0.2.2 (the slirp gateway). slirp will consume the broadcast; the TX
	 * used-ring completion is the proof the TX path works.
	 */
	frame = (unsigned char *)(vionet_txbuf + VIONET_HDR_LEN);
	for (i = 0; i < 6; i++)
		frame[i] = 0xff;			/* dst broadcast */
	for (i = 0; i < 6; i++)
		frame[6 + i] = vionet_mac[i];		/* src */
	frame[12] = 0x08; frame[13] = 0x06;		/* ethertype ARP */
	/* ARP: htype=1 ptype=0x0800 hlen=6 plen=4 op=1(request). */
	frame[14] = 0x00; frame[15] = 0x01;
	frame[16] = 0x08; frame[17] = 0x00;
	frame[18] = 0x06; frame[19] = 0x04;
	frame[20] = 0x00; frame[21] = 0x01;
	for (i = 0; i < 6; i++)
		frame[22 + i] = vionet_mac[i];		/* sender HW */
	frame[28] = 10; frame[29] = 0; frame[30] = 2; frame[31] = 15;	/* sender IP 10.0.2.15 */
	for (i = 0; i < 6; i++)
		frame[32 + i] = 0x00;			/* target HW unknown */
	frame[38] = 10; frame[39] = 0; frame[40] = 2; frame[41] = 2;	/* target IP 10.0.2.2 */
	flen = 42;
	/* Pad to the 60-byte Ethernet minimum. */
	for (i = flen; i < 60; i++)
		frame[i] = 0x00;
	flen = 60;

	tx_ok = vionet_tx_frame(flen);
	sbi_console_puts("[vionet] TX broadcast ARP (");
	kputdec(flen);
	sbi_console_puts(" bytes): ");
	sbi_console_puts(tx_ok ? "completed (used ring)\n" : "TIMED OUT\n");

	/*
	 * Best-effort RX: poll the RX queue briefly for the ARP reply from the
	 * slirp gateway. Not guaranteed in a headless timebox, so RX-not-seen is
	 * not a failure of the driver.
	 */
	{
		int id = virtq_poll_used(&vionet_rxq);
		if (id >= 0) {
			rx_ok = 1;
			sbi_console_puts("[vionet] RX frame received (used "
			    "ring)\n");
		} else {
			sbi_console_puts("[vionet] RX: no frame within poll "
			    "window (slirp may not reply; TX path proven)\n");
		}
	}

	if (tx_ok) {
		sbi_console_puts("vionet: TX");
		if (rx_ok)
			sbi_console_puts("/RX");
		sbi_console_puts(" OK\n");
		return (1);
	}
	return (0);
}

/*
 * ---------------------------------------------------------------------------
 * rvsrv: the frame interface the IPv4 stack (inet.c) drives. The attach proof
 * above leaves one RX buffer posted and the RX/TX queues live; vionet_net_start
 * re-arms RX with VIONET_NRX buffers (one 2 KiB half-page each) so a burst of
 * frames is not dropped, and vionet_rx_poll / vionet_tx hand whole Ethernet
 * frames (no virtio-net header) across. Polled, like the rest of this driver:
 * inet.c's netd thread calls vionet_rx_poll. Caller serializes (inet netlock).
 * ---------------------------------------------------------------------------
 */
#define	VIONET_NRX	((int)VIRTQ_SIZE - 1)	/* keep one desc spare (attach) */
static unsigned long vionet_rxpage[VIONET_NRX];
static int vionet_rxdesc[VIONET_NRX];
static int vionet_started;

int
vionet_present(void)
{
	return (vionet_ready);
}

void
vionet_get_mac(unsigned char *mac)
{
	int i;

	for (i = 0; i < 6; i++)
		mac[i] = vionet_mac[i];
}

static void
vionet_rx_arm(int k)
{
	int d = vionet_rxdesc[k];

	vionet_rxq.vq_desc[d].addr = vionet_rxpage[k];
	vionet_rxq.vq_desc[d].len = 2048;
	vionet_rxq.vq_desc[d].flags = VIRTQ_DESC_F_WRITE;
	vionet_rxq.vq_desc[d].next = 0;
	virtq_submit(&vionet_rxq, d);
}

int
vionet_net_start(void)
{
	int k;

	if (!vionet_ready)
		return (0);
	if (vionet_started)
		return (1);
	for (k = 0; k < VIONET_NRX; k++) {
		vionet_rxpage[k] = page_alloc();
		vionet_rxdesc[k] = virtq_alloc_desc(&vionet_rxq);
		if (vionet_rxpage[k] == 0 || vionet_rxdesc[k] < 0)
			return (0);
		vionet_rx_arm(k);
	}
	vionet_started = 1;
	return (1);
}

/*
 * vionet_rx_poll -- if a frame has landed, copy up to `max` bytes of it (the
 * Ethernet frame, header stripped) into `buf`, re-post its buffer, and return
 * the frame length; 0 if nothing is pending. Non-blocking.
 */
unsigned int
vionet_rx_poll(unsigned char *buf, unsigned int max)
{
	struct virtq_used_elem *ue;
	unsigned int len, i;
	unsigned char *src;
	int id, k;

	if (!vionet_started)
		return (0);
	__asm__ __volatile__("fence ir, ir" ::: "memory");
	if (vionet_rxq.vq_used->idx == vionet_rxq.vq_last_used)
		return (0);
	ue = &vionet_rxq.vq_used->ring[vionet_rxq.vq_last_used %
	    vionet_rxq.vq_num];
	id = (int)ue->id;
	len = ue->len;
	vionet_rxq.vq_last_used++;

	for (k = 0; k < VIONET_NRX; k++)
		if (vionet_rxdesc[k] == id)
			break;
	if (k == VIONET_NRX) {
		/* attach's one-shot buffer: retire it, nothing to deliver */
		virtq_free_desc(&vionet_rxq, id);
		return (0);
	}
	len = len > VIONET_HDR_LEN ? len - VIONET_HDR_LEN : 0;
	if (len > max)
		len = max;
	src = (unsigned char *)(vionet_rxpage[k] + VIONET_HDR_LEN);
	for (i = 0; i < len; i++)
		buf[i] = src[i];
	vionet_rx_arm(k);
	return (len);
}

/* vionet_tx -- transmit one Ethernet frame (<= 1514 bytes). 1 on completion. */
int
vionet_tx(const unsigned char *frame, unsigned int len)
{
	unsigned char *dst;
	unsigned int i;

	if (!vionet_ready || len > 2048 - VIONET_HDR_LEN)
		return (0);
	dst = (unsigned char *)(vionet_txbuf + VIONET_HDR_LEN);
	for (i = 0; i < len; i++)
		dst[i] = frame[i];
	for (; i < 60; i++)
		dst[i] = 0;		/* pad a runt to the Ethernet minimum */
	return (vionet_tx_frame(len < 60 ? 60 : len));
}
