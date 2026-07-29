# NetBSD-sourced driver substrate for the P-D2 Wayland blockers on illumos

Research + map task (read/analyze/write, **NO builds**). Honesty rule holds:
this is the hardest substrate work in the whole project and the document is
deliberately pessimistic. Effort is stated in **quarters-scale engineer-time**,
not weeks. Every NetBSD path below was read from a real shallow-sparse checkout
of `github.com/NetBSD/src` (HEAD 2026-07-29, extracted 2026-07-29). The whole
tree was NOT kept; a compact source manifest lives in
`artifacts/netbsd-substrate/source-manifest.txt`.

Read first (and this doc builds on): `docs/desktop-gpu-research.md` (the P-D2
blocker analysis — the R6/R7/R8 wall: input, seat, Wayland-render) and
`docs/prior-art-n-hys-riscv.md` (the CDDL n-hys adoption + the attribution
model we already use for reused BSD/CDDL trees).

---

## Why NetBSD (confirmed against the source)

The maintainer's thesis holds up under inspection:

1. **NetBSD is the most portable BSD**, and its DRM/KMS lives at
   `sys/external/bsd/drm2/`. Its own README (verbatim, first line):
   > "Linux DRM/KMS graphics driver subsystem."
   The tree is Linux-derived (`dist/` holds the imported Linux drivers) and
   NetBSD wraps it in a **BSD-2-clause linux-KPI compat shim**. `README` +
   `prepare-import.sh` document the import ritual (RCS-tagging Linux sources on
   the way in).

2. **The shim IS the reusable pattern.** Bringing Linux-derived DRM to a
   non-Linux kernel is exactly our illumos problem, and NetBSD has already
   solved it once. The shim is two layers:
   - `sys/external/bsd/drm2/linux/` — DRM-specific KPI: **31 `linux_*.c`,
     11,265 LOC**, plus **178 emulated `include/linux/*.h`** headers.
   - `sys/external/bsd/common/linux/` — the shared foundational KPI:
     `linux_work.c` (workqueues), `linux_rcu.c`, `linux_tasklet.c`,
     `linux_srcu.c` — **4 `.c`, 3,044 LOC**, plus 28 more headers
     (`workqueue.h`, `completion.h`, `slab.h`, `gfp.h`, `bitops.h`, …).
   - Plus NetBSD-authored glue in `sys/external/bsd/drm2/drm/` (20 `.c`,
     4,417 LOC) that binds the Linux DRM core to the NetBSD device/cdevsw model.

3. **illumos already does a similar thing, twice**: the ancient `illumos/gfx-drm`
   gate (old i915/radeon KMS ported off a pre-2013 libdrm) is a Linux-DRM-on-
   illumos port of exactly this shape, and the illumos `lx` brand carries a
   large Linux syscall/KPI emulation surface. So illumos is not starting from
   zero on "run Linux-derived kernel code here" — but neither existing effort is
   a modern DRM shim. NetBSD's drm2 is the current, maintained model of the
   thing we want.

4. **NetBSD input = `sys/dev/wscons` + `sys/dev/hid`.** Confirmed. And — key
   finding — **NetBSD has NO evdev**: a full-tree search (`sys -iname '*evdev*'`)
   returned nothing. NetBSD's input event protocol is `wsevent`
   (`struct wscons_event`), not Linux evdev. This directly shapes the input
   verdict below (§2).

### Attribution model (BSD-2 = CDDL-compatible, same as n-hys/CDDL)

Confirmed by reading the shim files: **30 of the 31 `drm2/linux/*.c` files**
carry `Copyright ... The NetBSD Foundation, Inc.` under the **2-clause BSD**
license (the "Redistribution ... 1. retain the above copyright notice ...
2. reproduce ... in the documentation" text; no advertising clause, no
GPL). The 31st is a 2-clause BSD file by an individual NetBSD contributor.
BSD-2 imposes only an **attribution** obligation and is CDDL-compatible for
combination — the same posture we already accept for CDDL n-hys in
`docs/prior-art-n-hys-riscv.md`.

