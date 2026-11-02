/*
 * raw.c: hcitest -R, a recorder that does NOT use the netbt core (solnix, new
 * code). It drives the controller through the same transport and sends what
 * the core would send, from a separate reading of hci_unit.c / hci_event.c:
 * the Intel gate, HCI_Reset, then on each Command Complete the follow-ups
 * hci_cmd_reset / hci_cmd_read_local_features / _ver / _extended_features
 * queue, under the same one-credit flow control (hci_num_cmds runs before the
 * handler). Then Write_Inquiry_Mode and Inquiry, as hcitest -i does.
 * Replaying its transcript into the core on chef must match byte for byte;
 * a mismatch means the core or this reading is wrong.
 */
#include <stdio.h>
#include <string.h>
#include "xport.h"
#include "hcitest.h"

#define	RAW_Q	16

static uint8_t raw_q[RAW_Q][8];
static int raw_qlen, raw_qn[RAW_Q], raw_credit = 1;

/* hci_num_cmds: send from the queue head while there is credit */
static void
raw_flush(const struct xport *x)
{
	while (raw_credit > 0 && raw_qlen > 0) {
		(void) x->send_cmd(x->arg, raw_q[0], (size_t)raw_qn[0]);
		raw_credit--;
		memmove(raw_q[0], raw_q[1], sizeof (raw_q[0]) * (RAW_Q - 1));
		memmove(raw_qn, raw_qn + 1, sizeof (raw_qn[0]) * (RAW_Q - 1));
		raw_qlen--;
	}
}

/* hci_send_cmd: queue with no credit, else send now */
static void
raw_push(const struct xport *x, uint16_t op, const uint8_t *p, uint8_t n)
{
	if (raw_qlen == RAW_Q)
		return;
	raw_q[raw_qlen][0] = (uint8_t)op;
	raw_q[raw_qlen][1] = (uint8_t)(op >> 8);
	raw_q[raw_qlen][2] = n;
	memcpy(&raw_q[raw_qlen][3], p, n);
	raw_qn[raw_qlen++] = 3 + n;
	raw_flush(x);
}

static void
raw_credits(const struct xport *x, uint8_t n)
{
	raw_credit = n;
	raw_flush(x);
}

/* one event; ms budget. Returns its length, 0 timeout, -1 error. */
static int
raw_evt(const struct xport *x, uint8_t *e, int ms)
{
	return (x->recv_evt(x->arg, e, 258, ms));
}

int
raw_record(const struct xport *x, int inquiry)
{
	static const uint8_t z[1] = { 0 }, ext0[1] = { 0 };
	uint8_t e[258], img = 0, imode[1] = { 1 };
	uint8_t inq[5] = { 0x33, 0x8b, 0x9e, HT_INQ_LEN, HT_INQ_MAX };
	int pending = 4, phase = 0, n, waited = 0;

	if (x->open(x->arg) != 0)
		return (HT_RC_XPORT);
	if (gate_intel_operational(x, &img) != 0) {
		printf("raw: controller not operational (img_type 0x%02x): no HCI_Reset sent\n", img);
		x->close(x->arg);
		return (HT_RC_ENABLE);
	}
	raw_push(x, 0x0c03, z, 0);
	while (phase < 3 && waited < 15000) {
		if ((n = raw_evt(x, e, 500)) < 0)
			break;
		if (n == 0) {
			waited += 500;
			continue;
		}
		waited = 0;
		if (e[0] == 0x0f && n >= 6) {			/* Command Status */
			raw_credits(x, e[3]);
			if (phase == 2 && e[4] == 0x01 && e[5] == 0x04 && e[2] != 0) {
				printf("raw: inquiry Command Status 0x%02x\n", e[2]);
				break;
			}
			continue;
		}
		if (e[0] == 0x01 && phase == 2) {		/* Inquiry Complete */
			phase = 3;
			break;
		}
		if (e[0] != 0x0e || n < 6)
			continue;
		raw_credits(x, e[2]);
		/*
		 * e = code len ncmd oplo ophi status rp...; each case needs the
		 * whole return-parameter struct and status 0, or (like the core)
		 * does nothing and init stalls.
		 */
		switch (e[3] | e[4] << 8) {
		case 0x0c03:	/* hci_cmd_reset */
			if (n >= 6 && e[5] == 0) {
				raw_push(x, 0x1009, z, 0);
				raw_push(x, 0x1005, z, 0);
				raw_push(x, 0x1003, z, 0);
				raw_push(x, 0x1001, z, 0);
			}
			break;
		case 0x1009:	/* hci_read_bdaddr_rp: 7 */
			pending -= (n >= 12 && e[5] == 0);
			break;
		case 0x1005:	/* hci_read_buffer_size_rp: 8 */
			pending -= (n >= 13 && e[5] == 0);
			break;
		case 0x1003:	/* features[8]; extended pages when feat[7] bit 7 */
			if (n < 14 || e[5] != 0)
				break;
			if (e[13] & 0x80)
				raw_push(x, 0x1004, ext0, 1);
			else
				pending--;
			break;
		case 0x1004:	/* status page max_page features[8]: 11 */
			if (n < 16 || e[5] != 0)
				break;
			if (e[6] < e[7]) {
				uint8_t pg[1] = { (uint8_t)(e[6] + 1) };

				raw_push(x, 0x1004, pg, 1);
			} else {
				pending--;
			}
			break;
		case 0x1001:	/* hci_read_local_ver_rp: 9; commands from 1.2 */
			if (n < 14 || e[5] != 0)
				break;
			if (e[6] >= 0x02)
				raw_push(x, 0x1002, z, 0);
			else
				pending--;
			break;
		case 0x1002:	/* status commands[64] */
			pending -= (n >= 70 && e[5] == 0);
			break;
		case 0x0c45:
			if (phase == 1) {
				raw_push(x, 0x0401, inq, sizeof (inq));
				phase = 2;
			}
			break;
		}
		if (phase == 0 && pending == 0) {
			printf("raw: init complete\n");
			if (!inquiry)
				break;
			raw_push(x, 0x0c45, imode, 1);
			phase = 1;
		}
	}
	x->close(x->arg);
	printf("raw: %s\n", phase == 3 || (!inquiry && pending == 0) ?
	    "done" : "incomplete");
	return (phase == 3 || (!inquiry && pending == 0) ? 0 : HT_RC_INQUIRY);
}
