# NVIDIA GSP firmware for the nvidia-oss illumos modules (Turing and later).
#
# The open kernel modules hand most of the GPU to the GSP, a RISC-V core on the
# GPU that boots a firmware image the driver loads with firmware_open(9F) from
# /kernel/firmware/nvidia/<version>/ (kernel-illumos/nvidia/nvidia_fw.c). The
# version MUST equal the module's NV_VERSION_STRING (615.71.09): RM refuses a
# mismatched image. For each chip family RM loads BOTH gsp_<chip>.bin and
# ucodes_<chip>.bin (src/nvidia/arch/nvalloc/unix/src/osinit.c; only GB10Y has
# no ucodes file). The X1E's RTX 3080 Ti (GA103, 10de:2420) is GA10X.
#
# LICENCE: the NVIDIA Driver License Agreement shipped in the .run (LICENSE).
# 1.1(d) permits distributing the unmodified binaries "for use with operating
# system kernels distributed under the terms of an OSI-approved open source
# license", provided the Agreement goes to each recipient; 2.1 limits use to
# NVIDIA hardware and 2.8 limits GeForce firmware to GeForce hardware the user
# owns (not a datacenter). Redistributable but unfree, so it is an explicit
# opt-in, the same gate iwx/iwm firmware uses, and the Agreement is installed
# next to the blobs.
#
# Source: NVIDIA's own Linux driver package, pinned by sha256. Only firmware/
# and LICENSE are extracted (the .run is a makeself archive: a 1019-line shell
# header followed by a zstd tar).
{ system ? "x86_64-solaris"
, acceptFirmwareLicense ? false
}:

let
  version = "615.71.09";
  run = import <nix/fetchurl.nix> {
    url = "https://download.nvidia.com/XFree86/Linux-x86_64/${version}/NVIDIA-Linux-x86_64-${version}.run";
    name = "NVIDIA-Linux-x86_64-${version}.run";
    sha256 = "cdceed22bbeb61248d1a6deabc2596673e3a6501698ee71ac8d2fdc28f3b70fe";
  };
in
if !acceptFirmwareLicense then
  throw ''
    nvidia-gsp-firmware is NVIDIA's proprietary GSP firmware (unfree, but
    redistributable for open-source kernels under the NVIDIA Driver License
    Agreement). Turing and newer NVIDIA GPUs do not run without it. Pass
    acceptFirmwareLicense = true to accept that Agreement.
  ''
else
derivation {
  name = "nvidia-gsp-firmware-${version}";
  inherit system run version;
  builder = "/usr/bin/bash";
  PATH = "/usr/bin:/usr/gnu/bin";
  args = [ "-c" ''
    set -eu
    d=$out/kernel/firmware/nvidia/$version
    mkdir -p $d
    w=$(mktemp -d /tmp/nvgsp.XXXXXX)
    head -n 1 "$run" | grep -q '^#! /bin/sh' || { echo "nvidia-gsp-firmware: not a makeself .run" >&2; exit 1; }
    [ "$(sed -n 4p "$run")" = skip=1019 ] || { echo "nvidia-gsp-firmware: makeself skip changed" >&2; exit 1; }
    tail -n +1019 "$run" | zstd -dc | (cd $w && tar xf - firmware LICENSE)
    for f in gsp_ga10x.bin ucodes_ga10x.bin gsp_tu10x.bin ucodes_tu10x.bin; do
      cp $w/firmware/$f $d/$f
    done
    cp $w/LICENSE $d/LICENSE
    chmod 0444 $d/*
    # pinned blob hashes (the .run hash pins them already; this catches a
    # wrong extraction, e.g. a truncated stream)
    cd $d
    digest -a sha256 gsp_ga10x.bin | grep -qx c420726d2c76c55f028a59f67ebd7a906563ef807c945bb3baa9e88c36bf334b
    digest -a sha256 ucodes_ga10x.bin | grep -qx 6d56802aaf58513a69b47a1dc123aeb078e486f245ea721381c43ad197782e10
    digest -a sha256 gsp_tu10x.bin | grep -qx 78e0a2c8e4bd8a2faa1ff36137209669cdf60bd698b8f723dcf52869df82b909
    digest -a sha256 ucodes_tu10x.bin | grep -qx 36aa927eda920fe2648503ae73797d5239dd8b31583f484e22c5869c642d68b1
    digest -a sha256 LICENSE | grep -qx c692fb14ad4f499c6aee1b9e144e6905148c420e6225b17cb2937366c1e507ad
    cd /; find $w -delete
  '' ];
}
