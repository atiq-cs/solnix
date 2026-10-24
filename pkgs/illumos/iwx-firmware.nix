# Intel AX2xx firmware for the OpenBSD iwx(4) port (src/ports/wifi/iwx).
#
# PROPRIETARY but redistributable: linux-firmware's LICENCE.iwlwifi_firmware
# permits "Redistribution and use in binary form, without modification" with
# the copyright notice and disclaimer reproduced. The licence ships beside the
# blobs, as for ./iwm-firmware.nix.
#
# Which blob the X1E needs (measured): its AX211 is PCI 8086:51f0, subsystem
# 8086:0090, no CDB. iwx has no explicit iwx_dev_info row for it, so
# iwx_find_device_cfg matches the MAC_TYPE_SO + RF_TYPE_GF + NO_CDB wildcard ->
# iwx_2ax_cfg_so_gf_a0 -> "iwx-so-a0-gf-a0-77" + "iwx-so-a0-gf-a0.pnvm" (Linux
# runs so-a0-gf-a0-89 on lixi). gf4 is the AX411 (CDB) pair; ty is the AX210.
# Every AX210-generation cfg needs BOTH a ucode and a PNVM (if_iwxvar.h).
#
# Name mapping: OpenBSD keeps the iwx- prefix (iwx-so-a0-gf-a0-77, not
# iwlwifi-so-a0-gf-a0-77.ucode), and the driver asks for the OpenBSD names.
#
# Where it goes: loadfirmware() calls firmware_open("iwx", name), which opens
# "firmware/iwx/<name>" on the kernel module path (uts/common/os/firmload.c),
# i.e. /kernel/firmware/iwx/<name>.
#
# Plain derivation + <nix/fetchurl.nix> (fixed-output, flat sha256), the same
# pattern as ./iwm-firmware.nix, so it evaluates and builds on the illumos host
# without a nixpkgs stdenv. The hashes are the same blobs the earlier stdenvNoCC
# version pinned (its SRI hashes decode to these hex digests) and match the
# off-account copy in solnix-bank/firmware/iwx-ax210-api77-20241017/SHA256SUMS.
{ system ? "x86_64-solaris"
  # Explicit opt-in: the blobs are not open source.
, acceptFirmwareLicense ? false
  # The firmware API revision the vendored driver was written against. iwx
  # checks the API version and refuses a mismatch (if_iwx.c iwx_read_firmware).
, apiRev ? "77"
}:

let
  rev = "20241017";
  base = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain";
  fetch = lf: sha256: import <nix/fetchurl.nix> { url = "${base}/${lf}?id=${rev}"; name = lf; inherit sha256; };

  # OpenBSD name -> linux-firmware file, pinned. Only the api-77 blobs exist here.
  blobs = {
    "iwx-so-a0-gf-a0-${apiRev}" = fetch "iwlwifi-so-a0-gf-a0-${apiRev}.ucode" "87590ea9535a8939fddb296bc7622f3a900f28f47b45cb4e435a2a1d5f496ccd";
    "iwx-so-a0-gf-a0.pnvm"      = fetch "iwlwifi-so-a0-gf-a0.pnvm"            "0ea5aeac107c88ff7371188d922fe5337c5060e7e1b4c65053398db798d9c0fd";
    "iwx-so-a0-gf4-a0-${apiRev}" = fetch "iwlwifi-so-a0-gf4-a0-${apiRev}.ucode" "d945bce539ee78033a85c288da9b988b2651a1623c5f6081b7db510d3967df76";
    "iwx-so-a0-gf4-a0.pnvm"      = fetch "iwlwifi-so-a0-gf4-a0.pnvm"            "f0b9bfd93a17b03133129b49ac6871d47a51d4d281bf7ecb67b332f6e317fdc2";
    "iwx-ty-a0-gf-a0-${apiRev}" = fetch "iwlwifi-ty-a0-gf-a0-${apiRev}.ucode" "fd8977dbfacfe50b8a6601479aa9ffd21d01e274e4a9efd13935dd9d667fd45b";
    "iwx-ty-a0-gf-a0.pnvm"      = fetch "iwlwifi-ty-a0-gf-a0.pnvm"            "6ec769bb51449c1f1cbb0d528d8d5f3dc89de7546274913460e11a4b0da19e6c";
  };
  licence = fetch "LICENCE.iwlwifi_firmware" "16d5040c7cf851fc693b7542e20870935b99802533ea1bfd231c377a2305e5c5";
  names = builtins.attrNames blobs;
in
if apiRev != "77" then
  throw "iwx-firmware: only apiRev 77 is pinned (the vendored driver's API); got ${apiRev}"
else if !acceptFirmwareLicense then
  throw ''
    iwx-firmware is Intel's proprietary (redistributable) iwlwifi firmware.
    AX2xx hardware does not work without it and no free alternative exists.
    Set hardware.wirelessIwx.allowUnfreeFirmware = true to accept
    LICENCE.iwlwifi_firmware.
  ''
else
derivation {
  name = "iwx-firmware-${rev}-api${apiRev}";
  inherit system licence names;
  srcs = map (n: blobs.${n}) names;   # index-matched with names
  builder = "/usr/bin/bash";
  PATH = "/usr/bin";
  args = [ "-c" ''
    set -eu
    d=$out/kernel/firmware/iwx
    mkdir -p $d
    set -- $srcs
    for nm in $names; do
      cp "$1" "$d/$nm"; shift
    done
    cp $licence $d/iwx-license
    chmod 0444 $d/*
    # the X1E's AX211 needs BOTH; a missing one shows up much later as "no wifi".
    for need in iwx-so-a0-gf-a0-${apiRev} iwx-so-a0-gf-a0.pnvm; do
      [ -s "$d/$need" ] || { echo "iwx-firmware: missing $need" >&2; exit 1; }
    done
    n=$(ls -1 $d | grep -c '^iwx-[st]')
    [ "$n" -eq 6 ] || { echo "iwx-firmware: $n blobs, want 6" >&2; exit 1; }
  '' ];
}
