# cli/c-qalias.nix -- the x86 queue's nixpkgs VARIANT attrs whose content solnix does not serve yet (qalias lane, 2026-11-11): versioned
# copies of a library solnix already builds (fmt_9/_10/_11, isl_0_*), or a nixpkgs override of one (coreutils-prefixed, libjpeg8), each under the queue's attr name as its pname, because a job
# closes only for a drv whose pname AND version are the job's (infra authority-build.py "eval identity"; catch2_3/gmp6 precedent).
# Pure aliases of a served drv (gmpxx = gmp6, texinfo7, patch = gnupatch, go_latest, tcl-8_6, isl_0_20 = isl ...) are NOT here: they
# would publish a duplicate of served content (floki /scratch/solnix/briefs/qlane.md "Finding (qalias)").
# Versions, flags and patches are nixpkgs f4a03c0's (the tree the queue's targets follow). Store-only, an in-build check each.
# A new file, so no served drv moves.
{ base, mkSrcPkg, world, chk, dropDocs, hostTools, cmake, gnupatch, gmp6, autoreconfTools, autoreconf, bzip2-bin, nasm ? null, ... }:
let
  fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; };
  gh = repo: tag: sha256: { url = "https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}"; inherit sha256; };
  cmakeB = extra: ''
    cmake -S . -B _b -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib/amd64 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON -DCMAKE_IGNORE_PREFIX_PATH="/usr;/usr/local;/opt" \
      -DCMAKE_IGNORE_PATH="/usr/lib/64;/usr/lib/amd64;/lib/64" ${extra} >&2
    cmake --build _b -j16 >&2; cmake --install _b >&2
  '';

  # fmt (MIT), as nixpkgs' fmt generic: shared, tests off (they need gtest's network fetch), nixpkgs' per-version patch.
  # c4283ec only moves tests (not built here), 3cabf37 adds <cstdlib> to format.h: both applied, as nixpkgs.
  fmtV = attr: version: sha256: patch: mkSrcPkg {
    pname = attr; inherit version;
    src = gh "fmtlib/fmt" version sha256;
    deps = [ world ]; nativeTools = [ cmake ] ++ (if patch == null then [ ] else [ gnupatch ]) ++ hostTools;
    build = ''
      ${if patch == null then "" else "patch -p1 < ${patch}"}
      ${cmakeB "-DBUILD_SHARED_LIBS=ON -DFMT_TEST=OFF -DFMT_DOC=OFF"}
      printf '#include <fmt/format.h>\n#include <cstdio>\nint main(){std::puts(fmt::format("{:>6}|{:.3f}|{}", 42, 3.14159, FMT_VERSION).c_str());}\n' > "$W/t.cc"
      "$CXX" -std=c++17 -I"$out/include" "$W/t.cc" -L"$out/lib/amd64" -lfmt -o "$W/t"
      ${chk ''"$W/t"'' "^    42\\|3\\.142\\|${fmtNum version}$"}
    '';
  };
  # FMT_VERSION: major*10000 + minor*100 + patch (9.1.0 -> 90100)
  fmtNum = v: let p = builtins.splitVersion v; n = i: builtins.fromJSON (builtins.elemAt p i); in toString (n 0 * 10000 + n 1 * 100 + n 2);

  # isl (LGPL-2.1, MIT-licensed since 0.13 except imath: nixpkgs says lgpl21), as nixpkgs' generic.nix: on gmp, --with-gcc-arch=generic
  # (no -march guess from the build host's CPU). The libisl soname is per release, so each version is its own library.
  islV = attr: version: sha256: mkSrcPkg {
    pname = attr; inherit version;
    src = { url = "https://libisl.sourceforge.io/isl-${version}.tar.xz"; inherit sha256; };
    deps = [ world gmp6 ]; nativeTools = hostTools;
    build = ''
      # gmp: deps' -I/-L from the cc wrapper (isl's --with-gmp-prefix assumes lib/, not lib/amd64)
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --build=x86_64-pc-solaris2.11 --disable-static --with-gcc-arch=generic
      gmake -j16; gmake install
      ${dropDocs}
      printf '#include <isl/ctx.h>\n#include <isl/set.h>\n#include <isl/val.h>\n#include <isl/version.h>\n#include <stdio.h>\nint main(void){isl_ctx *c=isl_ctx_alloc();isl_set *s=isl_set_read_from_str(c,"{ [i] : 0 <= i < 10 }");isl_val *v=isl_set_count_val(s);printf("%%ld %%s",isl_val_get_num_si(v),isl_version());isl_val_free(v);isl_set_free(s);isl_ctx_free(c);return 0;}\n' > "$W/t.c"
      "$CC" -I"$out/include" "$W/t.c" -L"$out/lib/amd64" -lisl -lgmp -o "$W/t"
      ${chk ''"$W/t"'' "^10 isl-${version}-GMP$"}   # isl_version() ends in its own newline
    '';
  };
  # GNU tools as base-src.nix gnuTool builds them (its gnulib getlocalename_l fix, MAKEINFO=true, no NLS); copied, not shared, so
  # base-src.nix and every drv built from it stay as they are
  gnu = { pname, version, url, sha256, flags ? "", nativeTools ? hostTools, docOutputs ? [ ], pre ? "", post ? "" }: mkSrcPkg {
    inherit pname version nativeTools docOutputs; deps = [ world ]; src = { inherit url sha256; };
    build = ''
      for f in $(find . \( -name 'localename*.[ch]' -o -name 'getlocalename_l*.[ch]' -o -name 'setlocale_null*.c' \)); do
        sed -i 's/extern char \* *getlocalename_l/extern const char *getlocalename_l/;s/^char \* *getlocalename_l/const char *getlocalename_l/' "$f"
      done
      ${pre}
      FORCE_UNSAFE_CONFIGURE=1 MAKEINFO=true ./configure --prefix="$out" --disable-nls ${flags}
      gmake -j4 MAKEINFO=true
      gmake install MAKEINFO=true
      ${dropDocs}
      ${post}
    '';
  };

  # libjpeg-turbo 3.2.0 (IJG + BSD-3-Clause + zlib), as nixpkgs' libjpeg_turbo: cmake, nasm SIMD (required), shared only, the jpeg-6b
  # API (libjpeg.so.62) or, for libjpeg8, nixpkgs' enableJpeg8 = WITH_JPEG8 (the jpeg-8 API, libjpeg.so.8). desktop/gtk/base.nix's
  # libjpeg-turbo recipe (3.1.4.1, served) with its nasm wrapper (STT_FILE paths relative: gate B8). One output (nixpkgs splits bin dev
  # man doc). The check decodes the bundled test JPEG, and libjpeg8's names its soname.
  jpegV = attr: jpeg8: mkSrcPkg {
    pname = attr; version = "3.2.0";
    src = { url = "https://codeload.github.com/libjpeg-turbo/libjpeg-turbo/tar.gz/refs/tags/3.2.0";
            sha256 = "980dd81f425082aa6d7c9e47fef27554ce7a9ffc8e2f6e863b97d263c5c50858"; };
    deps = [ world ]; nativeTools = [ cmake ] ++ hostTools; linkDeps = [ nasm ];
    build = ''
      printf '%s\n' '#!/usr/bin/bash' \
        'rel() { local d=$PWD up=; while [ "''${1#"$d"/}" = "$1" ]; do d=''${d%/*}; up=../$up; done; printf %s "$up''${1#"$d"/}"; }' \
        "a=(); for x in \"\$@\"; do case \"\$x\" in $SRC/*) x=\$(rel \"\$x\");; esac; a+=(\"\$x\"); done" \
        'exec ${nasm}/bin/nasm "''${a[@]}"' > "$W/nasm"
      chmod +x "$W/nasm"
      # 3.2's bundled spng + zlib (PNG I/O for cjpeg/djpeg) are OBJECT libraries that the shared libturbojpeg links: without PIC, illumos ld
      # refuses their R_AMD64_32 relocations (measured). nixpkgs uses the bundled copies too (no WITH_SYSTEM_SPNG/ZLIB).
      ${cmakeB ''-DENABLE_STATIC=OFF -DENABLE_SHARED=ON -DWITH_JPEG7=OFF -DWITH_JPEG8=${if jpeg8 then "ON" else "OFF"} -DREQUIRE_SIMD=ON -DCMAKE_ASM_NASM_COMPILER="$W/nasm" -DCMAKE_POSITION_INDEPENDENT_CODE=ON''}
      find "$out/share/doc" -delete 2>/dev/null || true
      "$out/bin/djpeg" -ppm testimages/testorig.jpg | head -c 2 | grep -qx P6 || { echo "FATAL: djpeg" >&2; exit 1; }
      ${chk ''/usr/bin/elfdump -d "$out/lib/amd64/libjpeg.so" | grep SONAME'' (if jpeg8 then "libjpeg\\.so\\.8$" else "libjpeg\\.so\\.62$")}
    '';
  };
