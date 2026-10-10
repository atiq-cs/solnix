# X1 graphics route: a modern GPU stack on solnix without GPL code in the base

This is the route from today's firmware console on the X1 ("dixi") to Vulkan, Wayland and COSMIC
on real GPUs. It covers the Intel iGPU, AMD GPUs, hybrid i915 + discrete setups, and GPU LLM
inference. It covers the X1's iGPU first, then the AMD and hybrid cases.

Every statement is tagged **REAL** (measured, with the command or file it came from) or
**PLANNED** (not done; the cost given is an estimate). Raw evidence for the REAL items:
`/tmp/streamE-progress.txt` (first survey) and `/tmp/streamE2-progress.txt` (this run).

## 1. The hardware (REAL, `prtconf -v` + `mdb -k` on dixi)

| part | id | what binds today | notes |
|---|---|---|---|
| CPU | i7-8850H (Coffee Lake-H, 6C/12T), CM246 PCH | | 2 x 32 GB DDR4-2667, dual channel (`smbios -t SMB_TYPE_MEMDEVICE`) |
| iGPU | `8086:3e9b` rev 0, UHD 630, CFL-H GT2 (Gen9.5) | `vgatext` instance 0, `/dev/fb` | BAR0 GTTMMADR `0x60_4a000000` 16 MB; BAR2 GMADR `0x40_00000000` 512 MB; BAR4 I/O `0x3000` |
| dGPU | `10de:1c8c` GP107M (GTX 1050 Ti Mobile, Pascal) | **also** `vgatext`, instance 1, `/dev/fb1` | BAR0 `0xa3000000` 16 MB, BAR1 `0x60000000` 256 MB, BAR3 32 MB. PCIe gen3 x16 |

There is no AMD GPU in the X1. AMD (amdgpu) is for the maintainer's other machines and the EC2
V520 (g4ad), where `src/drm-port/amdgpu` already binds (STATUS.md, C3-amdgpu-d).

The console is `gfxp_bitmap` drawing on the UEFI GOP linear framebuffer. `fb_info` (kernel):
`fb_type=3` (RGB), `paddr=0x4000000000` (the iGPU GMADR aperture base), 3840x2160 XRGB8888,
pitch 15360, `fb_size=0x1fa4000`.

## 2. The licence rule

### 2.1 The rule

1. **No GPL-only or LGPL-only file is compiled into the solnix kernel or the solnix base
   libraries.** A file with no notice inside a Linux tree is treated as GPL-2.0-only (the kernel
   default, `Documentation/process/license-rules.rst`) until someone finds the same file under a
   permissive notice.
2. **Dual-licensed files** (`GPL-2.0 OR MIT`, `GPL-2.0-or-later OR BSD-2-Clause`, ...) are used
   under the permissive option, and their header is kept verbatim. Grepping for "GNU General
   Public" will hit these files. That is a dual grant, not contamination (same note as
   `src/wifi-port/iwx/PROVENANCE.md`).
3. **Separately packaged programs** are packaged under their own licences, the way NixOS packages
   any GPL program. This clause matters because **COSMIC itself is GPL-3.0** (REAL, GitHub API
   `license` field, 2026-10-08): cosmic-comp, cosmic-session, cosmic-panel, cosmic-term,
   cosmic-files, cosmic-settings, cosmic-greeter and xdg-desktop-portal-cosmic. libcosmic is
   MPL-2.0. A rule that banned GPL programs outright would rule out the desktop the goal names.
   **The maintainer needs to confirm this reading.** The rule above keeps GPL code out of what
   solnix *is* (kernel, drivers, base libraries) and treats COSMIC as an application.
4. **The 36 solnix files without a header** (`src/drm-port/src` 16, `src/drm-port/amdgpu` 20,
   REAL from `license-audit.sh`) get a header once the project licence is chosen. The repo root
   has no `LICENSE` file, and the maintainer has not stated a licence. Nothing here assumes one.

Tool: `src/drm-port/license-audit.sh DIR...` (`-l` lists the GPL and NONE files). This run
fixed a classifier bug. The ISC grant reads "Permission to use, copy, modify, and distribute",
and the regex only accepted "and/or", so OpenBSD's ISC files were reported as NONE. The
fixture `/tmp/streamE2-lictest` has three files. `isc_and.c` moved from NONE to PERM. `none.c`
stayed NONE, which is the negative control, and `gpl.c` stayed GPL.

### 2.2 Per-source licence table (REAL, `license-audit.sh`; .c + .h, classified from the first 60 lines)

