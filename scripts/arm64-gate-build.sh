#!/usr/bin/env bash
# arm64-gate-build.sh -- the aarch64 analog of oi-gate-build.sh. Fetches
# richlowe/arm64-gate + illumos-gate@arm64-gate and cross-builds the aarch64
# illumos KERNEL (unix/genunix) + world from an amd64 illumos host.
#
# Run ON an amd64 illumos build host (as root). The host must be a full illumos
# gate build host: onbld (bldenv/nightly/dmake/ctf tools), gcc-10 + gcc-14,
# astdev, illumos-closed, swig, gnu-make, openjdk8, texinfo, mpfr, mpc,
# pkg-config, gnutls-3, AND python3.13 (see ENV RECIPE below). The A2/A3 solnix
# hosts (OpenIndiana-based, /usr/gcc/{10,14}) already carry all of these.
#
# === ENV RECIPE (the exact build-env, the analog of oi-gate-build's learnings) ===
#
#  1. DISK: the arm64-gate tree + build is ~15-20G (1G gate + 1.24G gcc src +
#     377M binutils + 410M braich sysroot recv + the cross-toolchain + proto).
#     A 150G EBS root that shipped with an 8G zpool needs GROWING first:
#        format -e /dev/rdsk/cNtNdN  -> partition -> expand -> label -> 1 -> y
#        format -e ...  -> partition -> 1 -> usr -> wm -> <start> -> <end>e -> label -> 1 -> y
#        zpool set autoexpand=on <pool>; zpool online -e <pool> cNtNdNs1
#
#  2. PYTHON 3.13 (the historic wall): env/aarch64 matches the braich sysroot's
#     python minor (3.13) against /usr/bin/python3.$v ON THE HOST. sgs (the
#     link-editor build) ABORTS with "The detected Python version 3.13 in the
#     sysroot is not installed on the host!" unless python-313 is installed:
#        pkg install runtime/python-313
#
#  3. GMPINCDIR: the harness Makefile hardcodes GMPINCDIR=/usr/include/gmp
#     (the OmniOS layout). OpenIndiana puts gmp.h in /usr/include, so binutils
#     and gcc configure fail to find gmp.h. Override on the make line:
#        make GMPINCDIR=/usr/include setup
#
#  4. Sun make, NOT gmake: the harness Makefile line 1-3 deliberately breaks GNU
#     make ($(NOSUCH) GNU_MAKE_CANNOT_PARSE_THIS). Use /usr/bin/make (dmake).
#
#  5. PATH must lead with /usr/gnu/bin (the setup sub-builds -- gcc, u-boot, dtc,
#     perl -- want GNU install/tools), then /opt/onbld/bin.
#
set -euo pipefail

GATE=/aarch64/arm64-gate
HARNESS_REPO=https://github.com/richlowe/arm64-gate.git
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin
export LOGNAME=root MAILTO=root
LOGDIR=/var/log
MAKE=/usr/bin/make          # Sun make / dmake; NOT gmake
MK="$MAKE GMPINCDIR=/usr/include"

mkdir -p /aarch64
cd /aarch64

# 0. host python-313 (the sgs wall) -- install if missing
[ -x /usr/bin/python3.13 ] || pkg install -v runtime/python-313

# 1. FETCH: clone the harness; `make download` clones the gate + gcc + binutils
#    + u-boot + ATF + dtc + rpi-fw and pkgrecv's the OmniOS braich sysroot.
if [ ! -d "$GATE" ]; then
  git clone --depth 1 "$HARNESS_REPO" "$GATE"
fi
cd "$GATE"
if [ ! -d illumos-gate/usr/src ]; then
  echo "=== make download (gate arm64-gate + gcc + binutils + braich sysroot) ==="
  nohup $MK download > "$LOGDIR/arm64-download.log" 2>&1
fi

# 2. SETUP: build the cross toolchain + prereqs, in dependency order --
#    sysroot -> binutils-gdb -> sgs (Solaris ld) -> boot-gcc -> gcc (multi-hour)
#    -> perl -> u-boot(+qemu+rpi4) -> arm-trusted-firmware -> dtc -> barn.
#    Resumes from stamps/ (safe to re-run).
echo "=== make setup (cross gcc 14.3.0 + Solaris ld + sysroot; multi-hour) ==="
nohup $MK setup > "$LOGDIR/arm64-setup.log" 2>&1

# gate check: the cross gcc must compile a hello .o to aarch64 ELF.
# NOTE build dir is $(PWD)/build under the harness = $GATE/build (env/aarch64
# resolves aarch64_CROSS = CODEMGR_WS/../build/cross = illumos-gate/../build).
CROSS=$GATE/build/cross
echo 'int main(void){return 0;}' > /tmp/h.c
"$CROSS/bin/aarch64-unknown-solaris2.11-gcc" -c /tmp/h.c -o /tmp/h.o
file /tmp/h.o | grep -qi aarch64 || { echo "CROSS GCC did not emit aarch64"; exit 1; }
echo "cross gcc OK: $("$CROSS/bin/aarch64-unknown-solaris2.11-gcc" -dumpmachine)"

# 3. ILLUMOS: the kernel + world. `make illumos` = nightly -T aarch64 env/aarch64.
#    Produces proto/root_aarch64 (unix/genunix + kmods) + packages/aarch64/nightly.
echo "=== make illumos (nightly -T aarch64; the kernel + world; multi-hour) ==="
nohup $MK illumos > "$LOGDIR/arm64-illumos.log" 2>&1

# 4. VERIFY: the produced unix/genunix are aarch64 ELF (EM_AARCH64=183, ELFCLASS64)
#    nightly's MULTI_PROTO=yes lays proto in proto/root_aarch64-nd (non-debug)
#    and/or proto/root_aarch64; check both.
PROTO="$GATE/illumos-gate/proto/root_aarch64"
[ -d "$PROTO" ] || PROTO="$GATE/illumos-gate/proto/root_aarch64-nd"
UNIX="$PROTO/platform/armv8/kernel/aarch64/unix"
GENUNIX="$PROTO/kernel/aarch64/genunix"
for k in "$UNIX" "$GENUNIX"; do
  echo "--- $k ---"
  file "$k"
  readelf -h "$k" | grep -iE 'Class|Machine'
done
echo "PROTO=$PROTO"
echo "arm64-gate kernel build DONE."
