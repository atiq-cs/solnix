# configurations/installer-live.nix -- the MINIMAL live-ramdisk edition of the
# solnix installer media.
#
# NixOS precedent: installation-cd-minimal.nix is a 21-line file that composes
# installation-cd-base.nix + one or two toggles. This is that file: it imports
# the full installer config (installer.nix) and makes exactly ONE change --
# system.buildCapable = false -- which drops solnix-dev-full (gcc + the 219 MB
# gate-proto sysroot, ~1.2 GB, 2.5x the live-ramdisk ceiling) from the LIVE
# ramdisk closure.
#
# THE SPLIT (docs/design-two-installer-images.md #1 + #2):
#   * #1 the MINIMAL live root -> the RAM ramdisk (scripts/make-installer-image.sh,
#     the storeContents=[toplevel] closure assembler). It must fit under the X1's
#     measured 816,119,808 B largest-free-block ceiling (RD_MAX_RAW = 700 MiB).
#     Dropping dev-full is what makes it fit.
#   * #2 the FULL installer closure (incl. solnix-dev-full) -> the read-only
#     MEDIA STORE (solnix-store.iso, lofi-mounted at boot, added as
#     `--extra-substituters file://`). scripts/make-iso-usb.sh seeds it from the
#     FULL installer toplevel closure (SOLNIX_STORE_ROOTS).
#
# So install-from-flake (`solnix-install [--flake ...]`) builds the TARGET from
# the media store, which carries the compiler + base closure. The SHIPPED system
# is fully build-capable; only the LIVE ramdisk is minimal. By CONSTRUCTION the
# live root is still the solnix installer toplevel's own from-source closure --
# our world's init, utils and identity -- so there is NO OpenIndiana binary,
# banner or quirk anywhere, exactly as the closure model guarantees.
{ lib, ... }:

{
  imports = [ ./installer.nix ];

  networking.hostName = lib.mkForce "solnix-installer";

  # The ONE change: drop the build toolchain from the live ramdisk closure.
  # installer.nix gates `live.solnix-dev-full` on this option, and the toplevel's
  # disallowed-runtime-refs gate (modules/system/activation/default.nix) then
  # stays active -- a free assertion that the build-only gate proto did not leak
  # into the minimal ramdisk. dev-full is still SHIPPED, in the media store.
  system.buildCapable = lib.mkForce false;
}