| tree | files | permissive | public domain | dual | GPL/LGPL-only | no notice |
|---|---:|---:|---:|---:|---:|---:|
| Linux `drivers/gpu/drm/i915` (master 6c377d1) | 903 | 885 | 0 | 0 | **18** | 0 |
| Linux `drm/amd/amdgpu` | 634 | 621 | 0 | 10 | **3** | 0 |
| Linux `drm/amd/display` | 1309 | 1280 | 0 | 26 | 0 | 3 |
| Linux `drm/nouveau` | 1212 | 1157 | 0 | 1 | 0 | 54 |
| Linux `drm/ttm` | 26 | 4 | 0 | 12 | 10 (all `tests/`) | 0 |
| Linux `drm/scheduler` | 10 | 6 | 0 | 0 | 4 (all `tests/`) | 0 |
| Linux `drm/display` helpers | 19 | 14 | 0 | 0 | **5** | 0 |
| Linux drm core (102-file sample, `/tmp/streamE-core`) | 102 | 65 | 0 | 18 | **18** | 1 |
| Linux `drivers/dma-buf` | 20 | 5 | 0 | 0 | **15** | 0 |
| Linux `include/drm` | 161 | 113 | 0 | 12 | **34** | 2 |
| Linux `include/uapi/drm` | 34 | 22 | 0 | 4 | 8 (other drivers' UAPI) | 0 |
| **OpenBSD `sys/dev/pci/drm`** (37a498de, 2026-10-08) | 4204 | 3724 | 256 | 118 | **10 (all `ttm/tests/`, not built)** | 96 |
| OpenBSD `drm/i915` | 851 | 846 | 4 | 0 | 0 | 1 (`i915_devlist.h`, a generated table) |
| OpenBSD `drm/amd` | 2512 | 2437 | 2 | 53 | 0 | 20 |
| OpenBSD `drm/include/linux` (the KPI shim) | 278 | 37 | 194 | 0 | 0 | 47 (all 0-byte stubs) |
| OpenBSD `drm/include/drm` | 124 | 96 | 14 | 12 | 0 | 2 |
| FreeBSD drm-kmod `drivers/gpu/drm/i915` (9e7b4fd) | 742 | 733 | 2 | 0 | 5 | 2 |
| FreeBSD drm-kmod `drivers/dma-buf` | 8 | 6 | 0 | 0 | **2** (`sync_file.c`, `dma-fence-unwrap.c`) | 0 |
| FreeBSD drm-kmod `linuxkpi/gplv2` | 4 | 0 | 0 | 0 | **4** | 0 |
| FreeBSD drm-kmod `linuxkpi/bsd` | 14 | 12 | 0 | 0 | 0 | 2 |
| FreeBSD base `sys/compat/linuxkpi` | 464 | 321 | 32 | 4 | 0 | 107 |
| NetBSD `drm2/linux` | 31 | 31 | 0 | 0 | 0 | 0 |
| NetBSD `drm2/include` | 258 | 201 | 3 | 0 | 0 | 54 |
| NetBSD `drm2/i915drm` | 17 | 16 | 0 | 0 | 0 | 1 |
| NetBSD `bsd/common` | 36 | 36 | 0 | 0 | 0 | 0 |
| solnix `src/drm-port/powervr-drm/linux-ref` | 76 | 0 | 0 | 76 | 0 | 0 |
| solnix `src/drm-port/src` | 16 | 0 | 0 | 0 | 0 | **16** |
| solnix `src/drm-port/amdgpu` | 20 | 0 | 0 | 0 | 0 | **20** |

The Linux rows other than OpenBSD's are from `/tmp/streamE-lic-all.txt`. No OpenBSD-style ISC
wording appears in them, so they are unchanged by the fix. The OpenBSD rows were re-run
after the fix (`/tmp/streamE2-lic-rerun.txt`).

What the GPL-only files are (REAL, `/tmp/streamE-lic-gpl-*.txt`):

* Linux i915: tracepoints (`i915_trace.h`, `intel_display_trace.*`, `intel_uncore_trace.*`),
  selftests, and `display/intel_acpi.c`. None of these is needed for modeset on CFL.
* Linux amdgpu: `amdgpu_atpx_handler.c` (the PX hybrid ACPI method) and `amdgpu_vkms.*`.
* Linux drm core: `drm_managed.c` (i915 calls its `drmm_*` 10 times), `drm_gem_framebuffer_helper.c`,
  `drm_gem_shmem_helper.c`, `drm_gem_dma_helper.c`, `drm_gem_atomic_helper.c`, `drm_simple_kms_helper.c`,
  `drm_lease.c`, `drm_writeback.c`, `drm_sysfs.c` and others.
* Linux `drivers/dma-buf`: `dma-buf.c`, `dma-fence.c`, `dma-fence-array.c`, `dma-fence-chain.c`,
  `dma-fence-unwrap.c`, `sync_file.c`, `sw_sync.c`. This is the cross-driver sharing core.
* Linux `drivers/gpu/drm/sysfb/simpledrm.c` and `efidrm.c` are GPL-2.0-only (REAL, fetched from
  torvalds/linux master). A firmware-framebuffer KMS driver has to be written fresh.
* nouveau: no GPL-only files. The 54 NONE files are headers inside the Linux tree, so they count as
  GPL-2.0-only under rule 1 until each is traced to an MIT original. That provenance check is
  PLANNED and only needed if nouveau is pursued (R3).

**OpenBSD has replaced every GPL-only helper that i915 and amdgpu reach.** In OpenBSD `drm/`,
`drm_managed.c`, `drm_gem_framebuffer_helper.c`, `drm_gem_atomic_helper.c`,
`drm_gem_ttm_helper.c`, `drm_fb_dma_helper.c`, `display/drm_hdcp_helper.c`, `i915_trace.h` and
`amdgpu_vkms.c` all start `/* Public domain. */`. dma-fence, dma-buf and sync_file are
reimplemented in `drm_linux.c` (4164 lines, ISC, Jonathan Gray). `dma-resv.c` is MIT. OpenBSD's
tree has no `intel_acpi.c` or `amdgpu_atpx_handler.c` at all. The 10 GPL files left are TTM
kunit tests that `files.drm` does not build.

### 2.3 Source choice per component

| component | primary source | why | second reference |
|---|---|---|---|
| i915 driver (Gen9.5 CFL) | **OpenBSD `drm/i915`** | 846/851 permissive, no GPL, Linux-master level (`pciids.h:521` lists `0x3E9B`), OpenBSD-specific glue is only 5 `__OpenBSD__` files, and it runs on a non-Linux kernel today | FreeBSD drm-kmod i915 (same Linux base, its 5 GPL files are avoided) |
| drm core + KMS helpers | **OpenBSD `drm/*.c`** | the GPL-only Linux helpers are already public-domain rewrites there | NetBSD drm2 (Linux 5.6 era, older) |
| dma-buf / dma-fence / sync_file | **solnix C1c `src/drm_dma.c` + `src/drm_prime.c`** (already written, own design), with OpenBSD `drm_linux.c` (ISC) as the semantics reference | Linux's are GPL-2.0-only. FreeBSD's `sync_file.c` is GPL-2.0-only too | |
| linux-KPI shim | **solnix `src/drm-port/src/linux-compat`** grown toward OpenBSD's `include/linux` header set (PD/ISC), each primitive mapped to illumos DDI | OpenBSD's headers are PD/ISC but sit on OpenBSD kernel headers (section 4.3). The *set* of headers is the checklist, as NetBSD's was for C1 | FreeBSD base `sys/compat/linuxkpi` (BSD-2), never drm-kmod `linuxkpi/gplv2` |
| amdgpu | **solnix `src/drm-port/amdgpu`** (C3, binds on V520) cribbing OpenBSD `drm/amd` (no GPL; `KMS_DRIVER_MINOR 64` = Linux master) | | Linux amdgpu minus `atpx_handler`/`vkms` |
| firmware-framebuffer KMS (R1a below) | **new solnix code** over the existing C1 framework | Linux simpledrm/efidrm are GPL-2.0-only | the gfxp_bitmap source for fb_info |
| input (evdev) | **FreeBSD `sys/dev/evdev`** (BSD-2) | libinput speaks evdev. FreeBSD already exposes evdev from a BSD kernel | |
| udev / seat | **libudev-devd** (BSD-2) + **seatd/libseat** (MIT) | libudev-devd is what FreeBSD desktops use | |
| compositor libraries | Smithay, drm-rs, input.rs, gbm.rs (MIT), libinput (MIT) | | |
| Mesa (iris, anv, radv, llvmpipe) | Mesa (MIT) | `src/drm-port/anv`, `radv`, `nvk` are already compile-phase ports | |

## 3. Rung 0 (REAL, measured on dixi this run): pixels from userland, no kernel change

`src/drm-port/test/fbmmap.c`, built on dixi with the solnix-dev toolchain
(`PATH=/nix/store/jlzzgm9v2i2495zzd1z27b9b6c54klaf-solnix-dev/bin`, gcc 14.3.0. Headers come
from the gate proto, because dixi has no `/usr/include`):

```
cc -m64 -O2 -Wall -o fbmmap fbmmap.c        # /var/tmp/streamE2/fbmmap on dixi
./fbmmap        # map /dev/fb, draw 256x256 box bottom-right, verify, restore
./fbmmap -n     # negative control: verify against an unwritten pattern -> must FAIL
./fbmmap -r     # read-only observer in a second process
./fbmmap -g     # same, with KDSETMODE KD_GRAPHICS around the draw
./fbmmap -b     # bandwidth
```

Results (REAL):

* `/dev/fb` is `crw------- gburd staff 351,0`. The console user owns it, so no root is needed.
* `ident=illumos_fb kdmode=0 fbgattr: type=7 3840x2160 depth=32 size=0x1fa4000 pitch=15360 r8@16 g8@8 b8@0`
* `mmap ok: va=fffffc7fec600000 len=0x1fa4000`. **The gfxp_bitmap.c comment "Currently not
  working, mmap will receive -1 as pointer" is stale.** `bitmap_devmap` maps
  `fb_info.paddr` with `gfxp_map_devmem`, and it works in KD_TEXT. KD_GRAPHICS is not required.
* Pattern check: 0/65536 pixels mismatched, PASS, then restore PASS. **10/10 runs PASS. The
  negative control `-n` FAILS 8/8.**
* Second check by an independent observer. A second process with a `PROT_READ` mapping:
  * before the writer starts: FAIL 65536/65536
  * while the writer holds the pattern: PASS 0/65536
  * with the wrong salt: FAIL
  * after the writer restores: FAIL

  So both processes see the same device memory, not private pages.
* Physical address check (`mdb -k`, `::context` on the fbmmap proc, then `::vtop`): VA
  `fffffc7fee1e7800` maps to PA **`0x4001be7800`**, which is GMADR `0x40_00000000` plus the box
  offset `0x1be7800`. VA `+0x1fa3000` maps to PA `0x4001fa3000`. Negative control: the text page
  `0x400000` maps to PA `0x1006217000`, which is RAM.
* `-g`: `KDSETMODE KD_GRAPHICS ok`, then draw PASS, and the mode returns to KD_TEXT afterwards.
* Bandwidth (`-b`, 3 runs): write 18.7 / 20.9 / 20.4 GB/s (memcpy into the write-combining
  mapping; the timed loop has no `sfence`, and the verify afterwards PASSes). Read **67 / 67 / 66
  MB/s**. The mapping is write-combining (`DDI_MERGING_OK_ACC` in gfxp_bitmap.c), so reads are
  uncached. A compositor on this path must render into a RAM buffer and copy only damaged
  regions to the framebuffer. It must never read the framebuffer back: one 4K frame
  (33 MB) takes about 0.5 s to read.

What rung 0 gives the desktop work: a 3840x2160 XRGB8888 surface any process can draw on.
smithay's pixman renderer can composite into a RAM buffer and copy damage to the mapping, with
no kernel work. Fixed mode (no modeset), no vblank, no page flip, so there will be tearing.
Input must come separately (section 5, R5).

## 4. The phased route

Costs are engineer-weeks for one person who knows this code (PLANNED estimates). Each rung's
exit test is listed with it.

### R1a. A firmware-framebuffer DRM driver ("solnix-gopdrm"), so libdrm sees `/dev/dri/card0` (PLANNED, ~2 weeks)

Linux's answer is simpledrm/efidrm (GPL-2.0-only, so written fresh). The driver binds one CRTC,
one plane and one connector at the GOP mode. `DRM_IOCTL_MODE_CREATE_DUMB`/`MAP_DUMB` already
exist in C1 (`src/drm_gem.c`). The new work:

* `MODE_GETRESOURCES`, `GETCONNECTOR`, `GETENCODER`, `GETCRTC`, `ADDFB2`, `SETCRTC`,
  `PAGE_FLIP` (a copy to the GOP fb), `DIRTYFB`, `GET_CAP`, `SET_CLIENT_CAP`.
* The minimal atomic subset smithay's DRM backend uses: `ATOMIC`, `GETPROPERTY`, `OBJ_GETPROPERTIES`.
* A vblank event emulated off a cyclic timer.

C1's ioctl table has `VERSION`, `GEM_CLOSE`, the 3 dumb-buffer ioctls, 2 PRIME ioctls and a
private `SET_SCANOUT` (REAL, `src/uapi/drm/drm.h`). It needs the mode-object ioctls listed above.

**Hazard:** it must take the framebuffer over from `vgatext`/`gfxp_bitmap`, or co-exist with it
(`KD_GRAPHICS` while a DRM master holds it). Loading it needs the dump device the maintainer has
not yet approved.

Exit test: `modetest -M solnix-gopdrm` lists the connector, and smithay's DRM backend runs anvil
with pixman (llvmpipe through GBM comes later).

### R1. i915 KMS on CFL (PLANNED, ~10-14 weeks to a stable modeset)

The OpenBSD `drm/i915` modeset path (display/, ~190 kLOC; the full i915 tree is 409,641 lines,
REAL `wc -l`) needs:

* the solnix linux-KPI grown to the OpenBSD header set (4.3)
* `i915_driver.c` re-glued from OpenBSD autoconf/wsdisplay to illumos `dev_ops`
* GMBUS/AUX on illumos interrupts
* the DMC firmware `i915/kbl_dmc_ver1_04.bin`. CFL uses the KBL DMC (REAL, OpenBSD
  `intel_dmc.c:228-232`). It is only needed for display C-states, not for the first modeset.

GuC is off by default before Gen12 (REAL, `gt/uc/intel_uc.c:33-36`), so Gen9 needs no GuC
firmware.

Exit test: `modetest` sets 3840x2160 on eDP and an external DP mode, and a dumb buffer flips at
vblank.

### R2. i915 GEM + execlists + Mesa iris (GL 4.6) + anv (Vulkan) (PLANNED, ~8-12 weeks after R1)

* gem/ (31,645 lines) and gt/ (93,783 lines, the execlists submission path) on illumos VM:
  `ddi_umem`/`devmap` for userptr, GGTT/PPGTT page tables, shrinker, and the C1c fences as
  `i915_request`.
* Mesa iris (GL) and anv (Vulkan) on top. anv is already a compile-phase port in
  `src/drm-port/anv` and needs the i915 ioctl surface.
* Mesa `features.txt` lists anv as VK 1.4 DONE (REAL, fetched).

Exit test: `vulkaninfo` lists "Intel(R) UHD Graphics 630 (CFL GT2)", vkcube runs, and
`glxgears`/`eglgears` runs on iris.

### R3. Hybrid (PLANNED)

* **On the X1** the discrete GPU is NVIDIA Pascal GP107.
  * nouveau has **no clock subdev for GP107**. `nv137_chipset` in
    `nvkm/engine/device/base.c` has no `.clk` entry, while GP10B (Tegra) does (REAL, source).
    The board stays at boot clocks.
  * The PMU has no firmware either: `gp102_pmu_fwif[]` in `nvkm/subdev/pmu/gp102.c` has the single
    entry `gm200_pmu_nofw` (REAL, source). Reclocking needs NVIDIA-signed PMU firmware that is not
    in linux-firmware. That last point is NOT measured here; it is the explanation nouveau's
    maintainers have given in public.
  * So GP107 under nouveau gets display outputs and PRIME render offload at low clocks.
    **It is not an LLM accelerator.**
  * NVK lists Kepler and later as supported (REAL, Mesa `docs/drivers/nvk.rst`), but it inherits
    the same clocks.
  * nouveau licence: 1157/1212 permissive, 0 GPL-only, 54 NONE headers (2.2).
  * Cost if pursued: a nouveau port on top of the R1 linux-KPI, ~12+ weeks. That buys outputs
    wired to the dGPU and low-clock offload. **Recommendation: keep the dGPU unbound
    (vgatext only, as today) on the X1 and spend the effort on i915.**
* **PRIME between i915 and amdgpu** on AMD-equipped machines (render offload, `DRI_PRIME=1`):
  * The C1c PRIME fd (`src/drm_prime.c`, falloc plus spec-vnode) is the shared mechanism.
  * The importer side needs scatter-gather import into the other driver's GTT.
  * "One or the other only" is the same switch NixOS's `hardware.nvidia.prime` offers (sync /
    offload / reverseSync, REAL, `nixos/modules/hardware/video/nvidia.nix`), applied to
    i915 + amdgpu: bind only one driver, or bind both and pick the render GPU per client.
  * Linux's PX/ATPX power-switch method (`amdgpu_atpx_handler.c`) is GPL-only. OpenBSD omits it,
    and solnix would write the ACPI `_DSM`/`ATPX` calls fresh.
  * Cost: ~4-6 weeks after R1/R2 and R4.

