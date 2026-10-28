# graphics/cosmic-apps.nix -- the COSMIC 1.5.0 session, shell and apps (what NixOS
# services.desktopManager.cosmic installs) as cargoApp derivations. Each: the upstream
# epoch-1.5.0 tag (an FOD), its cargo vendor (an FOD), the illumos fixups, a run check.
# Features drop only what has no illumos backend (systemd/logind/journald, PipeWire,
# BlueZ, io_uring, gvfs/glib, flatpak, wgpu); each drop is named where it happens.
{ src, vendorOf, cargoApp, graphics, vendorHashes }:
let
  inherit (graphics) libxkbcommon wayland libffi mesa libdrm;
  client = [ libxkbcommon wayland libffi ];
  # wrap: wgpu panics with no backend (iced falls back only on Err), and libumem's sbrk
  # backend fails the first malloc of these large images (cosmic-desktop.nix, measured).
  appWrap = "ICED_BACKEND=tiny-skia UMEM_OPTIONS=backend=mmap";
  app = { pname, repo ? pname, sha256, libs ? client, required ? "rustix wayland-backend", stubs ? true,
          wrap ? appWrap, NO_SOFTBUFFER_KMS ? "1", ... }@a: cargoApp ({
    version = "1.5.0";
    src = src repo sha256;
    vendor = vendorOf { pname = "${pname}-1.5.0"; src = src repo sha256; narHash = vendorHashes.${pname}; };
    inherit libs required stubs wrap NO_SOFTBUFFER_KMS;
    appFixups = pname;
  } // removeAttrs a [ "repo" "sha256" "libs" "required" "stubs" "wrap" "NO_SOFTBUFFER_KMS" ]);
in {
  # Tier 1: session plumbing. NixOS cosmic-session; autostart without systemd (XDG scan).
  cosmic-session = app {
    pname = "cosmic-session"; sha256 = "c71cfe8061d3ea03534f594c05c99fcc4ea2cac4c30edeb96ac83554d8a67910";
    libs = [ ]; required = "rustix"; stubs = false; wrap = ""; features = "autostart"; bins = "cosmic-session";
    # start-cosmic as NixOS patches it: store paths for cosmic-session and dbus-run-session.
    install = ''
      sed -e "s|/usr/bin/cosmic-session|$out/bin/cosmic-session|" -e "s|/usr/bin/dbus-run-session|${graphics.dbus}/bin/dbus-run-session|" data/start-cosmic > "$out/bin/start-cosmic"
      chmod 0755 "$out/bin/start-cosmic"; grep -q "$out/bin/cosmic-session" "$out/bin/start-cosmic"
      sed "s|/usr/bin/start-cosmic|$out/bin/start-cosmic|" data/cosmic.desktop > cosmic.desktop
      install -Dm0644 cosmic.desktop "$out/share/wayland-sessions/cosmic.desktop"
      install -Dm0644 data/cosmic-mimeapps.list "$out/share/applications/cosmic-mimeapps.list"
    '';
    # no compositor here: it must start, try to spawn its compositor, and exit non-signalled.
    check = "runok cosmic-session /nonexistent-compositor";
  };
  # Tier 2: the shell. cosmic-panel is a nested compositor (smithay GLES on EGL), so it
  # needs Mesa's libEGL on its RUNPATH (smithay dlopens it); -p: the bin crate only.
  cosmic-panel = app {
    pname = "cosmic-panel"; sha256 = "66d8dfbc8aa62ff6a91e83e5bdcb5363c663aac5a58c111152b258054a815222";
    libs = client ++ [ mesa libdrm ]; required = "rustix wayland-backend smithay"; stubs = false;
    cargoArgs = "-p cosmic-panel-bin"; bins = "cosmic-panel";
    install = "schema data/default_schema";
    check = "runok cosmic-panel";   # loads its config, then fails to connect: no compositor
  };
  # One multicall binary (argv[0] picks the applet) + cosmic-panel-button. Dropped: the
  # bluetooth applet (bluer is compile_error! off Linux). battery/input-sources link the
  # libudev STUB; they start, and udev_new() fails as an Err at run time.
  cosmic-applets = app {
    pname = "cosmic-applets"; sha256 = "ac9328e58f5e9cb9c7561a2ce4af212d4916d97c820741f0959366c7e1a0e3ba";
    cargoArgs = "-p cosmic-applets -p cosmic-panel-button"; bins = "cosmic-applets cosmic-panel-button";
    install = ''
      link cosmic-applets cosmic-app-list cosmic-applet-a11y cosmic-applet-audio cosmic-applet-battery \
        cosmic-applet-minimize cosmic-applet-network cosmic-applet-notifications cosmic-applet-power \
        cosmic-applet-status-area cosmic-applet-tiling cosmic-applet-time cosmic-applet-workspaces cosmic-applet-input-sources
      for d in */data/icons; do tree "$d" share/icons/hicolor; done
      schema cosmic-app-list/data/default_schema
      app $(ls target/xdgen/*.desktop | grep -v Bluetooth)
    '';
    # panel-button takes the desktop id of the button it draws (as cosmic-panel launches it),
    # found on XDG_DATA_DIRS: use one this package installs.
    check = "runok cosmic-applet-time; XDG_DATA_DIRS=$out/share runok cosmic-panel-button com.system76.CosmicAppList";
  };
  cosmic-launcher = app {
    pname = "cosmic-launcher"; sha256 = "908cb0ef7e609ce0dec59f6d1cb4c249551883da42c957cd9dcb2e45892c7ec7";
    bins = "cosmic-launcher";
    install = "app data/com.system76.CosmicLauncher.desktop; meta data/com.system76.CosmicLauncher.metainfo.xml; icon data/icons/com.system76.CosmicLauncher.svg";
  };
  cosmic-app-library = app {
    pname = "cosmic-app-library"; sha256 = "39dfa91d807240585ece7794190229832cb0c48162d87a29d62fb6a43a5238e6";
    bins = "cosmic-app-library"; features = "";
    install = "app data/com.system76.CosmicAppLibrary.desktop; for f in data/icons/*.svg; do icon $f; done";
  };
  cosmic-notifications = app {   # no systemd (journald) feature
    pname = "cosmic-notifications"; sha256 = "8c60dd4c2161a2b9d2314597e141c600da9882fe774858283303370b2409ead7";
    bins = "cosmic-notifications";
  };
  cosmic-osd = app {
    pname = "cosmic-osd"; sha256 = "de1a409c95305059f0c79f1dff0089f7cf6aaf9b2b7201e982da9895d58ad4a3";
    bins = "cosmic-osd";
  };
  cosmic-bg = app {   # no avif (dav1d); png/jpeg/webp/jxl stay
    pname = "cosmic-bg"; sha256 = "12b30c60e15ac6c0f4b3eca8c37642145683e830833b429958222dfc395db177";
    bins = "cosmic-bg"; stubs = false; install = "schema data/v1 com.system76.CosmicBackground/v1";
  };
  cosmic-workspaces = app {   # GBM screencopy thumbnails: libgbm from Mesa
    pname = "cosmic-workspaces"; repo = "cosmic-workspaces-epoch"; sha256 = "d7b54ce8dd229c6b76c2132b38d0814df656439bd4c014d04bd052143dcf4249";
    libs = client ++ [ mesa libdrm ]; bins = "cosmic-workspaces";
    install = "app data/com.system76.CosmicWorkspaces.desktop; icon data/com.system76.CosmicWorkspaces.svg";
  };
  cosmic-randr = app {
    pname = "cosmic-randr"; sha256 = "55b7d6070f05c12477f18c1c72beab9f1f5409cd83b63c31846c8c1739993aa2";
    libs = [ wayland libffi ]; stubs = false; wrap = ""; bins = "cosmic-randr";
  };
  cosmic-idle = app {
    pname = "cosmic-idle"; sha256 = "f6eab0ed81bba6bd3a6dfb3ec78471a152852c59e6887a74206f4b59865df7c1";
    stubs = false; wrap = ""; bins = "cosmic-idle";
  };

  # Tier 3: the apps.
  cosmic-settings = app {
    pname = "cosmic-settings"; sha256 = "06070fae46b77a57f906b0ee670e9d5c8ec10604359653bc6ca7b1eece6237ec";
    # Dropped pages: sound (PipeWire), bluetooth (BlueZ); avif (dav1d). openrc: the non-systemd
    # service-manager arm the app requires one of (main.rs compile_error!).
    features = "wayland,single-instance,openrc,dbus-config,a11y,xdg-portal,page-about,page-date,page-default-apps,page-display,page-input,page-legacy-applications,page-networking,page-power,page-region,page-users,page-window-management,page-workspaces,page-accessibility";
    cargoArgs = "-p cosmic-settings"; bins = "cosmic-settings";
    install = ''
      meta resources/com.system76.CosmicSettings.metainfo.xml; app target/xdgen/*.desktop
      schema resources/default_schema; tree resources/icons share/icons/hicolor
    '';
  };
  cosmic-files = app {   # no io-uring (compio), gvfs (glib/gio), wgpu
    pname = "cosmic-files"; sha256 = "da8567bcd0a15ca6522a8800ec800701f8e994ef5da52513b3afdf95370e3bf1";
    features = "dbus-config,desktop,notify,wayland,bzip2,lzma-rust2"; cargoArgs = "-p cosmic-files"; bins = "cosmic-files";
    install = "app res/com.system76.CosmicFiles.desktop; meta res/com.system76.CosmicFiles.metainfo.xml; tree res/icons/hicolor share/icons/hicolor";
  };
  cosmic-edit = app {    # no gvfs, wgpu
    pname = "cosmic-edit"; sha256 = "d567902b1e04829eedd428cd37372137908947cfafccc14ba485b1ad58832cba";
    features = "dbus-config,wayland"; bins = "cosmic-edit";
    install = "app res/com.system76.CosmicEdit.desktop; meta res/com.system76.CosmicEdit.metainfo.xml; tree res/icons/hicolor share/icons/hicolor";
  };
  # No flatpak (libflatpak needs glib/ostree), no packagekit: the pkgar backend only, so the
  # store opens and lists nothing installable. NixOS installs cosmic-store only with flatpak.
  cosmic-store = app {
    pname = "cosmic-store"; sha256 = "5a1ed7f9e241b498592437f1d4bc125d39a6c743de15629148a2d27f4402610c";
    features = "dbus-config,notify,single-instance,wayland,xdg-portal,desktop,logind,pkgar"; bins = "cosmic-store";
    install = "app res/com.system76.CosmicStore.desktop; meta res/com.system76.CosmicStore.metainfo.xml; tree res/icons/hicolor share/icons/hicolor";
  };
  cosmic-screenshot = app {
    pname = "cosmic-screenshot"; sha256 = "2a0a1fb18303773fbfe54613b0b5603871a72cbbb5b0ae183b5390227671b9a3";
    libs = [ ]; stubs = false; wrap = ""; required = "rustix"; bins = "cosmic-screenshot";
    install = "app resources/com.system76.CosmicScreenshot.desktop; tree resources/icons/hicolor share/icons/hicolor";
  };

  # Tier 4: the greeter (+ its daemon). PAM is illumos libpam (pam-sys bindgen on the host
  # clang, pam-client's Solaris arms). No logind/systemd; upower over D-Bus stays.
  cosmic-greeter = app {
    pname = "cosmic-greeter"; sha256 = "bbd49754abdef813b8bf86fa3e724c243d0baca27447b8f908c85cfe2a60a73e";
    features = "upower"; cargoArgs = "--all"; bins = "cosmic-greeter cosmic-greeter-daemon";
    env = { VERGEN_GIT_SHA = "epoch-1.5.0"; VERGEN_GIT_COMMIT_DATE = "2026-01-01"; };   # nixpkgs: VERGEN_GIT_SHA = tag
    install = ''
      # COSMIC_COMP stays a run-time variable in the script (the module sets it to the store cosmic-comp).
      sed "s|exec cosmic-comp cosmic-greeter|exec \''${COSMIC_COMP:-cosmic-comp} $out/bin/cosmic-greeter|" cosmic-greeter-start.sh > "$out/bin/cosmic-greeter-start"
      chmod 0755 "$out/bin/cosmic-greeter-start"; grep -qF 'exec ''${COSMIC_COMP:-cosmic-comp} ' "$out/bin/cosmic-greeter-start"
      install -Dm0644 dbus/com.system76.CosmicGreeter.conf "$out/share/dbus-1/system.d/com.system76.CosmicGreeter.conf"
    '';
    check = "runok cosmic-greeter --help; runok cosmic-greeter-daemon --help";
  };
  # greetd 0.10.3 (NixOS services.greetd): the login daemon cosmic-greeter runs under.
  # illumos VT ioctls and /dev/vt/N, no PR_SET_PDEATHSIG (greetd-illumos.py); PAM is
  # illumos libpam through pam-sys 0.5's prebuilt bindings.
  greetd = let s = import <nix/fetchurl.nix> {
    name = "greetd-0.10.3.tar.gz"; url = "https://git.sr.ht/~kennylevinsen/greetd/archive/0.10.3.tar.gz";
    sha256 = "ee5cb70e0add4ca9c9fe57e47581ab0002d44c07743fb5492469f3b570db640b"; }; in cargoApp {
    pname = "greetd"; version = "0.10.3"; src = s;
    vendor = vendorOf { pname = "greetd-0.10.3"; src = s; narHash = vendorHashes.greetd; };
    libs = [ ]; required = "nix pam-sys"; bins = "greetd agreety";   # NixOS ships these two (fakegreet is a test greeter)
    prep = ''
      python3 $fixups/greetd-illumos.py $PWD
      python3 $fixups/pam-sys05-illumos.py vendor/pam-sys $gate/usr/include/security/pam_appl.h
      c=vendor/pam-sys/.cargo-checksum.json   # re-stamp both edited files
      for f in src/types.rs src/wrapped.rs; do
        sed -i "s|\"$f\":\"[0-9a-f]\{64\}\"|\"$f\":\"$(sha256sum vendor/pam-sys/$f | cut -d' ' -f1)\"|" $c
      done
    '';
    install = "install -Dm0644 config.toml $out/share/greetd/config.toml";
  };
}
