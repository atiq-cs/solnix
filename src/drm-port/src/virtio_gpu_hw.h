/*
 * virtio_gpu_hw.h - the virtio-gpu wire protocol (host<->guest command structs).
 *
 * Provenance: struct layouts, command enum, format enum, and config-space
 * layout reproduced VERBATIM from the Linux/QEMU virtio-gpu UAPI
 *   include/uapi/linux/virtio_gpu.h  (torvalds/linux master)
 * which is BSD-licensed precisely so non-Linux drivers can implement a
 * compatible guest driver. This is the on-the-wire ABI QEMU's virtio-gpu
 * device speaks; illumos must lay these structs out identically (all fields
 * little-endian, packed). Only the 2D subset the C1b modeset path uses is
 * reproduced (GET_DISPLAY_INFO, RESOURCE_CREATE_2D, RESOURCE_ATTACH_BACKING,
 * SET_SCANOUT, RESOURCE_FLUSH, TRANSFER_TO_HOST_2D); the 3D/virgl and blob
 * commands are omitted (not on the C1b critical path).
 *
 * NB: __le32/__le64 are little-endian on the wire. amd64 is little-endian, so
 * on this target the byte order matches native and no swap is needed; the
 * types are kept named __le* to mark the ABI contract (a big-endian illumos
 * port would add virtio_dev_get / virtio_dev_put swapping, which the illumos
 * virtio KPI already provides).
 */

#ifndef _VIRTIO_GPU_HW_H_
#define _VIRTIO_GPU_HW_H_

#include <sys/types.h>

typedef uint32_t __le32;
typedef uint64_t __le64;
typedef uint8_t  __u8;

/* virtio-gpu feature bits (negotiated with the host). */
#define VIRTIO_GPU_F_VIRGL		0	/* 3D/virgl (not used in C1b) */
#define VIRTIO_GPU_F_EDID		1
#define VIRTIO_GPU_F_RESOURCE_UUID	2
#define VIRTIO_GPU_F_RESOURCE_BLOB	3

/* PCI identity of the QEMU virtio-gpu device (transitional 0x1050 modern). */
#define VIRTIO_GPU_PCI_VENDOR		0x1af4
#define VIRTIO_GPU_PCI_DEVICE		0x1050	/* modern virtio device id 16 */
#define VIRTIO_ID_GPU			16

enum virtio_gpu_ctrl_type {
	VIRTIO_GPU_UNDEFINED = 0,

	/* 2d commands */
	VIRTIO_GPU_CMD_GET_DISPLAY_INFO = 0x0100,
	VIRTIO_GPU_CMD_RESOURCE_CREATE_2D,
	VIRTIO_GPU_CMD_RESOURCE_UNREF,
	VIRTIO_GPU_CMD_SET_SCANOUT,
	VIRTIO_GPU_CMD_RESOURCE_FLUSH,
	VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D,
	VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING,
	VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING,
	VIRTIO_GPU_CMD_GET_CAPSET_INFO,
	VIRTIO_GPU_CMD_GET_CAPSET,
	VIRTIO_GPU_CMD_GET_EDID,

	/* cursor commands */
	VIRTIO_GPU_CMD_UPDATE_CURSOR = 0x0300,
	VIRTIO_GPU_CMD_MOVE_CURSOR,

	/* success responses */
	VIRTIO_GPU_RESP_OK_NODATA = 0x1100,
	VIRTIO_GPU_RESP_OK_DISPLAY_INFO,
	VIRTIO_GPU_RESP_OK_CAPSET_INFO,
	VIRTIO_GPU_RESP_OK_CAPSET,
	VIRTIO_GPU_RESP_OK_EDID,

	/* error responses */
	VIRTIO_GPU_RESP_ERR_UNSPEC = 0x1200,
	VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY,
	VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID,
	VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID,
	VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID,
	VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER,
};

#define VIRTIO_GPU_FLAG_FENCE		(1 << 0)