**Adoption discipline (mirror the n-hys model):** keep each adopted NetBSD file's
copyright + license header verbatim; record every adopted path and its NetBSD
RCS id (the `$NetBSD: ...,v ...$` line each file carries) in an attribution
manifest (extend `docs/registry/` the way we track other reused trees); do not
relicense. Note the `dist/` Linux-derived drivers underneath carry their own
upstream licenses (MIT/GPL mix, per-file) — those are the imported Linux
sources, not the NetBSD shim, and their combination terms must be checked
per-driver before shipping any HW driver (this is a licensing sub-task, not a
blocker for the shim work itself).

---

## 1. DRM/KMS core (`sys/external/bsd/drm2/`)

### Architecture (what's actually there)

Three strata, bottom to top:

- **The imported Linux DRM (`dist/`)** — `dist/drm/` is the Linux DRM core
  (`drm_drv.c`, `drm_atomic.c`, `drm_gem.c`, `drm_vblank.c`, `drm_edid.c`,
  `drm_dp_mst_topology.c`, the KMS helper library, TTM, the scheduler) plus the
  HW drivers. **~501,700 LOC total** in `dist/`. Version: the i915 tree
  references `GEN11`/`GEN12`/`INTEL_GEN`, so the base is roughly **Linux ~5.6-era
  DRM** — far newer than gfx-drm's pre-2013 snapshot. This is imported, RCS-
  tagged Linux code; it is NOT the part we rewrite.

- **The linux-KPI shim (the reusable pattern)** — two files-of-record drive it:
  `drm2/linux/files.drmkms_linux` (defines the `drmkms_linux` module,
  `-I$S/external/bsd/common/include -I$S/external/bsd/drm2/include`) and
  `common/conf/files.linux`. What the shim actually emulates, by reading the
  `.c`:
  - **PCI** — `linux_pci.c` (1,158 LOC) maps `struct pci_dev` → NetBSD
    `device_t` + `pci_*` bus API (`pci_dev_dev`, `pci_set_drvdata`,
    `pci_name`, BAR mapping, MSI/MSI-X). This is the single most illumos-
    specific file: it's the bus-attach boundary.
  - **DMA / fences / reservations** — `linux_dma_resv.c` (1,481),
    `linux_dma_fence.c` (1,206), `linux_dma_fence_chain.c`, `linux_dma_buf.c`,
    `linux_sgt.c` (scatter-gather), `linux_io_mapping.c`. The GPU
    synchronization + buffer-sharing core.
  - **Locks** — `linux_ww_mutex.c` (1,134, wound/wait mutexes — GEM needs them),
    `linux_rwsem.c`, plus `common/linux`: `linux_work.c` (workqueues on NetBSD
    kthreads), `linux_rcu.c`, `linux_srcu.c`, `linux_tasklet.c`.
  - **Time / IRQ** — `linux_hrtimer.c`, `linux_irq_work.c`.
  - **Data structures** — `linux_idr.c` (433), `linux_radixtree.c`,
    `linux_xa.c` (xarray), `linux_list_sort.c`.
  - **Misc kernel services** — `linux_kthread.c` (317), `linux_kmap.c`
    (highmem/kmap over NetBSD pmap, 278), `linux_module.c`, `linux_firmware.c`
    (firmware blob loading), `linux_acpi.c`, `linux_i2c.c` (348, DDC/EDID),
    `linux_hdmi.c` (724), `linux_backlight.c`, `linux_notifier.c`,
    `linux_writecomb.c` (write-combining MTRR-equivalent).
  - **178 header shims** (`include/linux/`) providing the compile-time Linux API
    surface: `mm.h`, `pci.h`, `dma-mapping.h`, `scatterlist.h`, `interrupt.h`,
    `spinlock.h`, `mutex.h`, `wait.h`, `sched/*`, `io.h`, `vmalloc.h`,
    `slab.h`(common), etc.

