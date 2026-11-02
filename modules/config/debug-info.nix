# modules/config/debug-info.nix — separate debug-symbol delivery, system-wide.
#
# The solnix analog of NixOS's config/debug-info.nix (environment.enableDebugInfo).
#
# pkgs/illumos/mk-userland-pkg.nix already builds a SEPARATE `debug` output per
# package: the DWARF is split out of each ELF with GNU objcopy --only-keep-debug
# + --add-gnu-debuglink, keyed by a real .note.gnu.build-id note (injected because
# the Solaris linker emits none), under lib/debug/.build-id/<xx>/<rest>.debug. The
# main output ships stripped of DWARF (but keeps CTF for mdb/dtrace). The `debug`
# output is cached+signed and pulled ONLY when debugging.
#
# This module wires that output system-wide, exactly as NixOS does:
#   * environment.extraOutputsToInstall gains "debug", so modules/config/system-path.nix
#     adds each systemPackage's `debug` output (when it HAS one — mk-userland-pkg
#     packages do; mk-src-pkg ones do not) into the composed profile. The split
#     DWARF then appears at /run/current-system/sw/lib/debug/.build-id.
#   * NIX_DEBUG_INFO_DIRS points gdb at that directory, so gdb resolves split
#     debug BY build-id (the --add-gnu-debuglink + .note.gnu.build-id path).
#   * /etc/gdb/gdbinit sets debug-file-directory to the same tree, for a gdb run
#     with no NIX_DEBUG_INFO_DIRS in its env (belt and suspenders; NixOS relies on
#     the env var). /etc/gdb/gdbinit is the system gdbinit pkgs.solnix.gdb is
#     configured with (--with-system-gdbinit, as nixpkgs); gdb never reads /etc/gdbinit.
#
# Off by default (NixOS default) to keep the closure small; a config/dixi.nix
# sets environment.enableDebugInfo = true to get symbols for every package that
# ships a `debug` output.

{ config, lib, ... }:

let
  inherit (lib) mkOption mkIf types;
  debugDir = "/run/current-system/sw/lib/debug";
in
{
  options.environment.enableDebugInfo = mkOption {
    type = types.bool;
    default = false;
    description = ''
      Install the separate `debug` output of every package that provides one, so
      split debug symbols appear in /run/current-system/sw/lib/debug/.build-id,
      where gdb finds them by build-id. The solnix analog of NixOS's
      environment.enableDebugInfo. mk-userland-pkg packages carry a `debug`
      output; from-source base packages (mk-src-pkg) do not.
    '';
  };

  config = mkIf config.environment.enableDebugInfo {
    environment = {
      # Pull each package's `debug` output into the system profile (honored by
      # modules/config/system-path.nix, which adds pkg.debug when present).
      extraOutputsToInstall = [ "debug" ];

      # Link the split-debug subtree into the profile. solnix's default
      # pathsToLink is [ /bin /sbin /share/man /share/info ] — it does NOT carry
      # /lib, so without this the debug output's lib/debug/.build-id files are
      # filtered out by lib/build-env.nix's prefix match and never reach
      # sw/lib/debug. (NixOS links all of /lib and notes the same tension in a
      # FIXME; solnix links only /lib/debug, keeping the rest of /lib out of the
      # profile.)
      pathsToLink = [ "/lib/debug" ];

      # Point gdb/valgrind at the split-debug tree by build-id.
      sessionVariables.NIX_DEBUG_INFO_DIRS = debugDir;

      # the system gdbinit (gdb --configuration), so a bare `gdb` (no env) still finds the split debug tree.
      generatedEtc."gdb/gdbinit" = ''
        set debug-file-directory ${debugDir}
      '';
    };
  };
}
