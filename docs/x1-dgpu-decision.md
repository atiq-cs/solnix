# X1 discrete-GPU decision: NVIDIA GP107M (Pascal, 10de:1c8c)

The X1 ("dixi") has two GPUs: the Intel iGPU (UHD 630, 8086:3e9b, being brought up
live by the i915 stream) and an **NVIDIA GP107M / GTX 1050 Ti Mobile (10de:1c8c,
Pascal)**. The maintainer wants solnix to drive **either or both** GPUs. This doc
decides what to do with the NVIDIA part, with a measured compile-only probe behind
the recommendation.

Scope note (per the brief and AGENTS.md): this is analysis + design + a **compile-only**
probe. Nothing was loaded into the live kernel — no `add_drv`, `modload`, or reboot.
The i915 stream owns the live kernel; its state was only read. All probe builds ran on
dixi with the `solnix-dev` gcc against the illumos gate proto, nothing on floki.

Every claim is tagged **REAL** (measured, with the command/file) or **PLANNED**
(an estimate for work not done).

---

## TL;DR recommendation

**Near term: option (A) — leave the NVIDIA dGPU on `vgatext`, spend the effort on
i915.** It is the single-GPU display path the X1 already has, costs nothing, and
i915 is the GPU that matters for this machine.

**On the program: option (C) — the i915-primary + nouveau-display/offload hybrid — is
the right both-GPU answer, and it is far cheaper than it looks because the
compile-only probe shows a nouveau *display-only* driver reuses ~94% of the exact
linux-KPI shim the i915 route is already building.** The marginal cost over "i915
alone" is the nouveau MMIO modeset path cribbed onto a shim that already exists, not a
second driver stack from scratch.

**Option (B) — nouveau display-only as the *only* dGPU use — is tractable but not
worth doing on its own.** A second display output driven at Pascal boot clocks, with
no acceleration, buys very little on a laptop whose eDP + external outputs are already
driven by the iGPU. Its value is almost entirely as the first half of (C).

The reason the recommendation isn't just "(A) forever": the maintainer explicitly wants
both-GPU capability, and the probe below shows (C) is a bounded increment on i915, not a
new mountain. So: **(A) now, (C) as the both-GPU target, (B) only as a step inside (C).**

---

## The hardware and its hard limit (REAL)

| fact | value | source |
|---|---|---|
| dGPU | GP107M / GTX 1050 Ti Mobile, Pascal, `10de:1c8c` rev a1 | `prtconf -v` on dixi |
| current binding | **`vgatext` instance 1**, `/dev/fb1` → `display@0:text-1` | `prtconf -D`, `ls -l /dev/fb*` on dixi (READ-ONLY) |
| BARs | BAR0 `0xa3000000` 16 MB (MMIO), BAR1 `0x60000000` 256 MB, BAR3 32 MB | `prtconf -v` |
| chipset in nouveau | `nv137_chipset` ("GP107") | `nvkm/engine/device/base.c:2211,3336` |
| reclocking | **none** — `nv137_chipset` has **no `.clk` entry** (unlike GP10B/Tegra) | `nvkm/engine/device/base.c` nv137 block |
| PMU firmware | **none** — `gp102_pmu_fwif[] = { gm200_pmu_nofw }` | `nvkm/subdev/pmu/gp102.c:50` |

Correction to the route doc's framing: the dGPU is **bound to `vgatext` today, not
unbound**. "Option (A)" below means *leave it on vgatext* (the status quo), not actively
unbind it. The i915 stream's own notes (`/tmp/streamE-progress.txt`) already caught this.

The hard limit: **Pascal has no open reclocking.** With no `.clk` subdev and a
no-firmware PMU, nouveau can only run GP107 at the clocks the VBIOS set at boot. There is
no signed PMU firmware in linux-firmware to raise them (this is the public explanation
nouveau's maintainers give; not re-measured here). So under nouveau the GP107 is a
**display controller and a slow render device, never an accelerator worth having.** This
is not a solnix limitation — it is true on Linux too.

---

## The three options

### (A) Leave NVIDIA on `vgatext` (status quo) — RECOMMENDED near term

**What it takes on illumos:** nothing. The dGPU already binds `vgatext` at instance 1.
The i915 stream drives the real display on the iGPU.

**What it buys:** a single, working display path on the iGPU. Zero new code, zero new
firmware, zero new GPL exposure. The dGPU sits idle (and, on a laptop, draws power — a
runtime-PM "turn the dGPU off" story is a separate, later nicety).

**GPL exposure:** none.

**Firmware:** none.

### (B) nouveau display-only (KMS modeset at boot clocks, no accel) — tractable, low value alone

**What it takes on illumos:** a KMS-only nouveau driver (modeset + dumb framebuffer, no
GEM-accel, no command submission) ported onto the C1 DRM framework, over the linux-KPI
shim the i915 route is already building. The probe below sizes it.

**What it buys:** the dGPU's display outputs become usable (a second/alternate output
head), driven at Pascal boot clocks. On this laptop the eDP panel and the external DP/HDMI
are already reachable from the iGPU, so a *second* independent output is marginal. No
acceleration.

