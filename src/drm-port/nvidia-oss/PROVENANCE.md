# PROVENANCE — nvidia-oss (vendored NVIDIA open-kernel-module illumos port)

**Driver-port pattern: `vendor-open-kernel-module`** — the third reusable
solnix driver-port pattern, alongside the NetBSD-drm2 cribs (`netbsd-ref/`,
where solnix *rewrites* the shim against illumos) and the Mesa ICDs (userspace
GPU drivers). This pattern is distinct: the upstream already ships a working
illumos kernel-interface layer, so solnix **vendors the tree verbatim** and adds
only an off-hardware compile gate + license-gated packaging in NEW files —
nothing upstream is edited. Use it whenever an upstream driver already has an
illumos port we want to track at a pin.

This directory is a **verbatim vendor** of the illumos port of NVIDIA's
open-gpu-kernel-modules. No upstream file is edited; any solnix glue lives in
NEW files alongside this tree (`build.nix`, `build-objs-gate.sh`,
`build-objs-negctl.sh`, `LICENSE-AUDIT.md`, and this file).

## Upstream

| field | value |
| --- | --- |
| upstream URL | https://github.com/nwilkens/open-gpu-kernel-modules |
| branch | `illumos` |
| commit (pin) | `8da2326c626cdd08130538f0f5f9a1f985054f4a` (short `8da2326`) |
| commit subject | "Charge UVM page tables to the VA space owner" |
| commit date | 2026-09-24 13:08:46 -0400 |
| author | Nick Wilkens &lt;nick.wilkens@mnxsolutions.com&gt; (MNX Solutions) |
| NVIDIA driver version | **615.71.09** (`version.mk`: `NVIDIA_VERSION = 615.71.09`) |
| license | **MIT** (see `COPYING`; "Except where noted otherwise, the individual files within this package are licensed as MIT") |
| clone date | 2026-10-11 |
| vendored by | `git archive --format=tar 8da2326 | tar -x` (clean export, no `.git`, no working-tree edits) |
| file count | 4164 files, verbatim; integrity confirmed by sha256 spot-check against `git show 8da2326:<path>` |

Fork lineage: this is MNX Solutions' / Nick Wilkens' illumos port of NVIDIA's
upstream `NVIDIA/open-gpu-kernel-modules` (the open-source GPU kernel modules,
NVIDIA version 615.71.09). The illumos interface layer (`kernel-illumos/`) is
MNX's work; the OS-agnostic Resource Manager (`src/`) and shared OS-neutral
sources (`kernel-open/`) are NVIDIA's upstream MIT source.

## Hardware scope — IMPORTANT

**Turing+ only.** This driver is the GSP-firmware generation of NVIDIA's open
kernel modules: it supports Turing (TU1xx), Ampere, Ada, Hopper, Blackwell and
later GPUs, which carry the GSP (GPU System Processor) that runs the signed
firmware the open modules depend on. It does **NOT** cover Pascal or earlier,
and in particular **does NOT cover the X1 dGPU** (pre-Turing). The X1 remains
out of scope for this port.

No GPU firmware blob is bundled. `src/` is NVIDIA's redistributable MIT RM
source; `nv-kernel.o` is *built from* that source (not a shipped blob).

## Tree layout (preserved verbatim)

    COPYING                top-level MIT license (+ the "linked into a Linux
                           module" GPL note, which does not apply to the
                           illumos build — see LICENSE-AUDIT.md)
    README.md              upstream README (supported-GPU table drives the
                           PCI aliases)
    Makefile               top-level build (dispatches to kernel-illumos/ on
                           TARGET_OS=SunOS)
    utils.mk  version.mk   shared build machinery; version.mk pins 615.71.09
    kernel-illumos/        THE illumos interface layer (MNX glue) — 51 .c +
                           headers, ~31k lines. The porting surface.
      Makefile             builds nvidia / nvidia_modeset / nvidia_i2c /
                           nvidia_uvm .kmod; the `objs:` target (line 267)
                           compiles every glue .o with NO nv-kernel.o link —
                           this is the off-hardware compile gate
      nvidia/              core nvidia driver glue (ddi/pci/intr/mem/mmap/...)
      nvidia-modeset/      nvkms illumos glue
      nvidia-i2c/          GPU I2C controller glue
      nvidia-uvm/          UVM illumos glue + lkpi/ linux-KPI shadow headers
      common/inc/          nv-illumos-kpi.h, nv-illumos-pci-dev.h, ...
    kernel-open/           NVIDIA's OS-neutral kernel-open sources (UVM shared
                           sources + nv_uvm_interface.c); the illumos UVM
                           build compiles a subset of these
    src/                   NVIDIA Resource Manager (OS-agnostic, ~2.1M lines) —
                           compiled to nv-kernel.o / nv-modeset-kernel.o for the
                           final .kmod link (NOT needed by the compile gate).
                           *** NOT vendored here: 107 MB, mostly generated
                           GSP-firmware-as-C; fetched as a pinned FOD at commit
                           8da2326 — see src-FETCH.md. .gitignore excludes it so
                           the repo stays lean (we cut .git 79M->15M). ***
    nouveau/               (unused by the illumos build)
    nv-compiler.sh         upstream helper

