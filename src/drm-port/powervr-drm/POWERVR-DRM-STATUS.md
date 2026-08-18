# solnix PowerVR DRM port — STATUS (C-PVR-b: the Imagination kernel DRM driver)

## Goal

Port the Linux **kernel** DRM driver (`drivers/gpu/drm/imagination`, 29 `.c`,
~17.4k LOC) onto solnix's **C1 DRM framework**, COMPILE-phase, zero-phantom —
the kernel half of driving the Milk-V Jupiter's **Imagination PowerVR BXE-2-32**
GPU. The **userspace** half (`libvulkan_powervr_mesa.so`, the 15 pvr_drm ioctls)
is C-PVR-a (`../powervr/POWERVR-STATUS.md`); this driver is what those ioctls
target — the `libdrm_amdgpu ↔ amdgpu kernel` analogue, here `libvulkan_powervr
↔ this imagination DRM driver`.

Cribbed from the Linux `drivers/gpu/drm/imagination` source (mainline, pinned in
`linux-ref/`), adapted crib-and-adapt onto the C1 framework — the same playbook
that landed C3-amdgpu (113 undefs, 0 phantom) + C3-KFD. This is **another DRM
driver onto the same C1 framework** (C1 DRM core + GEM + drm_sched + dma-fence +
the linux-compat shims in `../src/`), the C3-amdgpu model applied to PowerVR.

## Verdict

**The powervr DRM driver COMPILED for illumos x86_64 as 12 ET_REL AMD64 objects
(2590 LOC), linked into one `drm-pvr` module, zero-phantom (every undef is a
real illumos KPI or a C1-framework symbol), and the 15-ioctl ABI matches
C-PVR-a's `pvr_drm.h` EXACTLY (all 14 encoded ioctl numbers + all arg struct
sizes verified).**

PowerVR's kernel driver is more **command-ring + firmware** than register-
banging (the FW does most of the work), so — unlike C3-amdgpu's register-heavy
IP bring-up — the load-bearing pieces here are pvr_gem (BO alloc), pvr_vm (the
GPU MMU), pvr_ccb (the FW command rings), pvr_context/queue/job (submission),
and the **pvr_fw + pvr_fw_riscv** firmware-load path (the BXE-2-32's FW processor
is a RISC-V coprocessor — `pvr_fw_riscv.c` exists in the Linux driver precisely
for this class of part).

## What compiled (12 objects, 2590 LOC) — the C3-amdgpu playbook

| object | LOC | role | onto the C1 framework |
|---|---|---|---|
| `pvr_device.c` | 290 | attach/detach + register access (`pvr_cr_read/write`) + per-file open/close | `ddi_regs_map_setup` rnumber 0 (SoC reg entry, not PCI BARs); `ddi_get32/put32` = `ioread32/iowrite32`; called from C1 `drm_attach` like `amdgpu_transport_attach` |
| `pvr_drv.c` | 137 | the **15-ioctl dispatch** + `DEV_QUERY` | switches on `DRM_IOCTL_PVR_*` (the C1 `_IOC` scheme), wired the way the virtio 3D ioctls are in `src/drm_core.c` |
| `pvr_gem.c` | 207 | **BO alloc** (CREATE_BO, GET_BO_MMAP_OFFSET) | the C1 GEM (`ddi_umem_alloc` + the devmap cookie) — the same primitive C3-amdgpu's TTM BOs wrap |
| `pvr_vm.c` | 305 | the **GPU MMU** (CREATE/DESTROY_VM_CONTEXT, VM_MAP, VM_UNMAP) | device-VA address space + mapping list; the PT walk (`pvr_mmu.c`) is BXE-gated |
| `pvr_context.c` | 377 | **contexts + queues + jobs** (CREATE/DESTROY_CONTEXT, SUBMIT_JOBS) | the C1 `drm_sched` (single-FIFO) + the C1 dma-fence; RENDER→geom+frag queues |
| `pvr_free_list.c` | 91 | free lists (CREATE/DESTROY_FREE_LIST) | idr handle table + grow-policy record |
| `pvr_hwrt.c` | 91 | HWRT datasets (CREATE/DESTROY_HWRT_DATASET) | idr + free-list ref validation |
| `pvr_ccb.c` | 129 | the **FW command rings** (KCCB kernel→FW, FWCCB FW→kernel) | FW objects (GEM BOs in the FW heap) + producer/consumer offsets; the doorbell kick is BXE-gated |
| `pvr_sync.c` | 84 | job sync → the C1 dma-fence | the C1 `dma_fence` (`src/drm_dma.c`) + `sync_file` (`src/drm_prime.c`) — the same substrate C-PVR-a drives via `vk_drm_syncobj` |
| `pvr_fw.c` | 302 | **FW load + boot** (`request_firmware`→`firmware(9F)`) + header parse/validate + FW-object allocator | `firmware_open/get_size/read/close` = the C3-amdgpu `amdgpu_ucode.c` mapping; the blob comes from the SpacemiT BSP, the driver LOADS it |
| `pvr_fw_riscv.c` | 190 | the **RISC-V FW back-end** (`pvr_fw_defs`) | vm_map into the kernel VM context; wrapper_init programs the RISC-V remap regs (BXE-gated) |
| `pvr_fw_startstop.c` | 69 | start/stop the FW processor | sequences wrapper_init + reset release (register writes BXE-gated) |
| **total** | **2590** | | |