**GPL exposure:** clean for display-only. nouveau's display path is **MIT** (see the GPL
section). It needs **no NVIDIA-signed firmware** (also below). The shim is OpenBSD
PD/ISC, reused. The DRM core is solnix's own C1.

**Firmware:** **none for display.** The display engine (`disp`/`dispnv50`) issues no
`request_firmware` (REAL, negative control below). `devinit` uses the on-board VBIOS.

### (C) Hybrid: i915 primary + nouveau PRIME render-offload — RECOMMENDED as the both-GPU target

**What it takes on illumos:** (B) plus cross-driver dma-buf import and a compositor that
can pick a render node per client. The symbol-scope mapfile (committed) lets i915 and
nouveau coexist as two DRM drivers in one kernel. The design is in the hybrid section.

**What it buys:** the maintainer's "either or both" — i915 drives the panel; nouveau
drives the dGPU outputs and can be a PRIME render offload target. On Pascal the offload is
*at boot clocks*, so it is a correctness/plumbing win, not a performance one. The real
performance payoff of the hybrid machinery arrives on a machine whose dGPU *does* clock
(an AMD box, or a future NVIDIA with GSP), where the same i915+second-driver plumbing
applies unchanged.

**GPL exposure:** same as (B) for the nouveau side; the cross-driver dma-buf is C1's own
PRIME (solnix code), and Linux's PX/ATPX power-switch (`amdgpu_atpx_handler.c`,
GPL-2.0-only) is **not** nouveau's path and is not used.

**Firmware:** none for the display + offload-plumbing path; accel (if ever wanted) would
need the gp107 blobs — see the firmware section.

### Per-option table

| | (A) vgatext | (B) nouveau display-only | (C) i915 + nouveau hybrid |
|---|---|---|---|
| **cost on illumos** | 0 | nouveau KMS modeset on the i915 shim (PLANNED ~6–10 wk, see probe) | (B) + cross-driver dma-buf import + compositor render-node select (PLANNED +3–5 wk, shares the MESA render-node work) |
| **buys** | one working display (iGPU) | the dGPU's outputs, at boot clocks, no accel | either-or-both GPUs; nouveau as a PRIME offload node (at boot clocks) |
| **GPL exposure** | none | **none** — nouveau core is MIT; shim is OpenBSD PD/ISC; DRM core is C1 | **none** — PX/ATPX (GPL) not used; dma-buf is C1's own |
| **firmware** | none | **none for display** (disp engine issues no `request_firmware`) | none for display/offload; accel-only would need gp107 blobs (redistributable) |
| **perf** | n/a | boot clocks (slow) | boot clocks on the dGPU; the plumbing is the reusable asset |
| **both-GPU?** | no | the dGPU alone, display only | **yes** |

---

## The GPL / licence story (REAL)

Verified with `src/drm-port/license-audit.sh` on the Linux nouveau tree
(`drivers/gpu/drm/nouveau`, master `6c377d19`), 1212 `.c`/`.h` files:

```
drivers/gpu/drm/nouveau  total=1212  PERM=1157  PD=0  DUAL=1  GPL=0  NONE=54
```

This **confirms the survey's count** (1157 PERM, 0 GPL-only, 54 NONE). Breaking the 1212
down by the actual notice in the first 60 lines:

| notice | files | meaning |
|---|---:|---|
| full MIT grant text ("Permission is hereby granted, free of charge…") | **762** | MIT, usable, header kept verbatim |
| `SPDX-License-Identifier: MIT` | **395** | MIT |
| `SPDX-License-Identifier: GPL-2.0 OR MIT` | **1** | dual — used under MIT (`include/nvif/log.h`) |
| no marker at all | **54** | all headers; GPL-2.0-only by Linux default (rule 1) until each is traced |

