# desktop/gtk/gfx.nix -- cairo, pango, gdk-pixbuf, libepoxy, at-spi2-core (atk + atk-bridge) and GTK 3 with ONLY
# its Wayland backend (no X11 on solnix; cosmic-comp has no Xwayland). nixpkgs 7f81d69 versions; X11 arms off.
{ mkSrcPkg, tools, base, zlib, graphics, nixChain, libxml2 }:
let
  m = tools.mesonBuild;
  inherit (base) glib pcre2 libpng libjpeg-turbo freetype fontconfig fribidi harfbuzz;
  inherit (graphics) libffi expat pixman wayland wayland-protocols libxkbcommon mesa dbus;
  # .pc Requires.private chains (glib -> pcre2/libffi, freetype -> png/bz2/brotli): link-time lookups only
  pcPriv = [ pcre2 libffi zlib libpng libjpeg-turbo nixChain.bzip2 nixChain.brotli expat ];
in
rec {
  # cairo: image/png/ft/fc/script surfaces + cairo-gobject. No xlib/xcb (nixpkgs enables them for X11).
  # OI 02-alloca: cairo-colr-glyph-render.c uses alloca without <alloca.h> (illumos does not get it from stdlib.h).
  # _POSIX_PTHREAD_SEMANTICS: the POSIX 2-argument ctime_r (cairo-ps-surface.c), as mesa.nix and OI's CPP_POSIX.
  cairo = mkSrcPkg {
    pname = "cairo"; version = "1.18.4";
    src = { url = "https://cairographics.org/releases/cairo-1.18.4.tar.xz";
            sha256 = "445ed8208a6e4823de1226a74ca319d3600e83f6369f99b14265006599c32ccb"; };
    deps = [ pixman libpng zlib freetype fontconfig glib ];
    linkDeps = pcPriv;
    build = ''
      ${tools.path}
      patch -p1 < ${./patches/cairo-1.18.4-illumos-alloca.patch}
      ${m "-Dxlib=disabled -Dxcb=disabled -Dxlib-xcb=disabled -Dquartz=disabled -Ddwrite=disabled -Dtests=disabled -Dlzo=disabled -Dgtk2-utils=disabled -Dspectre=disabled -Dsymbol-lookup=disabled -Dglib=enabled -Dpng=enabled -Dfreetype=enabled -Dfontconfig=enabled -Dzlib=enabled -Dtee=enabled -Dc_args=-D_POSIX_PTHREAD_SEMANTICS '-Dc_link_args=-lsocket'"}
      for pc in cairo cairo-ft cairo-png cairo-gobject; do
        [ -f "$out/lib/amd64/pkgconfig/$pc.pc" ] || { echo "FATAL: cairo did not install $pc.pc" >&2; exit 1; }
      done
    '';
  };

  # pango: no libthai, no xft (X11), no introspection. OI's pango CFLAGS (XPG8 + the two -Wno-errors) are for the
  # older OI gcc; measured on the build before adding any.
  pango = mkSrcPkg {
    pname = "pango"; version = "1.57.1";
    src = { url = "https://download.gnome.org/sources/pango/1.57/pango-1.57.1.tar.xz";
            sha256 = "e65d6d117080dc3aeeb7d8b4b3b518f7383aa2e6cfce23117c623cd624764c2f"; };
    deps = [ glib harfbuzz fribidi fontconfig freetype cairo ];
    linkDeps = pcPriv ++ [ pixman ];
    build = ''
      ${m "-Dintrospection=disabled -Ddocumentation=false -Dman-pages=false -Dbuild-testsuite=false -Dbuild-examples=false -Dxft=disabled -Dlibthai=disabled -Dsysprof=disabled -Dfontconfig=enabled -Dfreetype=enabled -Dcairo=enabled"}
      # render a line through pango-view with the source's DejaVu test font, to a PNG
      mkdir -p "$TMPDIR/fc"; cp tests/fonts/DejaVuSans.ttf "$TMPDIR/fc/"
      printf '<?xml version="1.0"?><fontconfig><dir>%s</dir><cachedir>%s</cachedir></fontconfig>\n' "$TMPDIR/fc" "$TMPDIR/fcc" > "$TMPDIR/fonts.conf"
      FONTCONFIG_FILE="$TMPDIR/fonts.conf" "$out/bin/pango-view" --no-display --font='DejaVu Sans 20' -t 'solnix' -o "$TMPDIR/p.png"
      [ "$(od -An -tx1 -N4 "$TMPDIR/p.png" | tr -d ' \n')" = 89504e47 ] || { echo "FATAL: pango-view made no PNG" >&2; exit 1; }
    '';
  };

  # gdk-pixbuf: png + jpeg (+ the in-tree gif/ico/bmp/... "others", as nixpkgs) BUILT IN (builtin_loaders=all), so no
  # loaders.cache and no module dir at run time. No tiff (nixpkgs links libtiff; nothing in the browser path needs it),
  # no glycin (Rust, sandboxed via bwrap: Linux only).
  gdk-pixbuf = mkSrcPkg {
    pname = "gdk-pixbuf"; version = "2.44.6";
    src = { url = "https://download.gnome.org/sources/gdk-pixbuf/2.44/gdk-pixbuf-2.44.6.tar.xz";
            sha256 = "140c2d0b899fcf853ee92b26373c9dc228dbcde0820a4246693f4328a27466fa"; };
    deps = [ glib libpng libjpeg-turbo ];
    linkDeps = pcPriv;
    build = ''
      # gettext is in illumos libc (as in glibc; gtk3 checks libc first). gdk-pixbuf always adds -lintl, which NEEDs
      # libintl.so.1, a libc filter the store libc slice does not carry (closure gate FAIL: /lib/64/libintl.so.1, measured).
      grep -q "^intl_dep = cc.find_library('intl', required: false)" meson.build || { echo "FATAL: gdk-pixbuf intl anchor" >&2; exit 1; }
      sed -i "s/^intl_dep = cc.find_library('intl', required: false)/intl_dep = []/" meson.build
      ${m "-Dpng=enabled -Djpeg=enabled -Dtiff=disabled -Dgif=enabled -Dothers=enabled -Dglycin=disabled -Dandroid=disabled -Dbuiltin_loaders=all -Dgio_sniffing=false -Dintrospection=disabled -Ddocumentation=false -Dman=false -Dtests=false -Dinstalled_tests=false -Dthumbnailer=disabled"}
      cat > "$TMPDIR/t.c" <<'EOF'
    #include <gdk-pixbuf/gdk-pixbuf.h>
    int main(int c, char **v) { GError *e = NULL; for (int i = 1; i < c; i++) { GdkPixbuf *p = gdk_pixbuf_new_from_file(v[i], &e);
      if (!p) { g_printerr("%s: %s\n", v[i], e->message); return 1; } g_print("%dx%d\n", gdk_pixbuf_get_width(p), gdk_pixbuf_get_height(p)); } return 0; }
    EOF
      $CC "$TMPDIR/t.c" -o "$TMPDIR/t" -Wl,-R,"$out/lib/amd64" $(PKG_CONFIG_PATH="$out/lib/amd64/pkgconfig" pkg-config --cflags --libs gdk-pixbuf-2.0)
      "$TMPDIR/t" docs/apple-red-1a.png tests/bug143608-comment.jpg > "$TMPDIR/t.out" || { echo "FATAL: gdk-pixbuf could not load png/jpeg" >&2; exit 1; }
      [ "$(wc -l < "$TMPDIR/t.out")" -eq 2 ] || { echo "FATAL: gdk-pixbuf loader output" >&2; exit 1; }
    '';
  };

  # libepoxy: EGL only (Mesa's libEGL/libGLESv2), no GLX/X11. nixpkgs' libgl-path patch is for libglvnd; here the
  # dlopen of libEGL.so.1 resolves through RUNPATH, so mesa's lib dir is a dep (a runtime reference, as nixpkgs' libGL).
  libepoxy = mkSrcPkg {
    pname = "libepoxy"; version = "1.5.10";
    src = { url = "https://github.com/anholt/libepoxy/archive/1.5.10.tar.gz";
            sha256 = "a7ced37f4102b745ac86d6a70a9da399cc139ff168ba6b8002b4d8d43c900c15"; };
    deps = [ mesa ];
    linkDeps = [ wayland graphics.libdrm ];
    build = ''
      ${m "-Degl=yes -Dglx=no -Dx11=false -Dtests=false -Ddocs=false"}
      grep -q 'epoxy_has_egl=1' "$out/lib/amd64/pkgconfig/epoxy.pc" || { echo "FATAL: epoxy without EGL" >&2; exit 1; }
    '';
  };

  # at-spi2-core: libatk, libatspi, libatk-bridge and the a11y bus launcher, no X11. The bus runs the from-source
  # dbus-daemon by store path (nixpkgs points it at /run/current-system/sw/bin/dbus-daemon; solnix's dbus is not in
  # every system path). use_systemd off. __EXTENSIONS__: it builds with _XOPEN_SOURCE=700, which on illumos hides
  # timersub() & co. unless extensions are asked for (glib's meson adds it on sunos itself).
  at-spi2-core = mkSrcPkg {
    pname = "at-spi2-core"; version = "2.60.4";
    src = { url = "https://download.gnome.org/sources/at-spi2-core/2.60/at-spi2-core-2.60.4.tar.xz";
            sha256 = "1a1f5ba9805917f41fc6aa6823dcf887a291d607a427e2d5afb6b5dfa65070c7"; };
    deps = [ glib dbus libxml2 ];
    linkDeps = pcPriv;
    build = ''
      ${m "-Dx11=disabled -Duse_systemd=false -Ddefault_bus=dbus-daemon -Ddbus_daemon=${dbus}/bin/dbus-daemon -Ddocs=false -Dintrospection=disabled -Dgtk2_atk_adaptor=false -Dc_args=-D__EXTENSIONS__ '-Dc_link_args=-lsocket -lnsl'"}
      for pc in atk atspi-2 atk-bridge-2.0; do
        [ -f "$out/lib/amd64/pkgconfig/$pc.pc" ] || { echo "FATAL: at-spi2-core did not install $pc.pc" >&2; exit 1; }
      done
    '';
  };

  # GTK 3 with only the Wayland backend (nixpkgs adds x11 + broadway). Print: file + lpr (no cups). No colord,
  # tracker, cloudproviders, introspection. gtk3-demo/widget-factory build (the HANDOFF GTK test runs gtk3-demo).
  # illumos: evdev button codes without <linux/input.h> (patch); OI's 19-export_dynamic only touches testsuite/,
  # which is off. shm: gdkdisplay-wayland.c already falls back to shm_open("/gdk-wayland-%x") without memfd_create.
  gtk3 = mkSrcPkg {
    pname = "gtk3"; version = "3.24.52";
    src = { url = "https://download.gnome.org/sources/gtk/3.24/gtk-3.24.52.tar.xz";
            sha256 = "80931fa472a77b9a164f6740e3c0b444fac6770054632d35a7ff9d679e5e7b9f"; };
    deps = [ glib cairo pango harfbuzz fribidi fontconfig freetype gdk-pixbuf libepoxy at-spi2-core wayland libxkbcommon mesa ];
    linkDeps = pcPriv ++ [ wayland-protocols pixman graphics.libdrm dbus libxml2 ];
    build = ''
      ${tools.path}
      export PATH=${wayland}/bin:$PATH   # wayland-scanner
      patch -p1 < ${./patches/gtk-3.24.52-illumos-evdev-codes.patch}
      ${m "-Dwayland_backend=true -Dx11_backend=false -Dbroadway_backend=false -Dquartz_backend=false -Dwin32_backend=false -Dxinerama=no -Dcloudproviders=false -Dprofiler=false -Dtracker3=false -Dcolord=no -Dprint_backends=file,lpr -Dintrospection=false -Dgtk_doc=false -Dman=false -Ddemos=true -Dexamples=false -Dtests=false -Dinstalled_tests=false '-Dc_link_args=-lsocket -lnsl'"}
      grep -q 'GDK_WINDOWING_WAYLAND' "$out/include/gtk-3.0/gdk/gdkconfig.h" || { echo "FATAL: no Wayland backend" >&2; exit 1; }
      ! grep -q '^#define GDK_WINDOWING_X11' "$out/include/gtk-3.0/gdk/gdkconfig.h" || { echo "FATAL: X11 backend built" >&2; exit 1; }
      # headless: link a program through gtk+-wayland-3.0.pc; with no compositor gtk_init_check must say FALSE (the real
      # positive test is gtk3-demo in lixi's COSMIC session). gtk3-demo --list needs a display (it activates first).
      printf '#include <gtk/gtk.h>\n#include <gdk/gdkwayland.h>\nint main(int c,char**v){g_print("%%u.%%u.%%u %%d\\n",gtk_get_major_version(),gtk_get_minor_version(),gtk_get_micro_version(),gtk_init_check(&c,&v));return 0;}\n' > "$TMPDIR/t.c"
      $CC "$TMPDIR/t.c" -o "$TMPDIR/t" -Wl,-R,"$out/lib/amd64" $(PKG_CONFIG_PATH="$out/lib/amd64/pkgconfig" pkg-config --cflags --libs gtk+-wayland-3.0)
      env -i PATH=/usr/bin XDG_RUNTIME_DIR="$TMPDIR" WAYLAND_DISPLAY=none "$TMPDIR/t" > "$TMPDIR/t.out" 2>&1
      grep -qx '3.24.52 0' "$TMPDIR/t.out" || { echo "FATAL: gtk_init_check without a display:" >&2; head -3 "$TMPDIR/t.out" >&2; exit 1; }
      env -i PATH=/usr/bin XDG_RUNTIME_DIR="$TMPDIR" WAYLAND_DISPLAY=none "$out/bin/gtk3-demo" > "$TMPDIR/nod.out" 2>&1 && \
        { echo "FATAL: gtk3-demo ran with no display" >&2; exit 1; }
      grep -q 'cannot open display' "$TMPDIR/nod.out" || { echo "FATAL: unexpected no-display error:" >&2; head -3 "$TMPDIR/nod.out" >&2; exit 1; }
    '';
  };

  # grim 1.5.0 (nixpkgs grim): a Wayland screenshot through ext-image-copy-capture-v1, which cosmic-comp 1.5 serves to
  # unsandboxed clients (state.rs client_not_sandboxed). The capture the GTK/Firefox panel runs on lixi read back.
  grim = mkSrcPkg {
    pname = "grim"; version = "1.5.0";
    src = { url = "https://gitlab.freedesktop.org/emersion/grim/-/archive/v1.5.0/grim-v1.5.0.tar.gz";
            sha256 = "9e72a98f7621b1f5741b405b8dbd447acf7d300ddb12667ec526db1ce6154eaa"; };
    deps = [ wayland libpng libjpeg-turbo pixman zlib ];
    linkDeps = [ wayland-protocols libffi ];
    build = ''
      ${tools.path}
      export PATH=${wayland}/bin:$PATH   # wayland-scanner
      # __EXTENSIONS__: getline() under _POSIX_C_SOURCE=200809L on illumos; -Db_ndebug leaves write_ppm.c's assert-only
      # variable unused, and grim builds with -Werror (both measured).
      ${m "-Djpeg=enabled -Dman-pages=disabled '-Dc_args=-D__EXTENSIONS__ -Wno-error=unused-variable'"}
      "$out/bin/grim" -h 2>&1 | grep -q 'Usage: grim' || { echo "FATAL: grim -h" >&2; exit 1; }
    '';
  };
}
