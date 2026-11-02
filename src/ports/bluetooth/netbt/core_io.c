/*
 * core_io.c: the receive side and the socket-layer hooks of the userland
 * netbt core (solnix, new code).
 *
 * hci_mtap and hci_drop are hci_socket.c's (raw HCI socket tap and sockbuf
 * accounting); phase 1 replaces the socket with a function pointer. The pump
 * takes the place of USBA's callback thread plus the softint thread.
 */
#include "compat/kshim.h"
#include "upstream/netbt/bluetooth.h"
#include "upstream/netbt/hci.h"
#include "xport.h"
#include "core.h"

extern core_tap_fn core_tap;
extern struct hci_unit *core_unit;

/* hci_socket.c: every packet in or out passes here; m starts with the H4 type byte. */
void
hci_mtap(struct mbuf *m, struct hci_unit *unit)
{
	uint8_t buf[1 + HCI_EVENT_PKT_SIZE];
	int len = m->m_pkthdr.len;

	(void) unit;
	if (core_tap == NULL)
		return;
	if (len > (int)sizeof (buf))
		len = (int)sizeof (buf);
	m_copydata(m, 0, len, buf);
	core_tap((m->m_flags & M_LINK0) != 0, buf, len);
}

/* STUB: hci_socket.c sockbuf accounting; only raw-socket commands carry a context. */
void
hci_drop(void *arg)
{
	(void) arg;
	kshim_panic(__FILE__, __LINE__, "STUB: hci_drop (no HCI socket in userland)");
}

/*
 * One step of the "kernel": wait up to ms for an event, hand it to the core
 * the way ubt_recv_event does (an mbuf with the H4 type byte in front), then
 * run the soft interrupt. bt_lock must not be held (hci_intr takes it).
 */
int
kshim_pump(int ms)
{
	uint8_t buf[HCI_EVENT_PKT_SIZE];
	struct mbuf *m;
	int n;

	KASSERT(!mutex_owned(bt_lock));
	if (kshim_run_softints())	/* work queued by a previous step first */
		return (0);
	n = xport_cur->recv_evt(xport_cur->arg, buf, sizeof (buf), ms);
	if (n < 0)
		return (-1);
	if (n > 0) {
		/*
		 * As ubt_recv_event: load what arrived, unchecked. A length that
		 * disagrees with the header is hci_event()'s to drop (upstream).
		 */
		if ((m = m_frombuf(HCI_EVENT_PKT, buf, n)) == NULL) {
			core_counts.evts_dropped++;
		} else if (!hci_input_event(core_unit, m)) {
			core_counts.evts_dropped++;
		} else {
			core_counts.evts_in++;
		}
	}
	(void) kshim_run_softints();
	return (0);
}

int
core_wait(int (*done)(void *), void *arg, int ms)
{
	uint64_t end = xport_cur->now_ms(xport_cur->arg) + (uint64_t)ms;

	while (!done(arg)) {
		uint64_t now = xport_cur->now_ms(xport_cur->arg);

		if (now >= end)
			return (0);
		if (kshim_pump((int)(end - now)) < 0)
			return (-1);
	}
	return (1);
}

void
core_down(void)
{
	struct btreq btr;

	memset(&btr, 0, sizeof (btr));
	(void) snprintf(btr.btr_name, sizeof (btr.btr_name), "%s",
	    device_xname(core_unit->hci_dev));
	if (core_ioctl(SIOCGBTINFO, &btr) != 0 || (btr.btr_flags & BTF_UP) == 0)
		return;
	btr.btr_flags &= ~BTF_UP;
	(void) core_ioctl(SIOCSBTFLAGS, &btr);
}
