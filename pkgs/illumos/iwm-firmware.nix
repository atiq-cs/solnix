# Intel firmware for the OpenBSD iwm(4) port (src/wifi-port/iwm) -- the AC 9560
# in the ThinkPad X1 Extreme Gen 1 ("dixi": 8086:a370 subsystem 8086:0030,
# Cannon Lake CNVi + Jefferson Peak RF, iwlwifi device family 9000).
#
# PROPRIETARY but redistributable: linux-firmware's LICENCE.iwlwifi_firmware
# permits "Redistribution and use in binary form, without modification" with
# the copyright notice and disclaimer reproduced, and forbids reverse
# engineering. The licence file ships beside the blob, as the licence requires
# and as OpenBSD's sysutils/firmware/iwm port does (it installs it as
# firmware/iwm-license).
#
# Name mapping, from OpenBSD (the driver asks for the OpenBSD name):
#   if_iwm.c:11855-11858  WL_9560_1/2/3 -> sc_fwname = "iwm-9000-46"
#   ports sysutils/firmware/iwm: FW+= 9000-pu-b0-jf-b0 46, installed as
#     iwm-${device:C/-.*//}-${api} = iwm-9000-46
#   Linux cfg/9000.c: IWL9000_FW_PRE "iwlwifi-9000-pu-b0-jf-b0", API max 46
#
# Where it goes: the port's loadfirmware() calls firmware_open("iwm", name),
# which opens "firmware/iwm/<name>" on the kernel module path
# (uts/common/os/firmload.c:86), i.e. /kernel/firmware/iwm/iwm-9000-46.
# The existing illumos iwn driver's blobs live the same way under
# /kernel/firmware/iwn/ on dixi (measured).
#
# Plain derivation + builtins.fetchurl (fixed-output by sha256), the same
# pattern as ./gcc-src.nix, so it evaluates and builds on the illumos host
# without a nixpkgs stdenv. ./iwx-firmware.nix (stdenvNoCC, fakeHash) cannot.
#
# Hashes MEASURED 2026-10-08 on floki, identical from git.kernel.org
# (plain/?id=20241017) and gitlab.com/kernel-firmware (raw/20241017):
#   iwlwifi-9000-pu-b0-jf-b0-46.ucode  1519568 bytes
#   LICENCE.iwlwifi_firmware           2046 bytes
{ system ? "x86_64-solaris"
  # Explicit opt-in, as for iwx-firmware: the blob is not open source.
, acceptFirmwareLicense ? false
}:

let
  rev = "20241017";
  base = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain";
  ucode = builtins.fetchurl {
    url = "${base}/iwlwifi-9000-pu-b0-jf-b0-46.ucode?id=${rev}";
    name = "iwlwifi-9000-pu-b0-jf-b0-46.ucode";
    sha256 = "9a0c5d938646942f9798e6212579c25771e4bb44301cd409b82abe361ca2c3e0";
  };
  licence = builtins.fetchurl {
    url = "${base}/LICENCE.iwlwifi_firmware?id=${rev}";
    name = "LICENCE.iwlwifi_firmware";
    sha256 = "16d5040c7cf851fc693b7542e20870935b99802533ea1bfd231c377a2305e5c5";
  };
in
if !acceptFirmwareLicense then
  throw ''
    iwm-firmware is Intel's proprietary (redistributable) iwlwifi firmware.
    The AC 9560 does not work without it and no free alternative exists.
    Set hardware.wirelessIwm.allowUnfreeFirmware = true to accept
    LICENCE.iwlwifi_firmware.
  ''
else
derivation {
  name = "iwm-firmware-${rev}";
  inherit system ucode licence;
  builder = "/usr/bin/bash";
  PATH = "/usr/bin";
  args = [ "-c" ''
    set -e
    d=$out/kernel/firmware/iwm
    mkdir -p $d
    cp $ucode $d/iwm-9000-46
    cp $licence $d/iwm-license
    chmod 0444 $d/iwm-9000-46 $d/iwm-license
    # the driver's TLV parser rejects anything else (if_iwm.c iwm_read_firmware)
    n=$(wc -c < $d/iwm-9000-46)
    [ "$n" -eq 1519568 ] || { echo "iwm-firmware: size $n" >&2; exit 1; }
  '' ];
}
