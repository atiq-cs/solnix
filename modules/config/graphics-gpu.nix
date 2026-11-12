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
#   hardware.graphics.nvidia.attachAtBoot  installed system: bind nvidia to
#       the RTX 3080 Ti (10de:2420) and bring it up after the dump device, under
#       a thermal guard (site/solnix-nvidia, in ./wireless-iwx.nix). Boot-once
#       BEs only, for now: docs/x1e-gpu-runtime-bind.md section D.
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
    nvidia.onMedia = lib.mkOption {
      type = lib.types.bool;
      default = cfg.onMedia;
      defaultText = lib.literalExpression "config.hardware.graphics.onMedia";
      description = ''
        With hardware.graphics.onMedia, also lay the three NVIDIA open modules
        (unbound) into the media's kernel tree. Off in configurations/installer.nix:
        the modules build only with OpenIndiana's gcc 14 (-msave-args), and they
        never attached from the media (no alias, no GSP firmware). An installed
        system enables them with hardware.graphics.nvidia.attachAtBoot.
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
        Agreement, which is installed next to the blobs. Takes effect with
        hardware.graphics.onMedia or hardware.graphics.nvidia.attachAtBoot.
      '';
    };
    nvidia.attachAtBoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bind the nvidia open module to the X1E's RTX 3080 Ti (pkgs.solnix.
        nvidiaAliases) at boot and bring the GPU up once the dump device is
        armed. Lays the three nvidia modules, nvidia.conf (the /dev/nvidiactl
        pseudo node, NVreg_GpuInitOnProbe=0) and the GSP firmware (under
        usr/kernel/firmware, out of the boot_archive), opts tzmon out of its
        boot-time dGPU power-off (solnix-dgpu-off=0; not with nvidia.rtd3,
        which attaches to the GPU tzmon powered off). A powered dGPU no
        driver manages overheats this laptop (53 to 94 C in ten minutes, then
        the EC cuts power), so site/solnix-nvidia-guard samples the EC's dGPU
        sensor from early boot and reboots at nvidia.maxTempC. After it and
        system/dumpadm, site/solnix-nvidia attaches nvidia and holds
        /dev/nvidia0 open, whose first open runs RmInitAdapter and boots the
        GSP. Use it only in a boot-once BE (beadm activate -t), so that
        reboot lands in a BE without it, where tzmon powers the GPU off.
        nvidia_modeset and nvidia_i2c are laid but not attached. Needs
        nvidia.acceptFirmwareLicense.
      '';
    };
    nvidia.rtd3 = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Runtime D3cold, coarse (NVIDIA's NVreg_DynamicPowerManagement=1): the
        nvidia module powers the dGPU off (D3hot, then the root port's ACPI
        _PR3 power resource off) as soon as the last client has closed it and RM
        has shut the GPU down (as Linux does: a powered GPU with RM down is
        unmanaged and heats), and on
        again at the next open. Without it an attached GPU idles in D0. The
        thermal guard accepts the missing reading of a GPU that is off only
        when both the power resource and the GPU's power GPIO say off. The
        GPU's HDMI audio function is offlined before the first power-off.
        tzmon keeps its boot-time dGPU power-off (no solnix-dgpu-off=0), so
        the GPU is off from about 2 s after the kernel banner, and the guard
        reboots if it is not off at its first sample. site/solnix-nvidia
        then attaches nvidia to it (the cold attach: power on, restore and
        verify the BIOS's BAR and Resizable BAR layout, online; any
        mismatch leaves it off and nvidia detached).
        site/solnix-nvidia probes the GPU once and lets it go instead of
        holding it open. Needs nvidia.attachAtBoot. Measured only on the X1E's
        RTX 3080 Ti; keep it to a boot-once BE until it is.
      '';
    };
    nvidia.modeset = lib.mkOption {
      type = lib.types.bool;
      default = cfg.nvidia.drm;
      defaultText = lib.literalExpression "config.hardware.graphics.nvidia.drm";
      description = ''
        nvidia_modeset (NVKMS): lays nvidia_modeset.conf, and site/solnix-nvidia
        configures /dev/nvidia-modeset after its guarded probe (nvidia_modeset
        refuses to load before RM is up). Loading it allocates no GPU; an
        NVKMS client (nvidia-drm, a probe of /dev/nvidia-modeset) does, for as
        long as it is open. Built only; it has not run on hardware. Keep it to
        a boot-once BE. Needs nvidia.attachAtBoot; nvidia.drm turns it on.
      '';
    };
    nvidia.drm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        nvidia-drm (pkgs.solnix.nvidia-drm-driver, MIT): NVIDIA's DRM driver
        over the OpenBSD drm layer i915 runs on, on top of nvidia_modeset
        (NVKMS). Lays kernel/drv/amd64/nvidia_drm, nvidia_drm.conf and
        nvidia_modeset.conf. After its guarded probe, site/solnix-nvidia
        configures nvidia_modeset (/dev/nvidia-modeset) and starts nvidia-drm,
        which makes /dev/dri/card1 and /dev/dri/renderD129 (i915 keeps card0).
        nvidia-drm asks NVKMS for the GPU only while a card1/renderD129 file or
        a buffer from one is open, so with nvidia.rtd3 an unused dGPU still
        powers off. Not done yet: mmap of buffers (dumb buffers cannot be
        drawn into), PRIME with i915, fbdev. Connectors read disconnected until
        the first open. Built and link-checked only; it has not run on
        hardware. Keep it to a boot-once BE. Needs nvidia.attachAtBoot.
      '';
    };
    nvidia.maxTempC = lib.mkOption {
      type = lib.types.int;
      default = 80;
      description = ''
        The dGPU temperature (C) at which site/solnix-nvidia-guard reboots. The
        sensor is the EC's GPUT (kstat dgputemp:0:ec:gput_C), the one that read
        92-94 C before the EC cut power; it is sampled every 3 s from early
        boot, and a reading it cannot get counts as too hot.
      '';
    };
  };
  config.assertions = [{
    assertion = !cfg.nvidia.acceptFirmwareLicense || (cfg.onMedia && cfg.nvidia.onMedia) || cfg.nvidia.attachAtBoot;
    message = ''
      hardware.graphics.nvidia.acceptFirmwareLicense lays NVIDIA's GSP firmware
      next to the nvidia modules, which only hardware.graphics.onMedia or
      hardware.graphics.nvidia.attachAtBoot ships.
    '';
  } {
    assertion = !cfg.nvidia.rtd3 || cfg.nvidia.attachAtBoot;
    message = ''
      hardware.graphics.nvidia.rtd3 is runtime power management of the bound
      nvidia driver: it needs hardware.graphics.nvidia.attachAtBoot.
    '';
  } {
    assertion = !cfg.nvidia.attachAtBoot || cfg.nvidia.acceptFirmwareLicense;
    message = ''
      hardware.graphics.nvidia.attachAtBoot needs NVIDIA's GSP firmware: the
      GA103 does not initialise without it. Set
      hardware.graphics.nvidia.acceptFirmwareLicense = true to accept the
      NVIDIA Driver License Agreement.
    '';
  } {
    assertion = !(cfg.nvidia.drm || cfg.nvidia.modeset) || cfg.nvidia.attachAtBoot;
    message = ''
      hardware.graphics.nvidia.modeset and .drm run on the bound nvidia driver
      and its RM: they need hardware.graphics.nvidia.attachAtBoot.
    '';
  } {
    assertion = !cfg.nvidia.drm || cfg.nvidia.modeset;
    message = ''
      hardware.graphics.nvidia.drm drives the display through nvidia_modeset:
      it needs hardware.graphics.nvidia.modeset (its default follows drm).
    '';
  } {
    assertion = !(cfg.nvidia.attachAtBoot && cfg.onMedia);
    message = "hardware.graphics.nvidia.attachAtBoot is for an installed system, not installer media (onMedia).";
  }];
}
