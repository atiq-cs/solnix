# obsd-compat provenance

Everything here is new solnix code except these three files, vendored verbatim from OpenBSD and kept
read-only. Each one passed `src/drm-port/license-audit.sh` as PERM.

| file | upstream | rev | licence | sha256 (first 16) |
|---|---|---|---|---|
| sys/tree.h | OpenBSD sys/sys/tree.h | 1.31 (also `src/ports/wifi/iwx/compat/sys/tree.h`; only the leading comment differs) | BSD-2-Clause, Niels Provos | 89729f918b3848ed |
| dev/acpi/acpireg.h | OpenBSD sys/dev/acpi/acpireg.h | 1.65 | ISC | f7be3f3327295477 |
| dev/acpi/amltypes.h | OpenBSD sys/dev/acpi/amltypes.h | 1.53 | ISC | d5530d4747829e3a |

The OpenBSD drm sources the layer compiles (sys/dev/pci/drm at 37a498de) are not copied here.
Measurement and status are in docs/x1-gpu-route.md section 5.4.

The OpenBSD kernel sources read while writing `obsd_time.c` (kern/kern_synch.c, the sleep-queue model),
`obsd_bus.c` (dev/pci/pci.c, pci_map.c) and `obsd_vm.c` (uvm/uvm_object.c) were references only: no code
from them is copied. The two kernel prototype blocks in `obsd_vm.c` and `obsd_glue.c` (xc_call,
invalidate_cache, hat_kpm_pfn2va, kernel_fpu_begin/end, KFPU_NO_STATE, HAT_PLAT_NOCACHE) restate
illumos-gate interfaces whose headers the installed proto does not ship; the running kernel exports
every one of them (measured).
