#!/bin/sh
# check-compat-local.sh -- fail if a linked kernel module exports any global
# symbol other than the module interface krtld resolves by name.
#
# WHY: iwm (src/ports/wifi) and i915 (src/drm-port) both carry an OpenBSD-
# kernel-API compat layer and both define the SAME global names (tsleep,
# wakeup, bus_dmamap_*, timeout_*, task_*, pci_conf_read, loadfirmware,
# systq, ...). krtld binds a loading module's non-local symbols to any
# existing definition (uts/common/krtld/kobj.c do_symbols), so whichever of
# the two loads second has its compat references cross-wired into the first
# module's copies. The mapfile at each `ld -r` step (iwm.mapfile, i915.mapfile)
# scopes everything local except _init/_fini/_info/_depends_on. This gate
# proves the mapfile actually took effect, and -- unlike the /dev/ksyms
# collision gate in build-dixi.sh / build-module.sh -- it does NOT depend on
# the other module being loaded, so it catches the defect in a single module
# built in isolation.
#
# Usage: check-compat-local.sh MODULE [NM]
#   MODULE  the linked ET_REL kernel module (iwm or i915)
#   NM      the nm to use (default: nm; on dixi pass gnm)
#
# The ONLY globals a correctly-scoped module may export are the kernel loader
# interface. Any other exported global (upper-case T/D/B/R/C in nm -p) is a
# compat global that escaped the mapfile, and this script exits non-zero and
# names them.
#
# NOTE: new solnix build glue, not derived from any GPL source.
set -u

mod=${1:?usage: check-compat-local.sh MODULE [NM]}
NM=${2:-nm}

# The interface krtld/modctl look up by name:
#   _init _fini _info     (os/modctl.c kobj_lookup)
#   _depends_on           (krtld/kobj.c depends_on -> lookup_one)
# A GLDv3 driver's dev_ops/modlinkage are referenced only inside the module
# (via mod_install) and need not be global, so they are NOT on this list.
#
# NOTE: the regex is fully anchored with ^(...)$ -- NOT `grep -x -E` with a
# bare alternation. Measured on dixi's grep, `grep -x -E '_init|_fini|_info'`
# matches drm_fb_helper_fini (the middle alternatives are not anchored by -x),
# which would silently fold compat globals into the interface set.
interface='^(_init|_fini|_info|_depends_on)$'

# nm -p is portable across illumos nm and GNU nm (gnm): one symbol per line,
# "value type name". A global/exported definition is an upper-case type
# (T text, D data, B bss, R rodata, C common); U is undefined, lower-case is
# local. We want exported definitions that are NOT the interface.
exported=$($NM -p "$mod" | awk '$2 ~ /^[TDBRC]$/ { print $3 }' | sort -u)
leaked=$(printf '%s\n' "$exported" | grep -v -E "$interface" || true)

ic=$(printf '%s\n' "$exported" | grep -E "$interface" | grep -c .)
lc=$(printf '%s\n' "$leaked" | grep -c . || true)

echo "check-compat-local: $mod"
echo "  interface globals present ($ic): $(printf '%s\n' "$exported" | grep -E "$interface" | tr '\n' ' ')"
echo "  non-interface exported globals (must be 0): $lc"
if [ "$lc" -ne 0 ]; then
	echo "  LEAKED (module exports OpenBSD-compat / non-interface globals -- krtld will cross-wire them):"
	printf '%s\n' "$leaked" | sed 's/^/    /'
	exit 1
fi
exit 0
