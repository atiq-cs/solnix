/*
 * gate.c: the Intel bootloader gate (solnix, new code).
 *
 * FreeBSD ng_ubt_intel.c:33-37: initialising the HCI stack while an Intel
 * controller sits in its bootloader can lock it until a power cycle. So the
 * enable hook asks Intel Read Version (0xfc05, TLV form) first and refuses
 * unless the image type is 0x03 (operational): bluetooth-phase1-plan.md 0.3.
 * The TLV parse is FreeBSD's (iwmbtfw upstream/iwmbt_fw.c, unmodified); this
 * file is compiled with iwmbtfw's compat headers and none of netbt's, because
 * the two define bdaddr_t differently.
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include "upstream/iwmbt_fw.h"
#include "xport.h"

/* iwmbt_fw.c's debug switches (upstream main.c defines them in btintelfw) */
int iwmbt_do_debug, iwmbt_do_info;

#define	GATE_TIMEOUT_MS	2000	/* iwmbtfw IWMBT_HCI_CMD_TIMEOUT */

int
gate_intel_operational(const struct xport *x, uint8_t *img_type)
{
	static const uint8_t cmd[] = { 0x05, 0xfc, 0x01, 0xff };
	struct iwmbt_version_tlv vt;
	uint8_t ev[258];
	uint64_t end;
	int n;

	*img_type = 0;
	if (x->send_cmd(x->arg, cmd, sizeof (cmd)) != 0)
		return (EIO);
	end = x->now_ms(x->arg) + GATE_TIMEOUT_MS;
	for (;;) {
		uint64_t now = x->now_ms(x->arg);

		if (now >= end)
			return (EIO);
		n = x->recv_evt(x->arg, ev, sizeof (ev), (int)(end - now));
		if (n < 0)
			return (EIO);
		/* Command Complete (0x0e) for 0xfc05; anything else is stray */
		if (n >= 6 && ev[0] == 0x0e && n == 2 + ev[1] &&
		    ev[3] == 0x05 && ev[4] == 0xfc)
			break;
	}
	memset(&vt, 0, sizeof (vt));
	/* return parameters: status, then the TLVs (iwmbt_read_version_tlv) */
	if (iwmbt_parse_tlv(ev + 5, (uint8_t)(ev[1] - 3), &vt) != 0)
		return (EIO);
	*img_type = vt.img_type;
	return (vt.img_type == TLV_IMG_TYPE_OPERATIONAL ? 0 : ENODEV);
}
