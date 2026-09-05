# aarch64 GTK4 toolkit fixes overlay (back-ported from the x86 COSMIC session,
# adapted to the aarch64 CROSS set). Injected into crossOverlays so it applies
# to the aarch64 target packages. Documented fixes: docs/x86-cosmic-stack.md,
# /root/gtk4-progress.txt (x86), /root/waveB1-progress.txt (x86).
#
# Covers the eval/build blockers found on the aarch64 cross toolkit spine:
#   openssl : no solaris64-aarch64 Configure target (eval throw)  -> add one.
#   cairo   : ipc_rmid_deferred_release cross-file has no solaris (eval throw).
#   wayland : illumos port (native epoll/getpeerucred/linux-input shim) so the
#             aarch64 libwayland actually builds (x86 proved Wayland is illumos-
#             portable, not a fetch gap).
#   gtk4    : Wayland-only, strip X-only buildInputs (avoids the X source swath).
#   libadwaita: appstream is heavy + pulls a cross-libc-asserting chain; the x86
#             session used an appstream-minimal. Here we mirror by turning off
#             the optional integrations libadwaita doesn't strictly need.
final: prev:
let
  # aarch64 target syslib shim (docs/aarch64-cross-rust.md): the target's
  # libnsl.so transitively NEEDs libmd (MD5*@SUNW_1.1) / libmp (mp_*@SUNW_1.1),
  # but the aarch64 seed ships libmd.so.1 (versioned-only, no bare libmd.so) so
  # -lmd won't resolve. Materialize bare libmd.so/libmp.so links against the
  # aarch64 libc-seed versioned libs, then link -L<shim>/lib -lmd -lmp.
  aaSeed = builtins.storePath /nix/store/d3wwr0blzzc2f5xysalbavx0wnc9l74z-illumos-aarch64-libc-seed;
  aaSyslibShim = prev.runCommand "aa-syslib-shim" { } ''
    mkdir -p $out/lib
    ln -s ${aaSeed}/lib/libmd.so.1 $out/lib/libmd.so
    ln -s ${aaSeed}/lib/libmp.so.2 $out/lib/libmp.so
  '';
  aaSyslibL = "-L${aaSyslibShim}/lib -lmd -lmp";
