# solnix on a real NVIDIA GPU (g4dn.xlarge / Tesla T4) — bind attempt + honest verdict

Node: `chiuso solnix-gpu-nvidia`, g4dn.xlarge, `root@3.148.170.42`.
Kernel: `SunOS solnix-builder-build 5.11 illumos-fb435c17bd i86pc`.

## 1. Milestone: solnix BOOTS on a real GPU instance — CONFIRMED

solnix boots and networks on the g4dn.xlarge (ena-fixed image). This is the
first solnix boot on a GPU-class EC2 instance — the prerequisite nobody had
before. `uname -a` and an SSH login both succeed on a live illumos kernel.

## 2. Milestone: illumos SEES the NVIDIA T4 — CONFIRMED (live, on-node)

`prtconf -pv` shows the T4 as a first-class PCIe device (PROM Node 0x00000a):

    unit-address:  '1e'
    compatible: 'pciex10de,1eb8.10de.12a2.a1' + ... + 'pciex10de,1eb8'
                + 'pciexclass,030200' + ... + 'pciclass,030200'
    model:  '3D controller'
    class-code:      00030200        (3D controller)
    vendor-id:       000010de        (NVIDIA)
    device-id:       00001eb8        (TU104 — Tesla T4)
    revision-id:     000000a1
    subsystem-id:    000012a2
    subsystem-vendor-id: 000010de
    assigned-addresses: BAR0 0xc0000000 (256 MB) + a 256 MB BAR + a 32 MB BAR

illumos enumerated the T4, read its config space, and assigned its BARs. The
device tree node name is `pci10de,12a2`.

## 3. T4 driver state — NOT ATTACHED (as expected)

`prtconf -D` (driver-attach view):

    pci, instance #0 (driver name: npe)
        ...
        display, instance #0 (driver name: vgatext)     <- the BOOT CONSOLE VGA
        pci1d0f,0, instance #0 (driver name: nvme)
        pci1d0f,ec20, instance #0 (driver name: ena)
        pci10de,12a2                                     <- the T4: NO driver name
        pci1d0f,0, instance #1 (driver name: nvme)

- The T4 (`pci10de,12a2`) has **no driver name** — driver not attached.
- The console framebuffer is `display@3` = `vgatext` on the QEMU/EC2 VGA
  (`1d0f,1111`, class 030000), **not** the T4.
- `/etc/driver_aliases` has **no** `10de` / `1eb8` / `nouveau` / `nvidia` entry —
  nothing on the system claims the T4.
- `/dev/dri` does not exist. `/dev/fbs` has only `text-0 -> .../display@3`.

## 4. The bind attempt + result: CANNOT BIND — structural blocker

**Verdict: the T4 does NOT bind, and no controlled attach is even possible with
what the port contains, because solnix has no nouveau kernel driver.**

The bind blocker is not a runtime register/GSP-firmware wall reached after an
attach — it is one level earlier: there is nothing to attach.

### 4a. solnix's DRM port has NO nouveau kernel driver

`src/drm-port/` (the C1 DRM framework) contains exactly two transport drivers:

| transport | binds | state |
|---|---|---|
| `virtio_gpu` (default) | virtio-gpu PCI children (`pciclass,030000` virtio, vendor 1af4) | compile-complete (C1a–d) |
| `amdgpu` | AMD Navi 12 / V520 only (**vendor 0x1002**, device 0x7362) | compile-phase (C3-amdgpu-a..d) |

`drm_core.c`'s `attach` calls `virtio_gpu_transport_attach(dip, drm)`, which
returns `NULL` on a non-virtio parent. There is **no code path** that classifies
or binds `pciex10de,1eb8` (NVIDIA). `amdgpu.c` is AMD-only. Nothing in the port
targets an NVIDIA vendor id.

`grep -rl nouveau src/drm-port/src/` → **empty**. Nouveau exists in the port
only as **userspace**: `libdrm_nouveau.so` (the nouveau ioctl wrapper) and the
NVK Vulkan ICD *config*. No `dev_ops`/`attach`/nouveau kernel module was ever
written — the port's own docs (`STATUS.md` anti-scope) explicitly defer
`nouveau` to "far later (C3)"; only amdgpu was started on the kernel side.

### 4b. Even the NVK userspace Vulkan driver does not link

Per `src/drm-port/nvk/NVK-STATUS.md`: `libvulkan_nouveau.so` (NVK) does **not**
link on illumos — not for a portability reason, but because NVK's shader
compiler **NAK** is Rust and requires `rustc >= 1.73` + `rust.bindgen`
(needs libclang). The meson config resolves every non-Rust dependency and dies
at `add_languages('rust', required: true)`. No rustc/cargo/bindgen/libclang on
the node or in the store. So there is no NVK ICD to enumerate the T4 even if a
kernel node appeared.

### 4c. This node is a fresh base image

