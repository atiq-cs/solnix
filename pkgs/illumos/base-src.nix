# base-src.nix -- the non-gate packages the base system needs, built FROM SOURCE
# with mk-src-pkg.nix. Each one replaces something that used to be copied from
# the build host: zlib + libxml2 replace externalLibs (host /usr/lib copies),
# openssl + openssh replace make-be's host sshd copy, bash replaces nothing (the
# gate has no bash) but is a login shell users expect.
{ gate, libcSlice, world ? null, gcc ? "/usr/gcc/14" }:
# gcc: the from-source gcc derivation (gcc-src.nix). Everything here is compiled
# by it, both ABIs; the IPS seed only compiled gcc itself.

let
  mkSrcPkg = import ./mk-src-pkg.nix {
    inherit gate gcc;
    runtimeLibDirs = [ "${libcSlice}/lib/amd64" "${libcSlice}/lib" ];
  };
  needWorld = if world == null then throw "base-src: this package needs the userland world" else world;
in
rec {
  inherit mkSrcPkg;

  # Nix 2.24.15 + its dependency chain (./nix-src.nix).
  nixChain = import ./nix-src.nix { inherit mkSrcPkg zlib openssl libcSlice; system = "x86_64-solaris"; gccLib = gcc.lib; };

  # libz.so.1 with the illumos symbol versions (SUNW_1.1 .. ILLUMOS_0.2). The
  # gate's libzfs/libzpool record `libz.so.1 SUNW_1.1` as a needed version, so an
  # unversioned upstream libz would fail to load there. The mapfile is
  # OpenIndiana's (oi-userland components/library/zlib/mapfile).
  zlib = mkSrcPkg {
    pname = "zlib"; version = "1.3.2";
    src = { url = "https://zlib.net/fossils/zlib-1.3.2.tar.gz";
            sha256 = "bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"; };
    abis = [ "64" "32" ];
    build = ''
      CFLAGS="-O2 -fPIC" LDSHARED="$CC -shared -Wl,-h,libz.so.1 -Wl,-M,${./patches/zlib-illumos.mapfile}" \
        ./configure --prefix="$out" --libdir="$out/$LIBSUB" --sharedlibdir="$out/$LIBSUB" --includedir="$out/include"
      gmake -j4 libz.so.1.3.2
      gmake install
    '';
  };

  # libxml2.so.16 (soname 16 first appears in 2.14). The gate's libpool,
  # libzonecfg, libbrand and svccfg NEED it; both ABIs, because SMF is 32-bit.
  libxml2 = mkSrcPkg {
    pname = "libxml2"; version = "2.14.6";
    src = { url = "https://download.gnome.org/sources/libxml2/2.14/libxml2-2.14.6.tar.xz";
            sha256 = "7ce458a0affeb83f0b55f1f4f9e0e55735dbfc1a9de124ee86fb4a66b597203a"; };
    abis = [ "64" "32" ];
    deps = [ zlib ];
    build = ''
      ./configure --prefix="$out" --libdir="$out/$LIBSUB" --without-python --without-icu \
        --without-lzma --with-zlib --disable-static --without-debug
      gmake -j4
      gmake install
    '';
  };

  openssl = mkSrcPkg {
    pname = "openssl"; version = "3.4.0";
    src = { url = "https://github.com/openssl/openssl/releases/download/openssl-3.4.0/openssl-3.4.0.tar.gz";
            sha256 = "e15dda82fe2fe8139dc2ac21a36d4ca01d5313c75f99f46c4e8a27709b7294bf"; };
    # libc only (runtimeLibDirs): no world dep, so nix's closure does not pull
    # the whole userland in through libcrypto.
    build = ''
      ./Configure solaris64-x86_64-gcc --prefix="$out" --libdir=lib/amd64 --openssldir=/etc/openssl \
        shared no-tests no-docs
      gmake -j6 build_sw
      gmake install_sw
    '';
  };

  # OpenSSH with PAM. docs/sshd-pam-fail-open.md: without UsePAM, OpenSSH 10 on
  # illumos accepts any password; the config make-be stages sets UsePAM yes.
  # sysconfdir is /etc/ssh (host keys + config are per-machine state, as on NixOS);
  # the binaries and libexec helpers live in the store.
  openssh = mkSrcPkg {
    pname = "openssh"; version = "10.2p1";
    src = { url = "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.2p1.tar.gz";
            sha256 = "ccc42c0419937959263fa1dbd16dafc18c56b984c03562d2937ce56a60f798b2"; };
    deps = [ needWorld zlib openssl ];
    build = ''
      DP=/run/current-system/sw/bin:/usr/bin:/usr/sbin:/sbin
      # GCC 14 makes -Wincompatible-pointer-types an error; illumos PAM declares
      # pam_get_item(..., void **) and a non-const conversation callback, where
      # OpenSSH assumes Linux-PAM's const forms (measured: auth-pam.c:480 etc).
      CFLAGS="-O2 -Wno-error=incompatible-pointer-types" \
      ./configure --prefix="$out" --sysconfdir=/etc/ssh --with-pam \
        --with-solaris-contracts --with-solaris-projects --with-solaris-privs \
        --with-privsep-path=/var/empty --with-privsep-user=sshd \
        --with-default-path="$DP" --with-superuser-path="$DP" \
        --with-pid-dir=/var/run --with-mantype=man --without-rpath
      gmake -j6
      D=$(mktemp -d /var/tmp/sshdest.XXXXXX)
      gmake install-nokeys DESTDIR="$D"
      cp -R "$D$out/." "$out/"
      mkdir -p "$out/share/ssh-defaults"; cp -R "$D/etc/ssh/." "$out/share/ssh-defaults/"
    '';
  };

  bash = mkSrcPkg {
    pname = "bash"; version = "5.2.37";
    src = { url = "https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz";
            sha256 = "9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff"; };
    deps = [ needWorld ];
    build = ''
      # illumos curses declares tputs(..., int (*)(char)); GCC 14 errors on the
      # mismatch with bash's int (*)(int) putc callback (display.c:2839, measured).
      CFLAGS="-O2 -Wno-error=incompatible-pointer-types" \
      ./configure --prefix="$out" --without-bash-malloc --disable-nls
      gmake -j6
      gmake install
    '';
  };
}
