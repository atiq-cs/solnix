/*
 * stubs.c: what hci_link.c and hci_ioctl.c reference from L2CAP, SCO and
 * RFCOMM, which phase 1 does not port (solnix, new code).
 *
 * Every function is STUB: it aborts, so reaching one is a loud failure and can
 * never pass for an implementation. The lists are REAL and empty, which is what
 * makes the stubs unreachable: with no L2CAP listener hci_acl_newconn refuses
 * an incoming connection, and with no link nothing is sent or received on ACL.
 */
#include "compat/kshim.h"
#include "upstream/netbt/bluetooth.h"
#include "upstream/netbt/hci.h"
#include "upstream/netbt/l2cap.h"
#include "upstream/netbt/sco.h"

struct l2cap_channel_list l2cap_active_list = LIST_HEAD_INITIALIZER(l2cap_active_list);
struct l2cap_channel_list l2cap_listen_list = LIST_HEAD_INITIALIZER(l2cap_listen_list);
struct sco_pcb_list sco_pcb = LIST_HEAD_INITIALIZER(sco_pcb);
struct pool l2cap_pdu_pool = { sizeof (struct l2cap_pdu) };

#define	STUB(what)	kshim_panic(__FILE__, __LINE__, "STUB: " what)

void
l2cap_close(struct l2cap_channel *c, int e)
{
	(void) c; (void) e;
	STUB("l2cap_close");
}

void
l2cap_recv_frame(struct mbuf *m, struct hci_link *l)
{
	(void) m; (void) l;
	STUB("l2cap_recv_frame");
}

int
l2cap_start(struct l2cap_channel *c)
{
	(void) c;
	STUB("l2cap_start");
}

void
l2cap_request_free(struct l2cap_req *r)
{
	(void) r;
	STUB("l2cap_request_free");
}

int
l2cap_send_connect_req(struct l2cap_channel *c)
{
	(void) c;
	STUB("l2cap_send_connect_req");
}

int
l2cap_send_config_req(struct l2cap_channel *c)
{
	(void) c;
	STUB("l2cap_send_config_req");
}

int
l2cap_send_connect_rsp(struct hci_link *l, uint8_t a, uint16_t b, uint16_t c,
    uint16_t d)
{
	(void) l; (void) a; (void) b; (void) c; (void) d;
	STUB("l2cap_send_connect_rsp");
}

void
sco_detach_pcb(struct sco_pcb **p)
{
	(void) p;
	STUB("sco_detach_pcb");
}