**The load-bearing finding: nouveau is overwhelmingly MIT** (Red Hat / Ben Skeggs), unlike
most of the Linux DRM tree, which is GPL-2.0 and forced the i915/amdgpu routes to rely on
OpenBSD's permissive rewrites. nouveau carries its MIT grant in-tree. So the base-licence
rule ("no GPL-only file enters the solnix kernel or base libraries") is satisfied *by
nouveau's own headers*, with two caveats:

1. **The 54 no-marker files** are all internal headers (e.g. `include/nvkm/subdev/gsp.h`,
   `dispnv50/disp.h`). Inside a Linux tree, no notice = GPL-2.0-only by default. Each must
   be traced to an MIT sibling or declared GPL-and-excluded. This is the same provenance
   check the route doc flagged (PLANNED, only needed if nouveau is pursued). Most are small
   struct/define headers that the MIT `.c` files already carry equivalent copyright on.
2. OpenBSD ships **no nouveau** (its DRM tree is i915 + display + ttm + scheduler + clients
   only — REAL, `ls` on the OpenBSD 37a498de tree on dixi). So nouveau cannot be cribbed
   from a permissive BSD port the way i915 was. It is cribbed from Linux directly — which is
   fine *because* nouveau is MIT, not because a BSD laundered it.

**No GPL enters the base in (B) or (C).** The modeset path is MIT; the shim is OpenBSD
PD/ISC (reused from the i915 route); the DRM core is solnix's own C1; the dma-buf/PRIME is
solnix's own C1c. Linux's GPL-only PX/ATPX power switch is an amdgpu/laptop-mux file, not
on nouveau's path.

---

## The firmware story (REAL)

The decisive question for display-only: does Pascal need NVIDIA-signed firmware *just to
modeset*? **No.**

| subsystem (GP107 / nv137) | needs firmware? | source |
|---|---|---|
| `disp` (`gp102_disp_new`, gf119 lineage) | **no** — 0 `request_firmware` across 32 disp files | negative control: `grep -rc request_firmware nvkm/engine/disp` = 0 |
| `dispnv50` (the KMS atomic layer) | **no** | same |
| `devinit` (`gm200_devinit`) | no — uses on-board VBIOS | `nvkm/subdev/devinit/gm200.c` |
| `pmu` (`gp102_pmu`) | **no** (`gm200_pmu_nofw`) → but therefore no reclock | `nvkm/subdev/pmu/gp102.c:50` |
| `gr` (graphics, `gp107_gr_new`) | **yes** — `nvidia/gp107/gr/{fecs,gpccs}_*.bin` | `nvkm/engine/gr/gp107.c:67` (positive control: 12 refs) |
| `acr` + `sec2` (secure boot for gr) | **yes** — `nvidia/gp102/acr/*.bin`, `.../sec2/*.bin` (GP107 shares gp102) | `nvkm/subdev/acr/gp102.c:178`, `nvkm/engine/sec2/gp102.c:227` |

So: **display is firmware-free; acceleration (the `gr` engine) needs the signed gp107/gp102
blobs.** Those blobs are redistributable (linux-firmware `WHENCE` carries an NVIDIA
redistribution grant) and would ship as a separate `nouveau-firmware` package the way the
amdgpu route plans `amdgpu-firmware` — never bundled into the driver. But since Pascal
can't reclock, the accel engine isn't worth lighting up anyway. **Display-only (B)/(C)
avoids the firmware question entirely.**

---

## The compile-only probe (REAL, dixi — nothing loaded)

Modeled on the i915 obsd-compat probe (`src/drm-port/i915/probe-headers.sh`): compile each
nouveau source against the illumos gate proto with nouveau's own `-Iinclude` paths; stub
each still-missing external header empty and retry until the header wall is cleared; the
residual errors are the real KPI gap. A minimal `<linux/types.h>` seed provides the integer
typedef floor (the measurement floor, not the port). Harness + outputs:
`/var/tmp/streamNOUVEAU/` on dixi.

**Subset probed: the GP107 display-only path, 418 files / 86,703 LOC** — `nvkm/core` (16),
`nvkm/engine/disp` (32), `nvkm/engine/device` (3), `dispnv50` (52), the display subdevs
(`nvkm/subdev/*`, 297), and the top-level DRM glue (`nouveau_*.c`, 18).

Results:

