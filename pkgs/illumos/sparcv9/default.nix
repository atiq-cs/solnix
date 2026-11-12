# pkgs/illumos/sparcv9 -- the native sparcv9 set (lixu: sun's zone), first rung: the gate proto (./gate.nix), its libc slice, and a
# seed zlib built with OI's gcc 13 (stage0, a host build tool, as x86's seed used /usr/gcc/14), and the ld slice (sv9-2 S2a: floki
# /scratch/solnix/lixu3/SPARC-ROWS-PLAN.md). gcc 14.3.0 from source (S2b), the seed build tools (S2c) and gcc 15 (S2d) come next.
# mk-src-pkg.nix's x86 text serves sparcv9 unchanged but for the LP64 lib dir (lib/amd64 -> lib/sparcv9), rewritten here (sparcv9Fix)
# so the shared file and every x86/aarch64 drv stay as they are.
{ system ? "sparcv9-solaris" }:
let
  gate = import ./gate.nix { };
  libc = import ../mk-illumos-component.nix {
    inherit gate system;
    name = "libc";
    originParts = [ "$ORIGIN" ];   # LP64 only: every sibling is in lib/sparcv9 with it
    files = map (l: "lib/sparcv9/${l}") [ "libc.so.1" "libm.so.2" "libm.so.1" "libsocket.so.1" "libnsl.so.1" "libresolv.so.2" "libelf.so.1"
        "libpthread.so.1" "librt.so.1" "libdl.so.1" "libmd.so.1" "libmp.so.2" "libcustr.so.1" "libofmt.so.1" "libumem.so.1"
        "libc.so" "libm.so" "libsocket.so" "libnsl.so" "libresolv.so" "libelf.so" ]
      ++ map (o: "usr/lib/sparcv9/${o}") [ "crt1.o" "crti.o" "crtn.o" "values-Xa.o" "values-Xc.o" "values-Xs.o" "values-Xt.o"
        "values-xpg4.o" "values-xpg6.o" "libc.so" "libm.so" "libsocket.so" "libnsl.so" "libresolv.so" "libelf.so" ]
      ++ [ "usr/include" ];
  };
  # usr/bin/ld: the proto tarball holds the proto's libraries and headers only (./mk-proto-tarball.sh), so the link-editor driver
  # (26 KB; its libld/liblddbg/libumem/libldstab are in the proto) is pinned on its own: OI developer/linker@0.5.11-2025.0.0.21764,
  # the proto's osnet build (31d3d510), packed in zone lixu like the proto (pkg verify OK, sha1 == the IPS manifest's, two packs
  # byte-identical; banked floki /scratch/solnix-bank/sv9gcc-20261112/). The same builtin:unpack-channel as ./gate.nix: no host tool.
  # shortcut: until infra hosts the URL, `nix-store --add-fixed sha256 proto-ld_sparcv9.tar.gz` first (as ./gate.nix says).
  ldProto = derivation {
    name = "illumos-sparcv9-ld-proto"; system = "builtin"; builder = "builtin:unpack-channel"; channelName = "ld";
    src = import <nix/fetchurl.nix> {
      url = "https://s3.solnix.io/solnix-cache/ami/sparcv9-ld-oi202604-21764/proto-ld_sparcv9.tar.gz";
      sha256 = "d8b47fdf3fd0d4158ed0d6552d1e1537fb83b71a686d4bc80793b12485fc4edc";
    };
  };
  # ld: the Solaris link-editor as a store slice (x86's/aarch64's `ld`), so collect2 runs it, not the host's /usr/bin/ld (gcc -Qy
  # records the ld version in every ELF). usr/bin/ld reaches lib/sparcv9 by $ORIGIN/../../lib/sparcv9, libldstab by $out/usr/lib/sparcv9,
  # libelf + libc come from the libc slice.
  ld = import ../mk-illumos-component.nix {
    inherit gate system;
    name = "ld";
    originParts = [ "$ORIGIN" "$ORIGIN/../../lib/sparcv9" ];
    files = [ "lib/sparcv9/libld.so.4" "lib/sparcv9/liblddbg.so.4" "lib/sparcv9/libumem.so.1" "usr/lib/sparcv9/libldstab.so.1" ];
    extraFiles = [ { src = "${ldProto}/ld/usr/bin/ld"; dst = "usr/bin/ld"; } ];
    selfLibDirs = [ "usr/lib/sparcv9" ];
    depRunpaths = [ "${libc}/lib/sparcv9" ];
  };
  # the 64-bit ISA dir is lib/sparcv9 where x86's is lib/amd64; buildKey recomputed the way mk-src-pkg computes it
  sparcv9Fix = d: let
      # + the seed cc wrapper gets -YP,<the gate's lib dirs>: OI gcc-13's specs (link_arch64) add `-Y P,/usr/gcc/13/lib/sparcv9:..
      # -R /usr/gcc/13/lib/sparcv9` unless -YP is given, and the post-link RUNPATH edit leaves that string in .dynstr (publish-gate
      # B13; measured lixu3 2026-11-10: plain gcc -shared -> RUNPATH /usr/gcc/13/lib/sparcv9, with -YP,<dirs> -> none, 0 bytes)
      r = builtins.replaceStrings [ "*/amd64|" "lib/amd64" "$DL -static-libgcc \"\\$@\"" ]
        [ "*/sparcv9|" "lib/sparcv9" "$DL -YP,$(echo $GL | tr ' ' :) -static-libgcc \"\\$@\"" ];
      a = builtins.removeAttrs d.drvAttrs [ "buildKey" ];
      a' = a // { args = map r a.args; build = r a.build; };
      b = derivation (a' // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON a')); });
    in if a'.args == a.args then throw "sparcv9Fix: no lib/amd64 in mk-src-pkg's text"
      else if builtins.match ".*-YP,.*" (toString a'.args) == null then throw "sparcv9Fix: the seed cc wrapper line moved (no -YP added)"
      else b;
  mkSrcPkg = args: sparcv9Fix (import ../mk-src-pkg.nix { inherit gate; gcc = "/usr/gcc/13"; stage0 = "/usr/gcc/13";
    runtimeLibDirs = [ "${libc}/lib/sparcv9" ]; } (args // { inherit system; }));
in
{
  inherit libc ld;
  # as ../aarch64/src.nix's zlib (OI symbol-version mapfile), LP64 only; --libdir first: zlib's configure is not autoconf
  zlib = mkSrcPkg {
    pname = "zlib"; version = "1.3.2";
    src = { url = "https://zlib.net/fossils/zlib-1.3.2.tar.gz";
            sha256 = "bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"; };
    build = ''
      CFLAGS="-O2 -fPIC" LDSHARED="$CC -shared -Wl,-h,libz.so.1 -Wl,-M,${../patches/zlib-illumos.mapfile}" \
        ./configure --libdir="$out/$LIBSUB" --prefix="$out" --sharedlibdir="$out/$LIBSUB" --includedir="$out/include"
      # GNU ar (gnu-binutils 2.46.1) bus-errors on sparcv9 archives of this size (15 objects: 6/6 in the zone; 3 small ones pass);
      # illumos ar is fine (lixu3 2026-11-10; sparc-nix224-setup.sh FIX C). A seed host tool, like gstrip.
      gmake -j2 AR=/usr/bin/ar libz.so.1.3.2
      gmake AR=/usr/bin/ar install
      /usr/bin/elfdump -e "$out/$LIBSUB/libz.so.1.3.2" | grep -q 'EM_SPARCV9' || { echo "FATAL: libz is not sparcv9" >&2; exit 1; }
    '';
  };
}
