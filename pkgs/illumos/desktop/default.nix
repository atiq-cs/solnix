# desktop/ -- desktop apps outside graphics/ (NixOS services.desktopManager.cosmic's systemPackages that the core
# COSMIC set lacks). Its own dir on purpose: graphics/cosmic.nix passes fixups = ./., so any file added there moves
# all 21 COSMIC derivations. Rust here builds on ../cargo.nix cargoPkg; the one shared file, the vendor fixup, is
# imported by path (a single store file), which leaves graphics/ and its outputs unchanged.
{ cargoPkg, graphics, fd, mkSrcPkg, bash, coreutils, gnugrep, gnused, file, hostname, jq, hostfixTools, world, python3, hostTools }:
let
  fetchurl = import <nix/fetchurl.nix>;
  gh = repo: sha256: { url = "https://codeload.github.com/pop-os/${repo}/tar.gz/refs/tags/epoch-1.5.0"; inherit sha256; };
in (import ./data.nix { tools = hostfixTools; inherit world python3; }) // (import ./xdg.nix { inherit mkSrcPkg bash coreutils gnugrep gnused file hostname hostTools; }) // {
  # the desktop's help: man: handler, launcher man search, Solnix Manual entry (./help.nix)
  solnix-help = import ./help.nix { inherit bash coreutils gnused gnugrep jq; };
  # the NetworkManager D-Bus subset COSMIC's network applet and Settings call, over dladm/ipadm (src/solnix-nm,
  # services.solnix-nm). Its unit and join-path tests need a session bus, so they run beside the build, not in it.
  solnix-nm = cargoPkg {
    pname = "solnix-nm"; version = "0.1.0"; src.dir = ../../../src/solnix-nm;
    vendorHash = "sha256-ceMF/hSWuVF/Kycmd2s91h62tQlz7nC1BD6yVblgkfk=";
    bins = "solnix-nm";
    man = ''install -D -m0444 dbus/org.freedesktop.NetworkManager.conf "$out/share/dbus-1/system.d/org.freedesktop.NetworkManager.conf"'';
    # it starts, finds no bus, and says so (exit 1, no signal): the binary loads and runs (|| keeps set -e from ending the build)
    check = ''rc=0; o=$(env -i DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent "$out/bin/solnix-nm" 2>&1) || rc=$?
      [ $rc -eq 1 ] && echo "$o" | grep -q /nonexistent || { echo "FATAL: solnix-nm rc $rc: $o" >&2; exit 1; }
      grep -q NetworkManager "$out/share/dbus-1/system.d/org.freedesktop.NetworkManager.conf"'';
  };
  # UPower and power profiles for COSMIC (Settings > Power, the battery applet), over acpi_drv kstats and power.conf
  # (src/solnix-power, services.solnix-power). Its D-Bus tests need a session bus, so they run beside the build.
  solnix-power = cargoPkg {
    pname = "solnix-power"; version = "0.1.0"; src.dir = ../../../src/solnix-power;
    vendorHash = "sha256-TUjXZnEnsAK55ihs/NsHv2YiYTOiWOlkGtiiO7JouIY=";
    bins = "solnix-power";
    man = ''install -D -m0444 dbus/org.freedesktop.UPower.conf "$out/share/dbus-1/system.d/org.freedesktop.UPower.conf"'';
    check = ''rc=0; o=$(env -i DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent "$out/bin/solnix-power" 2>&1) || rc=$?
      [ $rc -eq 1 ] && echo "$o" | grep -q /nonexistent || { echo "FATAL: solnix-power rc $rc: $o" >&2; exit 1; }
      grep -q UPower.PowerProfiles "$out/share/dbus-1/system.d/org.freedesktop.UPower.conf"'';
  };
} // rec {
  # pop-launcher (pop-os/launcher epoch-1.5.0 = NixOS's 1.2.7 + the discrete-GPU menu fix): the search service
  # cosmic-launcher runs from PATH, with its plugins (desktop entries, files, find, calc, scripts, ...).
  pop-launcher = cargoPkg {
    pname = "pop-launcher"; version = "1.5.0";
    src = gh "launcher" "39858eb5a15dac23604981a045db219a7cd435bc9d553974fa653ee0431f9871";
    vendorHash = "sha256-ojAPObOxDpN7vPQYSbPXc4HbRL21EB1yN/DWD1p/fho=";
    pkg = "pop-launcher-bin"; bins = "pop-launcher-bin";
    libs = [ graphics.libxkbcommon ];   # smithay-client-toolkit (cosmic-toplevel plugin) links -lxkbcommon
    # gettext-sys (freedesktop-desktop-entry): the illumos libintl, as graphics/cosmic-build.sh does.
    # SOURCE_DATE_EPOCH, as mk-src-pkg.nix (NixOS stdenv): mimalloc's options.c bakes __DATE__ __TIME__, and two
    # builds differed in exactly those bytes ("21:39:08" vs "21:48:11", nix-store --check, measured on chef).
    env = ''export GETTEXT_DIR="$gate" GETTEXT_LIB_DIR="$gate/usr/lib/amd64" GETTEXT_INCLUDE_DIR="$gate/usr/include" SOURCE_DATE_EPOCH=315532800'';
    # rustix ioctls, wayland-backend's illumos socket arms, and polling's epoll backend (the calloop self-wake fix):
    # the vendor fixups every COSMIC client takes. Then the source edits (./pop-launcher-src-fixup.py).
    prep = ''
      PATH="''${python3:+$python3/bin:}$PATH"   # hash B's cargo-build.sh drops /usr/bin python3 from PATH; it passes $python3
      REQUIRED="rustix wayland-backend polling" /usr/bin/bash ${../graphics/cosmic-comp-vendor-fixup.sh} "$PWD/$V"
      python3 ${./pop-launcher-src-fixup.py} "$PWD" "$out" "${fd}"
      # mimalloc 2.x (libmimalloc-sys, pop-launcher-bin's global allocator): on 64-bit, _mi_ptr_segment calls a segment
      # NULL when it is <= 0 as intptr_t. illumos amd64 user addresses are 0xfffffc7f..., negative as intptr_t, so every
      # segment was NULL and the first malloc dereferenced it: pop-launcher SIGSEGV at startup on lixi (gpuhang2 G2-1,
      # from the core: segment 0xfffffc7f80000000, jle taken). Use the pointer test mimalloc's 32-bit branch uses.
      vfix libmimalloc-sys c_src/mimalloc/v2/include/mimalloc/internal.h \
        "'  return ((intptr_t)segment <= 0 ? NULL : segment);\n'" "'  return (p==NULL ? NULL : segment);\n'"
    '';
    # the justfile's install-bin + install-plugins + install-scripts (cargoPkg's man hook runs in the source root)
    man = ''
      mv "$out/bin/pop-launcher-bin" "$out/bin/pop-launcher"
      d="$out/share/pop-launcher"
      for p in calc desktop_entries files find pop_shell pulse recent scripts terminal web cosmic_toplevel; do
        mkdir -p "$d/plugins/$p"; install -m0644 plugins/src/$p/*.ron "$d/plugins/$p/"
        ln -s ../../../../bin/pop-launcher "$d/plugins/$p/$(echo $p | sed 's/_/-/')"
      done
      mkdir -p "$d/scripts"; cp -R scripts/. "$d/scripts/"
    '';
    # The service must find a desktop entry through its installed desktop-entries plugin (argv[0] dispatch,
    # plugin.ron, the store plugin path), and must NOT find it once the entry is gone (negative control).
    check = ''
      q() {  # q <data-home>: search "solnixcheck", wait for the Update, then Exit
        o="$W/q-$(basename "$1").out"; : > "$o"
        ( printf '{"Search":"solnixcheck"}\n'
          for ((i = 0; i < 30; i++)); do grep -q '"Update"' "$o" && break; sleep 1; done; printf '"Exit"\n' ) |
          env -i PATH="$PATH" HOME="$W/chkhome" XDG_DATA_HOME="$1" XDG_DATA_DIRS="$W/none" timeout 60 "$out/bin/pop-launcher" > "$o" 2> "$o.err" || true
        grep -q '"Update"' "$o" || { echo "FATAL: pop-launcher sent no Update:" >&2; head -c 600 "$o" "$o.err" >&2; exit 1; }
        echo "$o"
      }
      mkdir -p "$W/chkhome" "$W/with/applications" "$W/without/applications"
      printf '[Desktop Entry]\nType=Application\nName=Solnixcheck\nExec=/usr/bin/true\n' > "$W/with/applications/solnixcheck.desktop"
      a=$(q "$W/with"); b=$(q "$W/without")   # an assignment: set -e stops the build if either sent no Update
      grep -q '"name":"Solnixcheck"' "$a" || { echo "FATAL: desktop entry not found" >&2; head -c 600 "$a" >&2; exit 1; }
      ! grep -q 'Solnixcheck' "$b" || { echo "FATAL: negative control found an absent entry" >&2; exit 1; }
      echo "CHECK-OK: desktop-entries plugin found the entry; negative control did not" >&2
    '';
  };

  # cosmic-wallpapers (data, NixOS 1.x: share/backgrounds/cosmic). The JPEGs are git-LFS objects; GitHub's archive
  # serves them resolved, so the guard fails on an LFS pointer (a text file) instead of shipping one.
  cosmic-wallpapers = derivation {
    name = "cosmic-wallpapers-1.5.0"; system = "x86_64-solaris"; builder = "/usr/bin/bash";
    src = fetchurl { name = "cosmic-wallpapers-epoch-1.5.0.tar.gz"; inherit (gh "cosmic-wallpapers" "decdaf0b17fd1fda7de5adf763bb68ef46c39daae1bd627330f66cf1a679b99d") url sha256; };
    tools = hostfixTools; inherit world;   # store tools only (data.nix says why)
    args = [ "-c" ''
      set -eu; export PATH="$tools/bin:$world/bin:$world/usr/bin"; /usr/bin/bash ${../path-gate.sh}
      tar xzf "$src"; cd cosmic-wallpapers-epoch-1.5.0; n=0
      for f in original/*.jpg; do
        [ "$(od -An -tx1 -N3 "$f" | tr -d ' \n')" = ffd8ff ] || { echo "FATAL: $f is not a JPEG (an LFS pointer?)" >&2; exit 1; }
        install -Dm0644 "$f" "$out/share/backgrounds/cosmic/$(basename "$f")"; n=$((n+1))
      done
      [ "$n" -eq 7 ] || { echo "FATAL: $n wallpapers, want 7" >&2; exit 1; }
      echo "cosmic-wallpapers: $n JPEGs" >&2
    '' ];
  };
}