- **NetBSD glue (`drm2/drm/`, 4,417 LOC)** — binds the Linux core to NetBSD's
  device model: `drm_cdevsw.c` (the `/dev/dri/*` character device — `open`
  calls `drm_master_open`), `drm_module.c`, `drm_stub.c`, `drmfb.c`
  (wsdisplay/genfb bridge), `drm_agp_hook.c`, `drm_sysctl.c` (`hw.drm2.*`),
  `drm_vm.c`/`drm_gem_vm.c` (mmap into GPU address space), `drm_lease.c`,
  `drm_lock.c`.

- **HW drivers present** (`dist/drm/`): **i915** (241,874 LOC — the largest,
  attaches as `i915drmkms`), **amdgpu** (164 `.c`) + **amdkfd** (33 `.c` — the
  compute/KFD path, see §6), **nouveau** (739 `.c`), **radeon**, plus `ast`,
  `qxl`, **`virtio`** (virtio-gpu — matters for VM guests), `vmwgfx`, `via`,
  and FDT-attached `sunxidrm`/`tegradrm`/`rkdrm` (ARM SoC — relevant to our
  aarch64/RISC-V targets later).

### Portability of the shim to illumos

**The critical number:** of ~501,700 LOC in `dist/`, the NetBSD-authored,
illumos-relevant surface — the shim + glue we'd actually adapt — is only
**~20,000 LOC** (`drm2/linux` + `common/linux` + `drm2/drm` + `ttm` + `pci`).
That 20k is the real porting cost surface; the 500k of Linux drivers ride on top
largely unmodified once the shim binds.

Where the shim is portable vs. illumos-specific:
- **Portable / mechanical** — the data-structure emulation (`idr`, `radixtree`,
  `xarray`, `list_sort`), the fence/dma-resv machinery, the ww_mutex, the header
  shims. These lean on generic C + a handful of primitives; adapting them to
  illumos synchronization/atomics is tedious but low-risk.
- **illumos-specific rewrite** — the files that touch the host kernel's bus,
  memory, and scheduler models:
  - `linux_pci.c` → must map `struct pci_dev` onto illumos `pci`/`ddi`
    (`pci_config_get*`, `ddi_regs_map_setup`, MSI via `ddi_intr_*`). illumos
    already has this machinery (and gfx-drm did it for i915) but the mapping is
    hand-written per-kernel.
  - `linux_work.c` (workqueue) → illumos `taskq(9F)` is the natural backing.
  - `linux_kthread.c` → illumos `thread_create`/`kthread`.
  - `linux_kmap.c` / `linux_writecomb.c` / `drm_vm.c` → illumos `seg`/`hat`
    memory + `devmap` for mmap; write-combining via illumos MTRR/PAT.
  - `drm_cdevsw.c` → illumos `cb_ops`/`dev_ops` and `/dev/dri/*` via `devfsadm`
    rules instead of NetBSD's cdevsw + static mknod.

**Verdict — ADOPT the drm core + shim as the model; ADAPT the shim's ~20k LOC
to illumos; do NOT rewrite the Linux DRM core.** The right move is to take
NetBSD's drm2 as the working reference for "modern Linux DRM on a non-Linux
kernel" and re-implement its shim boundary against illumos DDI/ku primitives,
exactly the way gfx-drm did for the ancient snapshot but at the current DRM
level and with NetBSD's shim as the proven map of *which* Linux APIs must be
emulated (the 178 headers + 35 `.c` are a checklist we otherwise have to
discover by compile-error archaeology). Bringing up **one** HW driver on top
(i915 for old Intel — see §5 milestone) is the realistic first target;
amdgpu/nouveau are far larger and later.

