/*
 * core.c: the hci_if a ubt driver gives netbt, over the userland transport
 * (solnix, new code). Shaped after NetBSD sys/dev/usb/ubt.c (ubt_hci,
 * ubt_enable, ubt_xmit_cmd, ubt_recv_event): enable opens the transport and
 * runs the Intel bootloader gate, output_cmd strips the H4 type byte and sends
 * the command, and received events are loaded into an mbuf with the type byte
 * in front (ubt_mbufload) and handed to hci_input_event.
 */
#include "compat/kshim.h"
#include "upstream/netbt/bluetooth.h"
#include "upstream/netbt/hci.h"
#include "xport.h"
#include "core.h"

const struct xport *xport_cur;
struct core_counts core_counts;
core_tap_fn core_tap;
static struct kshim_device core_dev;
struct hci_unit *core_unit;
static struct bt_stats core_stats;

void
core_note_error(void)
{
	core_counts.errors++;
}

void
core_set_tap(core_tap_fn fn)
{
	core_tap = fn;
}

static int
core_enable(device_t dev)
{
	uint8_t img = 0;
	int err;

	(void) dev;
	if (xport_cur->open(xport_cur->arg) != 0)
		return (EIO);
	/* bluetooth-phase1-plan.md 0.3: never reset an Intel controller in its bootloader */
	if ((err = gate_intel_operational(xport_cur, &img)) != 0) {
		core_counts.gate_refused++;
		fprintf(stderr, "%s: controller not operational (img_type 0x%02x): "
		    "load the firmware first (btintelfw -l)\n", dev->xname, img);
		xport_cur->close(xport_cur->arg);
		return (err);
	}
	return (0);
}

static void
core_disable(device_t dev)
{
	(void) dev;
	xport_cur->close(xport_cur->arg);
}

static void
core_output_cmd(device_t dev, struct mbuf *m)
{
	uint8_t buf[HCI_CMD_PKT_SIZE];
	int len = m->m_pkthdr.len - 1;

	(void) dev;
	KASSERT(len >= 3 && len <= (int)sizeof (buf));
	m_copydata(m, 1, len, buf);	/* drop the H4 type byte, as ubt does */
	m_freem(m);
	if (xport_cur->send_cmd(xport_cur->arg, buf, (size_t)len) != 0) {
		core_stats.err_tx++;
		return;
	}
	core_counts.cmds_out++;
	core_stats.cmd_tx++;
	core_stats.byte_tx += (uint32_t)len;
}

/* STUB: no ACL/SCO links in phase 1; hci_link.c never sends without one. */
static void
core_output_data(device_t dev, struct mbuf *m)
{
	(void) dev;
	m_freem(m);
	core_stats.err_tx++;
}

static void
core_get_stats(device_t dev, struct bt_stats *dest, int flush)
{
	(void) dev;
	memcpy(dest, &core_stats, sizeof (*dest));
	if (flush)
		memset(&core_stats, 0, sizeof (core_stats));
}

static const struct hci_if core_hci = {
	.enable = core_enable,
	.disable = core_disable,
	.output_cmd = core_output_cmd,
	.output_acl = core_output_data,
	.output_sco = core_output_data,
	.get_stats = core_get_stats,
	.ipl = IPL_SOFTNET,
};

int
core_attach(const char *xname)
{
	(void) snprintf(core_dev.xname, sizeof (core_dev.xname), "%s", xname);
	core_unit = hci_attach_pcb(&core_hci, &core_dev, 0);
	return (core_unit == NULL ? ENOMEM : 0);
}

int
core_ioctl(unsigned long cmd, struct btreq *btr)
{
	int err;

	mutex_enter(bt_lock);
	err = hci_ioctl_pcb(cmd, btr);
	mutex_exit(bt_lock);
	return (err);
}

int
core_send_cmd(uint16_t opcode, const void *params, uint8_t len)
{
	int err;

	mutex_enter(bt_lock);
	err = hci_send_cmd(core_unit, opcode, (void *)(uintptr_t)params, len);
	mutex_exit(bt_lock);
	return (err);
}

int
core_memo_count(void)
{
	struct hci_memo *memo;
	int n = 0;

	LIST_FOREACH(memo, &core_unit->hci_memos, next)
		n++;
	return (n);
}
