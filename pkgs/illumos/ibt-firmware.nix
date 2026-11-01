# Intel Bluetooth firmware (ibt-*.sfi + .ddc) for the AX210/AX211 family's
# Bluetooth half (USB 8087:0032/0033), loaded by btintelfw
# (src/ports/bluetooth/iwmbtfw, FreeBSD iwmbtfw over ugen; docs/design-bluetooth.md).
#
# PROPRIETARY but redistributable: linux-firmware's LICENCE.ibt_firmware
# permits "Redistribution and use in binary form, without modification" with
# the notice reproduced, and forbids reverse engineering. The licence ships
# beside the blobs, as for ./iwx-firmware.nix.
#
# Which blob: the controller names it. Intel Read Version (0xfc05) returns
# CNVI_TOP/CNVR_TOP, packed to ibt-<cnvi>-<cnvr> (iwmbt_get_fwname_tlv). Every
# so/ty CNVi (AX210/AX211) is ibt-0040-*; the CNVR half varies by RF module, so
# all five linux-firmware ibt-0040 pairs are pinned. The five .ddc files are
# byte-identical (measured).
#
# Where it goes: $out/kernel/firmware/ibt/<name>, the path a future kernel ubt
# would firmware_open("ibt", name); btintelfw -f takes the same directory.
#
# Plain derivation + <nix/fetchurl.nix>, the ./iwx-firmware.nix pattern.
{ system ? "x86_64-solaris"
  # Explicit opt-in: the blobs are not open source.
, acceptFirmwareLicense ? false
}:

let
  rev = "20241017";
  base = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain";
  fetch = lf: sha256: import <nix/fetchurl.nix> { url = "${base}/${lf}?id=${rev}"; name = baseNameOf lf; inherit sha256; };
  ddc = "fe272982577efdc289cfe3e8bedafca607c0b7d6c9df1aab1880e22ef930d077";
  blobs = {
    "ibt-0040-0041.sfi" = fetch "intel/ibt-0040-0041.sfi" "3c4737a066b7bb26f34772603fa62417f0c93826567003f858d86d614766c663";
    "ibt-0040-0041.ddc" = fetch "intel/ibt-0040-0041.ddc" ddc;
    "ibt-0040-1020.sfi" = fetch "intel/ibt-0040-1020.sfi" "609b00758870c7f10141221f73c3798c336305df1d312ced4f6de4ed9624491f";
    "ibt-0040-1020.ddc" = fetch "intel/ibt-0040-1020.ddc" ddc;
    "ibt-0040-1050.sfi" = fetch "intel/ibt-0040-1050.sfi" "b40dd6c320805c75ef75049eb657bc4298953048cc2b694e9eba1e16f7ee8f6b";
    "ibt-0040-1050.ddc" = fetch "intel/ibt-0040-1050.ddc" ddc;
    "ibt-0040-2120.sfi" = fetch "intel/ibt-0040-2120.sfi" "609b00758870c7f10141221f73c3798c336305df1d312ced4f6de4ed9624491f";
    "ibt-0040-2120.ddc" = fetch "intel/ibt-0040-2120.ddc" ddc;
    "ibt-0040-4150.sfi" = fetch "intel/ibt-0040-4150.sfi" "3c4737a066b7bb26f34772603fa62417f0c93826567003f858d86d614766c663";
    "ibt-0040-4150.ddc" = fetch "intel/ibt-0040-4150.ddc" ddc;
  };
  licence = fetch "LICENCE.ibt_firmware" "5181b0b51efc79d5acb2c9bb92042878fdbad97a92114d4ab5e32e2b5b52fce4";
  names = builtins.attrNames blobs;
in
if !acceptFirmwareLicense then
  throw ''
    ibt-firmware is Intel's proprietary (redistributable) Bluetooth firmware.
    Intel AX2xx Bluetooth does not work without it and no free alternative
    exists. Pass acceptFirmwareLicense = true to accept LICENCE.ibt_firmware.
  ''
else
derivation {
  name = "ibt-firmware-${rev}";
  inherit system licence names;
  srcs = map (n: blobs.${n}) names;   # index-matched with names
  builder = "/usr/bin/bash";
  PATH = "/usr/bin";
  args = [ "-c" ''
    set -eu
    d=$out/kernel/firmware/ibt
    mkdir -p $d
    set -- $srcs
    for nm in $names; do
      cp "$1" "$d/$nm"; shift
    done
    cp $licence $d/ibt-license
    chmod 0444 $d/*
    n=$(ls -1 $d | grep -c '^ibt-0040-')
    [ "$n" -eq 10 ] || { echo "ibt-firmware: $n blobs, want 10" >&2; exit 1; }
  '' ];
}
