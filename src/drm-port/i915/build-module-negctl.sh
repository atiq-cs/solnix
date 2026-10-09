#!/bin/sh
# build-module-negctl.sh -- negative controls for build-module.sh's two
# gates; each must make the gate FAIL by name.
#   unresolved: a module that also calls a function no kernel defines;
#   collision:  a module that also defines a global the kernel defines
#               (ddi_get_lbolt) -- exactly what krtld would rebind.
# Usage (on dixi): build-module-negctl.sh OBSD_DRM_DIR PORT_DIR OUT_BASE FILES_TXT OBJS_FROM
set -u
obsd=$1 port=$2 base=$3 files=$4 from=$5
here=$(cd -- "$(dirname -- "$0")" && pwd)
rc=0
for kind in unresolved collision; do
	neg=$base-$kind
	mkdir -p "$neg/port"
	cp -rp "$port/obsd-compat" "$port/i915" "$neg/port/"
	if [ $kind = unresolved ]; then
		printf '\nvoid i915_negctl(void) { extern void no_such_kernel_function(void); no_such_kernel_function(); }\n' \
		    >> "$neg/port/i915/i915_illumos.c"
	else
		printf '\nclock_t ddi_get_lbolt(void) { return (0); }\n' >> "$neg/port/i915/i915_illumos.c"
	fi
	if OBJS_FROM=$from sh "$here/build-module.sh" "$obsd" "$neg/port" "$neg/out" "$files" > "$neg/log" 2>&1; then
		echo "NEGATIVE CONTROL ($kind) DID NOT FAIL"; rc=1
	else
		echo "negative control ($kind) FAILS as required: $(tail -2 "$neg/log" | tr '\n' ' ')"
	fi
done
exit $rc
