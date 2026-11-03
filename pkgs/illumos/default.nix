# solnix illumos world — standalone Nix expression for the illumos build host.
#
# GATES A/B/C + the core world slices of docs/design-gate-derivation.md,
# self-contained (no nixpkgs). Build on the host with Nix 2.3.16:
#   nix-build /var/tmp/solnix-nix/default.nix -A gate
#   nix-build /var/tmp/solnix-nix/default.nix -A libc
#   nix-build /var/tmp/solnix-nix/default.nix -A rtld
#   nix-build /var/tmp/solnix-nix/default.nix -A ld
#   nix-build /var/tmp/solnix-nix/default.nix -A sys
#   nix-build /var/tmp/solnix-nix/default.nix -A base-tools
#   nix-build /var/tmp/solnix-nix/default.nix -A systemPath
#
# Fork mapping: `gate` -> pkgs/os-specific/illumos/pkgs/gate.nix (as FOD),
# `libc`/`rtld`/`ld`/`sys`/`base-tools` -> mkIllumosComponent calls in
# default.nix's rec block; `systemPath` -> buildEnv (design §4.2).

# THE GATE IS INJECTABLE, and it has to be. `import ./gate.nix { }` ALWAYS fails:
# gate.nix:68 asserts `srcDir != null || srcHash != null` and both default to null,
# deliberately (an unpinned network fetch is not reproducible). So every attr that
# touches `gate` -- libc, rtld, base-tools, systemPath, every slice -- was
# unevaluatable through a plain `import ./pkgs/illumos`, which is why NO toplevel
# in this repo has ever built: modules/system/activation reads pkgs.solnix.systemPath.
#
# Nix's laziness hid this: `builtins.attrNames (import ./pkgs/illumos)` lists all 21
# attrs happily, because forcing the NAMES does not force the VALUES. The failure
# only appears when something forces systemPath, and then it surfaces one layer up
# as `attribute 'systemPath' missing` from the overlay -- naming the consumer rather
# than the cause.
#
#   gate      -- pass a store path / builtins.path of an ALREADY-BUILT proto (what
#                the illumos host does: /var/tmp/proto-unpack/<hash>-illumos-gate-proto)
#   gateArgs  -- or pass gate.nix's own args (srcDir/srcHash/rev) to BUILD it
# Default: null/{} -> the old behaviour, which throws on use rather than silently
# yielding an empty world.
{
  gate ? null,
  gateArgs ? { },
  # buildTools: store paths whose bin/ go first on every from-source builder
  # PATH (store gmake/gnutar/gzip/xz/bzip2/gnugrep/gnused/gstrip). Default []
  # keeps the OI buildhost path (/usr/gnu + host decompressors), so NO hash
  # changes for a bhost build beyond the sha256sum->digest + guard-grep fix.
  # A solnix system (dixi, EC2) injects the store set so it can build with no
  # /usr/gnu, no host sha256sum/gstrip/gzip. See docs/pending/builders-need-store-tools.md.
  buildTools ? [ ],
  # seedTools: world-FREE store tools for the recipes the world itself depends on (nss: libldap/kmf_nss link it), from the seed instance
  # (lib/host-pkgs.nix seedPkgs: perl coreutils findutils + the seed world). [] (the bhost/seed path) keeps the old PATH.
  seedTools ? [ ],
  # stdenvGcc: "15" (default) = every from-source package builds with gcc15, which the "14" instance (the gcc 14 chain:
  # gcc-src.nix from the IPS seed, its wrapper, binutils, the seed tools) builds as its own gcc15 (NixOS stage chain:
  # stage N's compiler comes from stage N-1). "14" is that boot instance; nothing else should pass it.
  stdenvGcc ? "15",
  # gcc15From: the stdenv gcc15 from the caller's stage chain (lib/host-pkgs.nix passes the seed instance's: stdenvGcc = "14",
  # buildTools = [ ]). null = the same, imported here (flake.nix's worldOverlay, a bare import), so every instance has one gcc15.
  gcc15From ? null,
}:

