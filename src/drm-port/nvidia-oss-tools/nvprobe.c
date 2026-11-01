/*
 * nvprobe -- the NVIDIA open-module ioctl probe for illumos (no proprietary
 * userland). Opens /dev/nvidiactl, checks the RM API version, lists the GPUs
 * (NV_ESC_CARD_INFO), opens /dev/nvidia0 (the first open brings RM up on the
 * GPU: RmInitAdapter, GSP boot), allocates root client -> device ->
 * subdevice, and prints the GPU name and its core temperature.
 *
 *   nvprobe            one probe, exit 0 when every step answered
 *   nvprobe -t         temperature only, one integer (C) on stdout
 *   nvprobe -w SECS    probe, then hold /dev/nvidia0 open SECS seconds (0 =
 *                      forever): RM tears the GPU down at the last close
 *
 * MIT (it reuses only the ABI from the MIT kernel-open/ and src/common/sdk/).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include "nvtypes.h"
#include "nv-ioctl.h"
#include "nv_escape.h"
#include "nvos.h"
#include "nvstatus.h"
#include "class/cl0000.h"
#include "class/cl0080.h"
#include "class/cl2080.h"
#include "ctrl/ctrl0000/ctrl0000gpu.h"
#include "ctrl/ctrl2080/ctrl2080gpu.h"
#include "ctrl/ctrl2080/ctrl2080thermal.h"

/* _IOWR('F', nr, size): what nvidia_ioctl() decodes (nv-illumos.h NV_IOC_*) */
#define	NVIOC(nr, sz)	(0xc0000000U | (((sz) & 0x3fffU) << 16) | \
			(NV_IOCTL_MAGIC << 8) | (nr))

static int
nvioc(int fd, int nr, void *p, size_t sz)
{
	nv_ioctl_xfer_t x;

	if (sz <= 0x3fffU)
		return (ioctl(fd, NVIOC(nr, sz), p));
	/* large arguments go through XFER, as libnvidia does */
	x.cmd = nr;
	x.size = sz;
	x.ptr = (NvP64)(uintptr_t)p;
	return (ioctl(fd, NVIOC(NV_ESC_IOCTL_XFER_CMD, sizeof (x)), &x));
}

/* RM picks the handle (hObjectNew 0), as the Linux userland does */
static int
rmalloc(int fd, NvHandle cl, NvHandle par, NvHandle *obj, NvU32 cls,
    void *prm, NvU32 psz)
{
	NVOS21_PARAMETERS a;

	memset(&a, 0, sizeof (a));
	a.hRoot = cl;
	a.hObjectParent = par;
	a.hObjectNew = 0;
	a.hClass = cls;
	a.pAllocParms = (NvP64)(uintptr_t)prm;
	a.paramsSize = psz;
	if (nvioc(fd, NV_ESC_RM_ALLOC, &a, sizeof (a)) != 0)
		return (-errno);
	*obj = a.hObjectNew;
	return (a.status);
}

static int
rmctl(int fd, NvHandle cl, NvHandle obj, NvU32 cmd, void *prm, NvU32 psz)
{
	NVOS54_PARAMETERS c;

	memset(&c, 0, sizeof (c));
	c.hClient = cl;
	c.hObject = obj;
	c.cmd = cmd;
	c.params = (NvP64)(uintptr_t)prm;
	c.paramsSize = psz;
	if (nvioc(fd, NV_ESC_RM_CONTROL, &c, sizeof (c)) != 0)
		return (-errno);
	return (c.status);
}

static NvHandle HCL, HDEV, HSUB;

/* the GPU core temperature in C via THERMAL_SYSTEM_EXECUTE_V2, or -1000 */
static int
gputemp(int fd)
{
	static NV2080_CTRL_THERMAL_SYSTEM_EXECUTE_V2_PARAMS p;
	NV2080_CTRL_THERMAL_SYSTEM_INSTRUCTION *in = p.instructionList;
	NvU32 n, i, s;

	memset(&p, 0, sizeof (p));
	p.clientAPIVersion = THERMAL_SYSTEM_API_VER;
	p.clientAPIRevision = THERMAL_SYSTEM_API_REV;
	p.clientInstructionSizeOf = sizeof (*in);
	p.instructionListSize = 1;
	in[0].opcode = NV2080_CTRL_THERMAL_SYSTEM_GET_INFO_SENSORS_AVAILABLE_OPCODE;
	if (rmctl(fd, HCL, HSUB, NV2080_CTRL_CMD_THERMAL_SYSTEM_EXECUTE_V2,
	    &p, sizeof (p)) != NV_OK || !in[0].executed || in[0].result != NV_OK)
		return (-1000);
	n = in[0].operands.getInfoSensorsAvailable.availableSensors;
	for (s = 0; s < n && s < 8; s++) {
		/* the first sensor whose target is the GPU */
		memset(&p.instructionList, 0, sizeof (p.instructionList));
		p.instructionListSize = 2;
		in[0].opcode = NV2080_CTRL_THERMAL_SYSTEM_GET_INFO_SENSOR_TARGET_OPCODE;
		in[0].operands.getInfoSensorTarget.sensorIndex = s;
		in[1].opcode = NV2080_CTRL_THERMAL_SYSTEM_GET_STATUS_SENSOR_READING_OPCODE;
		in[1].operands.getStatusSensorReading.sensorIndex = s;
		if (rmctl(fd, HCL, HSUB, NV2080_CTRL_CMD_THERMAL_SYSTEM_EXECUTE_V2,
		    &p, sizeof (p)) != NV_OK)
			continue;
		i = in[0].operands.getInfoSensorTarget.targetIndex;
		if (in[1].executed && in[1].result == NV_OK && i == 0)
			return (in[1].operands.getStatusSensorReading.value);
	}
	return (-1000);
}

