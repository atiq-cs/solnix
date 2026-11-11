# modules/module-list.nix — the solnix base module list.
#
# Analog of nixos/modules/module-list.nix. Every module evaluated for a solnix
# system by default. Grow lazily: add a module here only when a config needs it
# (no speculative modules).
#
# Upstream nixos modules that are OS-agnostic should be pulled by reference
# (nixbsd's extPath pattern, roadmap T1.10) rather than copied. Fork only the
# delta. Those references get added here as they're needed.

[
  ./nixos-compat.nix
  ./config/assertions.nix
  ./config/edition.nix
  ./config/release.nix
  ./config/nix-channel.nix
  ./config/sudo.nix
  ./config/dumpadm.nix
  ./config/zfs.nix
  ./config/coreadm.nix
  ./config/user-limit.nix
  ./config/libumem.nix
  ./config/first-boot-defaults.nix
  ./config/ec2-first-boot.nix
  ./config/ephemeral-pool.nix
  ./config/mtu.nix
  ./config/firewall.nix
  ./config/wireless-iwx.nix
  ./config/graphics-gpu.nix
  ./config/touchpad-i2c-hid.nix
  ./config/audio-hda.nix
  ./config/networking.nix
  ./config/solnix-netd.nix
  ./config/solnix-nm.nix
  ./config/solnix-power.nix
  ./config/solnix-accounts.nix
  ./config/tailscale.nix
  ./config/users.nix
  ./config/system-path.nix
  ./config/documentation.nix
  ./config/debug-info.nix
  ./config/pgfarm.nix
  ./config/cosmic-desktop.nix
  ./config/desktop-cosmic.nix
  ./config/dbus.nix
  ./config/shell-environment.nix
  ./config/nix.nix
  ./config/community/options.nix
  ./config/community/census.nix
  ./config/community/cache-proxy.nix
  ./config/community/builder.nix
  ./config/community/builder-zone.nix
  ./config/community/seed.nix
  ./system/boot/init/smf.nix
  ./system/activation
]