Plus `pvr_priv.h` (318, the softc + subsystem model) + `uapi/pvr_drm.h` (1306,
the ABI header, illumos-kernel-guarded).

Build: `gmake all` on the node (`/root/drm-port/powervr-drm/`) — gcc-14,
`-m64 -D_KERNEL -ffreestanding -nostdinc -I/usr/include -I../src
-I../src/uapi/drm`. **Zero warnings, zero errors.** `file drm-pvr` → `ELF 64-bit
LSB relocatable AMD64`.

## The 15-ioctl ABI — matches C-PVR-a's pvr_drm.h EXACTLY

`gcc -I../src/uapi/drm test_pvr_abi.c && ./a.out` → **PASS**. The kernel-side
`DRM_IOCTL_PVR_*` numbers (encoded through the C1 `_IOC` scheme) equal C-PVR-a's
`pvr-ioctl-encoding.out` table byte-for-byte:

| opcode | ioctl | encoded | args size | handler |
|---|---|---|---|---|
| 0x00 | DEV_QUERY | `0xc0106440` | 16 | `pvr_dev_query_ioctl` |
| 0x01 | CREATE_BO | `0xc0186441` | 24 | `pvr_gem_create_bo_ioctl` |
| 0x02 | GET_BO_MMAP_OFFSET | `0xc0106442` | 16 | `pvr_gem_get_bo_mmap_offset_ioctl` |
| 0x03 | CREATE_VM_CONTEXT | `0xc0086443` | 8 | `pvr_create_vm_context_ioctl` |
| 0x04 | DESTROY_VM_CONTEXT | `0x40086444` | 8 | `pvr_destroy_vm_context_ioctl` |
| 0x05 | VM_MAP | `0x40286445` | 40 | `pvr_vm_map_ioctl` |
| 0x06 | VM_UNMAP | `0x40186446` | 24 | `pvr_vm_unmap_ioctl` |
| 0x07 | CREATE_CONTEXT | `0xc0286447` | 40 | `pvr_create_context_ioctl` |
| 0x08 | DESTROY_CONTEXT | `0x40086448` | 8 | `pvr_destroy_context_ioctl` |
| 0x09 | CREATE_FREE_LIST | `0xc0206449` | 32 | `pvr_create_free_list_ioctl` |
| 0x0a | DESTROY_FREE_LIST | `0x4008644a` | 8 | `pvr_destroy_free_list_ioctl` |
| 0x0b | CREATE_HWRT_DATASET | `0xc088644b` | 136 | `pvr_create_hwrt_dataset_ioctl` |
| 0x0c | DESTROY_HWRT_DATASET | `0x4008644c` | 8 | `pvr_destroy_hwrt_dataset_ioctl` |
| 0x0d | SUBMIT_JOBS | `0x4010644d` | 16 | `pvr_submit_jobs_ioctl` |

`DEV_QUERY` sub-queries decoded: `GPU_INFO_GET`, `RUNTIME_INFO_GET`,
`QUIRKS_GET`, `ENHANCEMENTS_GET`, `HEAP_INFO_GET`, `STATIC_DATA_AREAS_GET` (the
two-pass size-probe/fill contract honored; the payloads are FW-boot-gated).
Job types: `GEOMETRY`/`FRAGMENT`/`COMPUTE`/`TRANSFER_FRAG`. Context types:
`RENDER`/`COMPUTE`/`TRANSFER_FRAG`; priorities `LOW`/`NORMAL`/`HIGH`
(-512/0/512). All validated in the handlers.

The uapi header (`uapi/pvr_drm.h`) is the Linux `drivers/gpu/drm/imagination`
uapi verbatim, with the `#include <linux/const.h>`/`<linux/types.h>` swapped for
the C1 `drm.h` (which supplies `__uN` + `DRM_IOWR`/`DRM_COMMAND_BASE`) + a
`_BITULL` fallback — the same substitution C-PVR-a's `_IOC` shim made, mirrored
for the `-nostdinc` kernel build.

