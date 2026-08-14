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
 * C1d appends the 3D command family (CTX_CREATE/CTX_DESTROY,
 * RESOURCE_CREATE_3D, TRANSFER_{TO,FROM}_HOST_3D, SUBMIT_3D, GET_CAPSET_INFO/
 * GET_CAPSET) that the virgl/venus command streams ride on -- same provenance
 * (Linux virtio_gpu.h, BSD-licensed), same little-endian packed ABI.
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

	/* 3d commands (C1d; enum values match Linux virtio_gpu.h verbatim) */
	VIRTIO_GPU_CMD_CTX_CREATE = 0x0200,
	VIRTIO_GPU_CMD_CTX_DESTROY,
	VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE,
	VIRTIO_GPU_CMD_CTX_DETACH_RESOURCE,
	VIRTIO_GPU_CMD_RESOURCE_CREATE_3D,
	VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D,
	VIRTIO_GPU_CMD_TRANSFER_FROM_HOST_3D,
	VIRTIO_GPU_CMD_SUBMIT_3D,
	VIRTIO_GPU_CMD_RESOURCE_MAP_BLOB,
	VIRTIO_GPU_CMD_RESOURCE_UNMAP_BLOB,

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

/*
 * ---- 3D command structs (C1d) ----
 *
 * Provenance: layouts reproduced VERBATIM from Linux/QEMU
 * include/uapi/linux/virtio_gpu.h (the same BSD-licensed guest-driver ABI as
 * the 2D structs above). These are the wire commands the virgl/venus command
 * streams ride on: CTX_CREATE/CTX_DESTROY (a per-drm-file 3D context),
 * RESOURCE_CREATE_3D (a 3D resource: target/format/bind/dims/array/mip),
 * TRANSFER_{TO,FROM}_HOST_3D (box-form data movement), SUBMIT_3D (the
 * command-buffer submit EXECBUFFER wraps), and GET_CAPSET_INFO/GET_CAPSET
 * (capset feature query). All fields little-endian, packed identically.
 */

/* data passed in the control vq, 3d related */
struct virtio_gpu_box {
	__le32 x, y, z;
	__le32 w, h, d;
};

/* VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D, VIRTIO_GPU_CMD_TRANSFER_FROM_HOST_3D */
struct virtio_gpu_transfer_host_3d {
	struct virtio_gpu_ctrl_hdr hdr;
	struct virtio_gpu_box box;
	__le64 offset;
	__le32 resource_id;
	__le32 level;
	__le32 stride;
	__le32 layer_stride;
};

/* VIRTIO_GPU_CMD_RESOURCE_CREATE_3D */
#define VIRTIO_GPU_RESOURCE_FLAG_Y_0_TOP (1 << 0)
struct virtio_gpu_resource_create_3d {
	struct virtio_gpu_ctrl_hdr hdr;
	__le32 resource_id;
	__le32 target;
	__le32 format;
	__le32 bind;
	__le32 width;
	__le32 height;
	__le32 depth;
	__le32 array_size;
	__le32 last_level;
	__le32 nr_samples;
	__le32 flags;
	__le32 padding;
};

/* VIRTIO_GPU_CMD_CTX_CREATE */
#define VIRTIO_GPU_CONTEXT_INIT_CAPSET_ID_MASK 0x000000ff
struct virtio_gpu_ctx_create {
	struct virtio_gpu_ctrl_hdr hdr;
	__le32 nlen;
	__le32 context_init;
	char   debug_name[64];
};

/* VIRTIO_GPU_CMD_CTX_DESTROY */
struct virtio_gpu_ctx_destroy {
	struct virtio_gpu_ctrl_hdr hdr;
};

/* VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE, VIRTIO_GPU_CMD_CTX_DETACH_RESOURCE */
struct virtio_gpu_ctx_resource {
	struct virtio_gpu_ctrl_hdr hdr;
	__le32 resource_id;
	__le32 padding;
};

/* VIRTIO_GPU_CMD_SUBMIT_3D (hdr + size, followed by `size` command bytes) */
struct virtio_gpu_cmd_submit {
	struct virtio_gpu_ctrl_hdr hdr;
	__le32 size;
	__le32 padding;
};

/* capset ids (Mesa selects virgl vs venus by these). */
#define VIRTIO_GPU_CAPSET_VIRGL			1
#define VIRTIO_GPU_CAPSET_VIRGL2		2
#define VIRTIO_GPU_CAPSET_GFXSTREAM_VULKAN	3
#define VIRTIO_GPU_CAPSET_VENUS			4
#define VIRTIO_GPU_CAPSET_CROSS_DOMAIN		5
#define VIRTIO_GPU_CAPSET_DRM			6

/* VIRTIO_GPU_CMD_GET_CAPSET_INFO */
struct virtio_gpu_get_capset_info {
	struct virtio_gpu_ctrl_hdr hdr;
	__le32 capset_index;
	__le32 padding;
};

/* VIRTIO_GPU_RESP_OK_CAPSET_INFO */
struct virtio_gpu_resp_capset_info {
	struct virtio_gpu_ctrl_hdr hdr;
	__le32 capset_id;
	__le32 capset_max_version;
	__le32 capset_max_size;
	__le32 padding;
};

/* VIRTIO_GPU_CMD_GET_CAPSET */
struct virtio_gpu_get_capset {
	struct virtio_gpu_ctrl_hdr hdr;
	__le32 capset_id;
	__le32 capset_version;
};

/* VIRTIO_GPU_RESP_OK_CAPSET (hdr followed by the capset blob) */
struct virtio_gpu_resp_capset {
	struct virtio_gpu_ctrl_hdr hdr;
	__u8 capset_data[1];	/* flexible; blob follows the header */
};

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