**Effort:** the shim adaptation is a **multi-quarter (roughly 3–4 quarters for
one engineer to first modeset)** effort: ~20k LOC of shim to port, against a
moving illumos DDI, with the debugging cost of a GPU driver that only tells you
it's wrong by hanging the display. gfx-drm proves the shape is possible; the
delta is doing it at the 5.6-era DRM level. This is ADAPT, not ADOPT-verbatim,
because the illumos-specific files have no NetBSD-to-illumos shortcut.

---

## 2. Input (`wscons` / `hid` / evdev) — the hardest missing piece

Per `docs/desktop-gpu-research.md` this is "the single hardest missing piece."
The NetBSD source makes it harder, not easier, and I'll be blunt about why.

### NetBSD's input path (what's actually there)

- **`sys/dev/wscons`** — the workstation console: `wsdisplay` (framebuffer +
  VT emulation), `wskbd`, `wsmouse`, `wsmux`, and the event layer
  `wsevent.c`/`wseventvar.h`. Applications read **`struct wscons_event`**
  (`wsconsio.h`) from `/dev/wskbd*` / `/dev/wsmouse*` — a NetBSD-native event
  format, NOT evdev. ~18,455 LOC across wscons+hid.
- **`sys/dev/hid`** — `hid.c` (report parsing), `hidkbd.c`, `hidms.c` (mouse),
  `hidev.c`, `uhid.c` (raw userspace HID). Feeds into wsmux as wskbd/wsmouse.
- **`sys/dev/wscons/linux_keymap.c`** exists — but it is a *keymap translation
  table* (mapping to Linux keycodes for a `uhid`/`ikbd` variant), **not** an
  evdev device emulation. It does not give you `/dev/input/eventN`.

### The problem for Wayland

Wayland's reference input library is **libinput**, which reads **Linux evdev**
(`/dev/input/event*` with the `EV_KEY`/`EV_ABS`/`EV_REL` protocol and the
`libudev` device enumeration). NetBSD offers neither evdev nor udev — so
NetBSD's input path is **not directly reusable as a libinput backend**. This is
unlike DRM, where the *userland ABI is already the Linux ABI* (§3). For input,
NetBSD adopted its own protocol and never adopted evdev, so there is no
"NetBSD evdev shim" to lift.

Contrast: **FreeBSD** *does* have an `evdev`/`cuse`-backed input layer and a
libinput port precisely because it built evdev emulation. NetBSD did not. So on
the input axis specifically, NetBSD is the *weaker* donor.

### The three candidate paths (honest assessment)

1. **Port an evdev-emulation + libinput onto illumos, feeding from illumos's
   existing input (or wscons-if-adopted).** This is the "real" path: write an
   evdev-compatible character device (`/dev/input/event*`) that translates from
   illumos's kbd/mouse `streams`/`usba` HID sources into `struct input_event`,
   provide a `libudev`-shim so libinput can enumerate, then port libinput. Every
   piece is net-new on illumos. **Verdict: ADAPT/illumos-native-rewrite, and it
   is the biggest single unknown in the whole substrate.**

