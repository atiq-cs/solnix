# configurations/installer-wired.nix -- the wired/cloud edition of the installer media: no wifi and no GPU modules.
#
# Composed onto an installer configuration in flake.nix: installer-wired = installer.nix + this, installer-live-wired =
# installer-live.nix + this (the live ramdisk; the full one rides in the media store, as for the other editions).
#
# Why it exists: installer.nix lays the iwm/iwx wifi drivers and the i915/NVIDIA modules into the media's kernel tree
# (hardware.wirelessIntel.onMedia, hardware.graphics.onMedia; all unbound at boot, for a runtime bind or load test). Those
# kernel trees are built by mkIwmKernel/mkIwxKernel/mkGpuKernel, whose stripSliceRefs needs /usr/bin/perl, and the NVIDIA
# modules need OpenIndiana's gcc 14 (-msave-args). A solnix host has neither, so until stripSliceRefs takes its tool from
# the store (and NVIDIA builds elsewhere) those media can only be built on an OpenIndiana host. This edition builds on a
# solnix host. It installs over a wired NIC (or a USB ethernet adapter) and is the base for the test AMI, where wifi and a
# GPU mean nothing. An installed system can still enable wifi or i915 in its own configuration.
{ lib, ... }:

{
  hardware.wirelessIntel.onMedia = lib.mkForce false;
  hardware.graphics.onMedia = lib.mkForce false;
}
