# X1 discrete-GPU decision: NVIDIA GP107M (Pascal, 10de:1c8c)

The X1 (dixi) has Intel UHD 630 (`8086:3e9b`) and NVIDIA GP107M / GTX 1050 Ti
Mobile (`10de:1c8c`, Pascal). The maintainer wants either-or-both GPU support.
**Recommendation: keep the existing display path and prioritize i915 diagnosis;
nouveau display and accelerated hybrid offload are separate, unproven targets.**

The original stream ran a syntax/header probe on dixi, not a working nouveau
port. The [runtime audit](x1-gpu-runtime-audit.md) corrects its interpretation:
**418 files, 71,389 residual errors, zero error-free files**. Header-name overlap
with OpenBSD does not quantify implementation reuse. The earlier 94%-reuse and
6–10/+3–5-week estimates are withdrawn, not established engineering budgets.

The original probe made no live kernel changes. The later audit used read-only
crash/source inspection. It found only a saved iwm panic; **the reported i915
boot-failure phase is unknown**. The operator record says c3 hash prefix
`1dacd9ae` was copied into solnix-4 before a reboot around 2026-10-11 03:23:42 UTC,
followed by a user-reported loop, with no explicit orchestrator DRM open. That is
not proof of loader identity or absence of other DRM openers. The c3 handover
source is missing from the repository implementation; see
[CONSOLE-HANDOVER.md](../src/drm-port/i915/CONSOLE-HANDOVER.md).

Labels below distinguish **REAL source/measurement evidence**, **historical
records**, and **PLANNED capability**. No new runtime or performance proof is
claimed. Builds remain dixi/authorized EC2 only, never floki.

## Recommendation and options (PLANNED)

| Option | Scope | Dependencies and limits |
|---|---|---|
| **A: leave NVIDIA on its existing vgatext binding** | Immediate recommendation; no new driver work | Keep the known GOP/text display path. i915 runtime is not yet validated. This does not demonstrate NVIDIA rendering or power management. |
| **B: nouveau display-only** | KMS and dumb buffers on outputs actually wired to GP107 | Requires a chosen DRM integration, DDI/interrupt/MMIO/DMA support, memory management and connector/VBIOS bring-up. Physical routing and runtime need proof. No accelerated render offload. |
| **C: i915-primary + nouveau accelerated PRIME offload** | Both-GPU target, after separate driver validation | B plus NVIDIA execution/channels/fences/firmware/userspace, a shared fd/lifetime contract, cross-device SG mapping and coherency/synchronization. C1 does not already supply these to OpenBSD i915. |

No schedule or performance ranking follows from the probe. Do not label B as
working offload or C as merely “B + importer + render-node selection.” Display
sharing and accelerated rendering need distinct acceptance tests.

## Hardware and source constraints (historical measurements, REAL source reading)

| fact | value | source |
|---|---|---|
| dGPU | GP107M / GTX 1050 Ti Mobile, Pascal, `10de:1c8c` rev a1 | `prtconf -v` on dixi |
| binding observed by original stream | **`vgatext` instance 1**, `/dev/fb1` → `display@0:text-1` | `prtconf -D`, `ls -l /dev/fb*` on dixi (READ-ONLY) |
| BARs | BAR0 `0xa3000000` 16 MB (MMIO), BAR1 `0x60000000` 256 MB, BAR3 32 MB | `prtconf -v` |
| chipset in nouveau | `nv137_chipset` ("GP107") | `nvkm/engine/device/base.c:2211,3336` |
| reclocking | **none** — `nv137_chipset` has **no `.clk` entry** (unlike GP10B/Tegra) | `nvkm/engine/device/base.c` nv137 block |
| PMU firmware | **none** — `gp102_pmu_fwif[] = { gm200_pmu_nofw }` | `nvkm/subdev/pmu/gp102.c:50` |

Correction to the route doc's framing: the original stream observed the dGPU
**bound to `vgatext`, not unbound**. Option A means leave that binding in place,
not actively unbind it. The i915 stream's notes (`/tmp/streamE-progress.txt`) also
recorded it.