### R4. amdgpu runtime on AMD machines (PLANNED; current state REAL in `src/drm-port/STATUS.md`)

On g4ad (V520, Navi 12) solnix's amdgpu binds and loads firmware. It stops at the PSP mailbox
because the MP0 SMN registers cannot be reached through a direct BAR
(`docs/gpu2-v520-psp-mp0-wall*.md`). Next: the SMN indirect path, then the ring tests. On a local
AMD board the same driver avoids the EC2 virtualisation question. RADV is a compile-phase port
in `src/drm-port/radv`.

### R5. COSMIC on DRM (PLANNED)

`docs/cosmic-comp-illumos-finding.md` lists what cosmic-comp needs from smithay:
`backend_drm`, `backend_gbm`, `backend_egl`, `backend_libinput`, `backend_session_libseat` and
`backend_udev`. The gaps and their analogs:

* **DRM + GBM:** R1a or R1 for the node. GBM comes from Mesa (iris after R2; llvmpipe/kms_swrast
  over R1a before that).
* **Input:** dixi has `i8042` → `kb8042` + `mouse8042`, and 2 `hid` instances (REAL,
  `prtconf -D`). `/dev/kbd` and `/dev/mouse` are owned by the console user. Plan: port FreeBSD's
  `sys/dev/evdev` (BSD-2) as an illumos driver that publishes `/dev/input/event*`, fed by the
  kb8042/hid streams. libinput (MIT) then works almost unchanged. Cost ~3-4 weeks.
