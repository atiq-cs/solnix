/*
 * amdgpu_ucode.c - C3-amdgpu-d: the amdgpu microcode loader over illumos
 * firmware(9F), + the common_firmware_header parse/validate.
 *
 * The request_firmware analogue. Linux does:
 *   request_firmware(&fw, "amdgpu/navi12_pfp.bin", dev)
 *   -> fw->data / fw->size
 * illumos firmware(9F) (sys/firmload.h) does the same in three calls:
 *   firmware_open("amdgpu", "navi12_pfp.bin", &h)  (searches the fw path)
 *   firmware_get_size(h)                            (blob size)
 *   firmware_read(h, 0, buf, size)                  (copy the blob out)
 *   firmware_close(h)
 * We wrap that as amdgpu_ucode_load, then parse+validate the header before the
 * blob is ever handed to the GPU (a truncated or foreign file is rejected here,
 * off-hardware).
 *
 * COMPILE + parse/validate are fully off-hardware. Handing the validated ucode
 * to the engines (PSP authenticate, GFX/SDMA ucode DMA) is the .hw_init work in
 * gfx_hw.c/sdma_hw.c/psp.c -- register pokes to live silicon.
 *
 * firmware-package plan (solnix): the redistributable linux-firmware amdgpu/
 * navi12_*.bin blobs ship in a solnix package that installs them under the
 * illumos firmware search path (the same path firmware_open searches, e.g.
 * /usr/lib/firmware or the boot module dir per the firmload config). No blob
 * is bundled in this driver source; the package is a separate deliverable so
 * the driver stays license-clean. See the design doc.
 *
 * Crib provenance (firmware ABI + names; NO Linux/NetBSD .c lifted):
 *   - firmware(9F): sys/firmload.h (firmware_open/_get_size/_read/_close)
 *   - common_firmware_header validate logic: Linux amdgpu_ucode.c
 *     amdgpu_ucode_validate (magic/size/version sanity), re-expressed
 *   - the navi12_*.bin names: linux-firmware amdgpu/ + gfx_v10_0/sdma_v5_0
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/sysmacros.h>
#include <sys/cmn_err.h>
#include <sys/firmload.h>

#include "amdgpu_priv.h"
#include "amdgpu_ucode.h"

/*
 * amdgpu_ucode_validate - parse + sanity-check a common_firmware_header. The
 * gate every blob passes before a byte reaches the GPU. Crib: Linux
 * amdgpu_ucode.c amdgpu_ucode_validate (the size/version consistency checks).
 *
 * Checks (all off-hardware, deterministic):
 *   - raw_size >= sizeof(common_firmware_header) (a header is present);
 *   - hdr->size_bytes == raw_size (the blob is whole, not truncated/padded);
 *   - hdr->header_size_bytes <= raw_size (the header fits);
 *   - ucode_array_offset_bytes + ucode_size_bytes <= raw_size (the payload
 *     span is inside the blob -- rejects an out-of-bounds ucode pointer);
 *   - header_version_major != 0 (a real versioned header).
 * On disk the fields are little-endian; the amd64 host is LE, so the struct
 * overlay reads them directly (no byteswap).
 */
int
amdgpu_ucode_validate(const uint8_t *raw, size_t raw_size,
    const struct common_firmware_header **hdr_out)
{
	const struct common_firmware_header *hdr;

	if (raw == NULL || raw_size < sizeof (struct common_firmware_header))
		return (DDI_FAILURE);

	hdr = (const struct common_firmware_header *)raw;

	/* the blob's self-declared size must match what we read */
	if (hdr->size_bytes != raw_size)
		return (DDI_FAILURE);

	/* the header must fit inside the blob */
	if (hdr->header_size_bytes < sizeof (struct common_firmware_header) ||
	    hdr->header_size_bytes > raw_size)
		return (DDI_FAILURE);

	/* the ucode payload span must lie entirely inside the blob */
	if (hdr->ucode_array_offset_bytes > raw_size ||
	    hdr->ucode_size_bytes > raw_size ||
	    (uint64_t)hdr->ucode_array_offset_bytes +
	    (uint64_t)hdr->ucode_size_bytes > (uint64_t)raw_size)
		return (DDI_FAILURE);

	/* a real versioned header (v0 is a malformed/foreign file) */
	if (hdr->header_version_major == 0)
		return (DDI_FAILURE);

	if (hdr_out != NULL)
		*hdr_out = hdr;
	return (DDI_SUCCESS);
}

