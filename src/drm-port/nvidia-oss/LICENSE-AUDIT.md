# LICENSE AUDIT — nvidia-oss

Audit of the vendored NVIDIA open-kernel-module illumos port (pin `8da2326`,
NVIDIA 615.71.09), run with `src/drm-port/license-audit.sh`. The question for
solnix: does the **illumos glue** carry any copyleft that would keep it out of
the tree, and what license does the compiled module redistribute under.

## Result (one line)

**The illumos glue (`kernel-illumos/`) is MIT/permissive-clean: GPL=0, CDDL=0.**
The vendored tree as a whole is NVIDIA's **dual MIT/GPLv2** open-kernel-module
source; redistributable, no foreign/third-party or CDDL copyleft.

## license-audit.sh output

    nvidia-oss/kernel-illumos  total=149  PERM=83  PD=0  DUAL=0  GPL=0  NONE=66

- **PERM=83** — MIT (NVIDIA/MNX headers + glue) or BSD. The 51 glue `.c` and
  their headers.
- **GPL=0, CDDL=0, DUAL=0** — no copyleft and no CDDL anywhere in the illumos
  interface layer. `grep -riI "GNU General Public License\|CDDL" kernel-illumos`
  returns **nothing**.
- **NONE=66** — all 66 are **one-line** `lkpi/linux/*.h` shadow headers, each
  the single line `#include "uvm_illumos_kpi.h"` (verified: every NONE file is
  1 line). They are MNX's linux-KPI shim redirects, not Linux source; `NONE`
  here means "no SPDX/grant line", not "unknown origin". They inherit the MIT
  `uvm_illumos_kpi.h` they redirect to. Not a copyleft risk.

## The two "GPL" tokens in the glue — both benign (as the brief predicted)

A text grep for the string `GPL` in `kernel-illumos/` finds exactly two hits,
neither a license:

1. `nvidia-uvm/lkpi/kpi/uvm_kpi_file.h:117`
   `#define EXPORT_SYMBOL_GPL(sym)` — a **no-op macro**. Linux's
   `EXPORT_SYMBOL_GPL` is defined away to nothing on illumos (illumos has no
   per-symbol GPL export marking). It expands to empty; it imposes no license.
