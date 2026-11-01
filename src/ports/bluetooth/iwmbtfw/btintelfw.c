/*
 * btintelfw: Intel Bluetooth firmware loader for illumos (solnix, new code).
 *
 * Runs FreeBSD's iwmbtfw (upstream/, unmodified, BSD-2) over ugen(4D) through
 * the libusb subset in ugen_usb.c. Including the upstream .c files here keeps
 * them byte-identical while giving us their static helpers.
 *
 *   btintelfw -d /dev/usb/8087.33/0 -r            read-only: Intel version TLV + fw name
 *   btintelfw -d /dev/usb/8087.33/0 -l -f <dir>   load .sfi + .ddc (upstream handle_9260)
 *   btintelfw -d /dev/usb/8087.33/0 -V            HCI_Read_Local_Version
 *   btintelfw -t                                  self-test (no device)
 */
#define	main	iwmbtfw_main
#include "upstream/main.c"
#undef	main
#include "upstream/iwmbt_hw.c"
#include "ugen_evq.h"

int btintel_selftest(void);
int btintel_read_local_version(libusb_device_handle *, uint8_t *);

/*
 * HCI_Read_Local_Version (OGF 4, OCF 1): standard, read-only. out9, if not
 * NULL, gets the 9 return-parameter bytes (status first).
 */
int
btintel_read_local_version(libusb_device_handle *hdl, uint8_t *out9)
{
	static struct iwmbt_hci_cmd cmd = {
		.opcode = htole16(0x1001),
		.length = 0,
	};
	uint8_t buf[64];
	struct iwmbt_hci_event_cmd_compl *ev = (void *)buf;
	int r, n = 0;

	memset(buf, 0, sizeof (buf));
	r = iwmbt_hci_command(hdl, &cmd, buf, sizeof (buf), &n,
	    IWMBT_HCI_CMD_TIMEOUT);
	if (r < 0 || ev->header.event != NG_HCI_EVENT_COMMAND_COMPL ||
	    n < (int)offsetof(struct iwmbt_hci_event_cmd_compl, data) + 9) {
		iwmbt_err("HCI_Read_Local_Version failed: r=%d len=%d evt=0x%02x",
		    r, n, ev->header.event);
		return (-1);
	}
	if (ev->data[0] != 0) {
		iwmbt_err("HCI_Read_Local_Version status 0x%02x", ev->data[0]);
		return (-1);
	}
	if (out9 != NULL)
		memcpy(out9, ev->data, 9);
	printf("HCI_Read_Local_Version: hci_version=%u hci_revision=0x%04x "
	    "lmp_version=%u manufacturer=0x%04x lmp_subversion=0x%04x\n",
	    ev->data[1], le16dec(ev->data + 2), ev->data[4],
	    le16dec(ev->data + 5), le16dec(ev->data + 7));
	return (0);
}

/* -r: Intel Read Version (0xfc05, TLV form; read-only) and the firmware name. */
static int
btintel_read_only(libusb_device_handle *hdl, const char *fwdir)
{
	struct iwmbt_version_tlv vt;
	char *sfi, *ddc;

	memset(&vt, 0, sizeof (vt));	/* absent TLVs print as 0, not stack */
	if (iwmbt_get_version_tlv(hdl, &vt) < 0) {
		iwmbt_err("Intel Read Version (TLV) failed");
		return (-1);
	}
	iwmbt_do_info = 1;
	iwmbt_dump_version_tlv(&vt);
	sfi = iwmbt_get_fwname_tlv(&vt, fwdir, "sfi");
	ddc = iwmbt_get_fwname_tlv(&vt, fwdir, "ddc");
	printf("img_type=0x%02x (%s) hw_variant=0x%02x sbe_type=%u "
	    "limited_cce=%u\nfirmware: %s\nddc: %s\n", vt.img_type,
	    vt.img_type == TLV_IMG_TYPE_BOOTLOADER ? "bootloader" :
	    vt.img_type == TLV_IMG_TYPE_OPERATIONAL ? "operational" : "unknown",
	    (vt.cnvi_bt >> 16) & 0x3f, vt.sbe_type, vt.limited_cce,
	    sfi ? sfi : "?", ddc ? ddc : "?");
	free(sfi);
	free(ddc);
	return (0);
}

static void
btintel_usage(void)
{
	fprintf(stderr, "usage: btintelfw -d /dev/usb/<vid>.<pid>/<inst> "
	    "{-r | -l | -V [-n N]} [-f fwdir] [-D]\n       btintelfw -t\n");
	exit(2);
}

int
main(int argc, char *argv[])
{
	libusb_context *ctx = NULL;
	libusb_device *dev = NULL;
	libusb_device_handle *hdl = NULL;
	enum iwmbt_device type = IWMBT_DEVICE_UNKNOWN;
	const char *dir = NULL, *fwdir = _DEFAULT_IWMBT_FIRMWARE_PATH;
	int c, ronly = 0, load = 0, ver = 0, nrep = 1, ok = 0, rc = 1;

	while ((c = getopt(argc, argv, "d:f:rlVDtn:")) != -1) {
		switch (c) {
		case 'd': dir = optarg; break;
		case 'f': fwdir = optarg; break;
		case 'r': ronly = 1; break;
		case 'l': load = 1; break;
		case 'V': ver = 1; break;
		case 'n': nrep = atoi(optarg); break;
		case 'D': iwmbt_do_debug = iwmbt_do_info = 1; break;
		case 't': return (btintel_selftest() == 0 ? 0 : 1);
		default: btintel_usage();
		}
	}
	if (dir == NULL || (ronly + load + ver) == 0 || nrep < 1 || nrep > 1000)
		btintel_usage();
	if (ugen_usb_set_dir(dir) != 0 || libusb_init(&ctx) != 0) {
		iwmbt_err("bad ugen directory %s", dir);
		return (1);
	}
	if ((dev = iwmbt_find_device(ctx, 0, 0, &type)) == NULL) {
		iwmbt_err("%s: no supported Intel Bluetooth device", dir);
		goto out;
	}
	if ((c = libusb_open(dev, &hdl)) != 0) {
		iwmbt_err("open %s: %s", dir, libusb_strerror(c));
		goto out;
	}
	if (ronly && btintel_read_only(hdl, fwdir) != 0)
		goto out;
	if (load) {
		/* only the TLV (9260+) family has been exercised on illumos */
		if (iwmbt_identify(hdl, type) != IWMBT_DEVICE_9260) {
			iwmbt_err("refusing to load: not a 9260-family device");
			goto out;
		}
		iwmbt_do_info = 1;
		if (handle_9260(hdl, (char *)fwdir) != 0)
			goto out;
	}
	/* -n N: N reads on ONE open handle, to separate ugen reopen from controller state */
	for (c = 0; ver && c < nrep; c++)
		if (btintel_read_local_version(hdl, NULL) == 0)
			ok++;
	if (ver && nrep > 1)
		printf("HCI_Read_Local_Version: %d/%d ok on one handle\n", ok, nrep);
	if (ver && ok != nrep)
		goto out;
	rc = 0;
out:
	libusb_close(hdl);
	libusb_unref_device(dev);
	libusb_exit(ctx);
	return (rc);
}