let
  # GATE A: the gate proto as a store path. Injected if given, else built from
  # gateArgs (which must carry srcDir or srcHash -- see the note above).
  gate' = if gate != null then gate else import ./gate.nix gateArgs;

  # buildEnv — the symlink-farm merge, factored out of `systemPath` (below) into
  # lib/build-env.nix so the declarative userland (modules/config/system-path.nix)
  # composes its profile the same way. systemPath now CALLS it (design §B).
  buildEnv0 = import ../../lib/build-env.nix { };
  # store-only buildEnv (wave6): the seed farm (seedBuildTools') stays on buildEnv0, a bootstrap-set member; every other farm
  # in an instance with store build tools merges with store coreutils + findutils. The seed instance keeps the old PATH.
  buildEnv = args: buildEnv0 (args // (if buildTools == [ ] then { } else {
    storeTools = "${srcPkgs.coreutils}/bin:${srcPkgs.findutils}/bin"; pathGate = ./path-gate.sh; }));

  mkIllumosComponent = args: import ./mk-illumos-component.nix ({ gate = gate'; } // args);

  # store libdirs of the libc slice, for cross-component RUNPATH baking. Both
  # ABIs: 64-bit libs in lib/amd64, 32-bit in lib. The loader is ABI-aware (a
  # 32-bit binary won't load a 64-bit .so), so a consumer can safely carry BOTH
  # in its RUNPATH — it resolves the matching-class lib. This is what lets the
  # 32-bit SMF stack AND the 64-bit tools share one libc slice (design §2.2).
  # Interpolating the derivation forces its realisation and yields the concrete
  # /nix/store/...-libc path.
  libcLibDirs = [ "${libc}/lib/amd64" "${libc}/lib" ];

  # GATE B: libc slice — ABI-complete (64-bit in lib/amd64, 32-bit in lib).
  # illumos ships SMF (svc.startd/svcs/init) as 32-bit ONLY, so base-tools needs
  # the 32-bit libc; the 64-bit tools (ld, amd64/ls, ksh93) need the 64-bit one.
  # All siblings live inside this component, so intra-component resolution is
  # $ORIGIN (no deps, no selfLibDirs).
  libc = mkIllumosComponent {
    name = "libc";
    files = [
      # --- 64-bit runtime libc + historically-split siblings ---
      "lib/amd64/libc.so.1"
      "lib/amd64/libm.so.1"
      "lib/amd64/libm.so.2"
      "lib/amd64/libsocket.so.1"
      "lib/amd64/libnsl.so.1"
      "lib/amd64/libresolv.so.2"
      "lib/amd64/libelf.so.1"
      "lib/amd64/libpthread.so.1"
      "lib/amd64/librt.so.1"
      "lib/amd64/libdl.so.1"
      # libmd: libnsl/libresolv NEED it, so it belongs in the libc slice to keep
      # the slice self-contained ($ORIGIN-resolvable, no host /lib fallback).
      "lib/amd64/libmd.so.1"
      # --- 32-bit runtime libc + siblings (SMF and the 32-bit coreutils) ---
      "lib/libc.so.1"
      "lib/libm.so.1"
      "lib/libm.so.2"
      "lib/libsocket.so.1"
      "lib/libnsl.so.1"
      "lib/libresolv.so.2"
      "lib/libelf.so.1"
      "lib/libpthread.so.1"
      "lib/librt.so.1"
      "lib/libdl.so.1"
      "lib/libmd.so.1"
      # extra 32-bit libc-adjacent siblings the coreutils pull (libmp/libcustr/
      # libofmt live beside libc; they are part of the core C runtime surface).
      "lib/libmp.so.2"
      "lib/amd64/libmp.so.2"
      "lib/libcustr.so.1"
      "lib/amd64/libcustr.so.1"
      "lib/libofmt.so.1"
      "lib/amd64/libofmt.so.1"
      # --- 64-bit crt + values startup objects ---
      "usr/lib/amd64/crt1.o"
      "usr/lib/amd64/crti.o"
      "usr/lib/amd64/crtn.o"
      "usr/lib/amd64/values-Xa.o"
      "usr/lib/amd64/values-Xc.o"
      "usr/lib/amd64/values-Xs.o"
      "usr/lib/amd64/values-Xt.o"
      "usr/lib/amd64/values-xpg4.o"
      "usr/lib/amd64/values-xpg6.o"
      # --- 32-bit crt + values startup objects ---
      "usr/lib/crt1.o"
      "usr/lib/crti.o"
      "usr/lib/crtn.o"
      "usr/lib/values-Xa.o"
      "usr/lib/values-Xc.o"
      "usr/lib/values-Xs.o"
      "usr/lib/values-Xt.o"
      "usr/lib/values-xpg4.o"
      "usr/lib/values-xpg6.o"
      # link-editor symlinks (.so -> ../../../lib/amd64/.so.N and ../../lib/.so.N)
      "usr/lib/amd64/libc.so"
      "usr/lib/amd64/libm.so"
      "usr/lib/amd64/libsocket.so"
      "usr/lib/amd64/libnsl.so"
      "usr/lib/amd64/libresolv.so"
      "usr/lib/amd64/libelf.so"
      "usr/lib/libc.so"
      "usr/lib/libm.so"
      "usr/lib/libsocket.so"
      "usr/lib/libnsl.so"
      "usr/lib/libresolv.so"
      "usr/lib/libelf.so"
      # full system header tree
      "usr/include"
    ];
    # passthru-equivalent (consumed by cc-wrapper later): incdir=/usr/include,
    # libdir=/usr/lib/amd64. Plain derivation has no passthru; the fork sets it.
  };

  # rtld — the runtime linker (ld.so.1) + the libs IT NEEDs (librtld/libld/
  # liblddbg live in lib/amd64). ld.so.1 IS the interpreter (.interp points here);
  # its own RUNPATH is $ORIGIN and covers its siblings inside lib/amd64. Its NEEDED
  # libld/liblddbg also NEED libc/libelf, so add the libc slice as a cross-dep.
  # Consumers point -I at ${rtld}/lib/amd64/ld.so.1 (design §2.4).
  rtld = mkIllumosComponent {
    name = "rtld";
    files = [
      "lib/amd64/ld.so.1"       # 64-bit runtime linker (.interp target)
      "lib/ld.so.1"             # 32-bit runtime linker
      "lib/amd64/librtld.so.1"  # NEEDED by ld.so.1
      "lib/amd64/libld.so.4"    # NEEDED by ld.so.1
      "lib/amd64/liblddbg.so.4" # NEEDED by libld/ld.so.1
      "lib/librtld.so.1"
      "lib/libld.so.4"
      "lib/liblddbg.so.4"
    ];
    depRunpaths = libcLibDirs; # librtld/libld -> libc/libelf from the libc slice
  };

  # ld — the Solaris link-editor. usr/bin/ld + its 64-bit alias symlink, plus the
  # support libs it (and libld) NEED: libld/liblddbg/libumem in lib/amd64, and
  # libldstab (mapfile stabbing, loaded on demand) in usr/lib/amd64. libelf + libc
  # come from the libc slice (CROSS-component RUNPATH — the first real store-path
  # cross-dep test; grow-in-place verified OK on this bigger binary).
  # usr/bin/ld reaches lib/amd64 via $ORIGIN/../../lib/amd64 (originParts);
  # libldstab in usr/lib/amd64 is reached via $out/usr/lib/amd64 (selfLibDirs).
  ld = mkIllumosComponent {
    name = "ld";
    files = [
      "usr/bin/ld"
      "usr/bin/amd64/ld"          # symlink -> ../../bin/ld
      "lib/amd64/libld.so.4"
      "lib/amd64/liblddbg.so.4"
      "lib/amd64/libumem.so.1"
      "usr/lib/amd64/libldstab.so.1"
    ];
    selfLibDirs = [ "usr/lib/amd64" ]; # libldstab isn't reachable via $ORIGIN
    depRunpaths = libcLibDirs;         # libelf + libc from the libc slice
  };

  # sys — the kernel. i86pc platform unix + amd64 genunix + the amd64 kernel
  # module tree. Kernel objects are NOT userland ELF (no SONAME/NEEDED/RUNPATH),
  # so the relocation loop skips them and CTF (.SUNW_ctf) survives cp -a verbatim.
  # PREMISE CORRECTION: `unix` IS in this proto, at platform/i86pc/kernel/amd64/
  # unix (the platform-specific location; it is NOT under kernel/). The task said
  # unix was missing — that was wrong for this proto. Sliced here.
  sys = mkIllumosComponent {
    name = "sys";
    files = [
      "platform/i86pc/kernel"     # unix + platform kernel modules (mach, drv, ...)
      "kernel"                    # genunix + shared kernel module tree
    ];
    # deps=[] : the kernel does not link userland libc. Nothing to relocate.
  };

  # base-tools — MINIMAL userland toward multi-user, ALL 32-bit. illumos ships
  # SMF (svc.startd/svcs/svcadm/init) as 32-bit ONLY, and keeping the whole
  # component single-ABI means ONE RUNPATH string (≤ the .dynstr grow limit,
  # design risk #1) resolves every ELF. The picked tools have a COMPLETE,
  # proto-satisfiable NEEDED closure (svccfg/svc.configd EXCLUDED: external
  # libxml2 / libsqlite-sys; ksh93 EXCLUDED: 64-bit, would overflow .dynstr).
  # The closure spans lib + usr/lib + lib/fm + usr/lib/fm (all 32-bit). $ORIGIN
  # can't bridge those subdirs, so selfLibDirs bakes each as an $out-absolute
  # RUNPATH entry; libc (both ABIs) comes from the libc slice.
  base-tools = mkIllumosComponent {
    name = "base-tools";
    files = baseToolBins ++ baseToolLibs;
    # base-tools is 32-bit ONLY, so the amd64 $ORIGIN parts are dead weight and
    # the 64-bit libc dir is never consulted. Drop both to save RUNPATH chars.
    originParts = [ "$ORIGIN" ];
    # its libs sprawl across lib/usr/lib/lib/fm/usr/lib/fm — four $out-absolute
    # entries blew the .dynstr ceiling once externalLibs joined the RUNPATH
    # (616 chars, correction #6). Flatten them into ONE dir so the RUNPATH is
    # $ORIGIN + libc/lib + externalLibs/usr/lib + $out/lib-all (~230 chars).
    flattenLibsInto = "lib-all";
    depRunpaths = [ "${libc}/lib" "${srcPkgs.zlib}/lib" "${srcPkgs.libxml2}/lib" ];
  };

  # picked binaries: SMF core (minus svccfg/svc.configd), the 32-bit shell, and
  # a coreutils-equiv set. ALL 32-bit — illumos ships SMF 32-bit only, and this
  # keeps base-tools single-ABI so one RUNPATH string fits every ELF's .dynstr
  # (see the ksh93 note below). ksh93 (the only 64-bit tool) is DROPPED: its
  # 64-bit closure would push the shared RUNPATH past the .dynstr grow limit
  # (design risk #1). sbin/sh is the shell for method scripts.
  baseToolBins = [
    "usr/bin/svcs"
    "usr/sbin/svcadm"
    "lib/svc/bin/svc.startd"
    "lib/svc/bin/svc.configd"
    "sbin/init"
    "sbin/sh"
    "usr/bin/ls"
    "usr/bin/cp"
    "usr/bin/mv"
    "usr/bin/cat"
    "usr/bin/rm"
    "usr/bin/mkdir"
    "usr/bin/ln"
  ];

  # transitive, ABI-AWARE non-libc NEEDED closure of baseToolBins, computed on
  # the host with scripts/oi-closure.sh (BFS over elfdump NEEDED, tracking each
  # object's ELF class, minus the libc-slice sonames). base-tools is 32-bit-only
  # now, so all libs resolve from lib/ + usr/lib/ (+ the fm/ variants). Re-run
  # that script if the tool set changes; paste the result here.
  baseToolLibs = [
    "lib/fm/libfmevent.so.1"
    "lib/libadm.so.1"
    "lib/libavl.so.1"
    "lib/libbsm.so.1"
    "lib/libcmdutils.so.1"
    "lib/libcontract.so.1"
    "lib/libcryptoutil.so.1"
    "lib/libctf.so.1"
    "lib/libcurses.so.1"
    "lib/libdevid.so.1"
    "lib/libdevinfo.so.1"
    "lib/libdladm.so.1"
    "lib/libdlpi.so.1"
    "lib/libdwarf.so.1"
    "lib/libefi.so.1"
    "lib/libgen.so.1"
    "lib/libinetutil.so.1"
    "lib/libkstat.so.1"
    "lib/libmd5.so.1"
    "lib/libnvpair.so.1"
    "lib/libpam.so.1"
    "lib/libproc.so.1"
    "lib/librcm.so.1"
    "lib/librestart.so.1"
    "lib/librtld_db.so.1"
    "lib/libscf.so.1"
    "lib/libsec.so.1"
    "lib/libsecdb.so.1"
    "lib/libsysevent.so.1"
    "lib/libtsol.so.2"
    "lib/libumem.so.1"
    "lib/libuuid.so.1"
    "lib/libuutil.so.1"
    "lib/libvarpd.so.1"
    "lib/libzfs.so.1"
    "lib/libzfs_core.so.1"
    "lib/libzutil.so.1"
    "usr/lib/fm/libtopo.so.1"
    "usr/lib/libast.so.1"
    "usr/lib/libbe.so.1"
    "usr/lib/libbrand.so.1"
    "usr/lib/libcmd.so.1"
    "usr/lib/libdll.so.1"
    "usr/lib/libexacct.so.1"
    "usr/lib/libficl-sys.so.4.1.0"
    "usr/lib/libidmap.so.1"
    "usr/lib/libidspace.so.1"
    "usr/lib/libinstzones.so.1"
    "usr/lib/libipmi.so.1"
    "usr/lib/libpcidb.so.1"
    "usr/lib/libpkcs11.so.1"
    "usr/lib/libpool.so.1"
    "usr/lib/libproject.so.1"
    "usr/lib/librename.so.1"
    "usr/lib/libshell.so.1"
    "usr/lib/libsmbios.so.1"
    "usr/lib/libsum.so.1"
    "usr/lib/libzfsbootenv.so.1"
    "usr/lib/libzonecfg.so.1"
    # svc.configd's private sqlite (proto-shipped, 32-bit, NEEDs only libc)
    "lib/libsqlite-sys.so.2.8.15"
  ];

  # systemPath — compose the minimal world into one symlink-farm tree (design
  # §4.2), now via the factored-out buildEnv (design §B: reuse, don't duplicate).
  # pathsToLink=null links the FULL runtime /usr,/lib,/sbin,/kernel,/platform
  # layout the image expects (a pathsToLink filter would drop the kernel). SMF
  # manifests come from smf.nix (T1.11), merged by the image builder, not here.
  systemPath = buildEnv {
    name = "system-path";
    paths = [ sys rtld libc ld base-tools srcPkgs.zlib srcPkgs.libxml2 ];
    pathsToLink = null;      # link everything (kernel/platform/lib/usr/...).
    ignoreCollisions = true; # slices are disjoint by design; last wins on clash.
  };

  # ---------------------------------------------------------------------------
  # PROTO SLICES with a COMPUTED library closure (./slices.nix + ./mk-proto-slice.nix).
  #
  # These are the illumos CORE-OS components that docs/image-nixification-gap.md
  # measured as "NOT available as derivations": df, useradd/passwd,
  # reboot/halt/poweroff, zpool/zfs, svcadm/svccfg, and the kernel. Each is a real
  # derivation now.
  #
  # ⚠️ HOW THESE DIFFER FROM base-tools ABOVE, which is the whole point: base-tools
  # uses mkIllumosComponent with `baseToolLibs`, a list of 60 sonames PASTED IN BY
  # HAND from a scripts/oi-closure.sh run (its own comment says "Re-run that script
  # if the tool set changes; paste the result here"). The slices below name only
  # BINARIES; mk-proto-slice walks DT_NEEDED transitively IN THE BUILDER and FAILS
  # on any soname it cannot resolve. Adding a binary pulls its libraries in
  # automatically. That removes the "a human forgot a list entry" class which caused
  # every image failure this campaign.
  # The NON-DEBUG kernel, built from illumos-gate source (./kernel-nd.nix). The
  # gate proto's own kernel is DEBUG (nightly -F) and panics in DEBUG-only checks.
  kernelNd = import ./kernel-nd.nix { gate = gate'; };

  slices = import ./slices.nix {
    kernelTree = kernelNd;
    # from-source zlib + libxml2 (./base-src.nix) satisfy the SMF stack's
    # libxml2.so.16 / libz.so.1 edges that host copies used to fill.
    externalLibs = [ srcPkgs.zlib srcPkgs.libxml2 ];
    gate = gate';
    libcSlice = libc;
    rtldSlice = rtld;
  };

  # Modern compiler toolchains (backlog PS-1 clang / PS-4 latest-GCC/GDB, pulled
  # forward): gcc14 + clang sliced from the OI host IPS install and RUNPATH-
  # relocated into the store, the foundation the package-batch work builds on.
  # See ./toolchains.nix + docs/design-toolchains.md.
  toolchains = import ./toolchains.nix { inherit mkIllumosComponent libc; };

  # gcc built FROM SOURCE (./gcc-src.nix): the NixOS bootstrap step. The host's
  # IPS gcc-14 is only the stage0 seed that compiles it; gcc.lib (libstdc++,
  # libgcc_s) is the C++/unwind runtime every shipped C++ binary links.
  gcc14 = import ./gcc-src.nix { gate = gate'; libcSlice = libc; inherit ld; inherit (srcPkgs) libcExtra; };
  # the stdenv compiler (wave6 W0): gcc15 built by the gcc 14 instance, so gcc15's own inputs (stage0 = the gcc 14 wrapper,
  # binutils, perl, coreutils...) are the gcc 14 builds and nothing here depends on itself.
  stdGcc15 = if gcc15From != null then gcc15From
    else (import ./. { gate = gate'; inherit gateArgs; stdenvGcc = "14"; }).gcc15;
  gcc = if stdenvGcc == "14" then gcc14 else stdGcc15;
  # GCC 15.3.0 + the illumos patch series (./gcc15-src.nix, gcc1 fd815b3 as is), built in the gcc 14 instance.
  gcc15 = if stdenvGcc != "14" then stdGcc15 else import ./gcc15-src.nix { gate = gate'; libcSlice = libc; inherit ld world; inherit (srcPkgs) libcExtra binutils;
    stage0 = srcPkgs.gccWrapper;   # the gcc 14 stdenv compiler builds the next one (NixOS stage chain)
    # store-only PATH; perl: libssp/libatomic make_sunver.pl. cliBase, not cli: no go/cargo in gcc15's closure.
    tools = builtins.concatStringsSep ":" (map (p: "${p}/bin") [ seedBuildTools srcPkgs.coreutils srcPkgs.findutils cliBase.gnupatch cliBase.perl ]); };
  # its wrapper: srcPkgs.gccWrapper's recipe (gas via -B, -R to the runtime) on gcc15.
  gcc15Wrapper = if stdenvGcc != "14" then srcPkgs.gccWrapper
    else derivation (srcPkgs.gccWrapper.drvAttrs // { name = "gcc-wrapper-15.3.0"; gcc = gcc15; gccLib = gcc15.lib; });

  # Rust FROM SOURCE (./rust-src.nix), the N-1 chain of docs/rust-illumos-bootstrap.md.
  # stage0 is the OI 1.97.1 seed tree, fetched by its NarHash from the cache (the
  # same store path, c821qgb6, as a fixed-output derivation, so pure eval works).
  rustSeedStage = import <nix/fetchurl.nix> {
    name = "rust-seed-stage";
    url = "https://cache.solnix.io/nar/1pl9c29vgwsknlaz7nqmfk2dxkhn3lni31z7yrszxv0nag9g1bw1.nar.xz";
    sha256 = "01cwvndhz2lm2wkjpsrvmna36msjnirbffb1s2s5c9nqbvw6jsir";
    unpack = true;
  };
  mkRust = args: import ./rust-src.nix ({
    inherit gcc libc world; gate = gate'; inherit (srcPkgs) openssl zlib;
    tools = hostfixTools; inherit (cliBase) python3;
  } // args);
  rust198 = mkRust { version = "1.98.0"; stage0 = rustSeedStage; seedStage0 = true;
    sha256 = "271fa73d8174f53d713c46a8310da7bf7cfdcfb8b7cfd1c2b74b84a83ae9fb1e"; };
  # The N-1 chain, one more hop: 1.97.1 seed -> 1.98.0 -> 1.99.0 -> 1.99.1. rust-1.98 (built by the OI seed) DIFFERS under --check
  # (wave5, 2/2) while rust-1.99.0 (built by 1.98) is SAME, so the shipped compiler is built by 1.99.0, never straight by 1.98
  # (wave5 report). rust1990 is build-only: nothing ships it, as rust198. 1.99.1: infra's dixi trial (sha256 = static.rust-lang.org's).
  rust1990 = mkRust { version = "1.99.0"; stage0 = rust198;
    sha256 = "cc41916a8c84f5d9ec4f55561b44e39f43b647b133f8a6f51be9ea13c83f7036"; };
  rust199 = mkRust { version = "1.99.1"; stage0 = rust1990;
    sha256 = "6451598a99e77f07571960f6b21d577399d3a30f33e80cbd2e3a4aae6535d265"; };

  # From-source packages the gate does not provide (./base-src.nix). zlib and
  # libxml2 replace the host-copied externalLibs; world is built on top of them.
  srcPkgs = import ./base-src.nix { gate = gate'; libcSlice = libc; inherit world gcc buildTools seedTools;
    nixChainTools = if buildTools == [ ] then { } else { inherit (cliBase) cmake; bzip2Bin = cliBase.bzip2-bin;
      nixBuildTools = with cliBase; [ autoconf automake libtool autoconf-archive gnum4 bison flex gnupatch srcPkgs.pkgconf ]; }; };
  # The Wayland + Mesa userland (./graphics), built like srcPkgs.
  graphics = import ./graphics { inherit (srcPkgs) mkSrcPkg pkgconf zlib hostTools; inherit world; inherit (cliBase) perl;
    python3 = if buildTools == [ ] then null else cliBase.python3; gnupatch = if buildTools == [ ] then null else cliBase.gnupatch; };   # perl: libffi's make_sunver.pl
  # The maintainer's headless CLI set (werk/meh home.packages), from source (./cli).
  # Generic Rust packages on rust199 (./cargo.nix: vendorOf FOD + cargoPkg).
  cargo = import ./cargo.nix {
    rust = rust199; inherit gcc libc world; gate = gate'; gccLib = gcc.lib;
    inherit (srcPkgs.nixChain) cacert; tools = hostfixTools; inherit (cliBase) python3;
  };
  # hostfix: the store tools the cargo builders put first on PATH (NixOS: stdenv's tools are store paths), so a
  # solnix host (no /usr/gnu, no python3, no patch) rebuilds them. cliBase = the cli set without go/cargo (no cycle).
  cliBase = import ./cli { base = srcPkgs; inherit world graphics; goChain = null; cargoPkg = null; };
  hostfixTools = buildEnv { name = "solnix-hostfix-tools"; pathsToLink = [ "/bin" ];
    # bash: rust's `x install` runs install.sh as bare "bash" from PATH (P0 run n: rust-1.98 failed there); NixOS's PATH always has it
    paths = [ seedBuildTools srcPkgs.coreutils srcPkgs.findutils cliBase.gnupatch cliBase.cmake srcPkgs.pkgconf srcPkgs.bash ]; };   # pkgconf: -sys crates' pkg-config
  # Go from source: go1.4 (C) -> 1.17 -> 1.20 -> 1.22 -> 1.24 -> 1.26 (./go.nix).
  goChain = import ./go.nix { inherit gcc world; gate = gate'; gccLib = gcc.lib; inherit (srcPkgs.nixChain) cacert;
    tools = hostfixTools; inherit (cliBase) python3; };
  cli = import ./cli { base = srcPkgs; inherit world graphics goChain; inherit (cargo) cargoPkg; };
  # libtorrent-rasterbar + solnix-torrent, the community seeder's BitTorrent client (./solnix-torrent.nix).
  torrent = import ./solnix-torrent.nix {
    inherit (srcPkgs) mkSrcPkg openssl pkgconf gccWrapper binutils; inherit (srcPkgs.nixChain) boost; inherit (cli) cmake;
    inherit gcc libc; gate = gate';
  };
  # Desktop apps outside graphics/ (pop-launcher, cosmic-wallpapers): ./desktop, so the COSMIC outs do not move.
  desktop = import ./desktop { inherit (cargo) cargoPkg; inherit graphics; inherit (cli) fd file;
    inherit (srcPkgs) mkSrcPkg bash coreutils gnugrep gnused hostname jq hostTools; inherit hostfixTools world; inherit (cliBase) python3; };
  # The GTK 3 / Wayland stack for Firefox (./desktop/gtk): its own dir, so neither COSMIC nor desktop/ outs move.
  gtk = import ./desktop/gtk { base = srcPkgs; inherit graphics cli; inherit (cosmic) noto-sans; inherit (cargo) cargoPkg; rust = rust199; inherit world; };
  # LLVM 23.1.4 from source, split as nixpkgs' llvmPackages: llvm, clang, lld, lldb, clang-wrapper (./llvm).
  llvmPackages = import ./llvm { inherit (srcPkgs) mkSrcPkg hostTools; inherit (cli) cmake python3 gnupatch; inherit (gtk) ninja;
    inherit world gcc ld libc; gate = gate'; };
  # COSMIC's fonts and icon themes on store tools only (./desktop/cosmic-data.nix). Not graphics/cosmic-data.nix, which
  # still evaluates there (unused) because graphics/ is every COSMIC app's fixups = ./. input: editing it moves all 21.
  # shortcut: graphics/cosmic-data.nix is dead text kept for that hash; delete it in the next wave that rebuilds COSMIC.
  cosmicData = import ./desktop/cosmic-data.nix { fetchurl = import <nix/fetchurl.nix>; tools = hostfixTools; inherit world;
    inherit (cliBase) python3;
    src = repo: sha256: import <nix/fetchurl.nix> {   # = graphics/cosmic.nix's src (same FOD)
      name = "${repo}-epoch-1.5.0.tar.gz"; url = "https://codeload.github.com/pop-os/${repo}/tar.gz/refs/tags/epoch-1.5.0"; inherit sha256; }; };
  # COSMIC rust programs on rust199 + graphics (./graphics/cosmic.nix).
  cosmic = import ./graphics/cosmic.nix {
    rust = rust199; inherit gcc libc world; gate = gate'; gccLib = gcc.lib;
    inherit (srcPkgs.nixChain) cacert; inherit graphics; inherit (srcPkgs) openssl;
  };

  # ---------------------------------------------------------------------------
  # seedBuildTools -- the DEFAULT build-tool set that lets a BARE solnix system
  # (dixi, an EC2 solnix instance; no /usr/gnu, no host gcc/gstrip/gzip/xz)
  # build from-source packages. A buildEnv symlink-farm whose bin/ carries every
  # NAME the mk-src-pkg builder resolves from PATH, aliased to the from-source
  # store tools. See docs/pending/builders-need-store-tools.md.
  #
  # Names the builder resolves from PATH (mk-src-pkg.nix):
  #   tar   -- `tar xf src.tar` (GNU tar auto-decompresses .gz/.xz/.bz2 by
  #            shelling out to gzip/xz/bzip2 ON PATH; illumos SVR4 tar cannot)
  #   grep  -- the build-time-path guard (`grep -rl`)
  #   gmake -- every build script's `gmake -j4`
  #   sed   -- build scripts' `sed -i`
  #   gstrip-- the --strip-debug pass (binutils' GNU strip; SVR4 strip no-ops)
  #   gzip/xz/bzip2 -- GNU tar's decompressor shellouts for each archive type
  # cc/gcc/g++/cpp are NOT here: the builder makes its own wrapper scripts that
  # exec $gcc/bin (the gcc arg, gcc-src.nix), never PATH. ld is the gate's in
  # the system profile; digest is native /usr/bin/digest (always on illumos).
  #
  # NO mk-src-pkg->mk-src-pkg CYCLE: the seed's member tools are built from
  # `seedSrcPkgs`, a base-src.nix instance pinned to buildTools=[] (the OI/bhost
  # bootstrap path), INDEPENDENT of whatever buildTools this world was given. So
  # a system can set buildTools=seedBuildTools for its OWN srcPkgs while the seed
  # itself was bootstrapped the bhost way. (dixi's store already holds every one
  # of these from the bhost build; a fresh system substitutes them from cache.)
  #
  # NOT PROVIDED FROM SOURCE (would 127 if a build invoked them):
  #   * bzip2 CLI -- nixChain.bzip2 ships libbz2.so only, no bzip2 binary. Only a
  #     .tar.bz2 source needs it; in this repo that is boost (nix-chain) alone.
  #   * cmake -- no from-source cmake in the mk-src-pkg chain (packages.nix' cmake
  #     is the OI-host mk-userland-pkg path). Only brotli + nlohmann_json (both
  #     nix-chain) call cmake. docs/devtools-in-closure.md tracks both gaps.
  # The seed is COMPLETE for the trivial proof (pkgconf) and the base userland
  # (.tar.gz/.tar.xz sources: the GNU tools, nix minus boost/brotli/json).
  seedSrcPkgs = import ./base-src.nix {
    gate = gate'; libcSlice = libc; inherit world gcc;
    buildTools = [ ];   # bootstrap: always the OI/bhost path, so no self-cycle.
  };

  # alias farm: the one name the mk-src-pkg chain could call that the pkgs do not
  # install under that name. gnutar installs `tar`; the builder uses bare `tar`,
  # but build scripts and docs also name `gnutar`, so expose both. (gmake/make,
  # xz/xzcat, grep, sed, gzip, gstrip are already the installed names.)
  seedTarAlias = derivation {
    name = "seed-tar-alias"; system = "x86_64-solaris";
    gnutar = seedSrcPkgs.gnutar;
    builder = "/usr/bin/bash";
    PATH = "/usr/bin";
    args = [ "-c" ''
      set -eu; mkdir -p "$out/bin"
      /usr/bin/ln -s "$gnutar/bin/tar" "$out/bin/gnutar"
    '' ];
  };

  # In an instance given buildTools (the system instance: lib/host-pkgs.nix passes the seed instance's seedBuildTools), the
  # seed farm IS that one: hostfixTools and gcc15's tools must not build a second seed chain here (with this instance's gcc
  # it would be a different, host-PATH copy). Only the seed instance (buildTools = [ ]) builds it. NixOS: stage N's build
  # tools are stage N-1's outputs.
  seedBuildTools = if buildTools != [ ] then builtins.head buildTools else seedBuildTools';
  seedBuildTools' = buildEnv0 {
    name = "solnix-seed-build-tools";
    paths = [
      seedSrcPkgs.gnumake    # make, gmake
      seedSrcPkgs.gnutar     # tar
      seedSrcPkgs.gnugrep    # grep
      seedSrcPkgs.gnused     # sed
      seedSrcPkgs.gzip       # gzip, gunzip, zcat
      seedSrcPkgs.binutils   # gstrip, gas, gar, gnm, gobjdump, greadelf, as
      seedSrcPkgs.nixChain.xz # xz, xzcat
      seedTarAlias           # gnutar -> tar
    ];
    pathsToLink = [ "/bin" ];
  };

  # The whole gate userland, relocated into the store (./mk-proto-world.nix).
  # deps: nspr + nss for the gate's LDAP client stack (libldap.so.5), and gcc.lib
  # for the gate's few C++ objects (make, audioconvert, libfru*, libsun_fc, the
  # NIS yp servers), which NEED libstdc++.so.6 + libgcc_s.so.1.
  world = import ./mk-proto-world.nix {
    gate = gate'; libcSlice = libc;
    sharedLibs = [ srcPkgs.libcExtra ];
    deps = [ srcPkgs.zlib srcPkgs.libxml2 srcPkgs.nspr srcPkgs.nss gcc.lib ];
  };

  # The boot-time set: what must run before the shared /nix is mounted (init,
  # the shell inittab uses, zfs to mount /nix, and autopush, which must run
  # before anything opens the console or the console never gets ldterm). Lives
  # as real files at these store paths inside each generation's BE
  # (docs/design-nix-managed-base.md).
  early = import ./mk-proto-slice.nix {
    gate = gate'; name = "illumos-early";
    deps = [ libc rtld srcPkgs.zlib srcPkgs.libxml2 ];
    bins = [ "sbin/init" "sbin/sh" "sbin/zfs" "sbin/mount" "sbin/autopush" ];
    allowUnresolved = [ ];
  };

  # stock: the gate's /etc and /var as shipped (mutable state templates that
  # install-be lays into a fresh BE, like a pkg(5) install would).
  stock = derivation {
    name = "illumos-stock-etc-var"; system = "x86_64-solaris"; gate = gate';
    builder = "/usr/bin/bash";
    args = [ "-c" "set -eu; cd $gate; /usr/bin/mkdir -p $out; /usr/bin/tar cf - etc var | (cd $out && /usr/bin/tar xf -)" ];
  };
  # the /etc driver database rendered from the gate's pkg manifests (./data/drivers).
  drivers = builtins.path { path = ./data/drivers; name = "illumos-driver-db"; };

  # pkgs.solnix.iwm-driver -- the Intel AC 7260..9560 wireless kernel module
  # (OpenBSD iwm(4)) + the wpa-pmk userland PMK deriver, built from
  # src/ports/wifi/iwm as a pure derivation (./iwm-driver.nix). Output:
  #   $out/kernel/drv/amd64/iwm   the loadable module
  #   $out/usr/lib/inet/wpa-pmk   the WPA2 PMK deriver (solnix-wifi-join calls it)
  # Only materialised when a config enables hardware.wirelessIwm.attachAtBoot;
  # the module build is dixi/EC2-only (illumos toolchain), so no amd64-cross
  # config forces it unless the wifi is actually wanted.
  # store tools for the out-of-gate kernel modules (wave6, gate2 A1): GNU coreutils/findutils/sed/grep/patch, git (git apply of the
  # port patches), and the world's illumos bins (nm elfdump ld mcs ...). Replaces /usr/bin:/usr/sbin:/usr/gnu/bin.
  kmodPath = if buildTools == [ ] then null else builtins.concatStringsSep ":" ((map (p: "${p}/bin")
    [ srcPkgs.coreutils srcPkgs.findutils srcPkgs.gnused srcPkgs.gnugrep cliBase.gnupatch srcPkgs.git ])
    ++ [ "${world}/usr/bin" "${world}/usr/sbin" "${world}/usr/ccs/bin" "${world}/bin" "${world}/sbin" ]);
  kmodGate = if buildTools == [ ] then null else ./path-gate.sh;
  iwm-driver = import ./iwm-driver.nix {
    kmodPath = kmodPath; pathGate = kmodGate;
    gate = gate';
    # the same C/C++ toolchain profile as `solnix-dev` (gcc 14.3.0 + gas + GNU
    # make); built inline here because solnix-dev itself is defined in the output
    # attrset, not this let, so it is not referenceable by name from here.
    solnixDev = buildEnv {
      name = "solnix-dev";
      paths = [ srcPkgs.gccWrapper srcPkgs.binutils srcPkgs.gnumake ];
      pathsToLink = [ "/bin" "/share/man" ];
    };
    inherit ld;
  };

  # pkgs.solnix.iwx-driver -- the Intel AX2xx wireless kernel module (OpenBSD
  # iwx(4)) under the giant-lock model, built from src/ports/wifi/iwx as a pure
  # derivation (./iwx-driver.nix). $out/kernel/drv/amd64/iwx. Its gate checks
  # symbol resolution against both the gate proto and kernelNd.
  # BSD fetch(1) (+ libfetch), from FreeBSD source: the last of the maintainer-required CLI set.
  bsdfetch = import ./bsdfetch.nix {
    gate = gate'; libcSlice = libc;
    inherit (srcPkgs) gccWrapper openssl; tools = hostfixTools; inherit (cliBase) perl; inherit world;
  };

  iwx-driver = import ./iwx-driver.nix {
    inherit kmodPath; pathGate = kmodGate;
    gate = gate';
    inherit kernelNd ld;
    solnixDev = buildEnv {
      name = "solnix-dev";
      paths = [ srcPkgs.gccWrapper srcPkgs.binutils srcPkgs.gnumake ];
      pathsToLink = [ "/bin" "/share/man" ];
    };
  };

  # pkgs.solnix.i915-driver -- the Intel iGPU kernel module (OpenBSD inteldrm +
  # drm via src/drm-port), a pure derivation (./i915-driver.nix) on the
  # iwx-driver pattern: $out/kernel/drv/amd64/i915. Its gate checks symbols
  # against the gate proto and kernelNd and that SIMD appears only inside
  # fpu_kernel_enter/exit sections (src/drm-port/i915/simd-gate.sh).
  i915-driver = import ./i915-driver.nix {
    inherit kmodPath; pathGate = kmodGate;
    gate = gate';
    inherit kernelNd ld;
    solnixDev = buildEnv {
      name = "solnix-dev";
      paths = [ srcPkgs.gccWrapper srcPkgs.binutils srcPkgs.gnumake ];
      pathsToLink = [ "/bin" "/share/man" ];
    };
  };

  # pkgs.solnix.touchpad-driver -- the X1E Gen 5 touchpad modules, dwiic (LPSS
  # DesignWare I2C) and ihid (HID over I2C, linked under consms with usbms), a
  # pure derivation (./touchpad-driver.nix) on the iwx-driver pattern. Headers
  # the proto lacks (sys/i2c, sys/acpica.h, usbai_private.h) come from
  # kernelNd.src. hardware.touchpad.i2cHid lays and binds them.
  touchpad-driver = import ./touchpad-driver.nix {
    inherit kmodPath; pathGate = kmodGate;
    gate = gate';
    inherit kernelNd ld;
    solnixDev = buildEnv {
      name = "solnix-dev";
      paths = [ srcPkgs.gccWrapper srcPkgs.binutils srcPkgs.gnumake ];
      pathsToLink = [ "/bin" "/share/man" ];
    };
  };

  # dgputemp: the X1E's dGPU temperature (EC GPUT) as a kstat, for the nvidia thermal guard.
  dgputemp = import ./dgputemp.nix {
    gate = gate';
    inherit kernelNd ld;
    solnixDev = buildEnv {
      name = "solnix-dev";
      paths = [ srcPkgs.gccWrapper srcPkgs.binutils srcPkgs.gnumake ];
      pathsToLink = [ "/bin" "/share/man" ];
    };
  };

  # wpa-pmk on the system PATH: a bin/-shaped view of iwm-driver's
  # usr/lib/inet/wpa-pmk, so environment.systemPackages puts it at sw/bin ->
  # /usr/bin/wpa-pmk, which the solnix-wifi-join service's PATH finds. (The join
  # script's PATH leads with /usr/lib/inet, the canonical illumos home for this
  # tool, and also carries /usr/bin, which this covers via sw/bin.)
  wpa-pmk = derivation {
    name = "wpa-pmk";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin";
    driver = iwm-driver;
    args = [ "-c" ''
      set -eu
      mkdir -p "$out/bin"
      cp "$driver/usr/lib/inet/wpa-pmk" "$out/bin/wpa-pmk"
      chmod 0555 "$out/bin/wpa-pmk"
    '' ];
  };

  # solnix-cputemp -- the coretemp ksensor reader the live media's temperature
  # line uses (src/live/solnix-cputemp.c): one ioctl per /dev/sensors/temperature/
  # cpu node. Built like wpa-pmk (the solnix-dev gcc), self-test at build time.
  solnix-cputemp = derivation {
    name = "solnix-cputemp";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin";
    src = ../../src/live/solnix-cputemp.c;
    solnixDev = buildEnv {
      name = "solnix-dev";
      paths = [ srcPkgs.gccWrapper srcPkgs.binutils srcPkgs.gnumake ];
      pathsToLink = [ "/bin" "/share/man" ];
    };
    args = [ "-c" ''
      set -eu
      export PATH="$solnixDev/bin:/usr/bin"
      mkdir -p "$out/bin"
      cp "$src" solnix-cputemp.c; gcc -O2 -Wall -Werror -Wl,-R,${libc}/lib/amd64 -o "$out/bin/solnix-cputemp" solnix-cputemp.c
      "$out/bin/solnix-cputemp" -t || { echo "FATAL: solnix-cputemp self-test failed" >&2; exit 1; }
      : > zc; /usr/bin/bash ${./zero-checksum.sh} "$out" zc; [ ! -s zc ] || { cat zc >&2; exit 1; }
    '' ];
  };

  # btintelfw + hcitest -- userland Bluetooth tools over ugen (./bluetooth):
  # the Intel firmware loader (FreeBSD iwmbtfw) and NetBSD's netbt HCI core
  # (unit up + inquiry). Each build runs its self-test and negative controls.
  bluetooth = import ./bluetooth {
    gate = gate';
    inherit libc;
    tools = [ srcPkgs.coreutils srcPkgs.findutils world ];
    solnixDev = buildEnv {
      name = "solnix-dev";
      paths = [ srcPkgs.gccWrapper srcPkgs.binutils srcPkgs.gnumake ];
      pathsToLink = [ "/bin" "/share/man" ];
    };
  };

  # iwm-firmware -- the proprietary (redistributable) iwlwifi blob + licence
  # (./iwm-firmware.nix), gated on the unfree opt-in. Threaded through here so
  # mkIwmKernel can lay it into the BE kernel tree alongside the module. The
  # acceptFirmwareLicense arg is passed by the config (hardware.wirelessIwm.
  # allowUnfreeFirmware); default false keeps the blob out of any closure that
  # did not opt in.
  iwmFirmware = acceptFirmwareLicense:
    import ./iwm-firmware.nix { inherit acceptFirmwareLicense; };

  # pkgs.solnix.nvidia-oss-modules -- the NVIDIA open GPU kernel modules
  # (nvidia, nvidia_modeset, nvidia_i2c; MIT), built from the pinned upstream
  # tree with its RM source and checked unresolved=0 against kernelNd
  # (./nvidia-oss.nix). Headers come from kernelNd's own illumos-gate source.
  # No config installs or binds these: first attach is supervised by hand
  # (nvidia before nvidia_modeset; see X1E-NVIDIA-STATUS.md).
  nvidia-oss-modules = (import ./nvidia-oss.nix {
    illumosSrc = kernelNd.src;
    kernel = kernelNd;
    gate = gate';
    solnixDev = null;
  }).nvidia-oss-modules;
  # nvidia-gsp-firmware 615.71.09 (GSP + ucodes for TU10X/GA10X), unfree,
  # redistributable for open-source kernels; gated on the explicit opt-in.
  nvidiaGspFirmware = acceptFirmwareLicense:
    import ./nvidia-gsp-firmware.nix { inherit acceptFirmwareLicense; };
  # nvidia-probe -- the open modules' ioctl probe (src/drm-port/nvidia-oss-tools/
  # nvprobe.c): /dev/nvidiactl version + card list, the first /dev/nvidia0 open
  # (RmInitAdapter, GSP boot), root client/device/subdevice, GPU name and
  # temperature. Only the MIT ABI headers of the pinned RM tree (rmSrc).
  nvidia-probe = derivation {
    name = "nvidia-probe-615.71.09";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin";
    src = ../../src/drm-port/nvidia-oss-tools/nvprobe.c;
    rm = import ./fetch-tarball.nix {
      url = "https://github.com/nwilkens/open-gpu-kernel-modules/archive/8da2326c626cdd08130538f0f5f9a1f985054f4a.tar.gz";
      sha256 = "386540bc01e99bae3bc1d7a137fa04969e33f77bb3e2eb9991445947806ceb00";
      narHash = "19r6wrm4067pq89nr63dppnbv85q5rmpwb2pp0kz85ymn69lg4lh";
    };
    solnixDev = buildEnv {
      name = "solnix-dev";
      paths = [ srcPkgs.gccWrapper srcPkgs.binutils srcPkgs.gnumake ];
      pathsToLink = [ "/bin" "/share/man" ];
    };
    args = [ "-c" ''
      set -eu
      export PATH="$solnixDev/bin:/usr/bin"
      mkdir -p "$out/bin"
      I="-I$rm/kernel-open/common/inc -I$rm/src/common/sdk/nvidia/inc -I$rm/src/nvidia/arch/nvalloc/unix/include -I$rm/src/common/inc"
      cp "$src" nvprobe.c; gcc -O2 -Wall -Werror $I -Wl,-R,${libc}/lib/amd64 -o "$out/bin/nvidia-probe" nvprobe.c
      # no GPU at build time: it must fail at the first step, not succeed
      "$out/bin/nvidia-probe" > /dev/null 2>&1 && { echo "FATAL: nvidia-probe passed without a GPU" >&2; exit 1; } || true
    '' ];
  };
  # mkNvidiaBootDb base -- `base` with the devlink.tab lines of the nvidia
  # module's /dev names (kernel-illumos/devlink.tab without nvidia_uvm, which
  # is not built). The majors and the alias come from mkDriversDbWith.
  mkNvidiaBootDb = base: derivation {
    name = "illumos-driver-db-nvidia";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin";
    inherit base;
    tab = "${nvidia-oss-modules}/share/nvidia-oss/devlink.tab";
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"; cp "$base"/* "$out"/; chmod u+w "$out"/*
      grep -v nvidia_uvm "$tab" | while IFS= read -r l; do
        grep -qxF "$l" "$out/devlink.tab.add" || printf '%s\n' "$l" >> "$out/devlink.tab.add"
      done
      grep -q 'type=ddi_pseudo:nvidia	' "$out/devlink.tab.add" || { echo "FATAL: nvidia devlink" >&2; exit 1; }
    '' ];
  };
  # mkNvidiaBootKernel base gsp -- `base` (mkGpuKernel's tree with the nvidia
  # modules) plus what an nvidia bound at boot needs:
  #   kernel/drv/nvidia.conf  the pseudo node (/dev/nvidiactl) and
  #       NVreg_GpuInitOnProbe=0: attach maps the BARs and makes /dev/nvidia0
  #       but leaves RmInitAdapter (GSP boot) to the first open, which a
  #       service runs after the dump device is up (graphics-gpu.nix);
  #   kernel/drv/tzmon.conf   solnix-dgpu-off=0: tzmon's boot-time dGPU
  #       power-off (scripts/patches/0005) acts on every unattached dGPU,
  #       bound or not, and would cut the GPU's power before nvidia attaches;
  #   kernel/misc/amd64/dgputemp  the EC dGPU-temperature kstat the thermal
  #       guard reads (pkgs.solnix.dgputemp);
  #   usr/kernel/firmware/nvidia/<v>/  the GSP firmware (85 MB for GA10X). It
  #       is on the module path (firmware_open -> kobj_open_path) but not in
  #       the boot_archive's filelist, which a kernel/ copy would grow by that.
  mkNvidiaBootKernel = base: gsp: derivation {
    name = "illumos-kernel-nvidia";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin:/usr/sbin";
    inherit base gsp dgputemp;
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"
      ( cd "$base" && tar cf - . ) | ( cd "$out" && tar xf - )
      for d in "$out" "$out/kernel" "$out/kernel/drv" "$out/kernel/drv/tzmon.conf" "$out/kernel/misc" "$out/kernel/misc/amd64" "$out/usr" "$out/usr/kernel"; do
        [ -e "$d" ] && [ ! -h "$d" ] && chmod u+w "$d" 2>/dev/null || true
      done
      [ -f "$out/kernel/drv/tzmon.conf" ] || { echo "FATAL: no kernel/drv/tzmon.conf in the base tree" >&2; exit 1; }
      mkdir -p "$out/usr/kernel/firmware"
      cp -R "$gsp/kernel/firmware/nvidia" "$out/usr/kernel/firmware/"
      cp "$dgputemp/kernel/misc/amd64/dgputemp" "$out/kernel/misc/amd64/dgputemp"
      printf '%s\n' '# solnix: the control node, and RM init deferred to the first open (graphics-gpu.nix)' \
        'name="nvidia" parent="pseudo" instance=0;' 'NVreg_GpuInitOnProbe=0;' > "$out/kernel/drv/nvidia.conf"
      grep -q '^solnix-dgpu-off' "$out/kernel/drv/tzmon.conf" && { echo "FATAL: tzmon.conf already sets solnix-dgpu-off" >&2; exit 1; }
      printf '%s\n' '# solnix: nvidia drives the dGPU; no boot-time power-off' 'solnix-dgpu-off=0;' >> "$out/kernel/drv/tzmon.conf"
      chmod 0444 "$out/kernel/drv/nvidia.conf" "$out/kernel/drv/tzmon.conf"
      [ -e "$out/kernel/drv/amd64/nvidia" ] || { echo "FATAL: no nvidia module in the base tree" >&2; exit 1; }
      for m in nvidia_modeset nvidia_i2c; do
        [ ! -e "$out/kernel/drv/$m.conf" ] || { echo "FATAL: $m.conf would attach $m at boot" >&2; exit 1; }
      done
      [ ! -e "$out/kernel/firmware/nvidia" ] && [ -s "$out/usr/kernel/firmware/nvidia/615.71.09/gsp_ga10x.bin" ] \
        || { echo "FATAL: GSP firmware not in usr/kernel only" >&2; exit 1; }
    '' ];
  };
  # i915-firmware (DMC + GuC + HuC for Alder Lake-P), unfree, redistributable
  # (linux-firmware LICENSE.i915); gated on the explicit opt-in.
  i915Firmware = acceptFirmwareLicense:
    import ./i915-firmware.nix { inherit acceptFirmwareLicense; };

  # mkIwmDriversDb -- the /etc driver database with the iwm lines merged in, so
  # install-be lays an iwm-aware DB into the BE with NO install-be change (it
  # copies name_to_major/driver_aliases/minor_perm verbatim; the config renders
  # the final DB, the NixOS way). Returns a store path shaped exactly like
  # `drivers` (./data/drivers) with iwm appended:
  #   name_to_major  iwm <N>              N = the LOWEST unused major (NOT a
  #                                       hardcoded 362; computed in the builder
  #                                       as the gate's own gen.py does)
  #   driver_aliases iwm "pciex8086,a370"  the AC 9560 PCI id (STATUS.md)
  #   minor_perm     iwm:* 0666 root sys  and  clone:iwm 0666 root sys
  mkIwmDriversDb = derivation {
    name = "illumos-driver-db-iwm";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin:/usr/sbin";
    base = drivers;
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"
      cp "$base"/* "$out"/
      chmod u+w "$out"/name_to_major "$out"/driver_aliases "$out"/minor_perm
      # already present (idempotent)? then nothing to do.
      if awk '{print $1}' "$out/name_to_major" | grep -qx iwm; then
        echo "iwm already in name_to_major" >&2
      else
        # lowest unused major, exactly as data/drivers/gen.py assigns new ones.
        used=$(awk '{print $2}' "$out/name_to_major" | sort -n)
        n=0
        for m in $used; do if [ "$m" = "$n" ]; then n=$((n+1)); fi; done
        # the loop stops at the first gap; keep stepping past contiguous highs.
        while printf '%s\n' $used | grep -qx "$n"; do n=$((n+1)); done
        echo "iwm $n" >> "$out/name_to_major"
        echo "iwm: allocated major $n (lowest free)" >&2
      fi
      grep -q '^iwm ' "$out/driver_aliases" || \
        printf 'iwm "pciex8086,a370"\n' >> "$out/driver_aliases"
      grep -q '^iwm:' "$out/minor_perm" || \
        { printf 'iwm:* 0666 root sys\n'; printf 'clone:iwm 0666 root sys\n'; } >> "$out/minor_perm"
      # sanity: the three lines are present
      awk '{print $1}' "$out/name_to_major" | grep -qx iwm || { echo "FATAL: no iwm major" >&2; exit 1; }
      grep -q '^iwm "pciex8086,a370"' "$out/driver_aliases" || { echo "FATAL: no iwm alias" >&2; exit 1; }
      grep -q '^iwm:\*' "$out/minor_perm" || { echo "FATAL: no iwm minor_perm" >&2; exit 1; }
    '' ];
  };

  # mkIwmDriversDbUnbound -- mkIwmDriversDb without the driver_aliases line:
  # iwm has a major and minor_perm (modload and a runtime `update_drv -a`
  # work) but binds nothing at boot. For installer media
  # (hardware.wirelessIntel.onMedia). A separate derivation so the bound one
  # above stays byte-identical.
  mkIwmDriversDbUnbound = derivation {
    name = "illumos-driver-db-iwm-unbound";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin:/usr/sbin";
    base = drivers;
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"
      cp "$base"/* "$out"/
      chmod u+w "$out"/name_to_major "$out"/driver_aliases "$out"/minor_perm
      if ! awk '{print $1}' "$out/name_to_major" | grep -qx iwm; then
        used=$(awk '{print $2}' "$out/name_to_major" | sort -n)
        n=0
        while printf '%s\n' $used | grep -qx "$n"; do n=$((n+1)); done
        echo "iwm $n" >> "$out/name_to_major"
      fi
      grep -q '^iwm:' "$out/minor_perm" || \
        { printf 'iwm:* 0666 root sys\n'; printf 'clone:iwm 0666 root sys\n'; } >> "$out/minor_perm"
      awk '{print $1}' "$out/name_to_major" | grep -qx iwm || { echo "FATAL: no iwm major" >&2; exit 1; }
      if grep -q '^iwm ' "$out/driver_aliases"; then echo "FATAL: unbound DB has an iwm alias" >&2; exit 1; fi
    '' ];
  };

  # stripSliceRefs -- run after a wrapper tar-copies a kernel slice. The copy
  # keeps the slice's own store path in boot/grub/bin/grub and
  # boot/solaris/bin/symdef (RUNPATH entries naming the slice's EMPTY
  # lib-32/lib-64) and in .slice/runpath.txt, so the wrapper referenced the slice
  # it copied and the kernel shipped twice (measured: +94.5 MB in the installer
  # ramdisk closure, which then failed its size cap). Each hash in $strip is
  # overwritten in place, same length, as nixpkgs' remove-references-to does;
  # the entries named empty dirs, so nothing resolves differently. Nix enforces
  # the result through disallowedReferences.
  stripSliceRefs = ''
      [ -x /usr/bin/perl ] || { echo "FATAL: /usr/bin/perl needed to strip slice references" >&2; exit 1; }
      for sp in $strip; do
        bh=$(basename "$sp" | cut -c1-32)
        grep -rl "$bh" "$out" 2>/dev/null | while read -r f; do
          [ -h "$f" ] && continue
          chmod u+w "$f" "$(dirname "$f")"
          /usr/bin/perl -0777 -pi -e "s/$bh/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee/g" "$f"
        done
      done
  '';

  # mkIwmKernel -- the kernel slice with the iwm module and its firmware laid
  # into the kernel tree, so a BE populated from this slice has
  #   kernel/drv/amd64/iwm          the module install-be copies as a real file
  #   kernel/firmware/iwm/iwm-9000-46   the blob loadfirmware() opens
  # install-be copies the whole kernel tree verbatim, so no install-be change is
  # needed. Takes acceptFirmwareLicense so the blob is only pulled on opt-in.
  mkIwmKernel = acceptFirmwareLicense: derivation {
    name = "illumos-kernel-iwm";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin:/usr/sbin";
    base = slices.kernel;
    module = iwm-driver;
    firmware = iwmFirmware acceptFirmwareLicense;
    strip = [ slices.kernel ];
    disallowedReferences = [ slices.kernel ];
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"
      # copy the base kernel slice, then overlay iwm's module + firmware.
      ( cd "$base" && tar cf - . ) | ( cd "$out" && tar xf - )
      ${stripSliceRefs}
      # NOT chmod -R: the kernel slice has relative symlinks (e.g.
      # boot/solaris/bin/root_archive) that dangle in this isolated tree, and
      # chmod -R FOLLOWS symlinks -> errors on the broken link (same hazard
      # install-be.sh documents). Make writable only the real dirs we add into,
      # walking the chain (store dirs arrive 0555).
      for d in "$out" "$out/kernel" "$out/kernel/drv" "$out/kernel/drv/amd64" "$out/kernel/firmware"; do
        [ -d "$d" ] && [ ! -h "$d" ] && chmod u+w "$d" 2>/dev/null || true
      done
      mkdir -p "$out/kernel/drv/amd64" "$out/kernel/firmware/iwm"
      cp "$module/kernel/drv/amd64/iwm" "$out/kernel/drv/amd64/iwm"
      cp "$firmware/kernel/firmware/iwm/"* "$out/kernel/firmware/iwm/"
      chmod 0555 "$out/kernel/drv/amd64/iwm"
      [ -f "$out/kernel/drv/amd64/iwm" ] || { echo "FATAL: iwm module not laid in" >&2; exit 1; }
      [ -f "$out/kernel/firmware/iwm/iwm-9000-46" ] || { echo "FATAL: iwm firmware not laid in" >&2; exit 1; }
      # the base kernel's unix must still be there (we only added files).
      [ -e "$out/platform/i86pc/kernel/amd64/unix" ] || { echo "FATAL: base kernel clobbered" >&2; exit 1; }
    '' ];
  };

  # iwx-firmware -- the AX2xx blobs + licence (./iwx-firmware.nix), gated on
  # the unfree opt-in like iwmFirmware.
  iwxFirmware = acceptFirmwareLicense:
    import ./iwx-firmware.nix { inherit acceptFirmwareLicense; };
  # ibt-firmware -- Intel AX2xx Bluetooth blobs + licence (./ibt-firmware.nix),
  # same unfree opt-in; loaded by btintelfw (docs/design-bluetooth.md).
  ibtFirmware = acceptFirmwareLicense:
    import ./ibt-firmware.nix { inherit acceptFirmwareLicense; };

  # The AX210/AX211 ids iwx claims (src/ports/wifi/iwx/compat/dev/pci/
  # pcidevs.h WL_22500_9..17), in the illumos pciex spelling. 51f0 is the X1E.
  iwxAliases = [ "pciex8086,2725" "pciex8086,2726" "pciex8086,51f0"
    "pciex8086,51f1" "pciex8086,54f0" "pciex8086,7a70" "pciex8086,7af0"
    "pciex8086,7e40" "pciex8086,7f70" ];

  # mkIwxDriversDb base bind -- the /etc driver database with iwx merged in,
  # the mkIwmDriversDb way: name_to_major iwx <lowest free major>, minor_perm
  # iwx:* + clone:iwx, and driver_aliases for iwxAliases ONLY when bind is
  # true. bind = false gives a database that knows the driver (so modload and
  # a runtime `update_drv -a` work) but never attaches it at boot. `base` is
  # the DB to extend (pkgs.solnix.drivers, or mkIwmDriversDb to carry both).
  mkIwxDriversDb = base: bind: derivation {
    name = "illumos-driver-db-iwx${if bind then "-bound" else ""}";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin:/usr/sbin";
    inherit base;
    aliases = if bind then iwxAliases else [ ];
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"
      cp "$base"/* "$out"/
      chmod u+w "$out"/name_to_major "$out"/driver_aliases "$out"/minor_perm
      if ! awk '{print $1}' "$out/name_to_major" | grep -qx iwx; then
        used=$(awk '{print $2}' "$out/name_to_major" | sort -n)
        n=0
        while printf '%s\n' $used | grep -qx "$n"; do n=$((n+1)); done
        echo "iwx $n" >> "$out/name_to_major"
        echo "iwx: allocated major $n (lowest free)" >&2
      fi
      for a in $aliases; do
        grep -qx "iwx \"$a\"" "$out/driver_aliases" || printf 'iwx "%s"\n' "$a" >> "$out/driver_aliases"
      done
      grep -q '^iwx:' "$out/minor_perm" || \
        { printf 'iwx:* 0666 root sys\n'; printf 'clone:iwx 0666 root sys\n'; } >> "$out/minor_perm"
      # every major unique, iwx present, aliases exactly as asked
      [ "$(awk '{print $2}' "$out/name_to_major" | sort | uniq -d | wc -l)" -eq 0 ] || { echo "FATAL: duplicate major" >&2; exit 1; }
      awk '{print $1}' "$out/name_to_major" | grep -qx iwx || { echo "FATAL: no iwx major" >&2; exit 1; }
      na=$(grep -c '^iwx ' "$out/driver_aliases" || true)
      want=$(set -- $aliases; echo $#)
      [ "$na" -eq "$want" ] || { echo "FATAL: $na iwx aliases, want $want" >&2; exit 1; }
      grep -q '^iwx:\*' "$out/minor_perm" || { echo "FATAL: no iwx minor_perm" >&2; exit 1; }
    '' ];
  };

  # mkIwxKernel base acceptFirmwareLicense -- `base` (a kernel slice, e.g.
  # slices.kernel or mkIwmKernel) with the iwx module and its firmware laid in:
  #   kernel/drv/amd64/iwx
  #   kernel/firmware/iwx/<name>   where loadfirmware() opens them:
  #     firmware_open("iwx", name) -> "firmware/iwx/<name>" on the module path
  mkIwxKernel = base: acceptFirmwareLicense: derivation {
    name = "illumos-kernel-iwx";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin:/usr/sbin";
    inherit base;
    module = iwx-driver;
    firmware = iwxFirmware acceptFirmwareLicense;
    strip = [ base slices.kernel ];
    disallowedReferences = [ base slices.kernel ];
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"
      ( cd "$base" && tar cf - . ) | ( cd "$out" && tar xf - )
      ${stripSliceRefs}
      # NOT chmod -R (it follows the slice's dangling relative symlinks).
      for d in "$out" "$out/kernel" "$out/kernel/drv" "$out/kernel/drv/amd64" "$out/kernel/firmware"; do
        [ -d "$d" ] && [ ! -h "$d" ] && chmod u+w "$d" 2>/dev/null || true
      done
      mkdir -p "$out/kernel/drv/amd64" "$out/kernel/firmware/iwx"
      cp "$module/kernel/drv/amd64/iwx" "$out/kernel/drv/amd64/iwx"
      cp "$firmware/kernel/firmware/iwx/"* "$out/kernel/firmware/iwx/"
      chmod 0555 "$out/kernel/drv/amd64/iwx"
      [ -f "$out/kernel/drv/amd64/iwx" ] || { echo "FATAL: iwx module not laid in" >&2; exit 1; }
      for f in iwx-so-a0-gf-a0-77 iwx-so-a0-gf-a0.pnvm; do
        [ -f "$out/kernel/firmware/iwx/$f" ] || { echo "FATAL: iwx firmware $f not laid in" >&2; exit 1; }
      done
      [ -e "$out/platform/i86pc/kernel/amd64/unix" ] || { echo "FATAL: base kernel clobbered" >&2; exit 1; }
    '' ];
  };


  # i915Aliases -- the iGPUs hardware.graphics.i915.attachAtBoot binds: the
  # X1E's Alder Lake-P Iris Xe and the X1's Coffee Lake-H UHD 630 (the two the
  # staged attach plan covers, src/drm-port/i915/STAGED-ATTACH-PLAN.md).
  i915Aliases = [ "pciex8086,46a6" "pciex8086,3e9b" ];
  # nvidiaAliases -- the dGPU hardware.graphics.nvidia.attachAtBoot binds: the
  # X1E Gen 5's RTX 3080 Ti Mobile (GA103). One id, not the 319-line
  # nvidia.aliases list: the only NVIDIA GPU this has been tried on.
  nvidiaAliases = [ "pciex10de,2420" ];

  # mkDriversDbWith base drivers -- `base` (a driver DB shaped like `drivers`)
  # with each of `drivers` ({ name; perm; aliases; }) added the mkIwxDriversDb
  # way: name_to_major at the lowest free major, "minor_perm <name>:* <perm>"
  # unless perm is null, and one driver_aliases line per alias. No aliases =
  # the system knows the driver (modload, a runtime update_drv -a work) but
  # binds it to nothing at boot.
  mkDriversDbWith = base: drivers: derivation {
    name = "illumos-driver-db-gpu";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin:/usr/sbin";
    inherit base;
    spec = builtins.concatStringsSep "\n" (map (d:
      "${d.name}|${if d.perm == null then "" else d.perm}|${builtins.concatStringsSep " " d.aliases}") drivers);
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"
      cp "$base"/* "$out"/
      chmod u+w "$out"/name_to_major "$out"/driver_aliases "$out"/minor_perm
      printf '%s\n' "$spec" | while IFS='|' read -r name perm aliases; do
        [ -n "$name" ] || continue
        if ! awk '{print $1}' "$out/name_to_major" | grep -qx "$name"; then
          used=$(awk '{print $2}' "$out/name_to_major" | sort -n)
          n=0
          while printf '%s\n' $used | grep -qx "$n"; do n=$((n+1)); done
          echo "$name $n" >> "$out/name_to_major"
          echo "$name: allocated major $n (lowest free)" >&2
        fi
        [ -z "$perm" ] || grep -q "^$name:" "$out/minor_perm" || printf '%s:* %s\n' "$name" "$perm" >> "$out/minor_perm"
        for a in $aliases; do
          grep -qx "$name \"$a\"" "$out/driver_aliases" || printf '%s "%s"\n' "$name" "$a" >> "$out/driver_aliases"
        done
        na=$(grep -c "^$name " "$out/driver_aliases" || true)
        want=$(set -- $aliases; echo $#)
        [ "$na" -eq "$want" ] || { echo "FATAL: $name has $na aliases, want $want" >&2; exit 1; }
        [ -z "$perm" ] || grep -q "^$name:\*" "$out/minor_perm" || { echo "FATAL: no $name minor_perm" >&2; exit 1; }
        # DRM minors (DDI_NT_DISPLAY_DRM, "ddi_display:drm") get /dev/dri/<minor>, as OI's
        # drm package adds: devfsadm has no built-in rule for that node type. Type only: a
        # devlink.tab "name=" selects the node name (display), not the driver, and matched
        # nothing on lixi (measured; the type-only rule gave card0 + renderD128).
        if [ "$name" = i915 ]; then
          chmod u+w "$out/devlink.tab.add"
          l=$(printf 'type=ddi_display:drm\tdri/\\M0')
          grep -qxF "$l" "$out/devlink.tab.add" || printf '%s\n' "$l" >> "$out/devlink.tab.add"
        fi
      done
      [ "$(awk '{print $2}' "$out/name_to_major" | sort | uniq -d | wc -l)" -eq 0 ] || { echo "FATAL: duplicate major" >&2; exit 1; }
    '' ];
  };

  # The LPSS I2C controller hardware.touchpad.i2cHid binds dwiic to: the X1E
  # Gen 5's Alder Lake-P I2C0 (8086:51e8), behind which sits the ELAN touchpad.
  touchpadAliases = [ "pci8086,51e8" ];

  # mkTouchpadDriversDb base -- `base` with dwiic (bound to touchpadAliases)
  # and ihid (no alias: it binds by node name to the i2c device the
  # solnix-touchpad SMF one-shot adds) and dacf.conf.add, the dacf(5) rule
  # install-be appends to /etc/dacf.conf: consconfig_dacf pushes usbms on
  # ihid's internal_mouse node and links it under consms, as it does for a USB
  # mouse (hid:internal_mouse). Neither driver has a minor_perm line: dwiic's
  # nodes belong to i2cnex and ihid's only node is kernel-internal.
  mkTouchpadDriversDb = base: derivation {
    name = "illumos-driver-db-touchpad";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin:/usr/sbin";
    db = mkDriversDbWith base [
      { name = "dwiic"; perm = null; aliases = touchpadAliases; }
      { name = "ihid"; perm = null; aliases = [ ]; }
    ];
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"; cp "$db"/* "$out"/; chmod u+w "$out"/*
      for op in post-attach pre-detach; do
        printf 'driver-minorname="ihid:internal_mouse" consconfig_dacf:ms_config %s - pushmod="usbms"\n' $op
      done >> "$out/dacf.conf.add"
      [ "$(grep -c '^driver-minorname="ihid:internal_mouse"' "$out/dacf.conf.add")" -eq 2 ] || { echo "FATAL: dacf rule" >&2; exit 1; }
    '' ];
  };

  # mkTouchpadKernel base -- `base` (a kernel slice) with kernel/drv/amd64/
  # dwiic and ihid laid in, the mkIwxKernel way. No driver.conf: nothing here
  # attaches unless the driver DB binds it.
  mkTouchpadKernel = base: derivation {
    name = "illumos-kernel-touchpad";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin:/usr/sbin";
    inherit base;
    module = touchpad-driver;
    strip = [ base slices.kernel ];
    disallowedReferences = [ base slices.kernel touchpad-driver ];
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"
      ( cd "$base" && tar cf - . ) | ( cd "$out" && tar xf - )
      ${stripSliceRefs}
      for d in "$out" "$out/kernel" "$out/kernel/drv" "$out/kernel/drv/amd64"; do
        [ -d "$d" ] && [ ! -h "$d" ] && chmod u+w "$d" 2>/dev/null || true
      done
      mkdir -p "$out/kernel/drv/amd64"
      for m in dwiic ihid; do
        cp "$module/kernel/drv/amd64/$m" "$out/kernel/drv/amd64/$m"; chmod 0555 "$out/kernel/drv/amd64/$m"
        [ ! -e "$out/kernel/drv/$m.conf" ] || { echo "FATAL: $m.conf in the tree" >&2; exit 1; }
      done
      [ -e "$out/platform/i86pc/kernel/amd64/unix" ] || { echo "FATAL: base kernel clobbered" >&2; exit 1; }
    '' ];
  };

  # mkGpuKernel base { nvidia; gspFirmware; } -- `base` (a kernel slice, e.g.
  # mkIwxKernel's) with kernel/drv/amd64/i915 laid in, plus nvidia,
  # nvidia_modeset and nvidia_i2c when nvidia = true, plus NVIDIA's GSP
  # firmware (kernel/firmware/nvidia/<version>/) when gspFirmware is the
  # licence-accepted nvidiaGspFirmware. No driver.conf is laid: nvidia.conf
  # and nvidia_i2c.conf declare pseudo children (nvidia_i2c with
  # ddi-forceattach=1) that boot would configure, loading nvidia unasked.
  # The nvidia modules embed __FILE__ paths into kernelNd's illumos source
  # (908 MB); they are rewritten like stripSliceRefs so that tree stays out of
  # the closure.
  mkGpuKernel = base: { nvidia ? false, gspFirmware ? null, i915Firmware ? null }: derivation {
    name = "illumos-kernel-gpu";
    system = "x86_64-solaris";
    builder = "/usr/bin/bash";
    PATH = "/usr/bin:/usr/sbin";
    inherit base;
    i915 = i915-driver;
    nv = if nvidia then nvidia-oss-modules else "";
    gsp = if gspFirmware == null then "" else gspFirmware;
    ifw = if i915Firmware == null then "" else i915Firmware;
    strip = [ base slices.kernel kernelNd.src ];
    disallowedReferences = [ base slices.kernel kernelNd.src kernelNd i915-driver ]
      ++ (if nvidia then [ nvidia-oss-modules ] else [ ]);
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"
      ( cd "$base" && tar cf - . ) | ( cd "$out" && tar xf - )
      for d in "$out" "$out/kernel" "$out/kernel/drv" "$out/kernel/drv/amd64" "$out/kernel/firmware"; do
        [ -d "$d" ] && [ ! -h "$d" ] && chmod u+w "$d" 2>/dev/null || true
      done
      mkdir -p "$out/kernel/drv/amd64"
      mods=i915
      cp "$i915/kernel/drv/amd64/i915" "$out/kernel/drv/amd64/i915"
      if [ -n "$nv" ]; then
        mods="$mods nvidia nvidia_modeset nvidia_i2c"
        for m in nvidia nvidia_modeset nvidia_i2c; do cp "$nv/kernel/drv/amd64/$m" "$out/kernel/drv/amd64/$m"; done
      fi
      if [ -n "$gsp" ]; then
        mkdir -p "$out/kernel/firmware"
        cp -R "$gsp/kernel/firmware/nvidia" "$out/kernel/firmware/"
      fi
      if [ -n "$ifw" ]; then
        mkdir -p "$out/kernel/firmware/drm"
        cp -R "$ifw/kernel/firmware/drm/i915" "$out/kernel/firmware/drm/"
      fi
      ${stripSliceRefs}
      for m in $mods; do
        chmod 0555 "$out/kernel/drv/amd64/$m"
        [ ! -e "$out/kernel/drv/$m.conf" ] || { echo "FATAL: $m.conf in the tree would attach $m at boot" >&2; exit 1; }
      done
      [ -e "$out/platform/i86pc/kernel/amd64/unix" ] || { echo "FATAL: base kernel clobbered" >&2; exit 1; }
      echo "gpu kernel: $mods''${gsp:+ + GSP firmware}''${ifw:+ + i915 firmware}" >&2
    '' ];
  };

  # worldMan: the gate's base man pages as a doc-only store path (the illumos
  # analog of NixOS delivering man pages through a profile package rather than
  # the kernel/libc closure). mk-proto-world EXCLUDES usr/share/man to keep the
  # runtime closure lean, so the base pages (ls(1), zfs(1M), ...) are not in the
  # installed BE. This slice carries them under $out/share/man so the existing
  # MANPATH=.../sw/share/man finds them once a config adds it to the system
  # profile (modules/config/documentation.nix). It also keeps the gate's
  # etc/man.conf. Copies files OUT of the gate (like `stock`), so it carries NO
  # reference back to the gate -> the toplevel's build-only-closure check still
  # passes. No ELF here, so no RUNPATH/relocation pass is needed.
  worldMan = derivation {
    name = "illumos-world-man"; system = "x86_64-solaris"; gate = gate';
    builder = "/usr/bin/bash";
    args = [ "-c" ''
      set -eu
      /usr/bin/mkdir -p "$out/share/man" "$out/etc"
      if [ -d "$gate/usr/share/man" ]; then
        ( cd "$gate/usr/share/man" && /usr/bin/tar cf - . ) \
          | ( cd "$out/share/man" && /usr/bin/tar xf - )
      fi
      [ -e "$gate/etc/man.conf" ] && /usr/bin/cp "$gate/etc/man.conf" "$out/etc/man.conf" || true
      # a real count so a zero (empty gate man tree) is visible, not silent.
      n=$(/usr/bin/find "$out/share/man" -type f 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
      printf '%s\n' "$n" > "$out/.manifest-man"
      echo "world-man: $n base man files" >&2
    '' ];
  };

  # nix (pkgs.solnix.nix) — the classic Nix 2.3.16 the host runs, ingested so it
  # ships on the image (design §C). First cut = host /nix-tools ingest; see the
  # TODO in ./nix.nix for the proper mk-illumos-component slice.
  nix = import ./nix.nix { };

  # nix224 is retired: it was a fetchClosure of a cache path nobody can rebuild
  # bit-for-bit, and the infra team hid it in the 10-05 cache retirement. The
  # shipped Nix is nixSrc (./nix-src.nix, nix.package's default).

  # cached (pkgs.solnix.cached.<pname>) — every wave-built package in the cache
  # (docs/registry/arch-manifest.tsv), exposed as a store-path attr so a config
  # can list `with pkgs.solnix.cached; [ vim curl ... ]` and have each substitute
  # from cache.solnix.io at realise time. See ./cached.nix for the CAVEATS
  # (best-effort pname keying, last-wins on duplicate versions, eval forces a
  # substituter check for absent paths).
  cached = import ./cached.nix { system = "x86_64-solaris"; };

  # starter (pkgs.solnix.starter.<pname>) — the FIRST declarative image's
  # starter set, keyed off docs/registry/real-derivations.tsv (the proven,
  # published, closure-complete real-derivation packages). See ./starter.nix.
  starter = import ./starter.nix { system = "x86_64-solaris"; };
in
{
  inherit libc rtld ld sys base-tools systemPath nix cached starter gcc world early stock drivers kernelNd worldMan;
  inherit gcc15 gcc15Wrapper;
  inherit rustSeedStage rust198 rust1990 rust199;
  # seedBuildTools -- the default build-tool set a bare solnix system passes as
  # buildTools so from-source builds resolve gmake/tar/grep/sed/gstrip/gzip/xz
  # from the store (not /usr/gnu). host-pkgs.nix wires it as the default for a
  # system eval; the gate/bhost build keeps buildTools=[] (byte-identical).
  inherit seedBuildTools;
  # the cargo/bsdfetch/COSMIC-data builders' store tool set, a build input of their served rows: exposed so a builder
  # without it can fetch it (recipes.tsv row) instead of declining those rows.
  solnix-hostfix-tools = hostfixTools;
  # iwm wifi: the driver module + wpa-pmk (iwm-driver), and the augmentation
  # helpers wireless-iwx.nix uses to render an iwm-aware driver DB and kernel
  # tree when hardware.wirelessIwm.attachAtBoot. mkIwmKernel/iwmFirmware take
  # the unfree opt-in so the blob stays out of any non-opted closure.
  inherit iwm-driver mkIwmDriversDb mkIwmDriversDbUnbound mkIwmKernel iwmFirmware wpa-pmk solnix-cputemp;
  # Intel Bluetooth firmware (phase 0, docs/design-bluetooth.md) and the userland tools.
  inherit ibtFirmware;
  inherit (bluetooth) btintelfw hcitest;
  # iwx wifi (AX2xx): module only; mkIwxDriversDb/mkIwxKernel below.
  inherit iwx-driver iwxFirmware iwxAliases mkIwxDriversDb mkIwxKernel;
  inherit nvidia-oss-modules nvidiaGspFirmware i915Firmware nvidia-probe nvidiaAliases dgputemp mkNvidiaBootDb mkNvidiaBootKernel;
  # Intel iGPU (i915) and the GPU driver-DB/kernel helpers (modules/config/graphics-gpu.nix).
  inherit i915-driver i915Aliases mkDriversDbWith mkGpuKernel;
  # X1E touchpad (dwiic + ihid) and its driver-DB/kernel helpers (modules/config/touchpad-i2c-hid.nix).
  inherit touchpad-driver touchpadAliases mkTouchpadDriversDb mkTouchpadKernel;

  inherit (srcPkgs) zlib libxml2 openssl openssh bash nspr nss git libcExtra binutils gnumake gccWrapper vi pkgconf;
  inherit (srcPkgs) ncurses less htop top libevent tmux coreutils gnugrep gnused gnutar findutils diffutils jq gettext home-manager xorgproto lndir hostname libiconv;
  inherit (srcPkgs) gzip nano rsync smartmontools tree db1 nvi;
  wget = srcPkgs.wgetWith cli.perl;   # pod2man from the store perl (a solnix host has no /usr/bin/pod2man)
  inherit (graphics) meson samurai expat libffi wayland wayland-protocols libdrm mesa
    pixman xkeyboard-config libxkbcommon libdisplay-info seatd dbus;
  inherit (cosmic) cosmic-comp cosmic-term cosmic-session cosmic-panel cosmic-applets cosmic-launcher
    cosmic-app-library cosmic-notifications cosmic-osd cosmic-settings-daemon cosmic-bg cosmic-workspaces cosmic-randr cosmic-idle
    cosmic-settings cosmic-files cosmic-edit cosmic-store cosmic-screenshot cosmic-greeter greetd;
  inherit (cosmicData) open-sans noto-sans noto-sans-mono fira-mono hicolor-icon-theme pop-icon-theme cosmic-icons;
  inherit (desktop) pop-launcher cosmic-wallpapers sound-theme-freedesktop adwaita-icon-theme dejavu-fonts liberation-fonts
    noto-fonts-color-emoji xdg-utils xdg-user-dirs solnix-help;
  inherit llvmPackages;
  inherit (llvmPackages) llvm lld lldb;
  clang-unwrapped = llvmPackages.clang;   # nixpkgs' names: clang is the wrapped compiler
  clang_23 = llvmPackages.clang-wrapper;
  inherit (gtk) pcre2 glib libpng libjpeg-turbo freetype fontconfig fribidi harfbuzz cairo pango gdk-pixbuf libepoxy
    at-spi2-core gtk3 grim gperf nasm ninja meson_1_10 nodejs cbindgen llvm-clang firefox-esr;
  # cargoLib.{vendorOf,cargoPkg}: build any Cargo.lock'd crate on rust199 (./cargo.nix).
  cargoLib = cargo;
  inherit (goChain) go go_1_4 go_1_17 go_1_20 go_1_22 go_1_24 go_1_26 go_1_27;
  inherit bsdfetch;
  inherit (torrent) libtorrent-rasterbar solnix-torrent;
  xz = srcPkgs.nixChain.xz;
  # A C/C++ toolchain to put on PATH (nix-shell / nix profile install), the
  # solnix analog of nixpkgs' stdenv.cc: the wrapped gcc, gas, GNU make. The
  # link-editor (ld) and ar/nm/strip are the gate's, in every system profile;
  # headers, crt objects and libc come from the gcc's sysroot, the gate proto.
  # Not in any system's packages: NixOS does not ship a compiler in its base.
  solnix-dev = buildEnv {
    name = "solnix-dev";
    paths = [ srcPkgs.gccWrapper srcPkgs.binutils srcPkgs.gnumake ];
    pathsToLink = [ "/bin" "/share/man" ];
  };

  # solnix-dev-full -- the "build host in the image" profile: the solnix-dev C/C++
  # toolchain PLUS pkg-config, so an installed/booted solnix system can rebuild
  # autotools/meson/cargo packages (the maintainer directive: ship enough on the
  # image to rebuild everything). gcc + gas + GNU make come from solnix-dev;
  # pkgconf adds pkg-config (library-flag resolution).
  #
  # DELIBERATELY NOT INCLUDED (see docs/devtools-in-closure.md for why + how to add):
  #   * autoconf/automake/libtool -- perl programs, and solnix has no from-source
  #     perl yet (an installed solnix has no /usr/bin/perl; base-src.nix has no
  #     perl package). A separate work item (perl + m4 from source). Most release
  #     tarballs ship a pre-generated ./configure, so gcc + make + pkg-config
  #     already build the common autotools-packaged source without them.
  #   * Rust (cargo/rustc) -- the seed wrapper 8daydac...-rust-illumos-1.97.1
  #     execs the re-pinned seed c821qgb6...-rust-seed-stage (re-extracted from
  #     OI rustc@1.97.1 by a REPRODUCIBLE staging script, 2026-10-11; rustc
  #     1.97.1 + cargo build a native illumos ELF). Re-published store-correct
  #     via the signed submit (recipes.tsv rust-seed-stage + rust-illumos-1.97.1
  #     rows). From-source Rust still needs a bootstrap rustc that does not exist
  #     on illumos outside this seed -- a separate item.
  solnix-dev-full = buildEnv {
    name = "solnix-dev-full";
    paths = [ srcPkgs.gccWrapper srcPkgs.binutils srcPkgs.gnumake srcPkgs.pkgconf ];
    pathsToLink = [ "/bin" "/share/man" ];
  };
  curl = srcPkgs.nixChain.curl;
  # nix 2.24.15 and its dependency chain, from source (./nix-src.nix).
  nixChain = srcPkgs.nixChain;
  nixSrc = srcPkgs.nixChain.nix;
  gate = gate';
  inherit (toolchains) gcc14 clang;   # gdb: from source, cli/c-dev.nix (reaches here through // cli)
  # the CORE-OS slices, each with a computed DT_NEEDED closure (./slices.nix).
  inherit slices;
  inherit (slices) core-utils oamuser halt smf zfs kernel;
} // cli
