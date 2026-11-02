/*
 * hcitest: NetBSD's netbt HCI core in userland, over ugen or a transcript
 * (solnix, new code; bluetooth-phase1-plan.md P4/P5).
 *
 *   hcitest -d /dev/usb/8087.33/0 [-i] [-W out.hcx] [-C]   live: unit up [+ inquiry]
 *   hcitest -F in.hcx [-i]                                  replay a transcript
 *   hcitest -R -d <dir> [-i] -W out.hcx                     record without the core
 *   hcitest -t                                              self-test
 *
 * "Up" is exactly btconfig's path: SIOCSBTFLAGS with BTF_UP into hci_ioctl_pcb,
 * which runs hci_enable (the enable hook = transport open + Intel gate, then
 * HCI_Reset and the init sequence hci_event.c drives). The inquiry is
 * libbluetooth bt_devinquiry's: Write_Inquiry_Mode 1 (RSSI, btconfig imode
 * rssi), then HCI_Inquiry, results read from the raw-socket tap (hci_mtap).
 * Remote addresses are printed as their OUI only.
 */
#include "compat/kshim.h"
#include "upstream/netbt/bluetooth.h"
#include "upstream/netbt/hci.h"
#include "xport.h"
#include "core.h"
#include "hcitest.h"

int mbuf_test(void);
int scrub_test(void);
extern struct hci_unit *core_unit;

static struct {
	int		done, cs_status, ndev;
	uint8_t		dev[HT_INQ_MAX * 4][6];
	unsigned	seen[256];
} ht;

static void
ht_dev(const uint8_t *ba, const uint8_t *cls, int rssi, int has_rssi)
{
	int i;

	for (i = 0; i < ht.ndev; i++)
		if (memcmp(ht.dev[i], ba, 6) == 0)
			return;
	if (ht.ndev == (int)__arraycount(ht.dev))
		return;
	memcpy(ht.dev[ht.ndev++], ba, 6);
	printf("  device %d: %02x:%02x:%02x:xx:xx:xx class %02x%02x%02x",
	    ht.ndev, ba[5], ba[4], ba[3], cls[2], cls[1], cls[0]);
	if (has_rssi)
		printf(" rssi %d dBm", rssi);
	printf("\n");
}

/* hci_mtap's view: H4 type byte, then the packet */
static void
ht_tap(int incoming, const uint8_t *p, int len)
{
	const uint8_t *e = p + 3;
	int n = len - 3, k;

	if (!incoming || len < 3 || p[0] != HCI_EVENT_PKT)
		return;
	ht.seen[p[1]]++;
	switch (p[1]) {
	case HCI_EVENT_COMMAND_STATUS:
		if (n >= 4 && e[2] == 0x01 && e[3] == 0x04 && e[0] != 0) {
			ht.cs_status = e[0];
			ht.done = 1;
		}
		break;
	case HCI_EVENT_INQUIRY_COMPL:
		ht.done = 1;
		break;
	case HCI_EVENT_INQUIRY_RESULT:		/* 14 bytes each, no RSSI */
		for (k = 0; n >= 1 && k < e[0] && 1 + (k + 1) * 14 <= n; k++)
			ht_dev(e + 1 + k * 14, e + 1 + k * 14 + 9, 0, 0);
		break;
	case HCI_EVENT_RSSI_RESULT:		/* 14 bytes each, RSSI last */
		for (k = 0; n >= 1 && k < e[0] && 1 + (k + 1) * 14 <= n; k++)
			ht_dev(e + 1 + k * 14, e + 1 + k * 14 + 8,
			    (int8_t)e[1 + k * 14 + 13], 1);
		break;
	case HCI_EVENT_EXTENDED_RESULT:
		if (n >= 15)
			ht_dev(e + 1, e + 9, (int8_t)e[14], 1);
		break;
	}
}

static int
ht_done(void *a)
{
	(void) a;
	return (ht.done);
}

static void
ht_print_unit(void)
{
	struct btreq btr;
	int i;

	memset(&btr, 0, sizeof (btr));
	(void) snprintf(btr.btr_name, sizeof (btr.btr_name), "ubt0");
	if (core_ioctl(SIOCGBTINFO, &btr) != 0)
		return;
	printf("ubt0: bdaddr %02x:%02x:%02x:%02x:%02x:%02x flags 0x%04x%s%s%s\n",
	    btr.btr_bdaddr.b[5], btr.btr_bdaddr.b[4], btr.btr_bdaddr.b[3],
	    btr.btr_bdaddr.b[2], btr.btr_bdaddr.b[1], btr.btr_bdaddr.b[0],
	    btr.btr_flags, (btr.btr_flags & BTF_UP) ? " UP" : "",
	    (btr.btr_flags & BTF_RUNNING) ? " RUNNING" : "",
	    (btr.btr_flags & BTF_INIT) ? " INIT-PENDING" : "");
	printf("ubt0: num_cmd %u acl mtu %u x %u, sco mtu %u x %u, ptype 0x%04x\n",
	    btr.btr_num_cmd, btr.btr_acl_mtu, btr.btr_max_acl, btr.btr_sco_mtu,
	    btr.btr_max_sco, btr.btr_packet_type);
	if (core_ioctl(SIOCGBTFEAT, &btr) != 0)
		return;
	printf("ubt0: features");
	for (i = 0; i < HCI_FEATURES_SIZE; i++)
		printf("%s%02x", i ? "" : " p0 ", btr.btr_features0[i]);
	for (i = 0; i < HCI_FEATURES_SIZE; i++)
		printf("%s%02x", i ? "" : " p1 ", btr.btr_features1[i]);
	for (i = 0; i < HCI_FEATURES_SIZE; i++)
		printf("%s%02x", i ? "" : " p2 ", btr.btr_features2[i]);
	printf("\n");
}

