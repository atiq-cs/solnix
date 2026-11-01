# hardware.audio.hdaIds -- bind the illumos HD Audio driver (audiohd) to controllers its stock aliases miss.
#
# audiohd binds by class (pciclass,0403 = HD Audio). Intel's newer PCH audio controllers report class 0x0401
# (multimedia audio) because they are SOF/cAVS DSPs whose host side still speaks plain HD Audio: lixi's Alder Lake-P
# controller (8086:51c8) is "pciclass,040100", so nothing binds it and /dev/sound stays empty (measured, cosmic8).
# Linux's snd_hda_intel drives the same controllers in legacy HDA mode by PCI id (dsp_driver=1); this is that.
# Each id is written as a driver_aliases line for audiohd in the BE's driver DB. No runtime update_drv: the bind
# takes effect on the next boot of that BE, so a boot-once BE is the way to try it.
{ config, lib, ... }:
{
  options.hardware.audio.hdaIds = lib.mkOption {
    type = lib.types.listOf (lib.types.strMatching "pci(ex)?[0-9a-f]{1,4},[0-9a-f]{1,4}");
    default = [ ];
    example = [ "pci8086,51c8" ];
    description = ''
      PCI ids (driver_aliases form, lower-case hex: "pci8086,51c8") of HD Audio controllers audiohd should
      bind in addition to its stock aliases. For Intel cAVS/SOF-class controllers that report PCI class 0x0401:
      audiohd drives their HDA link (the analog codec, HDMI) in legacy mode; DMIC arrays and I2S amplifiers
      behind the DSP stay unsupported.
    '';
  };
  # The driver DB is rendered with the wifi/GPU/touchpad drivers in ./wireless-iwx.nix.
}