* **udev:** libudev-devd (BSD-2), backed by devfsadm events. ~1-2 weeks.
* **Seat:** seatd/libseat (MIT), with an illumos backend that does VT switching through
  `KDSETMODE` and does DRM master set/drop. ~1-2 weeks.

The cheaper first milestone: anvil or cosmic-comp on rung 0 + R1a with pixman, before any GPU
acceleration.

### R6. GPU LLM inference (PLANNED; expectations from published numbers)

llama.cpp `GGML_VULKAN` on anv (R2). The ggml-vulkan port is in `src/drm-port/ggml-vulkan`. What
to expect on UHD 630 (Gen9.5 GT2, 24 EUs, shared DDR4-2667 dual channel, about 42.7 GB/s peak):

* llama.cpp issue 16230 (2025-09, Windows, Intel Vulkan driver) lists UHD 630 as Vulkan
  device 1 and a Quadro P620 as device 0. For Qwen2.5-1.5B Q4_K_M via `llama-server` it reports
  84.29 tok/s prefill and 34.19 tok/s decode. **It is unclear which of the two devices ran.**
  Treat it as an upper bound, not a UHD 630 result.
* llama.cpp issue 17056 (Linux, Mesa ANV, "Intel(R) UHD Graphics 630 (CFL GT2)") confirms
  ggml-vulkan runs on this exact iGPU under Mesa. It also documents correctness bugs on this
  GPU class (integer-dot matmul, fixed by #17108/#17106). Issue 29054 (2026-09, Mesa 26.2.2
  ANV, UHD 630) reports a GPU hang with a q8_0 KV cache. Gen9.5 is a tested but fragile target.
* The closest clean number: Iris Xe TGL GT2 (96 EUs, newer), 7B Q4_0 tg128 = 7.3-8.3 tok/s
  (llama.cpp discussion 10879, Mesa).
* In llama.cpp issue 24132, an Iris Xe on Windows ran *slower* fully offloaded (8.1 tok/s decode)
  than on the CPU (11.6 tok/s).

**Expected class on the X1:** decode is bound by memory bandwidth, and the iGPU shares the CPU's
DDR4. So for 7B Q4 expect roughly CPU-class decode (single-digit tok/s). The iGPU's gain is
mostly prompt processing and freeing the CPU. Small models (1-3B) are the practical target. The
X1 is not an LLM box. AMD discrete GPUs under R4 + RADV are the real local-LLM path.

## 5. Rung 1 started (REAL, this run): what OpenBSD's i915 needs from illumos

Harness: `src/drm-port/i915/probe-headers.sh`. It compiles an unmodified OpenBSD source file
against the illumos gate headers (`-D_KERNEL -ffreestanding -nostdinc`). Each missing header
is created empty in a scratch dir outside the repo, and the compile is retried. When no
header is missing any more, the remaining errors are the real API gap. This is measurement
scaffolding, not port code.

Facts (REAL, dixi, OpenBSD rev 37a498de copied to `/var/tmp/streamE2/obsd-drm`):

* The OpenBSD linux-KPI is layered **on OpenBSD kernel headers**:
  * `include/linux/types.h:13` includes `<machine/bus.h>`, and that is where an unmodified
    `i915_pci.c` first stops on illumos.
  * Of OpenBSD's shim headers, 87/266 `include/linux`, 9/20 `include/asm` and 4/87 `include/drm`
    include an OpenBSD host header directly. The most common are `sys/types.h` (45),
    `sys/param.h` (31), `sys/systm.h` (24) and `uvm/uvm_extern.h` (12).