/*
 * amdgpu_ucode_load - the request_firmware analogue: fetch amdgpu/<fw_name>
 * via firmware(9F) into a fresh kmem buffer, validate its header, and fill
 * out the amdgpu_firmware_info. On any failure the buffer is freed and out is
 * left zeroed (loaded == B_FALSE).
 *
 * firmware_open searches the illumos firmware path for AMDGPU_FW_DIR/<fw_name>
 * (the solnix firmware package installs the navi12_*.bin there). This is pure
 * file I/O + a header parse -- no GPU access -- so it runs + is verifiable
 * off-hardware (given the blobs installed, or the self-check's synthetic blob).
 */
int
amdgpu_ucode_load(struct amdgpu_softc *sc, enum amdgpu_ucode_id id,
    const char *fw_name, struct amdgpu_firmware_info *out)
{
	firmware_handle_t h;
	off_t sz;
	uint8_t *buf;
	const struct common_firmware_header *hdr;
	int r;

	bzero(out, sizeof (*out));
	out->fw_id = id;
	out->fw_name = fw_name;

	if (firmware_open(AMDGPU_FW_DIR, fw_name, &h) != 0) {
		cmn_err(CE_WARN, "?amdgpu: firmware %s/%s not found",
		    AMDGPU_FW_DIR, fw_name);
		return (DDI_FAILURE);
	}

	sz = firmware_get_size(h);
	if (sz <= (off_t)sizeof (struct common_firmware_header) ||
	    sz > (off_t)AMDGPU_UCODE_MAX_SIZE) {
		(void) firmware_close(h);
		cmn_err(CE_WARN, "?amdgpu: firmware %s bad size %lld",
		    fw_name, (long long)sz);
		return (DDI_FAILURE);
	}

	buf = kmem_alloc((size_t)sz, KM_SLEEP);
	r = firmware_read(h, 0, buf, (size_t)sz);
	(void) firmware_close(h);
	if (r != 0) {
		kmem_free(buf, (size_t)sz);
		cmn_err(CE_WARN, "?amdgpu: firmware %s read failed", fw_name);
		return (DDI_FAILURE);
	}

	if (amdgpu_ucode_validate(buf, (size_t)sz, &hdr) != DDI_SUCCESS) {
		kmem_free(buf, (size_t)sz);
		cmn_err(CE_WARN, "?amdgpu: firmware %s failed validation",
		    fw_name);
		return (DDI_FAILURE);
	}

	out->raw = buf;
	out->raw_size = (size_t)sz;
	out->hdr = hdr;
	out->ucode = buf + hdr->ucode_array_offset_bytes;
	out->ucode_size = hdr->ucode_size_bytes;
	out->ucode_ver = hdr->ucode_version;
	out->loaded = B_TRUE;

	cmn_err(CE_CONT, "?amdgpu: fw %s: %u bytes, ucode %u @ +%u, ver 0x%x\n",
	    fw_name, (uint32_t)sz, hdr->ucode_size_bytes,
	    hdr->ucode_array_offset_bytes, hdr->ucode_version);
	return (DDI_SUCCESS);
}

void
amdgpu_ucode_free(struct amdgpu_firmware_info *fw)
{
	if (fw->raw != NULL) {
		kmem_free(fw->raw, fw->raw_size);
		fw->raw = NULL;
	}
	fw->loaded = B_FALSE;
	fw->hdr = NULL;
	fw->ucode = NULL;
}