The g4ad-built artifacts are **not** on this T4 node: no `/root/drm-port`, no
`llama.cpp` / `llama-bench`, no `libvulkan_nouveau.so`, no `nouveau_icd.json`.
The only nouveau bits present are the base-image X stack's stock
`libdrm_nouveau.so.1` (unrelated to the port). No DRM/virtio-gpu kernel module
is installed in `/kernel/drv/amd64` either.

### 4d. Why no "controlled attach attempt" was made

The task allows a controlled `add_drv`/`update_drv` attach on this
(disposable) hardware. But there is no nouveau `drm` kernel module to load, and
force-binding the amdgpu-only `drm` module to `pciex10de,1eb8` would do nothing
useful (amdgpu classifies vendor 0x1002 only; on an NVIDIA parent
`amdgpu_transport_attach` never runs) while risking a panic on the live box for
zero information gain. The honest, safe result is the structural finding above.

## 5. The GGML_VULKAN measurement — NOT RUN (no solnix T4 number)

No GPU bind → no `/dev/dri/card0` → no NVK/RADV ICD → no `llama.cpp`
GGML_VULKAN run on the T4. **There is no solnix T4 tok/s number to report, and
none was fabricated.**

The Linux baseline for reference (from `docs/GPU-PARITY-RESULTS.md`, measured on
a **different GPU** — AMD Radeon Pro V520 via RADV on g4ad, **not** this T4):

    TinyLlama-1.1B-Q4  tg64 283 tok/s (5.3x over 53 CPU),  pp128 1995 (3.1x over 644)

A fair T4 comparison would require the T4 to bind under solnix first; it does
not, so no parity verdict is possible. (The well-known Linux+CUDA T4 llama.cpp
figure for this model is ~1400–1600 pp / ~110–140 tg tok/s, GPU/driver/quant
dependent — but that is Linux+CUDA, and irrelevant until solnix has any T4
number of its own.)

## 6. HONEST VERDICT

- **solnix boots on g4dn.xlarge:** YES (milestone).
- **illumos sees the T4 (`pciex10de,1eb8`, class 030200):** YES (milestone) —
  enumerated, config-space read, BARs assigned, driver NOT attached.
- **GPU bind under solnix:** **NO.**
- **solnix T4 GGML_VULKAN number:** none (bind failed; nothing fabricated).
- **Parity vs Linux 283 tok/s:** not determinable (no solnix GPU number).

### The EXACT bind blocker (the first real solnix-on-NVIDIA data point)

solnix has **no nouveau kernel DRM driver at all**. The DRM port's only kernel
transports are virtio-gpu and amdgpu (AMD-only). The NVIDIA/nouveau kernel
driver — the module that would `add_drv` onto `pciex10de,1eb8`, load the T4's
**GSP firmware** (Turing needs GSP-RM), and stand up the rings/doorbells — was
never written; nouveau is present only as ported *userspace* (libdrm_nouveau +
an NVK config that itself does not link, blocked on a Rust 1.73 + bindgen/
libclang toolchain).

### What closes it (in order, largest first)

1. **A nouveau (or NVIDIA-open GSP) kernel DRM driver for illumos** binding
   `pciex10de,1eb8` on the C1 DRM framework: PCI attach + BAR map + TTM/VRAM +
   **GSP-RM firmware load** (the Turing hardware wall) + ring/doorbell init +
   the nouveau ioctl surface (already ported in `libdrm_nouveau`). This is a
   multi-thousand-LOC driver comparable to the amdgpu C3 effort, plus the
   GSP-firmware handshake that has no illumos precedent — the deep,
   genuinely-hardware-gated step. **Alternatively** finish amdgpu C3 runtime and
   benchmark on an AMD GPU instead (amdgpu is far closer: compile-complete
   through C3-amdgpu-d, only the live-register/PSP-firmware runtime remains, and
   it needs no GSP wall).
2. **Bootstrap Rust 1.73 + bindgen/libclang on illumos x86_64** so NVK's
   `libvulkan_nouveau.so` links (userspace Vulkan ICD). Independent of #1; both
   are needed for the NVK+nouveau path end to end.
3. Only after #1 (a bound T4 → `/dev/dri/card0`) and #2 (a linked NVK ICD) can
   `llama.cpp` GGML_VULKAN enumerate the T4 and produce a solnix number to
   compare against the Linux baseline.

## 7. Bottom line

The milestone is real and new: **solnix boots on a real NVIDIA GPU instance and
illumos sees the Tesla T4 as a 3D-controller PCIe device with BARs assigned.**
The GPU **does not bind** — not from a firmware register hit mid-attach, but
because solnix has no nouveau kernel driver to attach at all (only virtio-gpu +
AMD-only amdgpu on the kernel side; nouveau is userspace-only and its NVK ICD
does not even link). No solnix T4 GGML_VULKAN number exists, so no parity claim
is made. The closest path to a real solnix GPU number remains **amdgpu on an
AMD instance** (compile-complete, no GSP wall), not the T4.