| metric | value |
|---|---|
| files that cleared the header wall (parse reaches the KPI gap, no runaway) | **418 / 418** |
| distinct external headers that had to exist | **105** (98 `linux/`, 2 `soc/tegra`, 2 `acpi`, 1 `video`, 1 `trace`, 1 `asm`) |
| `drm/` headers that had to be stubbed | **0** (nouveau's own `include/` + the real `include/drm` + the C1 DRM core satisfy them) |
| residual KPI error lines (the Linux-KPI identifier gap) | **71,389** |

For comparison, the i915 obsd-compat baseline before its shim was 129,793 error lines over
377 files; nouveau's 71,389 over 418 is the **same kind** of gap (Linux types + functions),
smaller because the display subset is leaner than full i915.

Top gaps (what the shim must supply):

* **types:** `uint32_t`, `uint64_t`, `spinlock_t`, `refcount_t`, `ktime_t`, `pgprot_t`,
  `vm_fault_t`, `wait_queue_head_t` — standard Linux types; one real `<linux/types.h>`
  resolves the bulk (the 7927 `uint32_t` hits are an artifact of the minimal seed).
* **functions:** `kfree`, `mutex_init`, `ioread32`, `WARN_ON`, `list_for_each_entry`,
  `container_of`, `IS_ERR`, `spin_lock_init`, `kzalloc` — the exact C1 `linux-compat`
  family (kref/idr/mutex/spinlock/slab/workqueue/kthread/completion/list/rbtree/xarray).

### The decisive measurement: the shim is already (mostly) built

Of the **98 `linux/` headers** nouveau's display path needs, **92 are already present in
OpenBSD's `include/linux`** (the PD/ISC linux-KPI shim the i915 obsd-compat route brought to
illumos — REAL, `comm` against the OpenBSD 37a498de tree on dixi). Only **6 are new**:

```
const.h  leds.h  list_lru.h  regulator/consumer.h  reset.h  sched/signal.h
```

and of those, `leds.h`, `regulator/consumer.h`, and `reset.h` are stubs for subsystems the
display path doesn't actually exercise (LEDs, power regulators, SoC resets — Tegra/embedded
concerns). `const.h`/`sched/signal.h`/`list_lru.h` are small.

**So a nouveau display-only driver reuses ~94% of the exact linux-KPI shim the i915 route is
already building.** The nouveau-specific work is not "write a shim" — it is "crib nouveau's
MMIO modeset path (`disp` + `dispnv50`) onto the shim i915 already needs, plus the C1 DRM
core and the symbol-scope mapfile." That is why (C) is a bounded increment on i915, not a
second stack.

### Cost estimate (PLANNED)

Given the shim is shared and firmware-free for display:

* **(B) nouveau KMS modeset:** ~6–10 engineer-weeks on top of the i915 shim — the
  `disp`/`dispnv50` modeset path re-glued to illumos `dev_ops`, GP107 `devinit`/VBIOS parse,
  DP-AUX/GMBUS on illumos interrupts, dumb-fb through C1 GEM, and the 54 no-marker headers'
  provenance pass. No firmware, no reclock, no GEM-accel.
* **(C) hybrid delta:** ~+3–5 weeks for cross-driver dma-buf import and the compositor
  render-node selection — but this overlaps the MESA stream's render-node work (see
  dependency note), so most of it is shared, not nouveau-specific.

These assume the i915 shim lands first (it carries the 92 shared headers). Standalone, (B)
would also have to build that shim — which is why doing (B) *before or without* i915 is the
wrong order.

---

## Hybrid (C) design

The symbol-scope mapfile (committed) already lets two DRM drivers coexist in one illumos
kernel, so i915 + nouveau as separate modules is mechanically possible. The render-offload
mechanics:

### Node layout

* i915 is DRM master on the iGPU → `/dev/dri/card0` + `renderD128`, drives the eDP panel and
  the external outputs wired to the iGPU.
* nouveau binds the GP107 → `/dev/dri/card1` + `renderD129`, drives the dGPU-wired outputs
  (if any are routed to the NVIDIA part on this chassis) and offers a second **render node**.
* Both must link against the symbol-scope mapfile so their identically-named DRM-core
  symbols don't collide (the same requirement the i915 ATTACH-PLAN already states).

### Render offload (DRI_PRIME / Wayland dmabuf)

PRIME render offload = a client renders on the dGPU's render node, then the buffer is shared
to the primary (iGPU) node for scanout. On illumos this rides C1's PRIME:

1. **The shared fd mechanism exists.** C1c's `drm_prime.c` already exports and imports GEM
   buffers as fds over `falloc` + a spec-vnode (DESIGN.md D.1), passed between processes by
   `SCM_RIGHTS` exactly like Linux dma-buf — this is what a compositor needs to hand a
   dGPU-rendered buffer to the iGPU for display. (REAL: `PRIME_HANDLE_TO_FD` /
   `PRIME_FD_TO_HANDLE` + the per-export minor space are in `drm_prime.c`.)
