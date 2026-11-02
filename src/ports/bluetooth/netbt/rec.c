/*
 * rec.c: a transport that writes what it carries to a transcript the fixture
 * can replay (solnix, new code), with remote addresses scrubbed BEFORE they
 * are written (bt3 privacy rule: keep counts, classes and RSSI; truncate
 * addresses to the OUI; drop names).
 *
 *  - inquiry results (0x02, 0x22, 0x2f): each bdaddr keeps its OUI (b[5..3])
 *    and gets a per-device index in b[2..0]; EIR data (names live there) is
 *    zeroed. Class, RSSI, clock offset and scan modes are kept.
 *  - events that are neither command results (0x0e, 0x0f) nor inquiry
 *    results/complete (0x01): parameters zeroed, length kept.
 *  - commands: only HCI_Inquiry, Inquiry_Cancel and the init/info commands
 *    are expected; any other OGF-1 command (which may name a peer) has its
 *    parameters zeroed.
 * The controller's own address (Read_BD_ADDR) is kept: it is ours.
 */
#include <stdio.h>
#include <string.h>
#include "xport.h"

static const struct xport *rec_inner;
static FILE *rec_out;
static uint64_t rec_last_ms;
static uint8_t rec_map[64][6];
static int rec_nmap;

static void
rec_scrub_addr(uint8_t *b)
{
	int i;

	for (i = 0; i < rec_nmap; i++)
		if (memcmp(rec_map[i], b, 6) == 0)
			break;
	if (i == rec_nmap && rec_nmap < 64)
		memcpy(rec_map[rec_nmap++], b, 6);
	b[0] = (uint8_t)(i + 1);	/* bdaddr_t is little-endian: b[5] is the OUI's first byte */
	b[1] = 0x00;
	b[2] = 0x00;
}

/* buf = event code, length, params */
void
rec_scrub(uint8_t *e, size_t n)
{
	size_t i, k, num;

	if (n < 2 || n != 2u + e[1])
		return;
	switch (e[0]) {
	case 0x0e:
	case 0x0f:
	case 0x01:
		return;
	case 0x02:	/* bdaddr[6] psrm pspm psm class[3] clock[2] = 14 per response */
	case 0x22:	/* bdaddr[6] psrm blank class[3] clock[2] rssi  = 14 per response */
		num = n > 2 ? e[2] : 0;
		for (k = 0; k < num && 3 + (k + 1) * 14 <= n; k++)
			rec_scrub_addr(e + 3 + k * 14);
		return;
	case 0x2f:	/* num bdaddr psrm res class[3] clock[2] rssi eir[240] */
		if (n >= 3 + 14)
			rec_scrub_addr(e + 3);
		for (i = 3 + 14; i < n; i++)
			e[i] = 0;
		return;
	default:
		for (i = 2; i < n; i++)
			e[i] = 0;
		return;
	}
}

static void
rec_hex(char kind, const uint8_t *b, size_t n, uint64_t dms)
{
	if (rec_out == NULL)
		return;
	if (kind == 'E')
		fprintf(rec_out, "E +%llu ", (unsigned long long)dms);
	else
		fprintf(rec_out, "C ");
	for (size_t i = 0; i < n; i++)
		fprintf(rec_out, "%02x", b[i]);
	fputc('\n', rec_out);
	(void) fflush(rec_out);
}

static int
rec_send_cmd(void *a, const uint8_t *p, size_t n)
{
	uint8_t c[3 + 255];
	int r;

	(void) a;
	r = rec_inner->send_cmd(rec_inner->arg, p, n);
	if (r == 0 && n <= sizeof (c)) {
		uint16_t op = (uint16_t)(p[0] | p[1] << 8);

		memcpy(c, p, n);
		/* OGF 1 (link control) except Inquiry/Inquiry_Cancel may name a peer */
		if ((op >> 10) == 1 && op != 0x0401 && op != 0x0402)
			memset(c + 3, 0, n - 3);
		rec_hex('C', c, n, 0);
		rec_last_ms = rec_inner->now_ms(rec_inner->arg);
	}
	return (r);
}

static int
rec_recv_evt(void *a, uint8_t *p, size_t n, int ms)
{
	uint8_t e[258];
	int r;

	(void) a;
	r = rec_inner->recv_evt(rec_inner->arg, p, n, ms);
	if (r > 0 && (size_t)r <= sizeof (e)) {
		uint64_t now = rec_inner->now_ms(rec_inner->arg);

		memcpy(e, p, (size_t)r);
		rec_scrub(e, (size_t)r);
		rec_hex('E', e, (size_t)r, now - rec_last_ms);
		rec_last_ms = now;
	}
	return (r);
}

static int rec_open_x(void *a) { (void) a; return (rec_inner->open(rec_inner->arg)); }
static void rec_close_x(void *a) { (void) a; rec_inner->close(rec_inner->arg); }
static uint64_t rec_now(void *a) { (void) a; return (rec_inner->now_ms(rec_inner->arg)); }

const struct xport *
xport_tee(const struct xport *inner, FILE *out)
{
	static struct xport x = {
		"tee", rec_open_x, rec_close_x, rec_send_cmd, rec_recv_evt, rec_now, NULL
	};

	rec_inner = inner;
	rec_out = out;
	rec_last_ms = inner->now_ms(inner->arg);
	return (&x);
}
