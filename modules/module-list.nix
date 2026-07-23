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
  ./system/boot/init/smf.nix
]