* The include closure of all 378 `files.drm` sources (295 inteldrm + 83 drm core) reaches **252**
  `include/linux` + `include/asm` headers and **113** OpenBSD host headers
  (`/tmp/streamE2-work/gap.py`).
* solnix C1 linux-compat covers the API family of 13 of those 252: kref, idr, mutex, spinlock,
  slab, workqueue, kthread, completion, rwsem, dma-fence, ww_mutex, dma-resv and uaccess.
  The wifi port's OpenBSD compat (`src/wifi-port/iwx/compat/sys`) already covers 6 of the host
  headers: `_null`, `endian`, `malloc`, `task`, `timeout` and `tree`.
* `i915_pci.c` (the 0x3E9B device table) needs 35 empty stub headers. That leaves 1001 errors,
  most of them a `bool` cascade. With `-include sys/stdbool.h`, 380 errors remain:
  * about 80 implicit functions (`mtx_*`, `task_*`, `timeout_*`, `tsleep`/`msleep`/`wakeup`,
    `pci_conf_*`, `pci_mapreg_*`, `km_alloc`, `malloc(M_DRM)`, `atomic_setbits_int`,
    `arc4random`, `RB_*`/`SPLAY_*`, `READ_ONCE`)
  * 16 unknown types (`bus_space_*`, `bus_dma*`, `pcitag_t`, `vaddr_t`, `vm_page_t`, ...)
  * about 40 undeclared constants (`M_WAITOK`, `PAGE_SHIFT`, `IPL_*`, `PCATCH`, `INFSLP`, `uvmexp`, ...)
  * **only 1 collision with an illumos header** (`sys/list.h`)
* `i915/intel_cpu_info.c` compiles to 5 errors (`bool`, `ptrdiff_t`).

**What this means for the shim design:** the gap is the OpenBSD kernel API, not the Linux API.
OpenBSD already turned Linux calls into `mtx_enter`, `tsleep_nsec`, `bus_space_read_4` and
`pci_conf_read`. There are two ways to close it:

* **(a)** Write an "OpenBSD kernel API on illumos" layer (`sys/mutex.h`, `sys/task.h`,
  `machine/bus.h`, `dev/pci/pcivar.h`, `uvm_extern.h`, ...) and keep OpenBSD's PD/ISC
  `include/linux` unmodified. This is the iwx/net80211 approach, already proven on dixi for the
  wifi port.
* **(b)** Replace OpenBSD's `include/linux` with solnix's own linux-compat, mapping Linux
  directly to illumos DDI. This is the C1 approach.

(a) touches far fewer files, and OpenBSD's shim files can be re-fetched cleanly. (b) avoids a
double translation (Linux to OpenBSD to illumos) on hot paths like locking and MMIO.
**Recommendation: (a) for the bulk, with the hot primitives (`mtx_*` → `kmutex_t`,
`bus_space_*` → `ddi_get32`/`ddi_put32` on the BAR0 handle) as thin inline maps.** The union
measurement (5.1) supports this: 72 header-borne functions account for most of the error
volume across all 377 files.

### 5.1 Union gap over all inteldrm + drm-core files (REAL, dixi)

`/var/tmp/streamE2/union-gap.sh`, then `union-pass2.sh` (copies in `/tmp/streamE2.WIP/`):

* 48 empty stub headers get all 377 `files.drm` sources (inteldrm + `drm`) past the header wall.
  The stub set converged in 2 rounds.
* With `-fsyntax-only -include sys/stdbool.h`, 1 of the 377 files compiles clean, and there are
  129,793 error lines in total. **Correction (5.4): the clean count was 0/377, not 1/377.**
  `union-pass2.sh` counted every `*.err` in its log dir, and the one "clean" file was `all.err`,
  the empty concatenation that `union-gap.sh` left there.
* **Distinct names: 223 OpenBSD kernel functions/macros, 22 types, 139 identifiers.** There is
  **1** illumos-header collision: illumos `sys/list.h` `list_move_tail(list_t *, list_t *)` against
  Linux's `list_move_tail`, 42 sites.
* Of the 223 functions, **72 occur in 300 or more files**. They come in through OpenBSD's
  `include/linux` headers: 26,984 of the implicit-declaration sites are in `include/linux`, 1,027 in
  `include/asm`, and only 127 in `i915/*.c` and 68 in `drm_linux.c`. Supply those 72 once and
  most of the error volume goes. **134 occur in fewer than 10 files.** Those are the real
  per-subsystem work.

The 223 functions by OpenBSD subsystem:

| subsystem | n | illumos mapping (PLANNED) |
|---|---:|---|
| VM: `uvm_*`, `uao_*`, `pmap_*`, `km_*`, `PHYS_TO_VM_PAGE` | 30 | `page_t`/`page_create_va`, `hat_devload`, `ddi_umem_*`, `devmap_*`. The largest and riskiest part: GEM's shmem objects and GTT page tables live here |
| trees: `RB_*`, `SPLAY_*` | 17 | header-only. `src/wifi-port/iwx/compat/sys/tree.h` is already OpenBSD's tree.h on illumos |
| pci: `pci_conf_*`, `pci_mapreg_*`, `pci_get_capability`, ... | 17 | `pci_config_get*`/`put*`, `ddi_regs_map_setup`, `ddi_prop_lookup` on `reg` / `assigned-addresses` |
| bus_space / bus_dma | 14 | `ddi_get32`/`ddi_put32` on a BAR handle; `ddi_dma_alloc_handle`/`ddi_dma_mem_alloc`/`ddi_dma_addr_bind_handle` |
| sleep/wakeup: `tsleep_nsec`, `msleep`, `wakeup`, `sleep_setup` | 12 | `cv_timedwait_sig` on a wait channel hashed to a `kcondvar_t` |
| locks: `mtx_*`, `rw_*` | 12 | `kmutex_t` (`MUTEX_DRIVER`, with the interrupt priority for `IPL_*` > `IPL_NONE`), `krwlock_t` |
| timeout | 8 | `timeout(9F)`/`untimeout`, or a `ddi_periodic` |
| file descriptors: `fdalloc`, `fnew`, `FREF`, ... | 8 | the C1c `falloc` + spec-vnode mechanism (`src/drm_prime.c`) |
| taskq / task | 7 | `ddi_taskq_*`. The wifi port already maps `task.h` |
| atomics | 7 | `atomic_or_uint`/`atomic_and_uint`, `membar_*` |
| time | 6 | `gethrtime`, `gethrestime` |
| malloc / pool | 5 | `kmem_alloc`/`kmem_cache_*`. The wifi port already maps `malloc.h` |
| interrupts / spl | 5 | `ddi_intr_*`; `spl*` become no-ops under kmutex priority |
| i2c: `iic_*`, `i2c_bitbang_*` | 5 | GMBUS/DDC. Write against illumos `i2c` or keep OpenBSD's bit-bang code |
| random | 3 | `random_get_pseudo_bytes` |
| other | 67 | `KASSERT`, `printf`, endian swaps, `curcpu`, `KERNEL_LOCK`, `loadfirmware` (to `firmware(9F)`, as C3 amdgpu already does), `fpu_kernel_enter` (to `kpreempt_disable` + `fpu` save, for `i915_memcpy`), `extent_*` (aperture allocator), `inb`/`outb` (VGA), `knote` (to `pollwakeup`) |