## ZERO-PHANTOM audit: YES — 0 phantom (same bar as C3-amdgpu + KFD)

`drm-pvr` has **59 unique undefs**. Machine-checked (`comm -23`, `LC_ALL=C`)
against (illumos kernel KPI ∪ C1-framework defined symbols ∪ pvr-self symbols):

    PHANTOM (pvr undef resolving to no illumos KPI / C1 symbol): 0

The 59 split cleanly:

- **7 → the C1 framework** (`../src/*.o`): `dma_fence_init`, `dma_fence_put`,
  `dma_fence_context_alloc`, `drm_sched_init`, `drm_sched_fini`,
  `drm_sched_job_init`, `drm_sched_entity_push_job` — the C1c dma-fence +
  scheduler the pvr submission/sync path is wired onto.
- **52 → real illumos KPI**: `ddi_regs_map_setup/free`, `ddi_get32/64`,
  `ddi_put32/64`, `ddi_dev_regsize`, `ddi_intr_*` (alloc/add_handler/enable/
  free/get_navail/get_supported_types), `ddi_umem_alloc/free`, `ddi_copyin/out`,
  `firmware_open/get_size/read/close` (firmware(9F)), `kmem_alloc/zalloc/free`,
  `avl_*`, `list_*`, `mutex_*`, `rw_init/destroy`, `atomic_inc_uint`/
  `atomic_dec_uint_nv`/`atomic_inc_64_nv`, `bcopy`, `snprintf`, `cmn_err`,
  `_pagesize`.

Every one is `T`/`GLOB`-defined in genunix/unix or an `../src` C1 object — no
unresolved Linux symbol, no phantom. (The full pvr+C1 link `drm-pvr-full` shows
14 additional undefs — `virtio_gpu_*`, `kfd_ioctl`, `drm_gem_scanout` — but
those are the **C1 `drm_core.o`'s** references to the virtio/kfd handlers, not
pvr's; they resolve when the C1 virtio/amdkfd objects are in the link, exactly
as in the C1/C3 builds.)

## The pvr_fw_riscv FW-load path: YES

The BXE-2-32's FW processor is a **RISC-V coprocessor**, so `pvr_fw_riscv.c`
supplies the `pvr_fw_defs` back-end (vs the META/MIPS back-ends the older Rogue
parts use). The load path (`pvr_fw.c`):