2. `nvidia-uvm/lkpi/conftest/headers.h:42`
   `#define NV_IS_EXPORT_SYMBOL_GPL_dma_iova_try_alloc 0` — a **conftest
   feature-probe constant** (= 0, "this Linux symbol is not GPL-exported
   here"). A build-time flag, not a license.

## The dual MIT/GPLv2 reality (correction to the brief)

`COPYING` states the files are individually MIT, then:

> "However, when linked together to form a Linux kernel module, the resulting
> Linux kernel module is dual licensed as MIT/GPLv2."

This is NVIDIA's standard open-kernel-module stance. Consequences for the
vendored tree:

- **`src/` (Resource Manager, ~2.1M lines): MIT.** `nv-kernel.o` /
  `nv-modeset-kernel.o` are *built from* this MIT source — redistributable,
  **no bundled firmware blob**. (Spot-checked: `SPDX-FileCopyrightText ...
  NVIDIA CORPORATION`, MIT grant.)
- **`kernel-illumos/` (the glue): MIT.** As above.
- **`kernel-open/` (NVIDIA OS-neutral sources): 1 genuine GPLv2 file.** Across
  all of `kernel-open/`, exactly **one** source carries a GPLv2-only header:
  `kernel-open/nvidia-uvm/uvm_common.c` (© 2013-2023 NVIDIA Corporation, "GNU
  General Public License ... version 2 ... or (at your option) any later
  version"). The other 221 UVM files are permissive. This is NVIDIA's own
  code (the UVM Linux layer historically ships GPLv2), **not** third-party or
  CDDL copyleft.

### Impact on the compile gate and the shipped modules

The off-hardware compile gate (`gmake objs`) compiles the illumos glue **plus**
the NVIDIA UVM sources from `kernel-open/nvidia-uvm/` (via `NVIDIA_UVM_SOURCES`
in `nvidia-uvm-sources.Kbuild`, minus three illumos-replaced files). That set
includes `uvm_common.c`, so **the gate does compile one GPLv2 file**.

| built module | source | effective license |
| --- | --- | --- |
| `nvidia`, `nvidia_modeset`, `nvidia_i2c` | glue (MIT) + `nv-kernel.o`/`nv-modeset-kernel.o` from `src/` (MIT) | MIT |
| `nvidia_uvm` | glue (MIT) + `kernel-open/nvidia-uvm/*` incl. **`uvm_common.c` (GPLv2)** | **MIT/GPLv2 dual** (the `nvidia_uvm` module carries GPLv2) |

**Net:** everything here is redistributable. There is no foreign copyleft and
no CDDL. But the brief's "MIT-clean, ZERO GPL" is accurate only for the illumos
**glue**; the full vendored tree is NVIDIA's **dual MIT/GPLv2**, and the
`nvidia_uvm` module specifically redistributes under GPLv2 (via NVIDIA's own
`uvm_common.c`). This matches NVIDIA's published licensing for
open-gpu-kernel-modules and is expected, not a defect.

## Verdict

- **Glue clean for solnix:** `kernel-illumos/` is MIT/permissive, 0 GPL, 0 CDDL.
- **Vendor as-is:** verbatim MIT/GPLv2 NVIDIA source, no blob, redistributable.
- **One flag to carry forward:** the `nvidia_uvm` module is GPLv2 (NVIDIA
  `uvm_common.c`); account for that where solnix states per-package licenses.

## License-gated packaging (how solnix ships this)

The GPLv2 UVM piece is not merely a separate compile target -- it is a
**license-gated package** in `pkgs/illumos/nvidia-oss.nix`, modelled on
nixpkgs' `allowUnfree` / `meta.license` gating. Two attributes:

| attribute | modules | `meta.license` | gate goal | realisable by default? |
| --- | --- | --- | --- | --- |
| **`nvidia-oss`** (default) | nvidia + nvidia_modeset + nvidia_i2c | **MIT** (`lib.licenses.mit`) | `gate-mit` | **YES** -- no flag, zero GPL obligation |
| **`nvidia-oss-cuda`** (opt-in) | adds **nvidia_uvm** (CUDA UVM) | **GPL-2.0-only** (`lib.licenses.gpl2Only`) | `gate-uvm` | **NO** -- gated |

The gate: `nvidia-oss-cuda` is refused unless the caller passes
**`enableCuda = true`** (alias **`allowGplv2Kernel = true`**, default `false`).
Forcing it without opting in is an eval error that names the license and the
flag -- exactly the `allowUnfree` shape:

    pkgs.solnix.nvidia-oss                                   # MIT, builds freely
    pkgs.solnix.nvidia-oss-cuda                              # ERROR: GPL-2.0-only, refused by default
    pkgs.solnix.nvidia-oss-cuda.override { enableCuda = true; }   # opt-in -> builds

So a system that forbids GPL-only in kernel/base simply never realises
`nvidia-oss-cuda`; a system that opts into CUDA gets it, correctly tagged
GPLv2. **Base/default stays MIT-clean; CUDA is opt-in AND license-tagged.**
`gate-mit` is the default compile gate; `gate-uvm` is the opt-in one and
corresponds to `nvidia-oss-cuda`.

## EC2 compile-gate result (2026-10-11, off-hardware)

Verified on an illumos host (OpenIndiana, gcc 14.3.0, GNU ld 2.46.1,
`ILLUMOS_SRC` = illumos-gate master, `gmake -f gate.mk`):

| gate | license set | result |
| --- | --- | --- |
| `gate-mit` | nvidia + modeset + i2c (MIT) | **34/34 objects CLEAN, 0 errors** |
| `gate-uvm` | nvidia_uvm (GPLv2) | 130 objects, **1 file** fails: `uvm_illumos_stack.c` needs the `thread_splitstack` KPI (header delta, see PROVENANCE.md) |

Negative control (both goals): breaking a header include makes the gate FAIL as
required -- the gate is non-vacuous. So the MIT path is proven to compile clean,
and the one UVM gap is a precise, named header reconciliation, not a port
defect.