Top types: `pcitag_t`, `bus_size_t`, `bus_space_tag_t`, `pcireg_t`, `bus_addr_t`, `vm_prot_t`,
`bus_space_handle_t`, `vaddr_t`, `pci_chipset_tag_t`, `voff_t`, `vsize_t`, `vm_fault_t`,
`bus_dma_tag_t`, `bus_dmamap_t`, `vm_page_t`. Top identifiers: `M_DRM`, `M_WAITOK`, `M_CANFAIL`,
`cold`, `M_ZERO`, `PAGE_SHIFT`, `IPL_TTY`, `PCI_CAP_PCIEXPRESS`, `PAGE_SIZE`, `PCATCH`, `INFSLP`,
`uvmexp`.

**Cost of the shim (PLANNED):** the 72 header-borne functions plus the types and constants, a
few days of work. Locks, sleep, taskq, timeout, pci, bus_space and malloc, maybe 3 weeks with
tests. The VM row is the long pole, probably 4-6 weeks. It is needed in full for GEM (R2).
How much of it R1 needs is NOT measured. The GGTT entries are written through BAR0, at
GTTMMADR + 8 MB on Gen8+. But i915's modeset path still allocates framebuffers as GEM objects
(stolen memory or system pages), so part of the VM row lands in R1 too. Compiling `display/`
against the shim will show how much.

### 5.2 First rung-1 file compiled (REAL, dixi)

`src/drm-port/i915/`:

* `openbsd-orig/include/drm/intel/pciids.h`: unmodified upstream, read-only, sha256
  `51a2bf8e…4c08`, OpenBSD 37a498de. Intel MIT; Linux ships the same lists.
* `i915_pciid.c`/`.h`: the Gen9 big-core device match, built from pciids.h's own X-macro lists
  with the same list-to-info pairing as upstream `i915_pci.c`.
* `test/test_pciid.c`, `Makefile` (`obj`, `test`, `probe`).
* `probe-headers.sh`, the gap harness.

Results on dixi:

```
$ make obj      (-D_KERNEL -ffreestanding -nostdinc -Werror against the gate proto)
i915_pciid.o: ELF 64-bit LSB relocatable AMD64 ... e_type ET_REL, e_machine EM_AMD64
undefs: 0      T i915_pciid_match / i915_pciid_count / i915_pciid_device
$ make test
PASS 8086:3e9b class 030000 -> coffeelake gt2
PASS 8086:591b class 030000 -> kabylake gt2
PASS 8086:3e9b class 040300 -> no-match        (non-display class)
PASS 8086:9a49 class 030000 -> no-match        (Tiger Lake: not first target)
PASS 10de:1c8c class 030200 -> no-match        (NVIDIA)
PASS table has 86 ids, 0x3e9b listed 1 time(s)
negative control (CFL-H GT2 list removed): FAILS as required
$ ./test_pciid <vendor-id> <device-id> <class-code>   # values read live from pfexec prtconf -v
/devices/pci@0,0/display@2                 00008086:00003e9b class 00030000 -> coffeelake gen9 gt2   exit 0
/devices/pci@0,0/pci8086,1901@1/display@0  000010de:00001c8c class 00030000 -> no-match              exit 1
```

This is the device table, not a driver. Nothing has been loaded into the kernel.

### 5.3 Next steps for rung 1 (PLANNED, in order)

1. ~~`i915/compat/`: the OpenBSD-on-illumos headers~~ Done as `src/drm-port/obsd-compat/`, see 5.4.
2. Compile `intel_device_info.c`, `intel_step.c`, `intel_uncore.c` (MMIO + forcewake), then
   `display/intel_display_device.c`. These are the first files a probe needs.
3. An illumos `i915_attach`: `pci_config_setup`, `ddi_regs_map_setup` BAR0 (GTTMMADR,
   `reg` rnumber from `assigned-addresses`), `intel_uncore_init`, then read `GEN6_GT_THREAD_STATUS`
   / the `PCH` id as the first live register read. **Written and linked (5.5); running it needs a module
   load, which needs the dump device the maintainer has not yet approved. Not loaded.**

### 5.4 The OpenBSD-kernel-API compat layer: every file compiles (REAL, dixi)

`src/drm-port/obsd-compat/` is route (a) from section 5: the OpenBSD kernel API on illumos.
OpenBSD's `include/linux` and `include/asm` stay unmodified. Every OpenBSD source compiles
unmodified with `-include obsd_prelude.h`. The parts:

* **`obsd_prelude.h`** includes the illumos headers first, under their own names. Then it renames
  the tags and functions that collide, for the rest of the translation unit: `struct proc`,
  `struct task`, `struct pool`, `struct file`, `list_move_tail`, `resume`, `rw_*`. It renames the
  kernel-exported names whose signatures differ (`taskq_create`, `suser`, `pool_init`,
  `pool_destroy`), because krtld would bind them to the kernel's own definitions. It also defines
  `__OpenBSD__` and `I915`, the two macros OpenBSD's own amd64 kernel build defines
  (`option I915` is in `GENERIC`).