2. **The new piece is cross-driver import.** Today C1's import re-derives a handle within one
   driver instance. Hybrid offload needs the *importer* (i915) to map the *exporter's*
   (nouveau's) pages into its own GTT as a scatter-gather buffer — the scatter-gather import
   path. This is the same importer work the amdgpu route notes for i915+amdgpu PRIME; it is
   written once in the C1 PRIME layer and serves any pair.
3. **The compositor side (Wayland).** cosmic-comp through smithay already has multi-GPU
   support (`render::GlMulti`, `BackendData::Kms` — REAL, `docs/cosmic-comp-illumos-finding.md`).
   smithay's KMS backend enumerates render nodes and composites a client's dGPU buffer onto
   the primary. The per-client "render on card1, scan out on card0" selection is the
   `DRI_PRIME`/`GlMulti` path — compositor + Mesa work, not kernel work.

### What this depends on (DO NOT duplicate)

* **The MESA stream's render-node work.** The `GlMulti`/EGL render-node selection and the
  Mesa-side dmabuf import/export are owned by the MESA/compositor stream. The hybrid needs
  that work; it does not re-implement it. This doc flags the dependency: hybrid (C) is
  "nouveau KMS (B) + C1 cross-driver sg-import + the MESA render-node path," and the middle
  piece is the only kernel-new part.
* **i915 landing first.** (C) is i915-primary; it has no meaning until i915 drives the panel.

### The honest performance caveat

On *this* GPU the offload runs at Pascal boot clocks, so DRI_PRIME to the dGPU is slower than
rendering on the iGPU for most work — the hybrid's value here is capability and plumbing, not
speed. The plumbing (two coexisting DRM drivers + cross-driver dma-buf + compositor
render-node select) is the reusable asset: on an AMD box or a GSP-era NVIDIA where the dGPU
clocks, the identical machinery is a real performance win.

---

## The "growing set of modern GPUs"

One paragraph each on the realistic illumos path, all on the same C1 framework + OpenBSD-crib
(or MIT-crib for nouveau) + no-GPL-in-base + Mesa-userspace model:

**Intel Xe (newer iGPU / Arc dGPU).** The successor to i915 for Gen12+ (Tiger Lake and up,
Arc). It's a separate Linux driver (`drivers/gpu/drm/xe`), GPL-2.0, but structurally close to
i915 and sharing the same `display/` code. On illumos it rides the i915 shim already being
built — the linux-KPI surface is nearly identical — so Xe is "i915's shim + the xe-specific
GT/VM/submission path," not a fresh port. It needs GuC firmware (unlike Gen9 i915, which runs
GuC-less). It is the natural next Intel target once i915 is live; the C1 DRM core + the
obsd-compat shim carry straight over.

**AMD RDNA (amdgpu).** Already a separate stream: `src/drm-port/amdgpu` compiles against C1
and *binds on real hardware* (EC2 g4ad V520 / Navi 12), walling at the PSP MP0 mailbox because
the SMN-indirect register path isn't written yet (REAL, `docs/gpu2-v520-psp-mp0-wall-smn.md`).
amdgpu is the best modern-GPU parity target because it is fully open (no GSP wall, no reclock
wall) and RADV (Mesa, MIT) gives Vulkan — including the Vulkan-compute LLM path the parity
survey names as the realistic HW-GPU-LLM route. On the X1 there is no AMD part, so amdgpu is
for the maintainer's other machines; it is not an X1 dGPU option. Its PRIME importer work and
the C1 cross-driver dma-buf are shared with hybrid (C).

---

## Open questions carried to the maintainer

(The route doc's §6 list, narrowed to the dGPU decision.)

1. **Confirm (A)-now / (C)-target.** This doc recommends leaving the dGPU on vgatext now and
   treating the i915+nouveau hybrid as the both-GPU target, with nouveau display-only only as
   a step inside it. If the maintainer wants the dGPU's outputs usable *sooner* (standalone
   (B)), that's tractable but reorders effort ahead of i915.
2. **The 54 no-marker nouveau headers** need a provenance pass (trace each to an MIT sibling
   or exclude) before nouveau code enters the tree — only needed once (B)/(C) is green-lit.
3. The dump device (gates every kernel-module *load* step, i915 and nouveau alike) is still
   unapproved — but nothing here needs it, because this is compile-only.
