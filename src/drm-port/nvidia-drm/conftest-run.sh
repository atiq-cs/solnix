#!/bin/sh
# Generate nvidia-drm's conftest/*.h with NVIDIA's own kernel-open/conftest.sh, run against the OpenBSD drm
# headers and solnix's obsd-compat with the i915 compile flags, instead of picking the 87 NV_DRM_* / NV_LINUX_*
# macros by hand. The header-presence list and the nvidia-drm compile-test list are NVIDIA's.
# Usage: conftest-run.sh <outdir>   (writes <outdir>/cf/conftest/{headers,functions,generic,macros,symbols,types}.h)
# Environment: RM (upstream tree with kernel-open), OBSD (OpenBSD drm tree), COMPAT (src/drm-port/obsd-compat),
#              GATEINC (gate proto usr/include), CC (store gcc), GREP (GNU grep).
set -u
W=$1
: "${RM:?}" "${OBSD:?}" "${COMPAT:?}" "${GATEINC:?}" "${CC:?}" "${GREP:?}"
O=$OBSD; C=$COMPAT; G=$GATEINC; GG=$GREP
CF="-m64 -mcmodel=kernel -mno-red-zone -mno-mmx -mno-sse -D_KERNEL -ffreestanding -nostdinc -std=gnu11 -O2 -fno-strict-aliasing"
CF="$CF -D__HAVE_ACPI -DNACPI=1 -include $C/obsd_prelude.h -I$C -I$O/include -I$O/include/uapi -I$O -I$G -isystem $($CC -print-file-name=include)"
CF="$CF -Wno-implicit-function-declaration -Wno-strict-prototypes -Werror=incompatible-pointer-types -Wno-error"
D=$W/cf/conftest; mkdir -p $D $W/cf/tmp
# headers.h: header presence (NVIDIA's list), the conftest.sh test_header_presence logic
: > $D/headers.h
for h in $(sed -n '/NV_HEADER_PRESENCE_TESTS *=/,/^$/p' $RM/kernel-open/header-presence-tests.mk | tr -d '\\' | tr ' ' '\n' | $GG '\.h$'); do
  def=NV_$(echo "$h" | tr '/.-' '___' | tr 'a-z' 'A-Z')_PRESENT
  if echo "#include <$h>" | $CC $CF -E -M -x c - >/dev/null 2>&1; then echo "#define $def" >> $D/headers.h; else echo "#undef $def" >> $D/headers.h; fi
done
# compile tests: the nvidia-drm list by category, run through conftest.sh compile_tests (it cds to its own dir: copy it)
cp $RM/kernel-open/conftest.sh $W/cf/tmp/conftest.sh
mk=$RM/kernel-open/nvidia-drm/nvidia-drm-sources.mk
for cat in FUNCTION GENERIC MACRO SYMBOL TYPE; do
  case $cat in FUNCTION) f=functions;; GENERIC) f=generic;; MACRO) f=macros;; SYMBOL) f=symbols;; TYPE) f=types;; esac
  tests=$(awk -v c="NV_CONFTEST_${cat}_COMPILE_TESTS" '$1==c && $2=="+=" {print $3}' $mk)
  ( cd $W/cf/tmp && mkdir -p conftest && cp $D/headers.h conftest/headers.h &&
    OS=SunOS sh ./conftest.sh $CC x86_64 $O $W/cf/tmp compile_tests "$CF" $tests ) > $D/$f.h 2>$W/cf/$f.err
  echo "$f: $(echo $tests | wc -w | tr -d ' ') tests, $($GG -c '^#define' $D/$f.h) define, $($GG -c '^#undef' $D/$f.h) undef"
done