The reviewed GP107 chipset has no `.clk` subdevice and uses the no-firmware PMU
path. This supports the boot-clock/reclocking limitation in this source version.
It does not establish that hardware acceleration is impossible or worthless,
nor that it is slower than Intel for a given workload. No comparative benchmark
or NVIDIA execution test was performed. Graphics-engine firmware is a separate
requirement below.

## Licence inventory (historical scan; dependency closure still required)

The original stream recorded `src/drm-port/license-audit.sh` results on the Linux nouveau tree
(`drivers/gpu/drm/nouveau`, master `6c377d19`), 1212 `.c`/`.h` files:

```
drivers/gpu/drm/nouveau  total=1212  PERM=1157  PD=0  DUAL=1  GPL=0  NONE=54
```

The historical scan classified notices in the first 60 lines as follows. “GPL=0”
is the scanner's count of explicit GPL-only notices, not clearance of unmarked
files or their transitive dependencies:

| notice | files | meaning |
|---|---:|---|
| full MIT grant text ("Permission is hereby granted, free of charge…") | **762** | MIT, usable, header kept verbatim |
| `SPDX-License-Identifier: MIT` | **395** | MIT |
| `SPDX-License-Identifier: GPL-2.0 OR MIT` | **1** | dual — used under MIT (`include/nvif/log.h`) |
| no marker at all | **54** | all headers; unresolved provenance, excluded under project policy until traced |

Most scanned nouveau files carry MIT notices. That is useful provenance evidence,
but does not clear an eventual port's transitive dependencies or unresolved headers:

1. **The 54 no-marker files** include internal headers such as
   `include/nvkm/subdev/gsp.h` and `dispnv50/disp.h`. Trace each file's provenance
   before reuse; a permissive notice on a sibling file alone does not establish
   its licence.
2. The inspected OpenBSD DRM tree at 37a498de contains no nouveau port. The
   candidate source here comes from Linux nouveau. Its permissive files may be
   reusable, subject to the closure review; this is not an existing BSD port.

A port still needs a file-by-file dependency/provenance review under the project's
no-GPL-only-in-base policy. C1 and the OpenBSD DRM port are separate implementations;
referring to either by name does not establish which sources a nouveau port links.
Excluding an unrelated GPL power-switch file is not a licence audit of the closure.

## Firmware evidence (source references, not a display runtime proof)

| GP107 subsystem | Recorded source evidence | Limit of the conclusion |
|---|---|---|
| `disp` / `dispnv50` | Original scan found zero direct `request_firmware` occurrences; 32 disp files | Textual absence is not a transitive firmware audit or proof of a firmware-free boot/modeset. |
| `devinit` | `nvkm/subdev/devinit/gm200.c`, VBIOS use | VBIOS/device initialization remains part of bring-up. |
| `pmu` | `nvkm/subdev/pmu/gp102.c:50`, `gm200_pmu_nofw` | Distinct from graphics firmware and execution support. |
| `gr` | `nvkm/engine/gr/gp107.c`, 12 `MODULE_FIRMWARE` declarations for FECS/GPCCS and related blobs; `gm200_gr_load` | Accelerated graphics requires this engine/firmware path. |
| `acr` / `sec2` | `nvkm/subdev/acr/gp102.c:178`, `nvkm/engine/sec2/gp102.c:227` | Secure graphics startup needs review along with gp107/gp102 firmware packaging. |

The original stream cited linux-firmware `WHENCE` for NVIDIA redistribution terms;
verify exact blobs and their terms before packaging them separately. Render
offload necessarily includes rendering: a firmware-free fd-passing prototype, if
built, would not prove accelerated NVIDIA offload. No working display-only or
accelerated nouveau driver was tested here.

## The compile-only probe (REAL, dixi — nothing loaded)