struct virtio_gpu_ctrl_hdr {
	__le32 type;
	__le32 flags;
	__le64 fence_id;
	__le32 ctx_id;
	__u8   ring_idx;
	__u8   padding[3];
};

/* data passed in the control vq, 2d related */
struct virtio_gpu_rect {
	__le32 x;
	__le32 y;
	__le32 width;
	__le32 height;
};

/* VIRTIO_GPU_CMD_RESOURCE_UNREF */
struct virtio_gpu_resource_unref {
	struct virtio_gpu_ctrl_hdr hdr;
	__le32 resource_id;
	__le32 padding;
};

/* VIRTIO_GPU_CMD_RESOURCE_CREATE_2D */
struct virtio_gpu_resource_create_2d {
	struct virtio_gpu_ctrl_hdr hdr;
	__le32 resource_id;
	__le32 format;
	__le32 width;
	__le32 height;
};

/* VIRTIO_GPU_CMD_SET_SCANOUT */
struct virtio_gpu_set_scanout {
	struct virtio_gpu_ctrl_hdr hdr;
	struct virtio_gpu_rect r;
	__le32 scanout_id;
	__le32 resource_id;
};

/* VIRTIO_GPU_CMD_RESOURCE_FLUSH */
struct virtio_gpu_resource_flush {
	struct virtio_gpu_ctrl_hdr hdr;
	struct virtio_gpu_rect r;
	__le32 resource_id;
	__le32 padding;
};

/* VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D */
struct virtio_gpu_transfer_to_host_2d {
	struct virtio_gpu_ctrl_hdr hdr;
	struct virtio_gpu_rect r;
	__le64 offset;
	__le32 resource_id;
	__le32 padding;
};

struct virtio_gpu_mem_entry {
	__le64 addr;
	__le32 length;
	__le32 padding;
};

/* VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING (followed by nr_entries mem_entry) */
struct virtio_gpu_resource_attach_backing {
	struct virtio_gpu_ctrl_hdr hdr;
	__le32 resource_id;
	__le32 nr_entries;
};

/* VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING */
struct virtio_gpu_resource_detach_backing {
	struct virtio_gpu_ctrl_hdr hdr;
	__le32 resource_id;
	__le32 padding;
};

/* VIRTIO_GPU_RESP_OK_DISPLAY_INFO */
#define VIRTIO_GPU_MAX_SCANOUTS 16
struct virtio_gpu_resp_display_info {
	struct virtio_gpu_ctrl_hdr hdr;
	struct virtio_gpu_display_one {
		struct virtio_gpu_rect r;
		__le32 enabled;
		__le32 flags;
	} pmodes[VIRTIO_GPU_MAX_SCANOUTS];
};

#define VIRTIO_GPU_EVENT_DISPLAY (1 << 0)

/* virtio-gpu device config space (read via virtio_dev_get32 at devcfg off). */
struct virtio_gpu_config {
	__le32 events_read;
	__le32 events_clear;
	__le32 num_scanouts;
	__le32 num_capsets;
	__le32 blob_alignment;
};

/* config-space field offsets, for virtio_dev_get32(vio, off). */
#define VIRTIO_GPU_CFG_EVENTS_READ	0
#define VIRTIO_GPU_CFG_EVENTS_CLEAR	4
#define VIRTIO_GPU_CFG_NUM_SCANOUTS	8
#define VIRTIO_GPU_CFG_NUM_CAPSETS	12

/* simple pixel formats for fbcon/X (BGRA/BGRX are the common scanout ones). */
enum virtio_gpu_formats {
	VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM  = 1,
	VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM  = 2,
	VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM  = 3,
	VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM  = 4,
	VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM  = 67,
	VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM  = 68,
	VIRTIO_GPU_FORMAT_A8B8G8R8_UNORM  = 121,
	VIRTIO_GPU_FORMAT_R8G8B8X8_UNORM  = 134,
};

#endif /* _VIRTIO_GPU_HW_H_ */
