# pkgs/illumos/sparcv9/stdenv.nix -- sparcv9's store-only stdenv (sv9-2 S2c), aarch64's two-stage model (../aarch64/tools.nix):
#  1. seed: the build tools, compiled by the STORE gcc 14.3.0 (./gcc-src.nix) on the zone's host PATH (/usr/gnu/bin:/usr/bin, the OI
#     bootstrap's), buildTools = [ ] (bootstrap-exempt.tsv `seed`; gawk: `sv9seed`), their outs content-gated (seedOuts).
#  2. final: every recipe store-only: PATH = the seed farm + store coreutils/findutils (no /usr), gated by ../path-gate.sh in every
#     build (drv-gate A1 PASS). Not on PATH, named by absolute path as on aarch64 (tools.nix header): the builder interpreter
#     /usr/bin/bash, the illumos elfedit/elfdump/ldd/digest/od-free gates (IB=/usr/bin), gcc's /usr/bin/gas, and the gate's ld (a store slice).
# mk-src-pkg's x86 text serves both, rewritten for the LP64 lib dir (lib/amd64 -> lib/sparcv9) and a big-endian config.site.
# ./default.nix's zlib/libc/ld/gcc drvs are not touched by anything here.
{ gate, libc, ld, gcc, system ? "sparcv9-solaris" }:
let
  rtLib = "${libc}/lib/sparcv9";
  # sparcv9 rewrite of mk-src-pkg's text: the 64-bit lib dir, gcc's runtime dir, and the big-endian config.site (config.site says a
  # big-endian target needs its own). Anchors are checked: a rewrite that finds nothing throws instead of building x86 text.
  sv9 = d: let
      # illumos-bin.sh finds elfedit/elfdump/digest in x86's world (a nativeTools entry); sparcv9 has no world and its gate proto no
      # binaries, so IB stays the host's /usr/bin, as on aarch64 (bootstrap tools by absolute path, never on PATH: drv-gate A1)
      # ../split-debug-od.sh (store-only text only; the seed's is ../split-debug.sh) writes the build-id note little-endian: sparcv9's
      # copy writes it in the ELF's byte order (readelf rejected the LE note on jansson's big-endian .so, sv9q2)
      from = [ "*/amd64|" "lib/amd64" "$gccLib/amd64" "${../config-x86.site}" "${../config.site}" ". ${../illumos-bin.sh}" "${../split-debug-od.sh}" ];
      to = [ "*/sparcv9|" "lib/sparcv9" "$gccLib/sparcv9" "${./config.site}" "${./config.site}" "IB=/usr/bin" "${./split-debug-od.sh}" ];
      r = builtins.replaceStrings from to;
      a = builtins.removeAttrs d.drvAttrs [ "buildKey" ];
      a' = a // { args = map r a.args; build = r a.build; } // (if a ? PATH then { PATH = r a.PATH; } else { });
    in if builtins.match ".*lib/sparcv9.*" (toString a'.args) == null then throw "sparcv9 stdenv: no lib/amd64 in mk-src-pkg's text"
      else if builtins.replaceStrings [ "${./config.site}" ] [ "" ] (toString a'.args) == toString a'.args then throw "sparcv9 stdenv: no config.site in mk-src-pkg's text"
      else derivation (a' // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON a')); });
  mk = inst: args: sv9 (import ../mk-src-pkg.nix ({ inherit gate gcc; runtimeLibDirs = [ rtLib ]; } // inst) (args // { inherit system; }));
  seedMk = mk { seedOuts = true; };      # buildTools = [ ]: the host PATH (the `seed` marker: btPath ""), outs content-gated (seed-outs.sh)
  # GNU tools: base-src.nix's gnuTool text (gnulib getlocalename_l const fix, no NLS, no info), one recipe for both stages
  gnuTool = m: { pname, version, url, sha256, flags ? "", post ? "" }: m {
    inherit pname version; src = { inherit url sha256; };
    build = ''
      ${arFix}
      for f in $(find . \( -name 'localename*.[ch]' -o -name 'getlocalename_l*.[ch]' -o -name 'setlocale_null*.c' \)); do
        sed -i 's/extern char \* *getlocalename_l/extern const char *getlocalename_l/;s/^char \* *getlocalename_l/const char *getlocalename_l/' "$f"
      done
      FORCE_UNSAFE_CONFIGURE=1 MAKEINFO=true ./configure --prefix="$out" --disable-nls ${flags}
      gmake -j2 MAKEINFO=true
      gmake install MAKEINFO=true
      find "$out/share/doc" "$out/share/info" -delete 2>/dev/null || true
      ${post}
    '';
  };
  # OI's GNU ar 2.46.1 (the seed PATH's /usr/gnu/bin/ar) bus-errors once >= 17 inputs are open at once (sv9gcc z7-z14: its link
  # copy-relocates __iob past its .bss); bfd keeps <= rlimit/8 archives open, so a soft limit of 64 keeps it <= 8 (measured: rc 0 over 400
  # objects, output deterministic). Soft only: the binutils self-check below raises it again to test the new gar unprotected.
  arFix = "ulimit -S -n 64   # OI GNU ar 2.46.1 bus error (sv9gcc), see stdenv.nix";
  # the libc slice has libc's siblings only (no libsec, libkstat: x86 links them from the world, aarch64 from its gate-libs), so the
  # gnulib features that link them are off, as in NixOS's bootstrap tools (no ACL/xattr): sed's ACL code NEEDed libsec.so.1 from the
  # host /lib/64 and mk-src-pkg's closure gate failed it (measured, sv9q b1). coreutils' kstat is getloadavg's (uptime: no load average).
  noAcl = "--disable-acl";
  # likewise libgen.so.1: gnulib's euidaccess.m4 finds eaccess in -lgen (where illumos has it) and find NEEDed /lib/64/libgen.so.1
  # (measured, sv9q b2); with no -lgen gnulib uses its own euidaccess. The tools whose configure runs that probe (f2.out): 4.
  noGen = "ac_cv_search_eaccess=no";
  # seed-outs.sh rewrites #!/bin/bash with GNU sed's `\|$` alternation, which illumos sed (the zone has no GNU sed; x86's and
  # aarch64's seed hosts do) does not match, so gzip's scripts kept #!/bin/bash and seed-outs.sh FAILed them (measured, sv9q b2): gzip
  # below records /bin/sh itself (its scripts are POSIX sh, seed-outs.sh's own note; /bin/sh is ksh93 on illumos).
  ver = bin: re: ''"$out/bin/${bin}" --version | head -1 | grep -q '${re}' || { echo "FATAL: ${bin} --version: $("$out/bin/${bin}" --version | head -1)" >&2; exit 1; }'';
  gnu = n: "https://mirrors.kernel.org/gnu/${n}";
  # the seed set: the queue's cross-arch versions where it has one (x86 main's base-src: the same sources and hashes)
  tools = m: rec {
    gnumake = m {
      pname = "gnumake"; version = "4.4.1";
      src = { url = gnu "make/make-4.4.1.tar.gz"; sha256 = "dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3"; };
      build = ''
        ${arFix}
        ./configure --prefix="$out" --without-guile --disable-nls
        gmake -j2
        gmake install
        ln -s make "$out/bin/gmake"
        ${ver "make" "^GNU Make 4.4.1"}
      '';
    };
    gnused = gnuTool m { pname = "gnused"; version = "4.9"; url = gnu "sed/sed-4.9.tar.xz";
      sha256 = "6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181"; flags = "${noAcl} --disable-gcc-warnings"; post = ver "sed" "(GNU sed) 4.9"; };
    gnugrep = gnuTool m { pname = "gnugrep"; version = "3.11"; url = gnu "grep/grep-3.11.tar.xz";
      sha256 = "1db2aedde89d0dea42b16d9528f894c8d15dae4e190b59aecc78f5a951276eab"; flags = "--disable-perl-regexp --disable-gcc-warnings"; post = ver "grep" "(GNU grep) 3.11"; };
    gawk = gnuTool m { pname = "gawk"; version = "5.4.1"; url = gnu "gawk/gawk-5.4.1.tar.xz";
      sha256 = "07f6f7342b7febe4313fc2c2542ad93d64fe20ad8717200109f105a826f5fd37";
      # no readline/mpfr (nixpkgs' interactive extras); the extension .so files dlopen nothing but libc
      flags = "--without-readline --without-mpfr --disable-pma"; post = ''${ver "gawk" "^GNU Awk 5.4.1"}
        ln -sf gawk "$out/bin/awk"; [ "$(echo 1 2 | "$out/bin/awk" '{print $1+$2}')" = 3 ] || { echo "FATAL: awk self-check" >&2; exit 1; }''; };
    coreutils = gnuTool m { pname = "coreutils"; version = "9.7"; url = gnu "coreutils/coreutils-9.7.tar.xz";
      sha256 = "e8bb26ad0293f9b5a1fc43fb42ba970e312c66ce92c1b0b16713d7500db251bf";
      flags = "--without-selinux --disable-gcc-warnings --without-openssl --without-libgmp --enable-single-binary=symlinks ${noAcl} ${noGen} --disable-xattr ac_cv_lib_kstat_kstat_open=no ac_cv_prog_cc_c23=no ac_cv_func_getattrat=no";
      # ac_cv_func_getattrat=no: ls's Solaris extended-attribute listing links libnvpair.so.1 (not in the libc slice; measured, sv9q b2)
      # ac_cv_prog_cc_c23=no: configure adds -std=gnu23 after mk-src-pkg's -std=gnu17, and the sparcv9 gate's <sys/signal.h> declares
      # sa_handler as void (*)(), which C23 reads as (void): lib/sig-handler.h failed to compile (measured, sv9q b2). C17, as mk-src-pkg means.
      post = ver "ls" "(GNU coreutils) 9.7"; };
    findutils = gnuTool m { pname = "findutils"; version = "4.10.0"; url = gnu "findutils/findutils-4.10.0.tar.xz";
      sha256 = "1387e0b67ff247d2abde998f90dfbf70c1491391a59ddfecb8ae698789f0a4f5"; flags = "${noGen} --disable-gcc-warnings"; post = ver "find" "(GNU findutils) 4.10.0"; };
    diffutils = gnuTool m { pname = "diffutils"; version = "3.10"; url = gnu "diffutils/diffutils-3.10.tar.xz";
      sha256 = "90e5e93cc724e4ebe12ede80df1634063c7a855692685919bfe60b556c9bd09e"; flags = "--disable-gcc-warnings"; post = ver "diff" "(GNU diffutils) 3.10"; };
    gnutar = gnuTool m { pname = "gnutar"; version = "1.35"; url = gnu "tar/tar-1.35.tar.xz";
      sha256 = "4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16"; flags = "${noAcl} ${noGen} --without-posix-acls --without-xattrs --disable-gcc-warnings"; post = ver "tar" "(GNU tar) 1.35"; };
    # its scripts' #! is make's $(SHELL) (Makefile.in: s|/bin/sh|$(SHELL)|, '#!$(SHELL)'), which configure set to the bash it re-ran under
    # (CONFIG_SHELL on configure's line did not reach make: still #!/bin/bash, measured): give make the POSIX /bin/sh itself
    gzip = m {
      pname = "gzip"; version = "1.13";
      src = { url = gnu "gzip/gzip-1.13.tar.xz"; sha256 = "7454eb6935db17c6655576c2e1b0fabefd38b4d0936e0f87f48cd062ce91a057"; };
      build = ''
        ${arFix}
        MAKEINFO=true ./configure --prefix="$out" --disable-nls --disable-gcc-warnings
        gmake -j2 MAKEINFO=true SHELL=/bin/sh
        gmake install MAKEINFO=true SHELL=/bin/sh
        find "$out/share/doc" "$out/share/info" -delete 2>/dev/null || true
        [ "$(head -1 "$out/bin/zcat")" = '#!/bin/sh' ] || { echo "FATAL: zcat #! is $(head -1 "$out/bin/zcat")" >&2; exit 1; }
        ${ver "gzip" "^gzip 1.13"}
      '';
    };
    gnupatch = gnuTool m { pname = "gnupatch"; version = "2.8"; url = gnu "patch/patch-2.8.tar.xz";
      sha256 = "f87cee69eec2b4fcbf60a396b030ad6aa3415f192aa5f7ee84cad5e11f7f5ae3"; flags = "${noGen} --disable-xattr --disable-gcc-warnings"; post = ver "patch" "^GNU patch 2.8"; };
    gnum4 = gnuTool m { pname = "gnum4"; version = "1.4.20"; url = gnu "m4/m4-1.4.20.tar.xz";
      sha256 = "e236ea3a1ccf5f6c270b1c4bb60726f371fa49459a8eaaebc90b216b328daf2b"; flags = "--disable-gcc-warnings"; post = ver "m4" "^m4 (GNU M4) 1.4.20"; };
    # xz: x86 main's version (its queue job asks 5.6.3, the CVE-2025-31115 range: the job wants a retarget, as on x86)
    xz = m {
      pname = "xz"; version = "5.8.1";
      src = { url = "https://github.com/tukaani-project/xz/releases/download/v5.8.1/xz-5.8.1.tar.gz";
              sha256 = "507825b599356c10dca1cd720c9d0d0c9d5400b9de300af00e4d1ea150795543"; };
      build = ''
        ${arFix}
        ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-nls --disable-doc gl_cv_posix_shell=/bin/sh --enable-path-for-scripts=no
        gmake -j2; gmake install
        ${ver "xz" "^xz (XZ Utils) 5.8.1"}
      '';
    };
    # binutils 2.47 for sparc: gstrip/gobjcopy/greadelf for mk-src-pkg's split-debug + strip (store, not OI's 2.46.1), gnm/gar for
    # libtool. No ld (illumos ld is the link-editor), no gas use yet (gcc keeps /usr/bin/gas until S2d). GNU ar's bus error on sparcv9
    # (sv9gcc: >= 17 files open, OI 2.46.1's own link) is checked below with 40 members.
    binutils = m {
      pname = "binutils"; version = "2.47";
      src = { url = gnu "binutils/binutils-2.47.tar.xz"; sha256 = "154ab23b60070e8f27013c22977f1129425d67d1e8acd6e13010e617811e4cff"; };
      build = ''
        ${arFix}
        T=sparcv9-sun-solaris2.11
        sed -i 's/^development=true$/development=false/; s/^experimental=true$/experimental=false/' bfd/development.sh
        grep -qx development=false bfd/development.sh || { echo "FATAL: bfd/development.sh not pinned" >&2; exit 1; }
        CFLAGS=-O2 CXXFLAGS=-O2 MAKEINFO=true ./configure --prefix="$out" --build=$T --host=$T --target=$T \
          --program-prefix=g --disable-ld --disable-gold --disable-gprof --disable-gprofng \
          --disable-libctf --disable-shared --disable-install-libbfd --disable-nls --disable-werror --without-zstd
        gmake -j2 MAKEINFO=true LEXLIB=
        gmake install MAKEINFO=true LEXLIB=
        find "$out/$T" -delete 2>/dev/null || true
        printf '.text\n.globl f\nf: retl\n nop\n' > t.s; "$out/bin/gas" -64 -o t.o t.s
        [ "$(od -An -tx1 -N4 t.o | tr -d ' \n')" = 7f454c46 ] || { echo "FATAL: gas made no ELF" >&2; exit 1; }
        i=0; while [ $i -lt 40 ]; do i=$((i + 1)); cp t.o m$i.o; done
        ( ulimit -S -n 256; "$out/bin/gar" rcD t.a m*.o && "$out/bin/gnm" t.a > /dev/null ) || { echo "FATAL: the new gar/gnm on 40 members" >&2; exit 1; }
        ${ver "gstrip" " 2[.]47$"}
      '';
    };
  };
  seed = tools seedMk;
  # one farm dir (aarch64's buildToolsFarm shape: mk-src-pkg de-bakes each btPath entry once, so one entry), + the names libtool and
  # configure look up: nm/ar/ranlib/strip -> binutils' g-prefixed tools (the illumos ones are host /usr/bin; a store-only PATH has none)
  farm = derivation {
    name = "solnix-sv9-build-tools"; inherit system;
    builder = "/usr/bin/bash"; PATH = "${seed.coreutils}/bin";
    paths = with seed; [ gnumake gnused gnugrep gawk coreutils findutils diffutils gnutar gzip gnupatch gnum4 xz binutils ];
    args = [ "-c" ''
      set -eu
      mkdir -p $out/bin
      for p in $paths; do for f in $p/bin/*; do ln -sf $f $out/bin/; done; done
      for t in nm ar ranlib strip objdump readelf objcopy; do ln -sf g$t $out/bin/$t; done
      for t in make gmake sed grep awk gawk cp install find diff cmp tar gzip patch m4 xz gstrip gobjcopy greadelf nm ar ranlib nproc; do
        [ -x $out/bin/$t ] || { echo "FATAL: no $t" >&2; exit 1; }; done
    '' ];
  };
  finalMk0 = mk { buildTools = [ farm ]; storeOnly = true; defaultNativeTools = [ seed.coreutils seed.findutils ]; };
  # the store-only text must run sparcv9's split-debug-od.sh (a rewrite that found nothing would ship x86's little-endian note)
  has = s: x: builtins.replaceStrings [ x ] [ "" ] s != s;
  finalMk = args: let d = finalMk0 args; t = toString d.drvAttrs.args; in
    if !(has t "${./split-debug-od.sh}") || has t "${../split-debug-od.sh}"
    then throw "sparcv9 stdenv: the store-only text does not run ./split-debug-od.sh" else d;
in {
  inherit seed farm;
  seedMkSrcPkg = seedMk;   # the seed instance's (host PATH): a leaf built on it FAILs drv-gate A1, the negative control for mkSrcPkg
  # the store-only stdenv's mkSrcPkg (jansson/oniguruma are its proof: ./default.nix)
  mkSrcPkg = finalMk;
}