Modeled on the i915 obsd-compat probe (`src/drm-port/i915/probe-headers.sh`): compile each
nouveau source against the illumos gate proto with nouveau's own `-Iinclude` paths; stub
each still-missing external header empty and retry until the header wall is cleared; the
residual diagnostics expose unresolved interfaces and cascading parse errors, not
a count of missing implementations. A minimal `<linux/types.h>` seed provides the integer
typedef floor (the measurement floor, not the port). Harness + outputs:
`/var/tmp/streamNOUVEAU/` on dixi.

**Subset selected for a GP107 display-oriented probe: 418 files / 86,703 LOC** — `nvkm/core` (16),
`nvkm/engine/disp` (32), `nvkm/engine/device` (3), `dispnv50` (52), the display subdevs
(`nvkm/subdev/*`, 297), and the top-level DRM glue (`nouveau_*.c`, 18). This selection is not a demonstrated
closed, display-only dependency graph.

Results:

| metric | value |
|---|---|
| files that cleared the header wall (parse reaches the KPI gap, no runaway) | **418 / 418** |
| distinct external headers that had to exist | **105** (98 `linux/`, 2 `soc/tegra`, 2 `acpi`, 1 `video`, 1 `trace`, 1 `asm`) |
| `drm/` headers that had to be stubbed | **0**; Linux/nouveau include trees supplied declarations, not C1 implementation/link proof |
| residual error lines | **71,389** |
| error-free files | **0 / 418** |

The audit retrieved `/var/tmp/streamNOUVEAU/nouveau-probe2.sh` from dixi; it was
byte-identical to `/tmp/nouveau-probe2.sh`. The command uses `-fsyntax-only` with
nouveau/Linux headers, a seed, illumos gate headers and empty generated stubs.
It does not use OpenBSD shim or C1 implementation inputs and does not link.
Read-only aggregation of `probe2-results.txt` returned:

```text
rows=418 error_sum=71389 zero_error_rows=0
```

Evidence: `/tmp/streamGPU-resume.WIP/dixi-nouveau-probe2.sh` and
`/tmp/streamGPU-resume.WIP/nouveau-probe-counts.txt`. The earlier i915 probe's
129,793 diagnostics over 377 files used a different source/header environment;
neither diagnostic total measures implementation effort or semantic coverage.

Examples of unresolved names (not an implementation checklist):

* **types:** `uint32_t`, `uint64_t`, `spinlock_t`, `refcount_t`, `ktime_t`, `pgprot_t`,
  `vm_fault_t`, `wait_queue_head_t` — many diagnostics cascade from the minimal seed (including 7927 `uint32_t` hits);
  the probe did not measure a working replacement.
* **functions:** `kfree`, `mutex_init`, `ioread32`, `WARN_ON`, `list_for_each_entry`,
  `container_of`, `IS_ERR`, `spin_lock_init`, `kzalloc` — matching names in a compat layer do not establish compatible semantics,
  locking, memory ownership or call signatures.

### Header-name overlap (REAL count, not implementation reuse)

The original `comm` comparison found **92 of 98 `linux/` header names** in the
OpenBSD 37a498de tree. The six absent names were:

```text
const.h  leds.h  list_lru.h  regulator/consumer.h  reset.h  sched/signal.h
```

This is about filenames. Headers may expose incomplete APIs, stubs or incompatible
semantics. No runtime reachability analysis established that the six missing
headers' functionality is unused. The former “~94% shim reuse” conclusion and its
6–10-week display/+3–5-week hybrid estimates are **withdrawn**. A real probe must
compile a bounded production slice against the chosen implementation and inspect
its link dependencies, then label each required interface REAL/STUB/unsupported.

## Hybrid dependency review (REAL source findings; implementation PLANNED)

A possible future node layout is i915 card/render nodes for primary scanout and
nouveau card/render nodes for GP107. Neither node numbers nor physical output
routing establish execution capability. Symbol scoping reduces loader collisions;
it is necessary isolation work, not proof of dual-driver runtime or interoperability.

### There are two DRM implementations, not a shared ready-made PRIME layer