1. **`pvr_request_firmware`** — builds the `rogue_B.V.N.C_vM.fw` name from the
   BVNC + loads the blob via `firmware(9F)` (`firmware_open("powervr", name)` —
   the C3-amdgpu `request_firmware` mapping). The blob is from the SpacemiT BSP,
   redistributed into the illumos firmware path; **the driver loads it, does not
   contain it** (like amdgpu's signed microcode).
2. **`pvr_fw_validate`** — parses the `pvr_fw_info_header` at (size − 4K),
   checks `info_version == 3`, block alignment, and that the layout table fits.
3. **`pvr_fw_process`** — allocates the code/data FW objects + the RISC-V
   back-end (`pvr_riscv_fw_process`) fills the RISC-V boot data.
4. **`pvr_fw_startstop_start`** — the RISC-V `wrapper_init` (remap regs) + reset
   release + boot poll.

Compile-complete + off-hardware-runnable: the load, header parse/validate, FW-
object allocator, RISC-V vm_map (into the C1-backed kernel VM context), and the
boot-data fill. BXE-hardware-gated: the register-touching steps (`wrapper_init`
programs `ROGUE_RISCVFW_REGION_REMAP_*` + the Garten wrapper; the boot poll waits
for the FW `firmware_started`; the doorbell kick `ROGUE_CR_MTS_SCHEDULE`).

## Subsystems onto the C1 framework

- **pvr_gem → C1 GEM (ddi_umem):** YES. `pvr_gem_object` wraps a C1
  `drm_gem_object` (real `ddi_umem_alloc` backing + handle + mmap_offset); a
  userland mmap of the render node faults the same pages via the C1b `cb_devmap`
  — the same path C-PVR-a's `GET_BO_MMAP_OFFSET` + mmap use.
- **pvr_vm → the GPU MMU:** YES. Device-VA address space + mapping list +
  range/alignment validation + the map/unmap ioctl ABI. The multi-level PT walk
  + MMU cache flush (`pvr_mmu.c`) is BXE-gated.
- **pvr_ccb → the FW command ring:** YES. KCCB (kernel→FW) + FWCCB (FW→kernel)
  as FW objects with producer/consumer offsets; `pvr_kccb_send_cmd` enqueues +
  (gated) kicks the doorbell.
- **pvr_context/queue/job → the C1 drm_sched:** YES. Each SUBMIT_JOBS builds a
  `drm_sched_job` (`pvr_job` embeds it) whose `run_job` ships the command stream
  to the FW (gated) and whose finished dma-fence is the out fence — the C1d
  virtio-3D SUBMIT model applied to pvr.
- **pvr_sync → the C1 dma-fence:** YES. The output fence is a C1 `dma_fence`
  with a pvr ops vtable; the wait side resolves drm_syncobj handles through the
  C1 `sync_file` path (`src/drm_prime.c`).

## Compile-complete vs Jupiter-hardware-gated

**Compile-complete (delivered here):**
- 12 ET_REL objects, 2590 LOC, zero warnings/errors, zero-phantom.
- The char device (`/dev/dri/renderD*` via the C1 `cb_ops` — the driver hooks
  the C1 `drm_attach` via `pvr_transport_attach`, the amdgpu/virtio contract).
- The 15-ioctl dispatch, ABI-matching C-PVR-a byte-for-byte (verified).
- pvr_gem/pvr_vm/pvr_ccb/pvr_context/pvr_queue/pvr_job/pvr_sync onto the C1
  framework; the pvr_fw + pvr_fw_riscv load/parse/validate/section-alloc path.

**Jupiter-hardware-gated (needs the real BXE-2-32 + the SpacemiT FW blob):**
- **The BXE-2-32 registers.** The MMU PT walk + cache flush (`ROGUE_CR_MMU_*`),
  the RISC-V remap/wrapper init, the FW doorbell (`ROGUE_CR_MTS_SCHEDULE`), the
  boot poll, and the FW IRQ drain — all program device registers on the powered-
  up core. The register-access primitives (`pvr_cr_read/write`) + the sequencing
  are wired; the live writes need the metal.
- **The SpacemiT FW blob.** `pvr_request_firmware` loads `rogue_B.V.N.C_v1.fw`
  from the illumos firmware path; the blob must be redistributed there from the
  Jupiter BSP (like C-PVR-a's device-table-needs-Mesa-25.x gate — the port work
  carries forward unchanged once the blob is installed).
- **The BVNC device identity.** `pvr_read_gpu_id` reads CORE_ID at attach; off-
  hardware it is zeroed (so DEV_QUERY's feature/quirk payloads are FW-boot-gated,
  matching C-PVR-a: Mesa 24.0.9 does not even carry the BXE-2-32 device table).
- All actual rendering / job execution / GPU-VM (runtime = the BXE hardware).

## The one integration point

The driver hooks the C1 `drm_attach` exactly like `amdgpu_transport_attach` /
`virtio_gpu_transport_attach`: on a PowerVR SoC parent, `drm_attach` calls
`pvr_transport_attach(dip, dev)` (returns NULL on a non-PowerVR parent — clean
no-op, the C1 contract), and the C1 `drm_ioctl` routes a pvr command number to
`pvr_ioctl(sc, pf, cmd, arg, mode)`. Both are one-call-site edits to the shared
`src/drm_core.c` (which already carries the amdgpu + virtio + kfd hooks); the
pvr module is otherwise self-contained and builds/audits independently as
`drm-pvr`.

## Files (`src/drm-port/powervr-drm/`)

- `pvr_priv.h` — the softc + subsystem model (the pvr `pvr_device` + `pvr_file`).
- `pvr_device.c` `pvr_drv.c` `pvr_gem.c` `pvr_vm.c` `pvr_context.c`
  `pvr_free_list.c` `pvr_hwrt.c` `pvr_ccb.c` `pvr_sync.c` `pvr_fw.c`
  `pvr_fw_riscv.c` `pvr_fw_startstop.c` — the 12 driver objects.
- `uapi/pvr_drm.h` — the ABI header (Linux uapi, illumos-kernel-guarded).
- `test_pvr_abi.c` — the ioctl-ABI self-check (PASS).
- `Makefile` — `gmake all` (the 12 objects → `drm-pvr`); `gmake full` (pvr + C1
  → `drm-pvr-full` for the zero-phantom link); `gmake verify`.
- `linux-ref/` — the pinned Linux `drivers/gpu/drm/imagination` crib source.

## Reproduce (on the node /root/drm-port/powervr-drm/)

    export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
    cd /root/drm-port/powervr-drm && gmake all        # -> drm-pvr (12 objs)
    gmake full                                          # -> drm-pvr-full
    cd /root/drm-port && sh verify-syms.sh drm-pvr-full # (see note: 14 are C1's)
    # pvr-only zero-phantom: comm -23 pvr_undef  (kernel KPI ∪ C1 ∪ pvr-self) = 0
    cd powervr-drm && gcc -I../src/uapi/drm -o /tmp/t test_pvr_abi.c && /tmp/t
