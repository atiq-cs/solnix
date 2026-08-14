/*
 * amdgpu_ucode.h - C3-amdgpu-d: the AMD microcode (firmware) blob header model
 * + the illumos firmware(9F) loader interface, for Navi 12 (gfx1011).
 *
 * amdgpu ships as signed microcode blobs (linux-firmware amdgpu/navi12_*.bin):
 * the PSP boot loaders (sos/asd/ta), the SMU power controller, the GFX engine
 * ucode (pfp/me/mec + rlc), the SDMA copy-engine ucode, and VCN (video). Each
 * .bin begins with a common_firmware_header, followed by a per-class header
 * (gfx/sdma/rlc/smc/psp/gpu_info), followed by the raw ucode words the driver
 * later DMAs / register-loads into the engine.
 *
 * Linux fetches these with request_firmware(); illumos has firmware(9F)
 * (sys/firmload.h: firmware_open/_get_size/_read/_close -- the NetBSD-derived
 * loader, all four symbols exported by genunix, verified zero-phantom). This
 * header + amdgpu_ucode.c implement:
 *   1. amdgpu_ucode_load: firmware(9F) fetch of a navi12_*.bin into a kmem
 *      buffer (the request_firmware analogue);
 *   2. amdgpu_ucode_validate: parse + validate the common_firmware_header
 *      (magic, header/ucode sizes, version) so a truncated/foreign blob is
 *      rejected before any byte is handed to the GPU.
 *
 * This COMPILES + the header parse/validate is fully verifiable off-hardware
 * (given a real .bin, or the synthetic header the self-check builds). Handing
 * the ucode words to the engines (PSP authenticate, the GFX/SDMA ucode DMA)
 * is the .hw_init register work -- code in gfx_hw.c/sdma_hw.c/psp.c, run only
 * on a powered GPU.
 *
 * Crib provenance (struct shapes + magic; the AMD ucode ABI is stable and the
 * blobs are redistributable -- linux-firmware, GPL/redistributable license):
 *   - common_firmware_header + the per-class *_firmware_header layouts +
 *     AMDGPU_UCODE_ID_* + the amdgpu_firmware_info slot: Linux
 *     drivers/gpu/drm/amd/amdgpu/amdgpu_ucode.h (the stable header ABI;
 *     struct field order is load-bearing -- the GPU parses these offsets)
 *   - the navi12 blob file names: linux-firmware amdgpu/ (navi12_*.bin)
 *   - firmware(9F): sys/firmload.h (illumos/NetBSD firmload)
 */

#ifndef _AMDGPU_UCODE_H_
#define _AMDGPU_UCODE_H_

#include <sys/types.h>
#include "amdgpu_priv.h"

struct amdgpu_softc;

/*
 * common_firmware_header - the header every amdgpu .bin begins with (crib:
 * Linux amdgpu_ucode.h struct common_firmware_header; all fields __le32 on
 * disk -- little-endian, which matches the amd64 host, so a straight struct
 * overlay is valid). size_bytes is the whole blob; header_size_bytes is this
 * header; ucode_size_bytes / ucode_array_offset_bytes bound the payload.
 */
struct common_firmware_header {
	uint32_t	size_bytes;		/* size of the whole blob */
	uint32_t	header_size_bytes;	/* size of just the header */
	uint16_t	header_version_major;
	uint16_t	header_version_minor;
	uint16_t	ip_version_major;
	uint16_t	ip_version_minor;
	uint32_t	ucode_version;
	uint32_t	ucode_size_bytes;	/* size of the ucode payload */
	uint32_t	ucode_array_offset_bytes; /* payload offset in blob */
	uint32_t	crc32;
};

/* the "AMD " endian marker some later headers carry (crib: amdgpu_ucode.h). */
#define	AMDGPU_UCODE_HDR_MAGIC		0x414d4400	/* 'A''M''D''\0' */

/*
 * gfx_firmware_header_v1_0 - PFP/ME/CE/MEC engine ucode (crib: amdgpu_ucode.h).
 * jt_offset/jt_size describe the jump-table portion the RLC autoloads.
 */