- **OpenBSD i915 path:** `src/drm-port/i915/build-module.sh` links OpenBSD DRM
  objects and obsd-compat/DDI glue. It does **not** link C1
  `src/drm-port/src/drm_prime.c`.
- **fd export/import STUB:** `src/drm-port/obsd-compat/obsd_glue.c:290–304`
  returns ENOTSUP from `fdalloc`, NULL from `fd_getfile` and `fnew`. OpenBSD
  `drm_linux.c` uses these for dma-buf fds. Same-device fd sharing is not proven.
- **Foreign import UNIMPLEMENTED/PANIC:** OpenBSD
  `include/linux/dma-buf.h` has `dma_buf_attach = NULL` and a panicking detach.
  `i915/gem/i915_gem_dmabuf.c:293–360` has an own-device shortcut, but foreign
  object setup is behind `#ifdef notyet`; the compiled alternative calls
  `panic(__func__)`. Enabling fds alone would expose an unsafe path.
- **C1 is separate:** its PRIME export uses `falloc`/spec-vnodes; import looks up
  `dev->prime_exports` and reissues a handle within that device. It neither maps
  foreign pages nor bridges OpenBSD GEM types. The importer checks vnode type
  and minor without checking the exporter major; its foreign-fd boundary and
  lifetime handling need review, not a claim of working shared fds.
- **nouveau requires memory and synchronization semantics:** `nouveau_prime.c`
  uses TTM pages, SG tables, shared `dma_resv`, GEM lifetimes and GART
  initialization/pinning. Shared fd identity, cross-device mappings, coherency,
  fences and lifetime ownership need one explicit cross-module contract.

Reviewed OpenBSD revision: `37a498de2f7aa77a9e30afd65012af6434819316`, from
`/tmp/streamE5-obsd/obsd-drm/OPENBSD_REV`. Decisive source copies are in
`/tmp/streamGPU-resume.WIP/reference/`; see the audit for full paths/provenance.

### Accelerated offload is additional work

`nouveau_accel_init` initializes channels/fences and graphics/copy channels;
GP107's graphics engine uses firmware. A KMS/dumb-buffer port plus an importer
cannot execute client rendering. Working submission, GPU memory management,
interrupt/completion handling, synchronization and Mesa userspace are prerequisites.
The existence of a render node or a successful fd transfer would prove neither
GPU execution nor acceleration.

The MESA/compositor stream owns render-node selection and userspace dmabuf work;
do not duplicate it. The previously cited Smithay `GlMulti`/KMS interfaces
(`docs/cosmic-comp-illumos-finding.md`) are integration leads, not proof of an
end-to-end illumos hybrid. Tests must reject software-renderer fallback and verify
which GPU executed work before claiming accelerated offload. No relative
Intel/NVIDIA performance claim is supported by the evidence here.

## Other GPUs (separate programs, not automatic reuse)

Intel Xe needs its own licence, API, memory/submission and firmware review;
shared Intel concepts or headers do not make it an automatic extension of this
port. Do not infer a supported generation list or schedule from this probe.

AMD work lives separately under `src/drm-port/amdgpu`; the V520/Navi12 bring-up
record is `docs/gpu2-v520-psp-mp0-wall-smn.md`. It is not an X1 hardware option.
C1 work there may inform a future sharing design, but does not already interoperate
with OpenBSD i915. Reuse must be established at actual interfaces and lifetimes.

## Decisions still needed

1. Keep A-now/i915-first; decide whether to prioritize B display or C accelerated
   offload only after the dependency gap and physical routing are established.
2. Complete the unresolved-header and transitive licence review before importing
   nouveau kernel code; no blanket “GPL exposure none” claim is justified yet.
3. Choose and review the cross-module buffer/fence contract before implementation.
   Do not start by removing fd stubs around the foreign-import panic path.
4. The audit observed a configured dump device, not a guarantee of recovery.
   Further live work requires separate approval and the audit's capture/recovery
   prerequisites. No laptop operations follow from this document.
