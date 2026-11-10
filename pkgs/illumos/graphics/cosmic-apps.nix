# graphics/cosmic-apps.nix -- the COSMIC 1.11.0 session, shell and apps (what NixOS
# services.desktopManager.cosmic installs) as cargoApp derivations. Each: the upstream
# epoch-1.11.0 tag (an FOD), its cargo vendor (an FOD), the illumos fixups, a run check.
# Features drop only what has no illumos backend (systemd/logind/journald, PipeWire,
# BlueZ, io_uring, gvfs/glib, flatpak, wgpu); each drop is named where it happens.
{ src, vendorOf, cargoApp, graphics, vendorHashes, openssl, libclang ? null }:
let
  inherit (graphics) libxkbcommon wayland libffi mesa libdrm;
  client = [ libxkbcommon wayland libffi ];
  # wrap: wgpu panics with no backend (iced falls back only on Err), and libumem's sbrk
  # backend fails the first malloc of these large images (cosmic-desktop.nix, measured).
  appWrap = "ICED_BACKEND=tiny-skia UMEM_OPTIONS=backend=mmap";
  app = { pname, repo ? pname, sha256, libs ? client, required ? "rustix wayland-backend", stubs ? true,
          wrap ? appWrap, NO_SOFTBUFFER_KMS ? "1", ... }@a: cargoApp ({
    version = "1.11.0";
    src = src repo sha256;
    vendor = vendorOf { pname = "${pname}-1.11.0"; src = src repo sha256; narHash = vendorHashes.${pname}; };
    inherit libs required stubs wrap NO_SOFTBUFFER_KMS;
    appFixups = pname;
  } // removeAttrs a [ "repo" "sha256" "libs" "required" "stubs" "wrap" "NO_SOFTBUFFER_KMS" ]);
in {
  # Tier 1: session plumbing. NixOS cosmic-session; autostart without systemd (XDG scan).
  cosmic-session = app {
    pname = "cosmic-session"; sha256 = "0c3d3e1f0ef534a063621932cdcc15c8af258df5c12ce6023615dc33222ebca5";
    libs = [ ]; required = "rustix"; stubs = false; wrap = ""; features = "autostart"; bins = "cosmic-session";
    # start-cosmic as NixOS patches it: store paths for cosmic-session and dbus-run-session.
    install = ''
      # and patchShebangs: 1.5.0's #!/bin/bash becomes the store bash (publish-gate B9; a solnix host has no /bin/bash)
      sed -e "1s|^#!/bin/bash$|#!$tools/bin/bash|" -e "s|/usr/bin/cosmic-session|$out/bin/cosmic-session|" -e "s|/usr/bin/dbus-run-session|${graphics.dbus}/bin/dbus-run-session|" data/start-cosmic > "$out/bin/start-cosmic"
      chmod 0755 "$out/bin/start-cosmic"; grep -q "$out/bin/cosmic-session" "$out/bin/start-cosmic"
      [ "$(head -1 "$out/bin/start-cosmic")" != "#!/bin/bash" ] || { echo "FATAL: start-cosmic keeps #!/bin/bash" >&2; exit 1; }
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
    pname = "cosmic-panel"; sha256 = "ef0de256580e1f1600c5a662179862976ba0b8475b45e99e9eb2713bed8e1007";
    libs = client ++ [ mesa libdrm ]; required = "rustix wayland-backend smithay"; stubs = false;
    cargoArgs = "-p cosmic-panel-bin"; bins = "cosmic-panel";
    install = "schema data/default_schema";
    check = "runok cosmic-panel";   # loads its config, then fails to connect: no compositor
  };
  # One multicall binary (argv[0] picks the applet) + cosmic-panel-button. Dropped: the
  # bluetooth applet (bluer is compile_error! off Linux). battery/input-sources link the
  # libudev STUB; they start, and udev_new() fails as an Err at run time.
  cosmic-applets = app {
    pname = "cosmic-applets"; sha256 = "d2ad09b72a2dcba2a17f12e557f0e21dc60171eefa54390e4b67bb058f9180e2";
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
    pname = "cosmic-launcher"; sha256 = "82a510d7d472c68cdd1137363704c1f6a91b37de4f48e5a1f844242de79f941d";
    bins = "cosmic-launcher";
    install = "app data/com.system76.CosmicLauncher.desktop; meta data/com.system76.CosmicLauncher.metainfo.xml; icon data/icons/com.system76.CosmicLauncher.svg";
  };
  cosmic-app-library = app {
    pname = "cosmic-app-library"; sha256 = "9ce3f012af1f885b0a99c589e77803c8d7fb76cba7a7202030cae19f1ac2dd55";
    bins = "cosmic-app-library"; features = "";
    install = "app data/com.system76.CosmicAppLibrary.desktop; for f in data/icons/*.svg; do icon $f; done";
  };
  cosmic-notifications = app {   # no systemd (journald) feature
    pname = "cosmic-notifications"; sha256 = "1874d0b5d67a0c6f1c1415f36a094faaac9c82f3ddf4eeb5061c516d778598c8";
    bins = "cosmic-notifications";
  };
  cosmic-osd = app {
    pname = "cosmic-osd"; sha256 = "98f049d10e9746ae9751d10d556eff73b7270d7d99861445ab9171bd140ba416";
    bins = "cosmic-osd";
  };
  # NixOS ships it (services.desktopManager.cosmic corePkgs) and cosmic-session starts it first: theme,
  # shortcuts' system actions, brightness, the audio varlink service. Its audio backend is PipeWire, which
  # illumos lacks: cosmic-apps-src-fixup.py gates the client off, so the audio server has no devices.
  # udev (backlight) links the STUB libudev and fails as an Err at run time. No polkit rule (no polkit).
  cosmic-settings-daemon = app {
    pname = "cosmic-settings-daemon"; sha256 = "1cc494c028a59a0356547c834421495da326622f837221726c15fceb14f3f9f0";
    # a wayland client (cctk): the client libs; openssl for geonames' reqwest (NixOS buildInputs has it too)
    libs = client ++ [ openssl ]; wrap = ""; bins = "cosmic-settings-daemon"; cargoArgs = "--bin cosmic-settings-daemon";
    install = ''install -Dm0644 data/system_actions.ron "$out/share/cosmic/com.system76.CosmicSettings.Shortcuts/v1/system_actions"'';
    check = "runok cosmic-settings-daemon";   # no session bus here: it must start and exit non-signalled
  };
  cosmic-bg = app {   # no avif (dav1d); png/jpeg/webp/jxl stay
    pname = "cosmic-bg"; sha256 = "00e0874b82877378be9cb305139e626f3cd5ef01ad7a1a517de826086adc2652";
    bins = "cosmic-bg"; stubs = false; install = "schema data/v1 com.system76.CosmicBackground/v1";
  };
  cosmic-workspaces = app {   # GBM screencopy thumbnails: libgbm from Mesa
    pname = "cosmic-workspaces"; repo = "cosmic-workspaces-epoch"; sha256 = "4dad3cd1fffe5b377c84948598c666493e5a053e6e1105a958f20a73bea92eab";
    libs = client ++ [ mesa libdrm ]; bins = "cosmic-workspaces";
    install = "app data/com.system76.CosmicWorkspaces.desktop; icon data/com.system76.CosmicWorkspaces.svg";
  };
  cosmic-randr = app {
    pname = "cosmic-randr"; sha256 = "cd04841b780ad13d407a0a3740f827b3fc214dfc198b114d6a83524c2a0ca96e";
    libs = [ wayland libffi ]; stubs = false; wrap = ""; bins = "cosmic-randr";
  };
  cosmic-idle = app {
    pname = "cosmic-idle"; sha256 = "683290f2a67a63fd553f654a34756cbfdcc41b2d2141b79850c58c16643dc63a";
    stubs = false; wrap = ""; bins = "cosmic-idle";
  };

  # Tier 3: the apps.
  cosmic-settings = app {
    pname = "cosmic-settings"; sha256 = "213459e770dc899da7f9d47557b7d3e4e27e1debb8d7af590995bd0f63da0a5e";
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
    pname = "cosmic-files"; sha256 = "ceeea09a6e249192a8e439d416f20391e923cb75c09922297ff9e6b9926e8eb7";
    features = "dbus-config,desktop,notify,wayland,bzip2,lzma-rust2"; cargoArgs = "-p cosmic-files"; bins = "cosmic-files";
    install = "app res/com.system76.CosmicFiles.desktop; meta res/com.system76.CosmicFiles.metainfo.xml; tree res/icons/hicolor share/icons/hicolor";
  };
  cosmic-edit = app {    # no gvfs, wgpu
    pname = "cosmic-edit"; sha256 = "aff1a305a4e7182ae1c360ceac43eff60ba32dc388f872f3ec04624677a6a290";
    features = "dbus-config,wayland"; bins = "cosmic-edit";
    install = "app res/com.system76.CosmicEdit.desktop; meta res/com.system76.CosmicEdit.metainfo.xml; tree res/icons/hicolor share/icons/hicolor";
    # main() daemonizes first (fork::daemon, src/main.rs): runok sees the parent exit 0 while the child
    # keeps running in $W and writing there, and the EXIT trap's removal of $W then fails "File exists"
    # (T5 06:24Z and its retry). Wait for the child, which has no display and exits on its own.
    check = "runok cosmic-edit --help; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f \"^$out/bin/cosmic-edit\" >/dev/null || break; sleep 2; done; ! pgrep -f \"^$out/bin/cosmic-edit\" >/dev/null";
  };
  # No flatpak (libflatpak needs glib/ostree), no packagekit: the pkgar backend only, so the
  # store opens and lists nothing installable. NixOS installs cosmic-store only with flatpak.
  cosmic-store = app {
    pname = "cosmic-store"; sha256 = "d8c95307e4a865ab4681a0be86fea98f82fb052ecc7bcea98fad2b8165c34e83";
    features = "dbus-config,notify,single-instance,wayland,xdg-portal,desktop,logind,pkgar"; bins = "cosmic-store";
    install = "app res/com.system76.CosmicStore.desktop; meta res/com.system76.CosmicStore.metainfo.xml; tree res/icons/hicolor share/icons/hicolor";
  };
  cosmic-screenshot = app {
    pname = "cosmic-screenshot"; sha256 = "0bf658bda69ce67113d58d1ad5d32126218095194cc51f69c27b8d6399962af7";
    libs = [ ]; stubs = false; wrap = ""; required = "rustix"; bins = "cosmic-screenshot";
    install = "app resources/com.system76.CosmicScreenshot.desktop; tree resources/icons/hicolor share/icons/hicolor";
  };

  # Tier 4: the greeter (+ its daemon). PAM is illumos libpam (pam-sys bindgen on libclang,
  # pam-client's Solaris arms). No logind/systemd; upower over D-Bus stays.
  cosmic-greeter = app {
    pname = "cosmic-greeter"; sha256 = "f31c5bac8e50ed5df75cb7d07fb8167e7835dc22b3438a48c8c1f27e7de36e48";
    features = "upower"; cargoArgs = "--all"; bins = "cosmic-greeter cosmic-greeter-daemon";
    env = { VERGEN_GIT_SHA = "epoch-1.11.0"; VERGEN_GIT_COMMIT_DATE = "2026-01-01";   # nixpkgs: VERGEN_GIT_SHA = tag
      # bindgen's libclang (nixpkgs: rustPlatform.bindgenHook = llvmPackages.clang); null: the OI host's (the seed instance)
      libclang = if libclang == null then "/usr/clang/21" else libclang; };
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