/* Bring ubt0 up the way btconfig does; prints the outcome. */
static int
ht_up(void)
{
	struct btreq btr;
	int err;

	if (core_attach("ubt0") != 0)
		return (HT_RC_ENABLE);
	memset(&btr, 0, sizeof (btr));
	(void) snprintf(btr.btr_name, sizeof (btr.btr_name), "ubt0");
	if ((err = core_ioctl(SIOCGBTINFO, &btr)) != 0)
		return (HT_RC_ENABLE);
	btr.btr_flags |= BTF_UP;
	err = core_ioctl(SIOCSBTFLAGS, &btr);
	printf("SIOCSBTFLAGS up: %s (err %d)\n", err == 0 ? "ok" : strerror(err), err);
	ht_print_unit();
	return (err == 0 ? HT_RC_OK : HT_RC_ENABLE);
}

static int
ht_inquiry(void)
{
	uint8_t imode = 1, cp[5] = { 0x33, 0x8b, 0x9e, HT_INQ_LEN, HT_INQ_MAX };
	int r;

	ht.done = 0;
	ht.cs_status = 0;
	ht.ndev = 0;
	if (core_send_cmd(HCI_CMD_WRITE_INQUIRY_MODE, &imode, 1) != 0 ||
	    core_send_cmd(HCI_CMD_INQUIRY, cp, sizeof (cp)) != 0)
		return (HT_RC_INQUIRY);
	printf("inquiry: general LAP, %u x 1.28 s, max %u responses, RSSI mode\n",
	    HT_INQ_LEN, HT_INQ_MAX);
	/* 7 x 1.28 s = 9 s; bt_devinquiry gives it to + 1 s; we allow 15 */
	r = core_wait(ht_done, NULL, 15000);
	if (r <= 0 || ht.cs_status != 0) {
		printf("inquiry: %s (status 0x%02x)\n", r < 0 ? "transport error" :
		    r == 0 ? "no Inquiry Complete in 15 s" : "refused", ht.cs_status);
		return (HT_RC_INQUIRY);
	}
	printf("inquiry: complete, %d device%s, memo cache %d\n", ht.ndev,
	    ht.ndev == 1 ? "" : "s", core_memo_count());
	return (ht.ndev > 0 ? HT_RC_OK : HT_RC_EMPTY);
}

static void
ht_summary(void)
{
	printf("core: cmds_out %u evts_in %u evts_dropped %u errors %u "
	    "gate_refused %u\n", core_counts.cmds_out, core_counts.evts_in,
	    core_counts.evts_dropped, core_counts.errors, core_counts.gate_refused);
	printf("events seen:");
	for (int i = 0; i < 256; i++)
		if (ht.seen[i])
			printf(" %02x:%u", i, ht.seen[i]);
	printf("\n");
}

static void
ht_usage(void)
{
	fprintf(stderr, "usage: hcitest -d <ugen dir> [-i] [-W out] [-C]\n"
	    "       hcitest -F <transcript> [-i]\n"
	    "       hcitest -R -d <ugen dir> [-i] -W out\n       hcitest -t\n");
	exit(HT_RC_USAGE);
}

int
main(int argc, char *argv[])
{
	const char *dir = NULL, *fix = NULL, *wout = NULL;
	const struct xport *x;
	FILE *wf = NULL;
	int c, inq = 0, raw = 0, noclear = 0, rc;
	char why[200];

	while ((c = getopt(argc, argv, "d:F:W:iRCt")) != -1) {
		switch (c) {
		case 'd': dir = optarg; break;
		case 'F': fix = optarg; break;
		case 'W': wout = optarg; break;
		case 'i': inq = 1; break;
		case 'R': raw = 1; break;
		case 'C': noclear = 1; break;
		case 't':
			rc = mbuf_test() + scrub_test();
			printf("selftest %s (%d failures)\n", rc ? "FAIL" : "PASS", rc);
			return (rc ? HT_RC_SELFTEST : HT_RC_OK);
		default: ht_usage();
		}
	}
	if ((dir == NULL) == (fix == NULL) || (raw && (dir == NULL || wout == NULL)))
		ht_usage();
	x = dir != NULL ? xport_ugen(dir, noclear) : xport_fixture(fix);
	if (x == NULL) {
		fprintf(stderr, "hcitest: cannot load %s\n", fix);
		return (HT_RC_XPORT);
	}
	if (wout != NULL) {
		if ((wf = fopen(wout, "w")) == NULL) {
			perror(wout);
			return (HT_RC_XPORT);
		}
		x = xport_tee(x, wf);
	}
	xport_cur = x;
	if (raw) {
		rc = raw_record(x, inq);
	} else {
		core_set_tap(ht_tap);
		rc = ht_up();
		if (rc == HT_RC_OK && inq)
			rc = ht_inquiry();
		core_down();
		ht_summary();
	}
	if (wf != NULL)
		(void) fclose(wf);
	if (fix != NULL) {
		int st = xport_fixture_status(why, sizeof (why));

		printf("fixture: %s\n", why);
		if (st != 0 && rc == HT_RC_OK)
			rc = HT_RC_FIXTURE;
	}
	printf("rc=%d\n", rc);
	return (rc);
}