in {
  fmt_9 = fmtV "fmt_9" "9.1.0" "5dea48d1fcddc3ec571ce2058e13910a0d4a6bab4cc09a809d8b1dd1c88ae6f2"
    (fetch "https://github.com/fmtlib/fmt/commit/c4283ec471bd3efdb114bc1ab30c7c7c5e5e0ee0.patch" "7433d75add5b9462f743be43b46d13ac1b6dd83173886757fd8cc0666078cbbf");
  fmt_10 = fmtV "fmt_10" "10.2.1" "1250e4cc58bf06ee631567523f48848dc4596133e163f02615c97f78bab6c811" null;
  fmt_11 = fmtV "fmt_11" "11.2.0" "bc23066d87ab3168f27cef3e97d545fa63314f5c79df5ea444d41d56f962c6af"
    (fetch "https://github.com/fmtlib/fmt/commit/3cabf3757b6bc00330b55975317b2c145e4c689d.patch" "365c64659e17a3299c13f7c61c74be191ec714e47a80206850de6ef491157ed9");
  # isl 0.20 is the "isl" job (nixpkgs isl = isl_0_20, the same drv): one out, so the isl_0_20 job is a duplicate and is not served here
  isl = islV "isl" "0.20" "a5596a9fb8a5b365cb612e4b9628735d6e67e9178fae134a816ae195017e77aa";
  isl_0_23 = islV "isl_0_23" "0.23" "5efc53efaef151301f4e7dde3856b66812d8153dede24fab17673f801c8698f2";
  isl_0_27 = islV "isl_0_27" "0.27" "6d8babb59e7b672e8cb7870e874f3f7b813b6e00e6af3f8b04f7579965643d5c";

  # libiconvReal: nixpkgs' standalone GNU libiconv 1.19 (main's libiconv is 1.17, gettext's). Shared only, as nixpkgs.
  libiconvReal = gnu {
    pname = "libiconvReal"; version = "1.19";
    url = "https://mirrors.kernel.org/gnu/libiconv/libiconv-1.19.tar.gz";
    sha256 = "88dd96a8c0464eca144fc791ae60cd31cd8ee78321e67397e25fc095c4a19aa6";
    flags = ''--libdir="$out/lib/amd64" --disable-static --enable-shared'';
    post = ''
      [ "$(printf '\303\251' | "$out/bin/iconv" -f UTF-8 -t UTF-16LE | od -An -tx1 | tr -d ' ')" = e900 ] \
        || { echo "FATAL: libiconv UTF-8 -> UTF-16LE self-check" >&2; exit 1; }
      ${chk ''"$out/bin/iconv" --version'' "^iconv \\(GNU libiconv 1\\.19\\)$"}
    '';
  };

  # coreutils-prefixed: nixpkgs' coreutils.override { withPrefix = true; singleBinary = false; }, i.e. every tool as g<name>
  # (--program-prefix=g), one binary each. base-src.nix coreutils 9.12's flags otherwise (kill and uptime; no arch: illumos has one).
  coreutils-prefixed = gnu {
    pname = "coreutils-prefixed"; version = "9.12";
    url = "https://mirrors.kernel.org/gnu/coreutils/coreutils-9.12.tar.xz";
    sha256 = "a480198559733e9b3da999e90543ac6f888a2caa544d8d664c5a1f17e528e210";
    docOutputs = [ "man" ];
    flags = "--without-selinux --disable-gcc-warnings --without-openssl --without-libgmp --enable-install-program=kill,uptime --program-prefix=g";
    post = ''
      [ ! -e "$out/bin/ls" ] && [ ! -e "$out/bin/coreutils" ] || { echo "FATAL: unprefixed or single-binary coreutils" >&2; exit 1; }
      ${chk ''"$out/bin/gls" --version'' "^ls \\(GNU coreutils\\) 9\\.12$"}   # --version names the program as built (ls), not g-prefixed
      ${chk ''printf 'b\na\n' | "$out/bin/gsort" | "$out/bin/ghead" -1'' "^a$"}
    '';
  };

  # gnumake42: GNU make 4.2.1 (GPL-3.0+) with nixpkgs' four patches (-p0: no /usr/include, /usr/lib impure dirs; pselect; glibc glob
  # fixes), no guile, as nixpkgs. Unlike base-src.nix gnumake 4.4.1 it installs no gmake link (nixpkgs' gnumake42 has none).
  gnumake42 = let np = f: sha256: fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/gn/gnumake42/${f}" sha256; in gnu {
    pname = "gnumake42"; version = "4.2.1";
    url = "https://mirrors.kernel.org/gnu/make/make-4.2.1.tar.bz2";
    sha256 = "d6e262bf3601b42d2b1e4ef8310029e1dcf20083c5446b4b7aa67081fdffc589";
    nativeTools = [ bzip2-bin gnupatch ] ++ hostTools;   # bzip2: GNU tar unpacks .tar.bz2 through it
    docOutputs = [ "man" ];
    flags = "--without-guile";
    pre = ''
      for p in ${np "impure-dirs.patch" "47e2b15f79a9d5b4fa54661e3e18ff24cfbb112f6061684fbb770541b66c5728"} \
               ${np "pselect.patch" "7189638e363a3cdb15998f571e83bb9905ee40373cef5ca92311f35953c8a658"} \
               ${np "glibc-2.27-glob.patch" "75926607612bd83ca2a127064338f98230194f38df6bc65650bfe5467c90365b"} \
               ${np "glibc-2.33-glob.patch" "36196e8dcde5442789607161f33dd17ac4638545dd768e8abd9b4ef232785e2e"}; do patch -p0 < "$p"; done
      # illumos declares getloadavg() in <sys/loadavg.h>, which 4.2.1 never includes (4.4's job.c does): gcc 15 rejects the implicit
      # declaration. Include it where job.c declares its own fallback (HAVE_GETLOADAVG is defined, so that prototype is skipped).
      grep -qx '#ifndef HAVE_GETLOADAVG' job.c || { echo "FATAL: gnumake42 getloadavg anchor" >&2; exit 1; }
      sed -i 's|^#ifndef HAVE_GETLOADAVG$|#include <sys/loadavg.h>\n&|' job.c
    '';
    post = ''
      ${chk ''"$out/bin/make" --version'' "^GNU Make 4\\.2\\.1$"}
      printf 'all:\n\t@echo made-$(MAKE_VERSION)\n' > "$W/Makefile"
      ${chk ''"$out/bin/make" -C "$W" -s'' "^made-4\\.2\\.1$"}
    '';
  };

  # libbacktrace (BSD-3-Clause), nixpkgs' snapshot 96664e6 with its three patches (configurable debug dir, several build-id dirs,
  # NIX_DEBUG_INFO_DIRS), autoreconf'd as nixpkgs, shared only. It reads ELF DWARF: the check prints a backtrace of its own frames.
  libbacktrace = let np = f: sha256: fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/by-name/li/libbacktrace/${f}" sha256; in mkSrcPkg {
    pname = "libbacktrace"; version = "0-unstable-2026-05-03";
    src = { url = "https://codeload.github.com/ianlancetaylor/libbacktrace/tar.gz/96664e69b1ecdb76e824be1d9e8f475b76dd08cf";
            sha256 = "16bdb21d6d5d7035fb36e937213d649961ca70b4a95c4f5ff5591be6fcd43483"; };
    deps = [ world ]; nativeTools = autoreconfTools ++ [ gnupatch ] ++ hostTools;
    build = ''
      for p in ${np "0002-libbacktrace-Allow-configuring-debug-dir.patch" "59aaf4ef5dd59b5eea9e56edee589d2fc5109a2abb415ab571d91d941284cb22"} \
               ${np "0003-libbacktrace-Support-multiple-build-id-directories.patch" "0456984d6d3580fb0a7c7d863913e0212249e1590c7c00123917725f6d68f488"} \
               ${np "0004-libbacktrace-Support-NIX_DEBUG_INFO_DIRS-environment.patch" "671ecc172fff8dd3495bc591ba043831d2549e2cbad75cd2863df7b6761b649f"}; do patch -p1 < "$p"; done
      ${autoreconf}
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --build=x86_64-pc-solaris2.11 --disable-static --enable-shared
      gmake -j8; gmake install
      printf '#include <backtrace.h>\n#include <stdio.h>\nstatic int cb(void *d,unsigned long pc,const char *f,int l,const char *fn){if(fn)printf("frame %%s\\n",fn);return 0;}\nstatic void er(void *d,const char *m,int e){printf("err %%s\\n",m);}\n__attribute__((noinline)) static void inner(struct backtrace_state *s){backtrace_full(s,0,cb,er,NULL);}\nint main(int c,char **v){struct backtrace_state *s=backtrace_create_state(v[0],0,er,NULL);inner(s);return 0;}\n' > "$W/t.c"
      "$CC" -g -O0 -I"$out/include" "$W/t.c" -L"$out/lib/amd64" -lbacktrace -o "$W/t"
      ${chk ''"$W/t"'' "^frame inner$"}
    '';
  };

  # bashNonInteractive: nixpkgs' bash 5.3p20 with interactive = false: GNU bash 5.3 + the 20 upstream patches bash53-001..020 (-p0) +
  # nixpkgs' pgrp-pipe-5.patch (a no-op on illumos: it changes the linux* case only; applied as nixpkgs does), --without-bash-malloc
  # --disable-readline, and nixpkgs' NIX_CFLAGS_COMPILE defines (/etc/bashrc, /etc/bash_logout, no default PATH, its own loadable
  # builtins dir, NON_INTERACTIVE_LOGIN_SHELLS, SSH_SOURCE_BASHRC). Non-interactive: share/ and bashbug removed, as nixpkgs; bin/sh ->
  # bash. base-src.nix bash 5.2.37's illumos fixes: -Wno-error=incompatible-pointer-types (curses tputs) and the pinned PIPESIZE
  # (builtins/psize.sh measures the build host's pipe). The tarball and every patch: .sig from the GNU mirror and sha256 = nixpkgs'.
  bashNonInteractive = let
    gnuBash = f: sha256: fetch "https://mirrors.kernel.org/gnu/bash/bash-5.3-patches/${f}" sha256;
    patches = [
      (gnuBash "bash53-001" "1f608434364af86b9b45c8b0ea3fb3b165fb830d27697e6cdfc7ac17dee3287f")
      (gnuBash "bash53-002" "e385548a00130765ec7938a56fbdca52447ab41fabc95a25f19ade527e282001")
      (gnuBash "bash53-003" "f245d9c7dc3f5a20d84b53d249334747940936f09dc97e1dcb89fc3ab37d60ed")
      (gnuBash "bash53-004" "9591d245045529f32f0812f94180b9d9ce9023f5a765c039b852e5dfc99747d0")
      (gnuBash "bash53-005" "cca1ef52dbbf433bc98e33269b64b2c814028efe2538be1e2c9a377da90bc99d")
      (gnuBash "bash53-006" "29119addefed8eff91ae37fd51822c31780ee30d4a28376e96002706c995ff10")
      (gnuBash "bash53-007" "c0976bbfffa1453c7cfdd62058f206a318568ff2d690f5d4fa048793fa3eb299")
      (gnuBash "bash53-008" "097cd723cbfb8907674ac32214063a3fd85282657ec5b4e544d2c0f719653fb4")
      (gnuBash "bash53-009" "eee30fe78a4b0cb2fe20e010e00308899cfc613e0774ebb3c8557a1552f24f8c")
      (gnuBash "bash53-010" "cf76f1cce2ea300c18bff9f002d21f280cc931acd17c28518110b93fe6e72569")
      (gnuBash "bash53-011" "0298df8f5ea2a31d3be43ed7d269c5b3c7c342dd5b570bea7f64d66dcbbe7531")
      (gnuBash "bash53-012" "d71379b39bebaedaf123414414e77fb458a0a43b9ad3116594c6df7ca6754573")
      (gnuBash "bash53-013" "042f9cda967e24bf4211944697441e93d06ff42b4b998629a98a1b249279f200")
      (gnuBash "bash53-014" "bd4360b401d38507e358783dcad8536a99c6789f0d3a5bd0cfb8c4a34144696c")
      (gnuBash "bash53-015" "55b79ceee2fc27f6767eed697e939a7eb2fe2a28c01556bd75f18d581014f46e")
      (gnuBash "bash53-016" "9ea29b266b7d24cb34d0ff3f1c4631e4d527bfe2d1ef15d17cdb924bf31ef767")
      (gnuBash "bash53-017" "443b927b45c1558ca72052410f8b8f6e5152b617ed707061a2781d4375b0d1c3")
      (gnuBash "bash53-018" "ae715d76c50341d7d7095e9a8d2eeed1ca9546152c2ac7289206f90cf30ac697")
      (gnuBash "bash53-019" "a25c581e4d0057dea3833918438a930e2e86ee4c6dc17fe15267b7f04cbc4e3d")
      (gnuBash "bash53-020" "df217ed3a9122aa2286d9b67bbe348661b6a9db262b580c29150dae55d532896")
      (fetch "https://raw.githubusercontent.com/NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6/pkgs/shells/bash/pgrp-pipe-5.patch"
        "82f67b5331f724ad49b0dff873b4b97f306297dd77974f4156498eca1d0fa0ed")
    ];
  in mkSrcPkg {
    pname = "bashNonInteractive"; version = "5.3p20";
    src = { url = "https://mirrors.kernel.org/gnu/bash/bash-5.3.tar.gz";
            sha256 = "0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba"; };
    deps = [ world ]; nativeTools = [ gnupatch ] ++ hostTools;
    build = ''
      for p in ${toString patches}; do patch -p0 < "$p"; done
      grep -qx '#define PATCHLEVEL 20' patchlevel.h || { echo "FATAL: bash patchlevel is not 20" >&2; exit 1; }
      # nixpkgs passes these through the cc wrapper; here they go first in config-top.h (its PATH/builtins defaults are #ifndef-guarded)
      { printf '#define SYS_BASHRC "/etc/bashrc"\n#define SYS_BASH_LOGOUT "/etc/bash_logout"\n'
        printf '#define DEFAULT_PATH_VALUE "/no-such-path"\n#define STANDARD_UTILS_PATH "/no-such-path"\n'
        printf '#define DEFAULT_LOADABLE_BUILTINS_PATH "%s/lib/bash:."\n' "$out"
        printf '#define NON_INTERACTIVE_LOGIN_SHELLS\n#define SSH_SOURCE_BASHRC\n'; cat config-top.h; } > config-top.h.new && mv config-top.h.new config-top.h
      CFLAGS="-O2 -Wno-error=incompatible-pointer-types" \
      ./configure --prefix="$out" --without-bash-malloc --disable-readline --disable-nls
      printf '#!/bin/sh\necho "#define PIPESIZE 5120"\n' > builtins/psize.sh
      gmake -j6
      grep -qx '#define PIPESIZE 5120' builtins/pipesize.h || { echo "FATAL: bash PIPESIZE not pinned" >&2; exit 1; }
      gmake install
      ln -s bash "$out/bin/sh"
      rm -f "$out/lib/bash/Makefile.inc"
      find "$out/share" -delete; rm -f "$out/bin/bashbug"
      strings -a "$out/bin/bash" | grep -qx /etc/bashrc || { echo "FATAL: bash built without SYS_BASHRC" >&2; exit 1; }
      ${chk ''env -i "$out/bin/bash" -c 'echo "$PATH"' '' "^/no-such-path$"}
      ${chk ''"$out/bin/bash" --version'' "^GNU bash, version 5\\.3\\.20\\("}
      ${chk ''"$out/bin/sh" -c 'a=(x y z); echo "''${#a[@]} $((6*7)) ''${BASH_VERSINFO[2]}"' '' "^3 42 20$"}
    '';
  };

  # libiberty 16.2.0 (LGPL-2.0+): GCC's utility library, as nixpkgs' libiberty: the gcc-16.2.0 tarball's libiberty/ only,
  # --enable-install-libiberty (include/libiberty headers) --enable-shared (= build the PIC objects), and the PIC archive installed
  # as lib/libiberty.a. nixpkgs' config.guess /usr/bin/uname -> uname fix, and --build pinned. MULTIOSDIR=. on install: libdir
  # is already lib/amd64 (its default asks $(CC) -print-multi-os-directory). The check links xstrdup/concat/lbasename from it.
  libiberty = mkSrcPkg {
    pname = "libiberty"; version = "16.2.0";
    src = { url = "https://mirrors.kernel.org/gnu/gcc/gcc-16.2.0/gcc-16.2.0.tar.xz";
            sha256 = "e6738e29597f733270731aa90600f37ffdc045079dfc27ec7e8192cc81085c3e"; };
    deps = [ world ]; nativeTools = hostTools;
    build = ''
      grep -q /usr/bin/uname config.guess || { echo "FATAL: libiberty config.guess anchor" >&2; exit 1; }
      sed -i 's|/usr/bin/uname|uname|g' config.guess
      cd libiberty
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --build=x86_64-pc-solaris2.11 --enable-install-libiberty --enable-shared
      gmake -j8
      gmake install MULTIOSDIR=.
      [ -f pic/libiberty.a ] || { echo "FATAL: libiberty: no pic/libiberty.a" >&2; exit 1; }
      cp pic/libiberty.a "$out/lib/amd64/libiberty.a"
      printf '#include <libiberty/libiberty.h>\n#include <stdio.h>\nint main(void){char *s=concat("solnix","-",xstrdup("ok"),NULL);printf("%%s %%s\\n",s,lbasename("/a/b/c.txt"));return 0;}\n' > "$W/t.c"
      "$CC" -fPIC -I"$out/include" "$W/t.c" "$out/lib/amd64/libiberty.a" -o "$W/t"
      ${chk ''"$W/t"'' "^solnix-ok c\\.txt$"}
    '';
  };
} // (if nasm == null then { } else {   # nasm: desktop/gtk's (x86 only)
  # libjpeg = nixpkgs' libjpeg_turbo at 3.2.0 (main serves libjpeg-turbo 3.1.4.1 only); libjpeg8 = its enableJpeg8 override
  libjpeg = jpegV "libjpeg" false;
  libjpeg8 = jpegV "libjpeg8" true;
})
