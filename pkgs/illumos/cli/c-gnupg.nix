# cli/c-gnupg.nix -- GnuPG 2.4 and its libraries (libgpg-error, libgcrypt, libassuan, libksba, npth).
{ mkSrcPkg, world, zlib, readline, ncurses, chk, dropDocs, hostTools, ... }:
let
  gpgSrc = name: version: sha256: { url = "https://gnupg.org/ftp/gcrypt/${name}/${name}-${version}.tar.bz2"; inherit sha256; };
  # the bzip2 CLI (bin/bzip2, bunzip2, bzcat; nixChain.bzip2 ships the library only): GNU tar unpacks these .tar.bz2 sources by
  # running bzip2 from PATH, and a solnix host has none ('lbzip2: Cannot exec', measured on dixi). Same pinned tarball as nixChain.bzip2.
  bzip2-bin = mkSrcPkg {
    pname = "bzip2-bin"; version = "1.0.8";
    src = { url = "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz";
            sha256 = "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"; };
    build = ''
      gmake bzip2 CC="$CC" >&2
      mkdir -p "$out/bin"; cp bzip2 "$out/bin/"; ln -s bzip2 "$out/bin/bunzip2"; ln -s bzip2 "$out/bin/bzcat"
      echo bzip2-ok | "$out/bin/bzip2" | "$out/bin/bzcat" | grep -qx bzip2-ok || { echo "FATAL: bzip2 round trip" >&2; exit 1; }
    '';
  };
  tools = [ bzip2-bin ] ++ hostTools;   # store-only PATH + config.site (wave4), and bzip2 for the .tar.bz2 unpack
  # The OI build host has its own gpgrt-config/libgcrypt in /usr/bin (1.12.4, measured): configure
  # takes a *-config from PATH, so the deps' bin/ go first and GPGRT_CONFIG names the store one.
  cfgPath = deps: builtins.concatStringsSep ":" (map (d: "${d}/bin") deps);
  lib = { pname, version, sha256, deps ? [ ], flags ? "", check }: mkSrcPkg {
    inherit pname version deps; src = gpgSrc pname version sha256; nativeTools = tools;
    build = ''
      export PATH="${cfgPath deps}''${PATH:+:$PATH}"
      ${if deps == [ ] then "" else "export GPGRT_CONFIG=${builtins.head deps}/bin/gpgrt-config"}
      # GREP/SED as bare names: configure would bake the builder's seed-tool path into the
      # installed *-config scripts, and mk-src-pkg's de-bake (`sed > f.btfix && mv`) then
      # drops their exec bit (libgcrypt-config came out 0444, measured).
      GREP=grep EGREP="grep -E" FGREP="grep -F" SED=sed \
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-doc ${flags}
      gmake -j8; gmake install
      ${dropDocs}
      ${check}
    '';
  };
in rec {
  libgpg-error = lib {
    pname = "libgpg-error"; version = "1.55";
    sha256 = "95b178148863f07d45df0cea67e880a79b9ef71f5d230baddc0071128516ef78";
    flags = "--disable-nls --disable-languages";
    check = chk ''"$out/bin/gpg-error" --version'' "^gpg-error \\(libgpg-error\\) 1\\.55";
  };
  npth = lib {
    pname = "npth"; version = "1.8";
    sha256 = "8bd24b4f23a3065d6e5b26e98aba9ce783ea4fd781069c1b35d149694e90ca3e";
    flags = "--enable-install-npth-config";
    check = ''[ -f "$out/lib/amd64/libnpth.so.0" ] || { echo "FATAL: no libnpth" >&2; exit 1; }'';
  };
  libgcrypt = lib {
    pname = "libgcrypt"; version = "1.11.2";
    sha256 = "6ba59dd192270e8c1d22ddb41a07d95dcdbc1f0fb02d03c4b54b235814330aac";
    deps = [ libgpg-error ];
    # no -fstack-protector: gcc.lib ships no libssp (base-src.nix smartmontools/libsodium).
    flags = "--with-libgpg-error-prefix=${libgpg-error} --disable-padlock-support";
    check = chk ''"$out/bin/dumpsexp" --version'' "dumpsexp \\(Libgcrypt\\) 1\\.11\\.2";
  };
  libassuan = lib {
    pname = "libassuan"; version = "3.0.2";
    sha256 = "d2931cdad266e633510f9970e1a2f346055e351bb19f9b78912475b8074c36f6";
    deps = [ libgpg-error ];
    flags = "--with-libgpg-error-prefix=${libgpg-error}";
    check = ''[ -f "$out/lib/amd64/libassuan.so.9" ] || { echo "FATAL: no libassuan.so.9" >&2; exit 1; }'';
  };
  libksba = lib {
    pname = "libksba"; version = "1.6.7";
    sha256 = "cf72510b8ebb4eb6693eef765749d83677a03c79291a311040a5bfd79baab763";
    deps = [ libgpg-error ];
    flags = "--with-libgpg-error-prefix=${libgpg-error}";
    check = ''[ -f "$out/lib/amd64/libksba.so.8" ] || { echo "FATAL: no libksba.so.8" >&2; exit 1; }'';
  };

  # gnupg: gpg, gpg-agent, dirmngr (no LDAP, no GnuTLS: dirmngr fetches keys over plain HKP),
  # no pinentry in this set (pinentry-curses is a follow-up; loopback pinentry works).
  gnupg = mkSrcPkg {
    pname = "gnupg"; version = "2.4.8";
    src = gpgSrc "gnupg" "2.4.8" "b58c80d79b04d3243ff49c1c3fc6b5f83138eb3784689563bcdd060595318616";
    deps = [ world zlib readline ncurses libgpg-error libgcrypt libassuan libksba npth ]; nativeTools = tools;
    build = ''
      export PATH="${cfgPath [ libgpg-error libgcrypt libassuan libksba npth ]}:$PATH"
      export GPGRT_CONFIG=${libgpg-error}/bin/gpgrt-config
      CFLAGS="-O2 -D__EXTENSIONS__" ./configure --prefix="$out" --libexecdir="$out/libexec" --sysconfdir=/etc \
        --with-libgpg-error-prefix=${libgpg-error} --with-libgcrypt-prefix=${libgcrypt} \
        --with-libassuan-prefix=${libassuan} --with-ksba-prefix=${libksba} --with-npth-prefix=${npth} \
        --with-readline=${readline} --disable-ldap --disable-gnutls --disable-sqlite --disable-tpm2d \
        --disable-ccid-driver --disable-nls --disable-doc --enable-gpg-is-gpg2=no
      grep -q "^LIBGCRYPT_CFLAGS = .*${libgcrypt}" Makefile || grep -q "${libgcrypt}" config.log \
        || { echo "FATAL: gnupg did not configure against the store libgcrypt" >&2; exit 1; }
      gmake -j8; gmake install
      ${dropDocs}
      ${chk ''"$out/bin/gpg" --version'' "^gpg \\(GnuPG\\) 2\\.4\\.8"}
      # functional: symmetric encrypt + decrypt round trip in a throwaway homedir
      G=$(mktemp -d /var/tmp/gpgh.XXXXXX); chmod 700 "$G"
      echo hlcli-gpg > "$G/m"
      "$out/bin/gpg" --homedir "$G" --batch --pinentry-mode loopback --passphrase p -c -o "$G/m.gpg" "$G/m"
      ${chk ''"$out/bin/gpg" --homedir "$G" --batch --pinentry-mode loopback --passphrase p -d "$G/m.gpg"'' "^hlcli-gpg$"}
      "$out/bin/gpgconf" --homedir "$G" --kill all 2>/dev/null || true
    '';
  };
}