2. **Adapt illumos's existing input rather than importing wscons.** illumos
   already has keyboard/mouse via `conskbd`, `kbtrans`, `usbkbm`/`usbms`, and
   the `/dev/kbd` + `/dev/mouse` (Sun `Ms`/`Vuid` event) nodes plus X's own
   input drivers. The lazy path is **not** to import NetBSD wscons (that would
   mean replacing illumos's console model — huge, invasive, and pointless) but
   to write a **thin evdev shim over illumos's existing HID/kbd/mouse streams**,
   then libinput on top. This reuses what illumos already ships and confines the
   new code to the evdev-translation + udev-enumeration shim + libinput port.

3. **Avoid libinput entirely: X-nested / winit path.** Per the research doc's
   COSMIC analysis, a compositor can run nested in Xorg and take input from the
   X server, sidestepping evdev/libinput. This unblocks a *demo* but is not a
   real standalone Wayland session.

### Verdict + effort

**libinput-over-NetBSD-evdev is NOT feasible, because NetBSD has no evdev to
sit on** — that's the blunt finding. The feasible real path is **path 2:
illumos-native evdev+udev shim over illumos's existing HID/kbd/mouse, then port
libinput** (libinput is portable C over evdev + a small udev-interface; the port
is tractable *once evdev + udev-enumeration exist*). NetBSD contributes
**reference, not code**, here: its `hid.c` report parser and wskbd/wsmouse event
semantics are a useful model for what a translation layer must produce, and its
`linux_keymap.c` is a starting keycode table. But this rung is **BLOCKED on
net-new illumos work**; NetBSD does not shortcut it.

**Effort: the largest and riskiest rung — 3–5+ quarters.** evdev char-device +
input_event translation (~1–2 quarters), a `libudev` enumeration shim (~1
quarter, or reuse an existing libudev-shim if one is portable), then the
libinput port + calibration/quirks (~1–2 quarters, and the quirks/calibration
tail is long — touchpads especially). Realistically de-risk by shipping the
X-nested path (path 3) first for any compositor demo, and treating standalone
libinput as its own tracked sub-project.

`ponytail`: NONE. (Per instruction — no simplification-corner markers written.)

---

## 3. GBM / EGL / DRM render backend

### How NetBSD wires GBM/EGL to drm2 — and why it "just works"

The decisive finding is in `share/man/man4/drm.4`: NetBSD's drm2 exposes
**`/dev/dri/render*`** and **`/dev/dri/card*`** with the standard Linux DRM
`ioctl(2)` UAPI (GEM buffer alloc, dumb buffers, prime/dma-buf FD export, KMS
modeset ioctls). Because the **userland kernel ABI is the Linux DRM ABI**,
**Mesa's GBM and EGL DRM/GBM platform backends run essentially unmodified** on
NetBSD — Mesa talks libdrm ioctls to `/dev/dri/*`, and NetBSD's drm2 answers
them. NetBSD does not port GBM/EGL specially; it makes the kernel speak the ABI
that upstream Mesa GBM/EGL already targets. `drm.4` even documents X creating
`/dev/dri/card0` and using drm automatically.

This is the same lever that makes the DRM adoption worthwhile: **get illumos's
drm shim to expose the Linux DRM UAPI on `/dev/dri/*`, and the entire
Mesa-GBM/EGL/DRM userland stack becomes a rebuild, not a port.**

### What illumos needs

Per `docs/desktop-gpu-research.md` Q3, OI's Mesa 21.3.9 is built
`-Dplatforms='x11' -Dllvm=false -Dgbm=enabled -Degl=enabled`. So GBM and EGL are
*already compiled*, but bound to X11 and with only softpipe (no llvmpipe). To
get a Wayland render backend illumos needs, in order:

1. **A `/dev/dri/*` Linux-DRM-UAPI node** — the output of §1's shim work. This
   is the hard prerequisite; without a modern DRM node, GBM has no kernel to
   talk to. (gfx-drm's ancient node speaks an old UAPI — possibly enough for
   old i915 GBM, worth a spike, but not for anything modern.)
2. **Rebuild Mesa with `-Dplatforms='x11,wayland'` + `-Dgbm=enabled`** so
   EGL/GBM expose the Wayland platform and the GBM device path. gbm/egl already
   build on illumos, so this is a Meson flag flip + fixing the illumos-specific
   compile breakage the wayland/gbm platforms surface (moderate).
3. **`-Dllvm=true` for llvmpipe** — needs LLVM on illumos first; big usability
   win but independent of the DRM path (a compositor can present GBM/DRM HW
   buffers with softpipe or even a HW i915 gallium driver).

### Verdict

**ADOPT the ABI, ADAPT (rebuild) Mesa; no GBM/EGL port needed.** GBM/EGL are
"free" once §1 delivers a Linux-DRM-UAPI `/dev/dri/*` — that's the whole payoff
of choosing NetBSD's Linux-ABI-preserving shim over a bespoke interface. The
Mesa side is a **rebuild + platform-flag + illumos-fixups** effort (**~1
quarter**), gated entirely on §1. Independently, **llvmpipe (LLVM-on-illumos +
Mesa rebuild)** is the software-render quality lever and is worth doing in
parallel (**~1–2 quarters**, per the research doc's R1b).

---

## 4. Seat / session (DRM-master + input arbitration)

### NetBSD's approach

**NetBSD has no seatd and no logind** (full-tree search for `*seat*`: nothing).
Instead, `drm2/drm/drm_cdevsw.c` calls **`drm_master_open()`** when
`/dev/dri/card*` is opened — the X server (running as root) opens the card node,
becomes DRM master, and holds it. Display-register access from userland requires
the `INSECURE` kernel option (per `drm.4`). Input arbitration is implicit: the X
server owns the wscons/hid devices while active. There is no multi-seat, no
session hand-off daemon — it's the classic single-server-holds-everything model.

### Minimal illumos seat shim

For a single-user illumos Wayland box we do **not** need seatd/logind's full
multi-session machinery. The minimal viable seat is:
- **DRM master**: the compositor opens `/dev/dri/card0` and becomes master via
  the same `drm_master_open` path the illumos DRM shim (§1) must implement
  anyway — no extra component.
- **Input open**: the compositor opens the evdev nodes (§2) directly.
- **A `libseat` "builtin" backend** — libseat (the small seat-abstraction used
  by wlroots/sway) has a **builtin backend that opens devices directly when the
  process is root/privileged**, needing no seatd daemon. Porting libseat's
  builtin path (tiny, portable C) gives compositors the seat API they expect
  without a session daemon. That's the lazy correct choice: adopt the interface,
  skip the daemon.

### Verdict

**ADAPT — a thin `libseat`-builtin shim, no seatd/logind daemon.** NetBSD proves
you don't need a seat daemon for a single-server model; illumos can do the same.
DRM-master arbitration falls out of §1's cdevsw work; input open falls out of
§2. The only net-new piece is a **libseat builtin backend port (~a few weeks,
call it 0.25–0.5 quarter)**, and even that is optional if we target a compositor
that can open devices directly. Multi-seat/fast-user-switching is explicitly out
of scope. **Not a blocker.**

---

## 5. Ordered adoption plan — to a minimally-viable Wayland substrate

Each rung marked **ADOPT-NetBSD** / **ADAPT** / **illumos-native-rewrite** /
**BLOCKED**, with quarters-scale effort. Build strictly bottom-up. Total honest
horizon to a usable standalone Wayland session: **~2.5–3.5 years of focused
single-engineer effort**; the first *visible* milestone is much sooner.

```
[S0] Spike: does gfx-drm's ancient /dev/dri node already do a modeset on
     old Intel? (validate the /dev/dri UAPI lever cheaply before big work)   ADAPT      ~0.25q
      └ if yes, GBM-on-old-i915 may be reachable without the full shim first.

[S1] DRM shim: adapt NetBSD drm2's linux-KPI (drm2/linux + common/linux,
     ~20k LOC) to illumos DDI/taskq/kthread/seg-hat; bind drm core via a
     drm_cdevsw over illumos cb_ops; expose /dev/dri/{card,render}*.
     Bring up EXACTLY ONE HW driver: i915 (old Intel).                       ADAPT      ~3-4q
      └ MILESTONE A (first realistic visible win): first DRM/KMS MODESET on
        illumos on old Intel via i915 — a lit framebuffer from a modern-ABI
        drm node. This is the keystone; everything above depends on it.

[S2] Mesa rebuild: -Dplatforms='x11,wayland' -Dgbm=enabled -Degl=enabled
     against the S1 /dev/dri node. GBM/EGL come "free" (Linux ABI).          ADAPT      ~1q
      └ (parallel) llvmpipe: LLVM-on-illumos + -Dllvm=true for usable SW GL. ADAPT      ~1-2q
      └ MILESTONE B: eglinfo/GBM allocates + renders a buffer on the S1 node.

[S3] Input: illumos-native evdev char-device + input_event translation over
     existing illumos HID/kbd/mouse; libudev enumeration shim; port libinput.
     (NetBSD = reference only; no evdev to lift.)                            illumos-native-rewrite  ~3-5q
      └ MILESTONE C: libinput enumerates + reports events on illumos. THE WALL.

[S4] Seat: libseat builtin backend (no seatd daemon); DRM-master via S1.     ADAPT      ~0.25-0.5q

[S5] Compositor, software-SHM first: stand up a minimal wlroots-shm or
     weston-pixman compositor that renders via SHM (no DRM, no libinput -
     input via S3 when ready, or X-nested for an early demo).                ADAPT      ~1q
      └ MILESTONE D: weston-terminal renders in a SW compositor on illumos.

[S6] Compositor, DRM/GBM present path: same compositor now scans out via
     the S1 DRM node + S2 GBM + S3 libinput + S4 seat.                       ADAPT      ~1-2q
      └ MILESTONE E: a standalone TTY Wayland session on old Intel. The goal.
```

**Reading the plan:** the sequence the maintainer named —
**DRM modeset (S1/Milestone A) -> GBM/EGL (S2) -> libinput-over-evdev (S3) ->
software-SHM-then-DRM Wayland compositor (S5->S6)** — is exactly right and is the
critical path. The **first realistic milestone is Milestone A: a DRM/KMS modeset
on illumos on old Intel via i915** — that's the keystone that turns the whole
Mesa/GBM/EGL userland from "port" into "rebuild." The **input rung (S3) is the
wall** and the biggest schedule risk; de-risk by shipping the SW-SHM/X-nested
compositor (S5) for a proof-of-life while S3 grinds. Realistic honest estimate to
Milestone E (standalone session on old Intel): **~2.5–3.5 years single-engineer**,
dominated by S1 (DRM shim) and S3 (input).

**What NOT to do (lazy discipline):** do not import NetBSD wscons wholesale (it
would fight illumos's console model); do not rewrite the 500k-LOC Linux DRM core
(adapt the 20k-LOC shim boundary only); do not build seatd (libseat builtin
suffices); do not chase amdgpu/nouveau before i915 modeset works.

---

## 6. GPU / CUDA note — what NetBSD does and does NOT unlock

**Confirmed from the source:** NetBSD's drm2 carries **amdgpu** (164 `.c`,
attaches per `drm.4`), **amdkfd** (33 `.c` — the AMD compute/KFD path, including
`kfd_chardev.c`, `cwsr_trap_handler_gfx{8,9,10}.asm`), **nouveau** (739 `.c`),
**radeon**, and **virtio-gpu**. So the HW-GL / (maybe) Vulkan / OpenCL-ROCm
gateway drivers *exist in the NetBSD tree*.

**But there is NO CUDA — and no BSD has one.** CUDA requires NVIDIA's
*proprietary* kernel driver + closed userland; **nouveau is the open reverse-
engineered NVIDIA driver, not CUDA**, and NVIDIA ships no CUDA kernel driver for
any BSD (nor for modern illumos — see `docs/desktop-gpu-research.md` Q3). amdkfd
being present means the *AMD* compute substrate (ROCm-adjacent) is theoretically
reachable far downstream if amdgpu+amdkfd were ever brought up on illumos — but
that is many quarters past even Milestone E and is not on any near-horizon path.

**Blunt bottom line:** adopting NetBSD's drm2 advances illumos toward **HW
OpenGL (via i915/radeon/amdgpu once ported)** and *possibly* **Vulkan** (Mesa's
anv/radv target the same DRM UAPI — a rebuild question, not a kernel-driver
question, once the drm node exists). It does **NOT** unlock **CUDA** — that stays
**BLOCKED**, permanently, absent an NVIDIA vendor port that will not happen.
**LLM hosting stays CPU-inference-only** (llama.cpp/bitnet.cpp on CPU +
OpenBLAS), exactly as `docs/desktop-gpu-research.md` and roadmap T3.3 already
state. NetBSD moves the *display/GL* needle; it does not move the *CUDA* needle
at all.

---

## Report summary (as requested)

- **DRM/KMS adopt-verdict:** ADOPT NetBSD drm2 as the model; **ADAPT its ~20k-LOC
  linux-KPI shim + glue** (`drm2/linux` 31×.c/11,265 LOC, `common/linux`
  4×.c/3,044 LOC, `drm2/drm` 4,417 LOC, 178+28 header shims) to illumos
  DDI/taskq/kthread/seg-hat; do NOT rewrite the 500k-LOC Linux DRM core.
  illumos gfx-drm + lx prove the shape is possible; delta is doing it at 5.6-era
  DRM. Portability: data-structure/fence shims mechanical; `linux_pci.c`,
  `linux_work.c`, `linux_kmap.c`, `drm_cdevsw.c` are the illumos-specific
  rewrites. **~3–4 quarters to first modeset.**
- **Input verdict (the hardest piece):** **libinput-over-NetBSD-evdev is NOT
  feasible — NetBSD has no evdev at all** (it uses wsevent, not evdev). The real
  path is an **illumos-native evdev + libudev-enumeration shim over existing
  illumos HID/kbd/mouse, then a libinput port**; NetBSD contributes reference
  (its `hid.c` parser, wskbd/wsmouse semantics, `linux_keymap.c`) but no code.
  **THE WALL — ~3–5+ quarters, biggest schedule risk.**
- **GBM/EGL / mesa-rebuild verdict:** **ADOPT the ABI, rebuild Mesa.** NetBSD
  exposes `/dev/dri/{card,render}*` with the standard Linux DRM UAPI, so Mesa
  GBM/EGL run unmodified — once §1 delivers the drm node, GBM/EGL are a
  **`-Dplatforms='x11,wayland'` + illumos-fixups rebuild (~1q)**, plus optional
  llvmpipe (LLVM-on-illumos, ~1–2q).
- **Seat verdict:** **ADAPT a thin `libseat` builtin backend, no seatd/logind.**
  NetBSD has no seat daemon (X server holds DRM master via `drm_master_open` on
  card open); illumos does the same. **Not a blocker, ~0.25–0.5q.**
- **Ordered substrate plan + first milestone:** S0 spike -> **S1 DRM shim +
  i915 => Milestone A: first DRM/KMS MODESET on illumos on OLD INTEL** (the
  keystone, ~3–4q) -> S2 GBM/EGL -> S3 libinput-over-evdev (the wall) -> S4 seat
  -> S5 SW-SHM compositor -> S6 DRM/GBM present => **Milestone E: standalone
  Wayland session on old Intel.** Honest horizon to Milestone E:
  **~2.5–3.5 years single-engineer**, dominated by DRM shim + input.
- **CUDA-stays-blocked confirmation:** CONFIRMED. NetBSD drm2 has amdgpu +
  amdkfd + nouveau + virtio-gpu, so HW OpenGL / maybe Vulkan (Mesa rebuild, same
  UAPI) become downstream-reachable — but **no CUDA on any BSD** (nouveau ≠ CUDA;
  no NVIDIA kernel driver). **CUDA BLOCKED permanently; LLM stays CPU-only.**

**Confirmations:** BSD-2 attribution model noted (30/31 shim files BSD-2 NetBSD
Foundation; keep headers + `$NetBSD$` RCS ids verbatim, track in
`docs/registry/`, same discipline as CDDL n-hys); no `ponytail:` markers written
(grep-clean); NO git commit; wrote `docs/netbsd-driver-substrate.md` and
appended `docs/progress.md`; source manifest kept small in
`artifacts/netbsd-substrate/` (16K — no gigabytes retained; the 286M sparse
checkout was extracted then discarded).