struct gfx_firmware_header_v1_0 {
	struct common_firmware_header	header;
	uint32_t	ucode_feature_version;
	uint32_t	jt_offset;	/* jump-table dword offset */
	uint32_t	jt_size;	/* jump-table size in dwords */
};

/*
 * rlc_firmware_header_v2_0 - the RLC (run-list controller) ucode + its save/
 * restore lists (crib: amdgpu_ucode.h; reduced to the v2_0 core fields that
 * gfx_v10 rlc load reads).
 */
struct rlc_firmware_header_v2_0 {
	struct common_firmware_header	header;
	uint32_t	ucode_feature_version;
	uint32_t	jt_offset;
	uint32_t	jt_size;
	uint32_t	save_and_restore_offset;
	uint32_t	clear_state_descriptor_offset;
	uint32_t	avail_scratch_ram_locations;
	uint32_t	reg_restore_list_size;
	uint32_t	reg_list_format_start;
	uint32_t	reg_list_format_separate_start;
	uint32_t	starting_offsets_start;
	uint32_t	reg_list_format_size_bytes;
	uint32_t	reg_list_format_array_offset_bytes;
	uint32_t	reg_list_size_bytes;
	uint32_t	reg_list_array_offset_bytes;
};

/*
 * sdma_firmware_header_v1_0 - SDMA copy-engine ucode (crib: amdgpu_ucode.h).
 */
struct sdma_firmware_header_v1_0 {
	struct common_firmware_header	header;
	uint32_t	ucode_feature_version;
	uint32_t	ucode_change_version;
	uint32_t	jt_offset;
	uint32_t	jt_size;
};

/*
 * smc_firmware_header_v1_0 - SMU (system-management / power) ucode (crib:
 * amdgpu_ucode.h). ucode_start_addr is where the SMU loads it.
 */
struct smc_firmware_header_v1_0 {
	struct common_firmware_header	header;
	uint32_t	ucode_start_addr;
};

/*
 * psp_firmware_header_v1_0 - the PSP (platform security processor) sos/asd/ta
 * blobs (crib: amdgpu_ucode.h; reduced to v1_0 sos offsets that psp_v11 reads).
 */
struct psp_firmware_header_v1_0 {
	struct common_firmware_header	header;
	uint32_t	ucode_feature_version;
	uint32_t	sos_offset_bytes;
	uint32_t	sos_size_bytes;
};

/*
 * gpu_info_firmware_header_v1_0 - the amdgpu_info blob (gfx config the driver
 * reads instead of probing on Navi; crib: amdgpu_ucode.h).
 */
struct gpu_info_firmware_header_v1_0 {
	struct common_firmware_header	header;
	uint16_t	version_major;
	uint16_t	version_minor;
};

/*
 * AMDGPU_UCODE_ID_* - the microcode-id enum the PSP/SMU firmware-load loop
 * keys off (crib: amdgpu_ucode.h enum AMDGPU_UCODE_ID). Only the ids the Navi
 * 12 reduced bring-up loads are materialized; the ordering is kept so the
 * load loop matches the crib.
 */
enum amdgpu_ucode_id {
	AMDGPU_UCODE_ID_SDMA0 = 0,
	AMDGPU_UCODE_ID_SDMA1,
	AMDGPU_UCODE_ID_CP_CE,
	AMDGPU_UCODE_ID_CP_PFP,
	AMDGPU_UCODE_ID_CP_ME,
	AMDGPU_UCODE_ID_CP_MEC1,
	AMDGPU_UCODE_ID_CP_MEC1_JT,
	AMDGPU_UCODE_ID_CP_MEC2,
	AMDGPU_UCODE_ID_CP_MEC2_JT,
	AMDGPU_UCODE_ID_RLC_G,
	AMDGPU_UCODE_ID_SMC,
	AMDGPU_UCODE_ID_VCN,
	AMDGPU_UCODE_ID_MAXIMUM,
};

