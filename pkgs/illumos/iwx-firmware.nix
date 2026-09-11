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

  # Map: OpenBSD's expected name <- the linux-firmware filename.
  # Derived from if_iwxvar.h's IWX_*_FW defines; see PROVENANCE.md for the table.
  blobs = {
    "iwx-cc-a0-${apiRev}" = "iwlwifi-cc-a0-${apiRev}.ucode";
    "iwx-QuZ-a0-hr-b0-${apiRev}" = "iwlwifi-QuZ-a0-hr-b0-${apiRev}.ucode";
    "iwx-Qu-b0-hr-b0-${apiRev}" = "iwlwifi-Qu-b0-hr-b0-${apiRev}.ucode";
    "iwx-Qu-c0-hr-b0-${apiRev}" = "iwlwifi-Qu-c0-hr-b0-${apiRev}.ucode";
    "iwx-Qu-b0-jf-b0-${apiRev}" = "iwlwifi-Qu-b0-jf-b0-${apiRev}.ucode";
    "iwx-QuZ-a0-jf-b0-${apiRev}" = "iwlwifi-QuZ-a0-jf-b0-${apiRev}.ucode";
    "iwx-so-a0-gf-a0-${apiRev}" = "iwlwifi-so-a0-gf-a0-${apiRev}.ucode";
    "iwx-ty-a0-gf-a0-${apiRev}" = "iwlwifi-ty-a0-gf-a0-${apiRev}.ucode";
  };
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

  # NOTE: hashes are left as the SRI zero-pad placeholder deliberately. Each must
  # be filled from a real fetch before this builds -- an invented hash is worse
  # than an obviously-empty one, because it fails at download time with a
  # confusing mismatch instead of failing loudly here.
  srcs = lib.mapAttrsToList (obsdName: lfName: fetchurl {
    name = obsdName;
    url = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/${lfName}?id=${rev}";
    hash = lib.fakeHash;
  }) blobs;

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/firmware
    # Install under the names iwx actually asks loadfirmware() for.
    for f in $srcs; do
      base=$(basename "$f" | sed 's/^[a-z0-9]*-//')
      install -m 0444 "$f" "$out/firmware/$base"
    done
    # Fail loudly if the mapping produced nothing -- a silent empty firmware
    # directory would present as "wifi does not work" much later, on hardware.
    n=$(ls -1 "$out/firmware" | wc -l)
    [ "$n" -ge 1 ] || { echo "iwx-firmware: no blobs installed" >&2; exit 1; }
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