int
main(int argc, char **argv)
{
	nv_ioctl_rm_api_version_t v;
	nv_ioctl_card_info_t ci[8];
	NV0000_CTRL_GPU_GET_ID_INFO_V2_PARAMS id;
	NV0080_ALLOC_PARAMETERS d;
	NV2080_ALLOC_PARAMETERS sd;
	NV2080_CTRL_GPU_GET_NAME_STRING_PARAMS nm;
	NVOS00_PARAMETERS fr;
	int ctl, gpu, i, r, t, tonly = 0, hold = -1, ng = 0;

	if (argc > 1 && strcmp(argv[1], "-t") == 0)
		tonly = 1;
	else if (argc > 2 && strcmp(argv[1], "-w") == 0)
		hold = atoi(argv[2]);
	if ((ctl = open("/dev/nvidiactl", O_RDWR)) < 0) {
		perror("nvprobe: /dev/nvidiactl");
		return (2);
	}
	memset(&v, 0, sizeof (v));
	v.cmd = NV_RM_API_VERSION_CMD_QUERY;
	r = nvioc(ctl, NV_ESC_CHECK_VERSION_STR, &v, sizeof (v));
	if (!tonly)
		printf("rm-api: rc=%d reply=%u version=%.64s\n", r, v.reply,
		    v.versionString);
	memset(ci, 0, sizeof (ci));
	if (nvioc(ctl, NV_ESC_CARD_INFO, ci, sizeof (ci)) != 0) {
		perror("nvprobe: CARD_INFO");
		return (3);
	}
	for (i = 0; i < 8; i++) {
		if (!ci[i].valid)
			continue;
		ng++;
		if (!tonly)
			printf("card %d: %04x:%04x bus %u gpu_id 0x%x minor %u "
			    "bar0 0x%llx/%llu MB fb 0x%llx/%llu MB\n", i,
			    ci[i].pci_info.vendor_id, ci[i].pci_info.device_id,
			    ci[i].pci_info.bus, ci[i].gpu_id, ci[i].minor_number,
			    (unsigned long long)ci[i].reg_address,
			    (unsigned long long)(ci[i].reg_size >> 20),
			    (unsigned long long)ci[i].fb_address,
			    (unsigned long long)(ci[i].fb_size >> 20));
	}
	if (ng == 0) {
		fprintf(stderr, "nvprobe: no GPU attached\n");
		return (3);
	}
	/* the first open of the GPU node starts RM on it (RmInitAdapter, GSP) */
	{
		char dev[32];
		nv_ioctl_register_fd_t rf;

		(void) snprintf(dev, sizeof (dev), "/dev/nvidia%u",
		    ci[0].valid ? ci[0].minor_number : 0);
		if ((gpu = open(dev, O_RDWR)) < 0) {
			fprintf(stderr, "nvprobe: %s: %s (RmInitAdapter/GSP "
			    "failed: see dmesg)\n", dev, strerror(errno));
			return (4);
		}
		rf.ctl_fd = ctl;
		if (nvioc(gpu, NV_ESC_REGISTER_FD, &rf, sizeof (rf)) != 0)
			perror("nvprobe: REGISTER_FD");
		if (!tonly)
			printf("open %s: ok (RM initialized the GPU)\n", dev);
	}
	if ((r = rmalloc(ctl, 0, 0, &HCL, NV01_ROOT_CLIENT, NULL, 0)) != NV_OK) {
		fprintf(stderr, "nvprobe: root client alloc: 0x%x\n", r);
		return (5);
	}
	memset(&id, 0, sizeof (id));
	id.gpuId = ci[0].gpu_id;
	r = rmctl(ctl, HCL, HCL, NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2, &id,
	    sizeof (id));
	memset(&d, 0, sizeof (d));
	d.deviceId = id.deviceInstance;
	d.hClientShare = HCL;
	memset(&sd, 0, sizeof (sd));
	if (r != NV_OK ||
	    (r = rmalloc(ctl, HCL, HCL, &HDEV, NV01_DEVICE_0, &d,
	    sizeof (d))) != NV_OK ||
	    (r = rmalloc(ctl, HCL, HDEV, &HSUB, NV20_SUBDEVICE_0, &sd,
	    sizeof (sd))) != NV_OK) {
		fprintf(stderr, "nvprobe: device/subdevice: 0x%x\n", r);
		return (5);
	}
	t = gputemp(ctl);
	if (tonly) {
		printf("%d\n", t);
		return (t > -1000 ? 0 : 6);
	}
	memset(&nm, 0, sizeof (nm));
	nm.gpuNameStringFlags = NV2080_CTRL_GPU_GET_NAME_STRING_FLAGS_TYPE_ASCII;
	r = rmctl(ctl, HCL, HSUB, NV2080_CTRL_CMD_GPU_GET_NAME_STRING, &nm,
	    sizeof (nm));
	printf("name: %s (0x%x)\ntemp: %d C\n",
	    r == NV_OK ? (char *)nm.gpuNameString.ascii : "?", r, t);
	if (hold >= 0) {
		printf("holding the GPU open%s\n", hold ? "" : " (until killed)");
		fflush(stdout);
		for (i = 0; hold == 0 || i < hold; i++)
			(void) sleep(1);
	}
	memset(&fr, 0, sizeof (fr));
	fr.hRoot = fr.hObjectParent = fr.hObjectOld = HCL;
	(void) nvioc(ctl, NV_ESC_RM_FREE, &fr, sizeof (fr));
	return (t > -1000 ? 0 : 6);
}
