# cli/c-qalias.nix -- the x86 queue's nixpkgs VARIANT attrs whose content solnix does not serve yet (qalias lane, 2026-11-11): versioned
# copies of a library solnix already builds (fmt_9/_10/_11, isl_0_*), each under the queue's attr name as its pname, because a job
# closes only for a drv whose pname AND version are the job's (infra authority-build.py "eval identity"; catch2_3/gmp6 precedent).
# Pure aliases of a served drv (gmpxx = gmp6, texinfo7, patch = gnupatch, go_latest, tcl-8_6, isl_0_20 = isl ...) are NOT here: they
# would publish a duplicate of served content (floki /scratch/solnix/briefs/qlane.md "Finding (qalias)").
# Versions, flags and patches are nixpkgs f4a03c0's (the tree the queue's targets follow). Store-only, an in-build check each.
# A new file, so no served drv moves.
{ base, mkSrcPkg, world, chk, dropDocs, hostTools, cmake, gnupatch, gmp6, ... }:
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
}