/*
 * struct amdgpu_firmware_info - one loaded microcode blob (crib: amdgpu_ucode.h
 * struct amdgpu_firmware_info). Holds the raw buffer fetched via firmware(9F)
 * + the parsed header pointer + the payload span. The PSP/SMU load loop
 * (deferred, needs hardware) walks an array of these and DMAs each ucode to
 * the engine after PSP authenticates it.
 *
 *   fw_id      which microcode (AMDGPU_UCODE_ID_*)
 *   raw        the whole blob (kmem_alloc'd, size raw_size)
 *   hdr        (struct common_firmware_header *)raw -- the parsed header
 *   ucode      raw + ucode_array_offset_bytes -- the payload start
 *   ucode_size ucode_size_bytes from the header
 *   ucode_ver  ucode_version from the header
 */
struct amdgpu_firmware_info {
	enum amdgpu_ucode_id		fw_id;
	const char			*fw_name;	/* navi12_*.bin */
	uint8_t				*raw;
	size_t				raw_size;
	const struct common_firmware_header *hdr;
	const uint8_t			*ucode;
	uint32_t			ucode_size;
	uint32_t			ucode_ver;
	boolean_t			loaded;
};

/*
 * The Navi 12 microcode file set (crib: linux-firmware amdgpu/navi12_*.bin +
 * gfx_v10_0/sdma_v5_0/psp_v11_0/smu_v11_0 the fw_name each requests). These
 * are the redistributable blobs the solnix firmware package ships (see the
 * packaging note in amdgpu_ucode.c / the design doc).
 */
#define	AMDGPU_FW_DIR		"amdgpu"	/* firmware(9F) subdir */
#define	NAVI12_FW_PFP		"navi12_pfp.bin"
#define	NAVI12_FW_ME		"navi12_me.bin"
#define	NAVI12_FW_CE		"navi12_ce.bin"
#define	NAVI12_FW_MEC		"navi12_mec.bin"
#define	NAVI12_FW_MEC2		"navi12_mec2.bin"
#define	NAVI12_FW_RLC		"navi12_rlc.bin"
#define	NAVI12_FW_SDMA		"navi12_sdma.bin"
#define	NAVI12_FW_SMC		"navi12_smc.bin"
#define	NAVI12_FW_SOS		"navi12_sos.bin"
#define	NAVI12_FW_ASD		"navi12_asd.bin"
#define	NAVI12_FW_TA		"navi12_ta.bin"
#define	NAVI12_FW_VCN		"navi12_vcn.bin"
#define	NAVI12_FW_GPU_INFO	"navi12_gpu_info.bin"

/* upper bound on a single blob (a foreign/huge file is rejected). 64 MB is
 * well above the largest Navi blob (VCN ~1 MB, RLC/MEC tens of KB). */
#define	AMDGPU_UCODE_MAX_SIZE	(64u * 1024 * 1024)

/*
 * struct amdgpu_ucode - the aggregate microcode state hung off the softc's IP
 * aggregate (the reduced amdgpu firmware store). The array is indexed by
 * AMDGPU_UCODE_ID_*; each slot is populated by amdgpu_ucode_load + validated.
 * The count / total-payload accounting mirrors amdgpu_device.c fw_load.
 */
struct amdgpu_ucode {
	struct amdgpu_firmware_info	fw[AMDGPU_UCODE_ID_MAXIMUM];
	uint32_t			fw_count;	/* slots populated */
	boolean_t			ready;		/* all required loaded */
};

/* --- firmware(9F) load + header validate (amdgpu_ucode.c) --- */
int	amdgpu_ucode_load(struct amdgpu_softc *, enum amdgpu_ucode_id id,
	    const char *fw_name, struct amdgpu_firmware_info *out);
int	amdgpu_ucode_validate(const uint8_t *raw, size_t raw_size,
	    const struct common_firmware_header **hdr_out);
void	amdgpu_ucode_free(struct amdgpu_firmware_info *);

/* fetch the whole Navi 12 microcode set into sc->ucode (amdgpu_ucode.c). */
int	amdgpu_ucode_init(struct amdgpu_softc *);
void	amdgpu_ucode_fini(struct amdgpu_softc *);

#endif	/* _AMDGPU_UCODE_H_ */
