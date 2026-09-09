# modules/config/cosmic-desktop.nix -- the COSMIC graphical desktop, declaratively.
#
# WHAT THIS REPLACES: the ad-hoc half of scripts/solnix-cosmic-session.sh, which
# exec'd prebuilt binaries from hardcoded /root paths
# (/root/cosmic-gcroots/waveB2-bin/smallvil, /nix/cosmic/cosmic-apps/...). This
# module lets an INSTALLED system select the desktop and get store paths instead.
#
# HONEST SCOPE -- read this before believing the module does more than it does:
#
#   * The APPS listed in solnix.desktop.cosmic.apps are real derivations
#     (pkgs/os-specific/illumos/cosmic/). cosmic-term is BUILT and RUNS on
#     x86_64-illumos; see docs/cosmic-nixification.md for exactly which claims
#     are verified and which are not.
#   * The COMPOSITOR is NOT packaged. smallvil is still a prebuilt binary and
#     cosmic-comp does not work on illumos at all
#     (docs/cosmic-comp-illumos-finding.md). So `enable = true` gives you the
#     applications and the session environment, NOT a running compositor from a
#     store path. solnix.desktop.cosmic.compositor is therefore a PATH to an
#     external binary, deliberately, so this module does not pretend otherwise.
#   * Nothing here has been booted on real hardware yet. It is the declarative
#     seam, wired from measured facts, not a validated desktop.
#
# The two runtime env vars are NOT cosmetic and are the same ones the app
# derivations set as defaults; they are repeated at the session level so a
# hand-launched binary in that session also gets them:
#   ICED_BACKEND=tiny-skia -- wgpu's Instance::new PANICS on illumos (does not
#     return Err), so iced's fallback renderer never fires and every app dies.
#   UMEM_OPTIONS=backend=mmap -- the illumos rustc target links -lumem, and
#     libumem's default sbrk backend returns NULL for the first malloc in these
#     large ET_EXEC Rust images, which Rust turns into abort. Measured 0/8 without
#     it, 8/8 with it.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkEnableOption types mkIf mkDefault;
  cfg = config.solnix.desktop.cosmic;
in
{
  options.solnix.desktop.cosmic = {
    enable = mkEnableOption "the COSMIC graphical desktop (x86_64-illumos)";

    apps = mkOption {
      type = types.listOf types.package;
      default = with pkgs; [ cosmic-term ];
      defaultText = "[ pkgs.cosmic-term ]";
      description = ''
        COSMIC applications to install. Defaults to just cosmic-term, which is
        the one whose binary has actually been built and run on illumos. Add
        cosmic-files / cosmic-edit once you have verified them on your hardware.
      '';
    };

    compositor = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/opt/smallvil/bin/smallvil";
      description = ''
        Path to the Wayland compositor binary to run the session under.

        This is a STRING PATH, not a package, and that is deliberate: the
        compositor is the one piece of this desktop that is still ad-hoc.
        smallvil is the working substrate on illumos and is not packaged;
        cosmic-comp is hard-coupled to DRM/GBM and does not build here at all
        (docs/cosmic-comp-illumos-finding.md). Leaving this null installs the
        apps and the session environment but starts no compositor.
      '';
    };

    waylandDisplay = mkOption {
      type = types.str;
      default = "wayland-1";
      description = ''
        WAYLAND_DISPLAY for the session. Note the measured caveat in
        rust-patches/wayland-client-*-blocking-read-timeout.notes.md: a COSMIC
        app started with WAYLAND_DISPLAY *set* while the compositor is itself a
        nested wayland client can wedge in Connection::roundtrip. The recorded
        launcher workaround is to leave it UNSET so winit takes the X11 path.
      '';
    };
  };

  config = mkIf cfg.enable {
    # roles/: a running system records what it is (see modules/config/edition.nix).
    solnix.roles = [ "cosmic-desktop" ];

    environment.systemPackages = cfg.apps;

    # Session-wide env. mkDefault so a host config can override either.
    environment.variables = {
      ICED_BACKEND = mkDefault "tiny-skia";
      UMEM_OPTIONS = mkDefault "backend=mmap";
      XDG_CURRENT_DESKTOP = mkDefault "COSMIC";
      XDG_SESSION_TYPE = mkDefault "wayland";
    };

    # Fail the BUILD, not the boot, if someone enables the desktop on an
    # architecture where none of this has ever been built. Cheaper to catch here
    # than to debug on a laptop that will not start a session.
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isx86_64;
        message =
          "solnix.desktop.cosmic is only known to build on x86_64-illumos; "
          + "nothing in the COSMIC set has been built for "
          + pkgs.stdenv.hostPlatform.system + ".";
      }
    ];

    warnings = lib.optional (cfg.compositor == null) ''
      solnix.desktop.cosmic.enable is true but no compositor is set, so no
      graphical session will start. This is the honest default: the compositor
      (smallvil) is not yet packaged as a derivation. Set
      solnix.desktop.cosmic.compositor to its path, or expect apps-only.
    '';
  };
}