* **`obsd_kern.h`**: types, malloc, mutex (OpenBSD's `struct mutex` is illumos `kmutex_t`),
  rwlock, sleep/wakeup, timeout, task/taskq, atomics, time, curproc/curcpu, autoconf, select/kqueue,
  the OpenBSD `struct file`, pool and firmware.
* **`obsd_vm.h`**: the UVM/pmap/km_alloc types and declarations.
* **`obsd_bus.h`**: bus_space, bus_dma, PCI and i2c.
* About 60 one-line forwarders for OpenBSD host headers that illumos lacks.
* Vendored, all permissive and read-only: `sys/tree.h` (BSD-2, the same file as the wifi port's
  copy), and `dev/acpi/acpireg.h` and `dev/acpi/amltypes.h` (ISC, data definitions only).
* **`obsd_kern.c`** holds the bodies: malloc/free, rwlock, sleep/wakeup on hashed condvars, time,
  timeout(9F), tasks via `taskq_dispatch_ent`, the curproc shadow in TSD, the cpu_info table,
  `loadfirmware` through firmware(9F), pool through kmem_cache, km_alloc for the kv/kp_dirty/kp_zero
  modes, PCI config space, capability lists and the BAR probe.

Harness: `src/drm-port/i915/union-probe.sh`, with the clean-count bug fixed. Missing headers are
stubbed and reported, so a clean count cannot hide one. `SET=full` adds the 13 `ttm` sources
(files.drm makes inteldrm depend on ttm) and `drm_drv.c`, which `sys/conf/files` lists as
`drm needs-flag`. **The 377 set from 5.1 left out the drm driver entry point itself.**
`src/drm-port/i915/link-gap.sh` compiles the clean files to real `-O2` kernel objects and lists
every undefined symbol that no object, `obsd_kern.o` or the running dixi kernel defines.

| run (dixi, OpenBSD 37a498de) | files | clean | error lines | stubbed headers |
|---|---:|---:|---:|---:|
| E2 baseline (5.1, recounted) | 377 | **0** | 129,793 | 48 |
| batch 1 (prelude + kern/vm/bus) | 377 | 339 | 311 | 3 |
| batch 2 (`I915`, OpenBSD file/UVM shapes, wscons types) | 377 | 374 | 18 | 0 |
| batch 5, ACPI off | 377 | 376 | 16 | 0 |
| batch 5, `SET=full`, ACPI off | 391 | 390 | 16 | 0 |
| **batch 5, `SET=full`, `-D__HAVE_ACPI -DNACPI=1` (OpenBSD amd64's own config)** | **391** | **391** | **0** | **0** |
| negative control: `mtx_enter` mapping deleted + `sys/tree.h` removed | 391 | 0 | 16,973 | 1 (`sys/tree.h`) |

With ACPI off, the one file that does not compile is `display/intel_opregion.c`. With
`CONFIG_ACPI` unset, its own header declares static-inline stubs that collide with the .c file,
which files.drm builds unconditionally. OpenBSD amd64 always defines `__HAVE_ACPI`, so that
configuration is not one upstream builds either.

`obsd_kern.o`: `make obj` (`-Werror`) gives an ELF64 ET_REL AMD64 object. `make syms` finds 60
undefined symbols, 0 of which are missing from dixi's running `unix` + `genunix`. `make negctl`
adds a call to a nonexistent function, and the check fails on that name as required.

**A file that parses is not a body.** `link-gap.sh`, with all 391 objects built and 0 module/kernel
name collisions after the `pool_*` rename, finds **114 symbols defined nowhere**
(`/tmp/streamE3.WIP/gap-users.txt`, with the objects that use each one). By area:

| area | symbols | needed for R1a (modeset + dumb buffer on eDP)? |
|---|---|---|
| VM: `PHYS_TO_VM_PAGE`(12 objs), `uao_*`, `uvm_obj_*`, `uvm_map`, `uvm_pglist*`, `pmap_*`, `uvmfault_unlockall`, `uvmexp`, `kernel_map` | 31 | **partly**: `PHYS_TO_VM_PAGE` is in `intel_ggtt.c` and `i915_gem_stolen.c`; dumb buffers go through `drm_gem` → `uao_create` |
| bus_space map + bus_dma | 15 | **yes** for `bus_space_map` (ggtt, stolen); bus_dma is for GEM pages (R2) |
| sleep: `sleep_setup`/`sleep_finish` (14 objs), `jiffies` (28 objs), `wakeup_proc`, `unsleep` | 5 | **yes**: `jiffies` is in intel_dp, link training, hotplug, drm_vblank |
| PCI interrupts + `pci_mapreg_map`/`pci_find_device`/`pci_enumerate_bus` | 8 | **yes** (attach, vblank and hotplug interrupts) |
| i2c bit-bang + `iic_exec` | 6 | **yes** for DDC/EDID over GMBUS on external outputs; the eDP panel's EDID comes over DP-AUX |
| file descriptors (`fnew`, `fd*`), `knote`/`klist`/`selwakeup` | 13 | no (dma-buf/sync_file fds, poll); needed for userland PRIME |
| wsdisplay/rasops/vga console glue | 15 | no: the illumos console stays vgatext, so `i915_driver.c`'s wsdisplay attach is replaced, not linked |
| ACPI AML + `acpi_softc` | 7 | no (VBT can come from the OpRegion mailbox) |
| autoconf `config_*`, `kthread_*`, `extent_*`, `fpu_kernel_*`, `wbinvd_on_all_cpus`, `mem_range_attr_set`, sysctl `hw_*`/`cpuspeed`, `obsd_cdevsw`, ISA hole | 14 | some: `fpu_kernel_*` (i915_memcpy), `wbinvd` (ggtt) |

So the next measured step is the R1a subset of this table: `bus_space_map`, `jiffies`,
`sleep_setup`/`sleep_finish`, PCI interrupts, `PHYS_TO_VM_PAGE` for GGTT/stolen, and enough
`uao_*` for dumb buffers. Then an `i915_attach` that replaces `i915_driver.c`'s OpenBSD autoconf
attach. Nothing in this section was loaded into a kernel, because the dump device is still not
approved (section 6).

### 5.5 Link gap closed; one i915 module that links against the running kernel (REAL, dixi solnix-3)

New compat files, each with a userland test and a negative control where the logic is testable:

| file | what | tag |
|---|---|---|
| `obsd-compat/obsd_time.c` | OpenBSD's sleep queue (`sleep_setup`/`sleep_finish`, `tsleep`/`msleep`/`rwsleep` + `_nsec`, `wakeup_n`, `wakeup_proc`, `unsleep`) on one kmutex + a per-thread kcondvar, the kern_synch.c model; `jiffies` as a variable refreshed from lbolt by a `ddi_periodic` | REAL |
| `obsd-compat/obsd_bus.c` | `bus_space_map` over `ddi_regs_map_setup` (BAR found from `reg` + `assigned-addresses`; prefetchable = `DDI_MERGING_OK_ACC`), non-BAR ranges over `psm_map_phys_new`; `pci_mapreg_map`; `pci_intr_*` over `ddi_intr_*` (MSI first); `pci_find_device` as a device-tree walk | REAL (walk: MAP) |
| `obsd-compat/obsd_vm.c` | `vm_page` registry (AVL of pfn intervals) for pages this layer allocates and `uvm_page_physload` ranges; `PHYS_TO_VM_PAGE`, `uvm_pglistalloc`, `uao_*` (wired at create), `uvm_obj_wire`, kernel `pmap_*` over `hat_devload`, `km_alloc`, `wbinvd_on_all_cpus` | REAL; user mappings ENOTSUP |
| `obsd-compat/obsd_glue.c` | autoconf `config_found_sm` (runs `drm_attach`), kthreads, kernel FPU, SMBIOS `hw_*` | REAL |
| `obsd-compat/obsd_glue.c` | bus_dma, dma-buf/sync_file fds, kqueue, i2c bit-bang, ACPI AML, wsdisplay/rasops/vga | **STUB** (fail, never fake success) |
| `i915/i915_illumos.c` | modlinkage/dev_ops for `i915`; attach builds an illumos-backed `pci_attach_args` and runs OpenBSD's `inteldrm_ca` match + attach; `/dev/dri/card0` minor | REAL, not loaded |

Measured:

* `link-gap.sh` "defined nowhere": 114 (5.4) → 109 (obsd_time) → 98 (obsd_bus) → 68 (obsd_vm) → **0** (glue +
  stubs), 391/391 objects, 0 kernel-name collisions.
* `i915/build-module.sh`: the `ld -r` module is 5,523,936 bytes (text 3,236,200), **178 undefined, 0 not exported
  by the running unix + genunix, 0 collisions with the 27,540 globals of /dev/ksyms** (kernel + loaded modules). The
  collision gate first found `free`, exported by the loaded `ufs` module; malloc(9) is now `obsd_*`. A first version
  of the gate ran `nm` on the `/dev/ksyms` character device, read 0 symbols and passed vacuously; it now copies the
  device and refuses a snapshot under 10,000 symbols. Both gates have negative controls that fail by name.
* Tests (`obsd-compat`, `gmake test`): sleep 8/8, BARs from dixi's real iGPU properties 4/4, vm/uao 14/14; 8 runs
  each all PASS; 4 negative controls FAIL as required.

Nothing was loaded. The load plan, including what happens to the gfxp_bitmap console when i915 takes display@2, is
`src/drm-port/i915/ATTACH-PLAN.md`. Short answer: illumos has no console handover, vgatext cannot detach from the
console node, so binding i915 takes a reboot and leaves no tem console until i915 provides a `visual_io`
polled-I/O console of its own (PLANNED).

## 6. Open questions for the maintainer

1. The licence rule's scope: is GPL-3 COSMIC acceptable as a separately packaged application
   (rule 3)?
2. The project licence, so the 36 header-less files can get headers.
3. The dump device, which gates every kernel-module step from R1a on.
4. Whether the X1's dGPU stays unbound (recommended: yes) or a nouveau port is wanted (R3).

## 5.6 Facts for the cdev and console step (stream E5, read from source + measured, 2026-10-09)

Read from illumos ac45d71 and OpenBSD 37a498de; F8 measured on the X1 with mdb.

- F1. The kernel terminal emulator (tem) opens the FIRST minor of the console display node
  (devcfg.c resolve_pathname: DDM_DEFAULT, else the first devi_minor) and sends VIS_DEVINIT
  with FKIOCTL. gfx_private's gfxp_fb_attach/ioctl/devmap/open (exported; 77 globals in
  /dev/ksyms) are the whole vgatext console: vgatext.c is a ~400-line wrapper around them. So i915
  can host the same bitmap console vgatext hosts today, on a text minor created first.
- F2. Would-panic in the E4 module: inteldrm_attachhook calls rasops_init(ri), then reads
  ri->ri_font->fontwidth. The E4 rasops_init stub leaves ri_font NULL, so the first SUCCESSFUL
  i915_driver_probe dereferences NULL. Must be fixed before any load (stub rasops with a font,
  or skip the wsdisplay attach path).
- F3. illumos _KERNEL minor(x) is x & 0xff (SVR3 O_MAXMIN), not OpenBSD's 24-bit minor:
  drm_drv.c's clone bits (CLONE_SHIFT 8) are cut, and every open would get the same file minor.
  The "same meaning" note in obsd_kern.h is wrong.
- F4. The Linux _IOC direction bits (WRITE = 1<<30 means copyin) are the opposite of BSD and
  illumos (IOC_IN 0x80000000, IOC_OUT 0x40000000), and illumos IOCPARM_MASK is 0xff where OpenBSD
  has 0x1fff. solnix's libdrm emits the Linux encoding (radv/build-libdrm.sh), so i915's ioctl
  entry must decode Linux _IOC and re-encode OpenBSD's for drm_ioctl.
- F5. x86 consconfig picks the console framebuffer by device_type and PCI IO (plat_fbpath),
  independent of the bound driver; there is no tem-support check on x86.
- F6. Dumb mmap on Gen9 (no LMEM, PAT enabled): I915_MMAP_TYPE_WC, which faults in the object's
  SYSTEM pages write-combined (pmap_enter with PMAP_WC), not the GTT aperture.
- F7. i915_gem_object_pin_map_unlocked(obj, I915_MAP_WC) gives a contiguous kernel VA, so a
  KMEM_NON_PAGEABLE ddi_umem cookie over that VA works with devmap_umem_setup. A cookie straight
  on the uao chunks would be wrong (their VAs are not contiguous).
- F8. The X1's fb_info (mdb): RGB, paddr 0x4000000000, size 0x1fa4000, pitch 0x3c00, 4 bytes per
  pixel, depth 32.

Design that follows: clone minors (c<<8 | 0 card, | 128 render) per open; a "text-0" minor
created FIRST so tem lands on it, served by gfxp_fb_open/ioctl/devmap; OpenBSD's inteldrm attach
(the modeset) deferred to the first open of card0 or renderD128; the console goes KD_GRAPHICS
while a DRM master exists and back to KD_TEXT (plus drm_client_dev_restore) when it drops.

### 5.7 The cdev and the console written into the module (stream E5b; REAL build, nothing loaded)

All five facts above now have code, in a module that still passes both gates. dixi, clean rebuild of all 391 objects:
5,536,008 bytes, 202 undefined, 0 not exported by unix + genunix + misc/gfx_private, 0 collisions with /dev/ksyms;
both gate negative controls fail by name. Details and the controls: `src/drm-port/i915/ATTACH-PLAN.md` section 0b.

| fact | code | measured |
|---|---|---|
| F2 | `obsd_glue.c` rasops_init sets a metrics-only `ri_font` | E4 rasops_init never stores ri_font; the new one does (disassembly) |
| F3 | `obsd_kern.h` minor() = getminor; minor layout in `i915_drmioc.h`; clone index from an id_space in open(9E) | 524,280 opens give 524,280 distinct drm_file keys; with SVR3 x & 0xff, 8 |
| F4 | `i915_il_ioctl`: Linux _IOC -> OpenBSD's, copyin/copyout as OpenBSD's sys_ioctl does | 152/152 ioctls, 21/21 R1a; sabotage fails 90 checks; 8/8 runs |
| F6/F7 | `i915_il_devmap` + `i915_drmglue.c`: WC mmap offset -> pin_map WC -> KMEM_NON_PAGEABLE cookie -> devmap_umem_setup (write-combining) | compiles and links; not run |
| F1 | DDI attach: gfxp_fb_attach + `text-0` before `card0`/`renderD128`; OpenBSD attach deferred to the first drm open; KD_GRAPHICS while a master exists | attach references gfxp_fb_attach, then text-0, then the drm minors; `inteldrm_ca` is referenced only from open |

Open risk: after the first modeset, gfxp's console buffer (GOP, GMADR offset 0) is visible only if i915's fbdev
inherits the BIOS plane. Not verified; the first load must check it.
