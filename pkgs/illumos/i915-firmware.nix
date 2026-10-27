# Intel i915 display (DMC) and GT (GuC, HuC) firmware for the OpenBSD inteldrm
# port (src/drm-port/i915), from linux-firmware, the same revision as
# ./iwx-firmware.nix.
#
# PROPRIETARY but redistributable: linux-firmware's LICENSE.i915. It is laid next
# to the blobs, and the derivation refuses to evaluate without
# acceptFirmwareLicense, as iwx-firmware does. The OpenBSD port asks for these by
# name. Without them, measured on lixi 2026-10-27 (first inteldrm attach):
#   "Failed to load DMC firmware i915/adlp_dmc.bin ... Disabling runtime power
#    management"   and   "GuC firmware i915/adlp_guc_70.bin: fetch failed"
# The modeset itself works without them.
#
# Where it goes: obsd-compat loadfirmware(name) calls firmware_open("drm", name)
# with name "i915/<blob>", so firmload.c opens firmware/drm/i915/<blob> on the
# module path: /kernel/firmware/drm/i915/<blob>.
#
# Which blobs: the Alder Lake-P entries of OpenBSD 37a498de's intel_dmc.c
# (ADLP_DMC_PATH, plus the legacy v2.16 fallback) and intel_uc_fw.c (GuC
# guc_maj(adlp, 70), HuC huc_raw(tgl) for ALDERLAKE_P). Coffee Lake-H (the X1,
# 8086:3e9b) is covered by the kbl ones.
{ system ? "x86_64-solaris"
, acceptFirmwareLicense ? false
}:
let
  rev = "20241017";
  base = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain";
  fetch = lf: sha256: import <nix/fetchurl.nix> {
    url = "${base}/${lf}?id=${rev}";
    name = builtins.replaceStrings [ "/" ] [ "-" ] lf;
    inherit sha256;
  };
  blobs = {
    "adlp_dmc.bin"         = fetch "i915/adlp_dmc.bin"         "3516de2e134ddcf3b319c75d2e437779fecbd58cbb77234bd6f297c544e92ccb";
    "adlp_dmc_ver2_16.bin" = fetch "i915/adlp_dmc_ver2_16.bin" "2da482ea46a40e54c9ca3b54185959177f393eff98ece21acdac7eb6cacb0fcb";
    "adlp_guc_70.bin"      = fetch "i915/adlp_guc_70.bin"      "ea4b1b25b78e5442c142d6c7b27d0ecea25ff0cfb2272832f0e01c45e577215e";
    "tgl_huc.bin"          = fetch "i915/tgl_huc.bin"          "dbb1316bac13a76427ffa7827e52b5b9affe8a4cadd23dc22e2a54e35c53bdad";
  };
  licence = fetch "LICENSE.i915" "8542aeabf2761935122d693561e16766ce1bcc2b0d003204f9040b7d6d929f2e";
  names = builtins.attrNames blobs;
in
if !acceptFirmwareLicense then
  throw ''
    i915-firmware is Intel's proprietary (redistributable) GPU firmware
    (linux-firmware LICENSE.i915). Without it the iGPU still modesets, but has no
    display power management (DMC) and no GuC/HuC. Set
    hardware.graphics.i915.acceptFirmwareLicense = true to accept LICENSE.i915.
  ''
else
derivation {
  name = "i915-firmware-${rev}";
  inherit system licence names;
  srcs = map (n: blobs.${n}) names;   # index-matched with names
  builder = "/usr/bin/bash";
  PATH = "/usr/bin";
  args = [ "-c" ''
    set -eu
    d=$out/kernel/firmware/drm/i915
    mkdir -p $d
    set -- $srcs
    for nm in $names; do
      cp "$1" "$d/$nm"; shift
    done
    cp $licence $d/LICENSE.i915
    chmod 0444 $d/*
    for need in adlp_dmc.bin adlp_guc_70.bin; do
      [ -s "$d/$need" ] || { echo "i915-firmware: missing $need" >&2; exit 1; }
    done
  '' ];
}
