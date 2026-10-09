# obsd-compat provenance

Everything here is new solnix code except these three files, vendored verbatim from OpenBSD and kept
read-only. Each one passed `src/drm-port/license-audit.sh` as PERM.

| file | upstream | rev | licence | sha256 (first 16) |
|---|---|---|---|---|
| sys/tree.h | OpenBSD sys/sys/tree.h | 1.31 (also `src/wifi-port/iwx/compat/sys/tree.h`; only the leading comment differs) | BSD-2-Clause, Niels Provos | 89729f918b3848ed |
| dev/acpi/acpireg.h | OpenBSD sys/dev/acpi/acpireg.h | 1.65 | ISC | f7be3f3327295477 |
| dev/acpi/amltypes.h | OpenBSD sys/dev/acpi/amltypes.h | 1.53 | ISC | d5530d4747829e3a |

The OpenBSD drm sources the layer compiles (sys/dev/pci/drm at 37a498de) are not copied here.
Measurement and status are in docs/x1-gpu-route.md section 5.4.