## Reproduce

    git clone https://github.com/nwilkens/open-gpu-kernel-modules /tmp/nwilkens-nv
    cd /tmp/nwilkens-nv && git checkout 8da2326
    git archive --format=tar 8da2326 | tar -x -C src/drm-port/nvidia-oss

## License posture (per module) and the license-gated packaging

Full audit in `LICENSE-AUDIT.md`. Summary:

- The illumos **glue** (`kernel-illumos/`) is MIT/permissive: **0 GPL, 0 CDDL**.
- `COPYING` is **dual MIT/GPLv2**: individual files MIT "except where noted",
  but "when linked together to form a kernel module, the resulting module is
  dual licensed as MIT/GPLv2".
- `src/` (Resource Manager) is **MIT**; `nv-kernel.o` is built from it, no blob.
- Exactly **one** GPLv2-only file exists in the whole vendored tree:
  `kernel-open/nvidia-uvm/uvm_common.c` (NVIDIA's own code), compiled **only**
  into `nvidia_uvm` (CUDA Unified Memory).

| built module | source | effective license |
| --- | --- | --- |
| `nvidia`, `nvidia_modeset`, `nvidia_i2c` | glue (MIT) + RM (MIT) | **MIT** |
| `nvidia_uvm` | glue (MIT) + UVM incl. `uvm_common.c` | **GPL-2.0-only** |

Solnix ships this as **two license-gated attributes** in
`pkgs/illumos/nvidia-oss.nix` (the nixpkgs `allowUnfree` model):

| attribute | modules | `meta.license` | compile gate | default? |
| --- | --- | --- | --- | --- |
| **`nvidia-oss`** | nvidia + nvidia_modeset + nvidia_i2c | `lib.licenses.mit` | `gate-mit` | **yes** (no flag) |
| **`nvidia-oss-cuda`** | adds `nvidia_uvm` | `lib.licenses.gpl2Only` | `gate-uvm` | **no**, gated |

`nvidia-oss-cuda` is refused unless the caller sets **`enableCuda = true`**
(alias **`allowGplv2Kernel = true`**, default `false`); forcing it otherwise is
an eval error naming the license + flag. Base/default stays MIT-clean; CUDA is
opt-in and tagged GPLv2.

## Compile gate (off-hardware) and the header delta

The gate (`kernel-illumos/gate.mk` + `build-objs-gate.sh` +
`build-objs-negctl.sh`) runs `gmake -f gate.mk <goal> ILLUMOS_SRC=<tree>` on an
illumos host: it compiles every glue `.c` to `.o` via the upstream `objs:`
machinery -- NO `nv-kernel.o`, NO RM link, NO GPU. Needs gcc, GNU binutils
(`gld`/`gobjcopy`), and an illumos-gate SOURCE tree for `ILLUMOS_SRC`
(`-I usr/src/uts/{i86pc,intel,common}`); `ctfconvert` is only for the `.kmod`
link, not the gate.

**EC2 result (2026-10-11, OpenIndiana, gcc 14.3.0, GNU ld 2.46.1,
`ILLUMOS_SRC` = illumos-gate master):**

- `gate-mit` (MIT: nvidia + modeset + i2c) -- **34/34 objects CLEAN, 0 errors.**
- `gate-uvm` (GPLv2: nvidia_uvm) -- 130 objects, **1 file fails**:
  `kernel-illumos/nvidia-uvm/uvm_illumos_stack.c`.
- Negative control (both goals): breaking a header include makes the gate FAIL
  as required (non-vacuous).

### Header delta (gate-uvm's one gap -- a header reconciliation, not a port bug)

`uvm_illumos_stack.c` line 38 declares `#pragma weak thread_splitstack` and uses
the bare symbol (lines 48/73/127). `#pragma weak` needs a prior C declaration
for gcc to bind the identifier; the port relies on a sys header providing
`thread_splitstack()` (the joyent/OI illumos the port was built against declares
it). **Our illumos-gate master has no `thread_splitstack`** -- not in
`usr/src/uts/common/sys/*.h`, not in the running kernel symbols. The port even
handles a kernel lacking the symbol at runtime (`if (thread_splitstack == NULL)
...`), but still needs the declaration to compile. The fix is a single `extern`
prototype in a solnix UVM glue header (not a change to any upstream file);
runtime resolution of the weak symbol is a separate question for a gate tree
that actually ships `thread_splitstack`. This is the measured "needs this one
header reconciled" deliverable, not a hand-patch of 51 files.
