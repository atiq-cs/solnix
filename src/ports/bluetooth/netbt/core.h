/*
 * core.h: plain-C entry points into the userland netbt core (solnix, new
 * code). core.c is the hci_if a ubt driver would provide, over xport_cur.
 */
#ifndef _SOLNIX_NETBT_CORE_H
#define	_SOLNIX_NETBT_CORE_H

#include <stdint.h>

struct btreq;

/* attach unit "ubt0" over the current transport (gate in its enable hook) */
int core_attach(const char *xname);
/* the ioctl path btconfig takes: hci_ioctl_pcb under bt_lock */
int core_ioctl(unsigned long cmd, struct btreq *);
/* send one HCI command through the core's credit queue (hci_send_cmd) */
int core_send_cmd(uint16_t opcode, const void *params, uint8_t len);
/*
 * Run the pump (bt_lock not held) until done(arg) is true or ms pass.
 * Returns 1 done, 0 timeout, -1 transport error.
 */
int core_wait(int (*done)(void *), void *arg, int ms);
/* the unit's memo (inquiry cache) length, hci_misc.c's list */
int core_memo_count(void);
/* bring the unit down if it is up (SIOCSBTFLAGS without BTF_UP) */
void core_down(void);
/* the raw-socket tap: hci_mtap calls this for every packet in or out */
typedef void (*core_tap_fn)(int incoming, const uint8_t *pkt, int len);
void core_set_tap(core_tap_fn);
/* counters the tests check */
struct core_counts {
	unsigned cmds_out;	/* commands handed to the transport */
	unsigned evts_in;	/* events handed to hci_input_event */
	unsigned evts_dropped;	/* refused by hci_input_event or bad framing */
	unsigned errors;	/* aprint_error_dev lines (CommandStatus/Complete failures) */
	unsigned gate_refused;	/* enable refused by the bootloader gate */
};
extern struct core_counts core_counts;
void core_note_error(void);

/* kshim.c */
int kshim_pump(int ms);		/* one transport wait + softints; -1 on error */
int kshim_run_softints(void);

#endif
