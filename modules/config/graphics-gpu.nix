# GPU kernel drivers: the Intel iGPU (i915, the OpenBSD inteldrm port) and the
# NVIDIA open modules (nvidia, nvidia_modeset, nvidia_i2c).
#
#   hardware.graphics.onMedia            installer media: i915 and the three
#       nvidia modules in the kernel tree, each with a name_to_major line and
#       (i915, nvidia, nvidia_modeset) a minor_perm line, but NO driver_aliases
#       line, so nothing binds at boot. The Iris Xe stays on vgatext (the boot
#       console) and the dGPU stays unbound. See docs/x1e-gpu-runtime-bind.md.
#       NVIDIA's GSP firmware (unfree) is laid in only with
#       hardware.graphics.nvidia.acceptFirmwareLicense.
#   hardware.graphics.i915.attachAtBoot  installed system: also lay the i915
#       module and bind it at boot to pkgs.solnix.i915Aliases (Alder Lake-P
#       8086:46a6, Coffee Lake-H 8086:3e9b), as hardware.wirelessIwm.
#       attachAtBoot does for iwm. This is stage 1 of
#       src/drm-port/i915/STAGED-ATTACH-PLAN.md: the driver takes the console
#       over gfxp_fb and creates card0/renderD128, and the OpenBSD inteldrm
#       modeset runs only on the first open of those nodes.
#
# The driver DB and kernel tree are rendered together with the wifi drivers'
# in modules/config/wireless-iwx.nix (one place renders the final
# system.build.driversDb / kernelTree); this file holds the options.
{ config, lib, ... }:
let
  cfg = config.hardware.graphics;
in
{
  options.hardware.graphics = {
    onMedia = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Put the i915 and NVIDIA open kernel modules into the kernel tree, each
        with a major number and minor_perm entry but no driver_aliases line,
        so none of them attaches at boot. For installer media: the modules are
        there for a supervised load test (modload/modinfo/modunload) without
        risking a boot-time attach of a driver that has never run on that
        silicon. NVIDIA's GSP firmware is added only with
        hardware.graphics.nvidia.acceptFirmwareLicense.
      '';
    };
    i915.attachAtBoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bind the i915 driver at boot: render name_to_major / minor_perm and a
        driver_aliases line for each of pkgs.solnix.i915Aliases, and lay
        kernel/drv/amd64/i915 (pkgs.solnix.i915-driver) into the BE kernel
        tree. Defaults to false: the driver has not attached on hardware yet.
        Enable it only in a boot-once BE (beadm activate -t), with the deadman
        and a dump device armed, per docs/x1e-gpu-runtime-bind.md stage B.
      '';
    };
    i915.acceptFirmwareLicense = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Lay Intel's i915 firmware (pkgs/illumos/i915-firmware.nix: Alder Lake-P
        DMC, GuC and HuC, kernel/firmware/drm/i915/) next to the i915 module.
        Without it the iGPU modesets but has no display power management (DMC)
        and no GuC/HuC. The firmware is unfree, redistributable under
        linux-firmware's LICENSE.i915, which is installed next to the blobs.
        Takes effect with hardware.graphics.i915.attachAtBoot or onMedia.
      '';
    };
    nvidia.acceptFirmwareLicense = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Lay NVIDIA's GSP firmware (pkgs/illumos/nvidia-gsp-firmware.nix,
        kernel/firmware/nvidia/615.71.09/) next to the nvidia modules. Turing
        and newer GPUs do not run without it. The firmware is unfree,
        redistributable for open-source kernels under the NVIDIA Driver License
        Agreement, which is installed next to the blobs. Only takes effect with
        hardware.graphics.onMedia.
      '';
    };
  };
  config.assertions = [{
    assertion = !cfg.nvidia.acceptFirmwareLicense || cfg.onMedia;
    message = ''
      hardware.graphics.nvidia.acceptFirmwareLicense lays NVIDIA's GSP firmware
      next to the nvidia modules, which only hardware.graphics.onMedia ships.
    '';
  }];
}
