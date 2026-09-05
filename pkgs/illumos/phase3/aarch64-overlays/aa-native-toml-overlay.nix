# Native (buildPackages) syslib + toml fixes for the aarch64 cross entry.
# buildPackages uses the older illumos-cc-10.5.0 cc-wrapper which PREDATES the
# x86 tranche's H6 fix (-L/lib/amd64 in the default link env). So native tools
# that link -lnsl (perl, openssl, tcl) hit unresolved libmd (MD5*) / libmp (mp_*)
# symbols that libnsl.so transitively NEEDs but which ship versioned-only with
# no bare lib<n>.so link on the default search path.
#   Fix (docs/aarch64-native-openssl-fix.md nativeOpensslWireOverlay, generalized):
#   add -L${extraSyslibs}/lib/amd64 -lmd -lmp to the affected native tools.
# Plus the toml FOD repin (fetchurl-shim drops the hash through fetchPypi's
# finalAttrs fold -> 0000... outputHash; the meson->sphinx doc chain pulls it).
final: prev:
let
  extraSyslibs = builtins.storePath /nix/store/ylyfkm6xwp60gg8yqcpj4g481l1fm1qq-illumos-extra-syslibs;
  seedL = "-L${extraSyslibs}/lib/amd64";
  # H6 native-syslib wire (docs/aarch64-native-openssl-fix.md): the buildPackages
  # cc-wrapper predates the -L/lib/amd64 default, so native tools linking -lnsl
  # hit unresolved libmd(MD5*)/libmp(mp_*). Add -L + -lmd -lmp per native tool.
  # (The custom illumos-cc doesn't honor cc-wrapper extraBuildCommands, so this
  # is per-tool rather than a single cc-wrapper edit.)
  # Add the H6 -L (+ -lmd -lmp on the link) into whichever slot the package uses:
  # structuredAttrs pkgs (o ? env) get ALL build vars in env, plain pkgs get them
  # top-level. Never mix -> no env-collision.
  wireSyslibs = pkg: pkg.overrideAttrs (o:
    let ld = " " + seedL + " -lmd -lmp"; cf = " " + seedL; in
    if o ? env
    then { env = o.env // {
             NIX_LDFLAGS = (o.env.NIX_LDFLAGS or "") + ld;
             NIX_CFLAGS_COMPILE = (o.env.NIX_CFLAGS_COMPILE or "") + cf;
           }; }
    else {
      NIX_LDFLAGS = (o.NIX_LDFLAGS or "") + ld;
      NIX_CFLAGS_COMPILE = (o.NIX_CFLAGS_COMPILE or "") + cf;
    });
in {
  # Per-tool native H6 syslib wire (docs/aarch64-native-openssl-fix.md): the
  # buildPackages cc-wrapper predates the x86 -L/lib/amd64 default, so native
  # tools linking -lnsl hit unresolved libmd(MD5*)/libmp(mp_*). Add -L + -lmd
  # -lmp per native tool. A single stdenv adapter would be the root fix, but the
  # custom illumos-cc + the structuredAttrs env/top-level NIX_LDFLAGS split make
  # a broad adapter collide; the fork's native cc-wrapper should carry the -L
  # default instead (the documented native-toolchain grind). openssl/perl/tcl/
  # libffi/pcre2 build with this per-tool wire.
  # perl gets the H6 -L in the entry's perl-wrap (top-level NIX_LDFLAGS). Here
  # wire the other native tools whose link hits the same libmd/libmp gap.
  openssl = wireSyslibs prev.openssl;
  tcl = wireSyslibs prev.tcl;
  # pkg-config-unwrapped (pulled by the cross build-tool set pkgsBuildBuild via
  # the shared overlays): its configure conftest links -lnsl -> H6 libmd/libmp gap.
  pkg-config-unwrapped = wireSyslibs prev.pkg-config-unwrapped;
  # native libffi doCheck pulls dejagnu -> expect -> tcl, whose
  # compat/fake-rfc2553.c re-declares strlcpy (gcc14 conflicting-types vs illumos
  # <string.h>). Drop the check chain (docs/aarch64-native-openssl-fix.md).
  libffi = prev.libffi.overrideAttrs (_: { doCheck = false; });
  # native zstd: buildContrib defaults ON (build==host) -> builds a C++ gen_html
  # doc tool that dies (libstdc++ / kstat). Drop contrib (docs/aarch64-native-openssl-fix.md).
  zstd = (prev.zstd.override { buildContrib = false; }).overrideAttrs (_: { doCheck = false; });

  # native gettext: WIRE to the already-built x86 native gettext-1.0 (same
  # x86_64-solaris build platform; the x86 COSMIC session cracked the libtool
  # illumos empty-global_symbol_pipe libintl.la wall). Reuse it (wave5
  # cmakeWireOverlay style) rather than re-cracking the libtool empty-pipe bug.
  gettext = builtins.storePath /nix/store/pq4h5warrx9cwx23srbzhmdmbxpvym7y-gettext-1.0;

  # native cmake-minimal: WIRE to the x86-session's working build (wave5
  # cmakeWireOverlay). The cross build tool set pulls native cmake (zstd/python3/
  # meson code-gen); its C++ bootstrap fails in-sandbox, already cracked on x86.
  cmake-minimal = builtins.storePath /nix/store/p7dvg7h6s4c3ccbjvdpkp6jv5b6bwifx-cmake-minimal-4.3.4;
  cmakeMinimal = builtins.storePath /nix/store/p7dvg7h6s4c3ccbjvdpkp6jv5b6bwifx-cmake-minimal-4.3.4;

  python3 = prev.python3.override (_: {
    packageOverrides = _pyfinal: pyprev: {
      toml = pyprev.toml.overrideAttrs (_: {
        src = prev.fetchurl {
          url = "https://files.pythonhosted.org/packages/source/t/toml/toml-0.10.2.tar.gz";
          sha256 = "b3bda1d108d5dd99f4a20d24d9c348e91c4db7ab1b749200bded2f839ccbe68f";
        };
      });
    };
  });
}
