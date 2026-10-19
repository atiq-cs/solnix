# Intel wireless firmware for the iwx driver.
#
# These are PROPRIETARY, redistributable-but-not-open blobs from Intel. They are
# gated behind the standard Nix unfree mechanism, so a user who has not opted in
# gets a clear evaluation error naming the licence rather than a silent download.
#
# The blobs come from the linux-firmware tree, which is where Intel publishes
# them. OpenBSD RENAMES them (iwx-cc-a0-77 rather than iwlwifi-cc-a0-77.ucode),
# and the driver looks for the OpenBSD names, so the install phase maps them.
{ lib
, stdenvNoCC
, fetchurl
  # Explicit opt-in. This is the REAL gate -- see the meta.license note below for
  # why the licence attribute alone does not stop evaluation.
, acceptFirmwareLicense ? false
  # The firmware API revision the vendored driver was written against. Bumping
  # this without re-reading if_iwxvar.h will produce blobs the driver rejects:
  # iwx checks the API version and refuses a mismatch (if_iwx.c:1229-1241).
, apiRev ? "77"
}:

let
  # linux-firmware pinned by commit, not a branch. A moving ref would change the
  # hash under us and, worse, could silently ship a different API revision.
  rev = "20241017";

  # Map: OpenBSD iwx's expected name <- the linux-firmware filename + its pinned
  # sha256. The vendored driver is API rev 77 (if_iwxvar.h IWX_*_FW), and the
  # AX210 "SO"/"TY" + "GF"/"GF4" device family is the one solnix targets: the
  # X1 Extreme Gen5's AX211 (PCI 8086:51f0) selects iwx_2ax_cfg_so_gf4_a0 ->
  # IWX_SO_A_GF4_A_FW "iwx-so-a0-gf4-a0-77" + IWX_SO_A_GF4_A_PNVM
  # "iwx-so-a0-gf4-a0.pnvm" (measured live on lixi: subsystem 8086:0090, Linux
  # loads iwlwifi-so-a0-gf4-a0). Each AX210 device needs BOTH a ucode and a PNVM
  # (if_iwxvar.h: every SO/TY/MA cfg has a .pnvm_name). The older Qu/HR/JF
  # families (different, pre-AX210 hardware) are intentionally NOT pinned here;
  # add them with real hashes when a Qu device is actually targeted, rather than
  # carry fakeHash placeholders that break eval. Hashes from the pinned
  # linux-firmware commit 20241017 via nix-prefetch-url.
  blobs = {
    # X1E AX211 (gf4): the pair the hardware actually loads.
    "iwx-so-a0-gf4-a0-${apiRev}" = { lf = "iwlwifi-so-a0-gf4-a0-${apiRev}.ucode"; hash = "sha256-2UW85TnueAM6hcKI2puYiyZRoWI8X2CBt9tRDTln33Y="; };
    "iwx-so-a0-gf4-a0.pnvm"      = { lf = "iwlwifi-so-a0-gf4-a0.pnvm";            hash = "sha256-8Lm/2ToXsDEzEptJrGhx1HpR1NKBv37LZ7My9uMX/cI="; };
    # SO/TY "gf" (non-4) siblings in the same AX210 family (other AX210/AX211 SKUs).
    "iwx-so-a0-gf-a0-${apiRev}"  = { lf = "iwlwifi-so-a0-gf-a0-${apiRev}.ucode";  hash = "sha256-h1kOqVNaiTn92ylrx2IvOpAPKPR7RctOQ1oqHV9JbM0="; };
    "iwx-so-a0-gf-a0.pnvm"       = { lf = "iwlwifi-so-a0-gf-a0.pnvm";             hash = "sha256-DqWurBB8iP9zcRiNki/lM3xQYOfhtMZQUzmNt5jZwP0="; };
    "iwx-ty-a0-gf-a0-${apiRev}"  = { lf = "iwlwifi-ty-a0-gf-a0-${apiRev}.ucode";  hash = "sha256-/Yl32/rP5QuKZgFHmqn/0h0B4nTkqe/ROTXdnWZ/1Fs="; };
    "iwx-ty-a0-gf-a0.pnvm"       = { lf = "iwlwifi-ty-a0-gf-a0.pnvm";             hash = "sha256-bsdpu1FEnB8cuw1SjY1fPcid51RidJE0YOEaSw2hnmw="; };
  };

  # Index-matched target names for the install phase (the OpenBSD names, with the
  # iwx- prefix loadfirmware() asks for). lib.attrNames and lib.mapAttrsToList
  # iterate attrs in the same (sorted) order, so names[i] pairs with srcs[i].
  obsdNames = lib.attrNames blobs;
in
# ⚠️ MEASURED, not assumed: nixpkgs defines unfreeRedistributableFirmware WITHOUT
# `free = false`, so it evaluates as free=true and does NOT trip allowUnfree.
# That is deliberate upstream -- it lets linux-firmware install by default. It
# also means tagging this package with that licence provides NO gate at all, so
# the block below is what actually enforces the opt-in.
lib.throwIf (!acceptFirmwareLicense) ''
  iwx-firmware requires proprietary Intel firmware blobs.

  AX2xx wireless hardware does not function without them, and no free
  alternative exists on any operating system.

  Set hardware.wirelessIwx.allowUnfreeFirmware = true (which passes
  acceptFirmwareLicense here) to accept Intel's redistributable-firmware
  licence terms.
''
stdenvNoCC.mkDerivation {
  pname = "iwx-firmware";
  version = "${rev}-api${apiRev}";

  srcs = lib.mapAttrsToList (obsdName: b: fetchurl {
    name = obsdName;
    url = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/${b.lf}?id=${rev}";
    inherit (b) hash;
  }) blobs;

  dontUnpack = true;
  dontBuild = true;

  # srcs (above) is already a derivation attribute, so the builder sees $srcs.
  # Add the index-matched target names: srcs[i] installs as $out/firmware/<names[i]>,
  # the exact name iwx's loadfirmware(sc_fwname) and the PNVM load ask for (OpenBSD
  # keeps the iwx- prefix, e.g. "iwx-so-a0-gf4-a0-77" and "iwx-so-a0-gf4-a0.pnvm").
  names = obsdNames;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/firmware
    set -- $srcs
    for nm in $names; do
      f=$1; shift
      install -m 0444 "$f" "$out/firmware/$nm"
    done
    # The AX211 needs BOTH its ucode and its PNVM; a missing one presents as
    # "wifi does not work" much later, on hardware. Fail loudly here instead.
    for need in iwx-so-a0-gf4-a0-${apiRev} iwx-so-a0-gf4-a0.pnvm; do
      [ -f "$out/firmware/$need" ] || { echo "iwx-firmware: missing $need" >&2; exit 1; }
    done
    n=$(ls -1 "$out/firmware" | wc -l)
    echo "iwx-firmware: installed $n blob(s)" >&2
    runHook postInstall
  '';

  meta = with lib; {
    description = "Intel AX2xx (iwlwifi) firmware, named for the OpenBSD iwx driver";
    homepage = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git";
    # Accurate licence tag. NOTE it is NOT the gate: nixpkgs gives this licence
    # free=true so that linux-firmware works out of the box, so allowUnfree does
    # not bite here. The acceptFirmwareLicense throw above is the enforcement.
    license = licenses.unfreeRedistributableFirmware;
    sourceProvenance = with sourceTypes; [ binaryFirmware ];
    platforms = [ "x86_64-solaris" ];
  };
}