/*
 * The Navi 12 required-firmware table: (id, file). Crib: the fw_name each of
 * gfx_v10_0 / sdma_v5_0 / psp_v11_0 / smu_v11_0 requests for CHIP_NAVI12.
 * SDMA1 shares the SDMA blob on Navi (one sdma.bin, two instances). VCN is
 * present but non-fatal (video decode is deferred).
 */
struct navi12_fw_ent {
	enum amdgpu_ucode_id	id;
	const char		*name;
	boolean_t		required;
};

static const struct navi12_fw_ent navi12_fw_table[] = {
	{ AMDGPU_UCODE_ID_SOS,     NAVI12_FW_SOS,  B_TRUE  },
	{ AMDGPU_UCODE_ID_CP_PFP,  NAVI12_FW_PFP,  B_TRUE  },
	{ AMDGPU_UCODE_ID_CP_ME,   NAVI12_FW_ME,   B_TRUE  },
	{ AMDGPU_UCODE_ID_CP_CE,   NAVI12_FW_CE,   B_TRUE  },
	{ AMDGPU_UCODE_ID_CP_MEC1, NAVI12_FW_MEC,  B_TRUE  },
	{ AMDGPU_UCODE_ID_RLC_G,   NAVI12_FW_RLC,  B_TRUE  },
	{ AMDGPU_UCODE_ID_SDMA0,   NAVI12_FW_SDMA, B_TRUE  },
	{ AMDGPU_UCODE_ID_SMC,     NAVI12_FW_SMC,  B_TRUE  },
	{ AMDGPU_UCODE_ID_VCN,     NAVI12_FW_VCN,  B_FALSE },
};

/*
 * amdgpu_ucode_init - fetch the whole Navi 12 microcode set into sc->ucode.
 * A missing REQUIRED blob fails the whole init (the GPU can't come up without
 * it); a missing optional blob (VCN) warns and continues. This is the
 * request_firmware phase of amdgpu_device_ip_init (the .sw_init that loads fw),
 * before any PSP authenticate. Note: without the solnix firmware package
 * installed this returns failure -- expected off a firmware-equipped host, and
 * the attach path treats it as non-fatal (BARs/TTM/rings stay valid).
 */
int
amdgpu_ucode_init(struct amdgpu_softc *sc)
{
	struct amdgpu_ucode *uc;
	uint32_t i;
	int r;

	if (sc->ucode != NULL)
		return (DDI_SUCCESS);		/* idempotent */

	uc = kmem_zalloc(sizeof (*uc), KM_SLEEP);
	sc->ucode = uc;

	for (i = 0; i < (sizeof (navi12_fw_table) / sizeof (navi12_fw_table[0]));
	    i++) {
		const struct navi12_fw_ent *e = &navi12_fw_table[i];

		r = amdgpu_ucode_load(sc, e->id, e->name, &uc->fw[e->id]);
		if (r != DDI_SUCCESS) {
			if (e->required) {
				cmn_err(CE_WARN, "?amdgpu: required firmware "
				    "%s missing; power-up cannot proceed",
				    e->name);
				amdgpu_ucode_fini(sc);
				return (DDI_FAILURE);
			}
			continue;	/* optional: skip */
		}
		uc->fw_count++;
	}

	uc->ready = B_TRUE;
	cmn_err(CE_CONT, "?amdgpu: microcode loaded: %u blobs\n", uc->fw_count);
	return (DDI_SUCCESS);
}

void
amdgpu_ucode_fini(struct amdgpu_softc *sc)
{
	struct amdgpu_ucode *uc = sc->ucode;
	uint32_t i;

	if (uc == NULL)
		return;
	for (i = 0; i < AMDGPU_UCODE_ID_MAXIMUM; i++)
		amdgpu_ucode_free(&uc->fw[i]);
	kmem_free(uc, sizeof (*uc));
	sc->ucode = NULL;
}