in {

  # --- libffi: (1) perl for the Solaris libffi.map-sun symbol-map gen; (2) its
  # Solaris symbol versioning passes `-Wl,-M,libffi.map-sun` (Solaris mapfile
  # syntax) directly via libtool, which GNU ld (the only aarch64 ld) can't parse
  # ("file format not recognized"). cxxNomapCc only fixes the gcc built-in spec,
  # not this explicit flag -> force libffi_cv_var_ld_versionscript=no so configure
  # drops the -M mapfile from the link (symbol versioning off; harmless for ABI).
  libffi = prev.libffi.overrideAttrs (o: {
    nativeBuildInputs = (o.nativeBuildInputs or [ ]) ++ [ final.buildPackages.perl ];
    configureFlags = (o.configureFlags or [ ])
      ++ [ "libffi_cv_var_ld_versionscript=no" "--disable-symvers" ];
  });

  # --- readline: Solaris shobj-conf sets SHLIB_XLDFLAGS='-Wl,-i ...' but GNU ld
  # (the only aarch64 ld) reads -i as -r (relocatable), which conflicts with
  # -shared -> "-r and -shared may not be used together". Drop the -Wl,-i token.
  readline = prev.readline.overrideAttrs (o: {
    postPatch = (o.postPatch or "") + ''
      substituteInPlace support/shobj-conf --replace-warn '-Wl,-i ' "" || true
      substituteInPlace support/shobj-conf --replace-warn "-Wl,-i" "" || true
    '';
  });

  # --- openssl target-config (the eval throw) + aarch64 syslib shim ---
  openssl = prev.openssl.overrideAttrs (o: {
    # A global/native override leaks `-L<x86 extra-syslibs>/lib/amd64 -lmd -lmp`
    # into the TARGET openssl NIX_LDFLAGS; GNU ld skips those AMD64 libs as
    # "incompatible". Replace with the aarch64 syslib shim so the target libnsl's
    # transitive MD5*/mp_* resolve against aarch64 libmd/libmp.
    NIX_LDFLAGS = aaSyslibL;
    postPatch = (o.postPatch or "") + ''
      cat > Configurations/50-solaris-aarch64.conf <<'EOF'
      my %targets = (
          "solaris64-aarch64-gcc" => {
              inherit_from     => [ "solaris-common-gcc" ],
              CC               => "gcc",
              CFLAGS           => add_before(picker(default => "-Wall",
                                                    debug   => "-O0 -g",
                                                    release => "-O3")),
              lib_cppflags     => add("-DL_ENDIAN"),
              bn_ops           => "SIXTY_FOUR_BIT_LONG",
              shared_cflag     => "-fPIC",
              shared_ldflag    => add_before("-shared -static-libgcc"),
              multilib         => "/64",
          },
      );
      EOF
    '';
    configureScript = "./Configure solaris64-aarch64-gcc no-asm";
  });

  # --- cairo cross-file ipc_rmid_deferred_release (eval throw) ---
  # The upstream mesonFlags builds a cross-file whose ipc_rmid_deferred_release
  # table has no `solaris` key -> throws at eval when forced. We must NOT read
  # o.mesonFlags (that forces the throw); replace it wholesale with a static
  # Wayland-only flag set + a solaris cross-file (illumos SysV shm defers
  # segment release after IPC_RMID until last detach, same as Linux -> true).
  cairo = prev.cairo.overrideAttrs (o: {
    mesonFlags = [
      "-Dgtk_doc=true"
      "-Dsymbol-lookup=disabled"
      "-Dspectre=disabled"
      "-Dglib=enabled"
      "-Dtests=disabled"
      "-Dxlib=disabled"
      "-Dxcb=disabled"
      "--cross-file=${builtins.toFile "cairo-solaris-ipc.conf" ''
        [properties]
        ipc_rmid_deferred_release = true
      ''}"
    ];
  });

  # --- wayland illumos port (native epoll + getpeerucred + linux-input shim) ---
  wayland = prev.wayland.overrideAttrs (o: {
    # illumos has NATIVE epoll (sys/epoll.h) + signalfd/timerfd in libc; the
    # kqueue-emulating epoll-shim is neither needed nor buildable (no sys/event.h).
    mesonFlags = (o.mesonFlags or [ ]) ++ [ "-Ddocumentation=false" ];
    # -D__EXTENSIONS__ exposes SFD_CLOEXEC/TFD_CLOEXEC under _POSIX_C_SOURCE;
    # split-libc socket syms (__xnet_*) need -lsocket -lnsl.
    NIX_CFLAGS_COMPILE = (o.NIX_CFLAGS_COMPILE or "") + " -D__EXTENSIONS__";
    NIX_LDFLAGS = (o.NIX_LDFLAGS or "") + " -lsocket -lnsl";
    postPatch = (o.postPatch or "") + ''
      # wl_os_socket_peercred: illumos has no SO_PEERCRED; use getpeerucred.
      if grep -q "SO_PEERCRED" src/wayland-os.c 2>/dev/null; then
        substituteInPlace src/wayland-os.c \
          --replace-warn '#if defined(SO_PEERCRED)' '#if defined(__sun)
	{
		ucred_t *uc = NULL;
		if (getpeerucred(sockfd, &uc) == -1)
			return -1;
		*pid = ucred_getpid(uc);
		*uid = ucred_geteuid(uc);
		*gid = ucred_getegid(uc);
		ucred_free(uc);
		return 0;
	}
#elif defined(SO_PEERCRED)' || true
      fi
    '';
  });

  # --- gtk4 Wayland-only: strip unconditional X-only buildInputs ---
  gtk4 = (prev.gtk4.override (oa:
    (if oa ? x11Support then { x11Support = false; } else { })
    // (if oa ? waylandSupport then { waylandSupport = true; } else { })
    // (if oa ? broadwaySupport then { broadwaySupport = false; } else { })
    // (if oa ? gstMediaSupport then { gstMediaSupport = false; } else { })
  ));

  # --- fontconfig: drop --with-default-fonts=dejavu_fonts.minimal ---
  # dejavu_fonts.minimal is built by fontforge (font subsetting), which drags in
  # libtiff -> sphinx -> pytest-xdist -> toml (a broken-hash python FOD) at eval.
  # illumos runtime supplies fonts via /etc/fonts; the compile-time default-font
  # path is not needed. Replace configureFlags statically (avoid forcing the
  # dejavu-referencing original list). cross keeps ac_cv_va_copy=C99.
  fontconfig = prev.fontconfig.overrideAttrs (o: {
    configureFlags = [
      "--sysconfdir=/etc"
      "--with-arch=${prev.stdenv.hostPlatform.parsed.cpu.name}"
      "--with-cache-dir=/var/cache/fontconfig"
      "ac_cv_va_copy=C99"
    ];
    # postInstall also references dejavu_fonts.minimal (xsltproc fontDirectories);
    # point at the illumos runtime font dir instead so dejavu/fontforge/toml
    # never gets pulled.
    postInstall = ''
      cd "$out/etc/fonts"
      xsltproc --stringparam fontDirectories "/usr/share/fonts" \
        --stringparam includes /etc/fonts/conf.d \
        --path $out/share/xml/fontconfig \
        ${prev.path + "/pkgs/development/libraries/fontconfig/make-fonts-conf.xsl"} $out/etc/fonts/fonts.conf \
        > fonts.conf.tmp
      mv fonts.conf.tmp $out/etc/fonts/fonts.conf
      rm -r $bin/share/man/man3
    '';
  });

  # --- libadwaita: drop the heavy optional chains that don't cross cleanly ---
  libadwaita = (prev.libadwaita.override (oa:
    (if oa ? withDocumentation then { withDocumentation = false; } else { })
    // (if oa ? withVala then { withVala = false; } else { })
  )).overrideAttrs (o: {
    doCheck = false;
  });
}
