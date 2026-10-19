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
}:

let
  # GATE A: the gate proto as a store path. Injected if given, else built from
  # gateArgs (which must carry srcDir or srcHash -- see the note above).
  gate' = if gate != null then gate else import ./gate.nix gateArgs;

  # buildEnv — the symlink-farm merge, factored out of `systemPath` (below) into
  # lib/build-env.nix so the declarative userland (modules/config/system-path.nix)
  # composes its profile the same way. systemPath now CALLS it (design §B).
  buildEnv = import ../../lib/build-env.nix { };

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
  # forward): gcc14 + clang + gdb sliced from the OI host IPS install and RUNPATH-
  # relocated into the store, the foundation the package-batch work builds on.
  # See ./toolchains.nix + docs/design-toolchains.md.
  toolchains = import ./toolchains.nix { inherit mkIllumosComponent libc; };

  # gcc built FROM SOURCE (./gcc-src.nix): the NixOS bootstrap step. The host's
  # IPS gcc-14 is only the stage0 seed that compiles it; gcc.lib (libstdc++,
  # libgcc_s) is the C++/unwind runtime every shipped C++ binary links.
  gcc = import ./gcc-src.nix { gate = gate'; libcSlice = libc; };

  # From-source packages the gate does not provide (./base-src.nix). zlib and
  # libxml2 replace the host-copied externalLibs; world is built on top of them.
  srcPkgs = import ./base-src.nix { gate = gate'; libcSlice = libc; inherit world gcc buildTools; };

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

  seedBuildTools = buildEnv {
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
  # the shell inittab uses, zfs to mount /nix). Lives as real files at these
  # store paths inside each generation's BE (docs/design-nix-managed-base.md).
  early = import ./mk-proto-slice.nix {
    gate = gate'; name = "illumos-early";
    deps = [ libc rtld srcPkgs.zlib srcPkgs.libxml2 ];
    bins = [ "sbin/init" "sbin/sh" "sbin/zfs" "sbin/mount" ];
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
  iwm-driver = import ./iwm-driver.nix {
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
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"
      # copy the base kernel slice, then overlay iwm's module + firmware.
      ( cd "$base" && tar cf - . ) | ( cd "$out" && tar xf - )
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

  # nix224 (pkgs.solnix.nix224) — the store-path Nix 2.24.15, RUNPATH-correct
  # (runs with no LD_LIBRARY_PATH), ships on PATH via the system profile the
  # NixOS way. This is the shipped nix (nix.package default), replacing the
  # /nix-tools224 bootstrap that must never appear on a shipped image PATH.
  # Substitutable from cache.solnix.io (5HAV-signed, durable).
  #
  # fetchClosure, not storePath: builtins.storePath is forbidden in pure eval
  # (nix eval .#), which blocked every toplevel via nix.package's default. Same
  # rewrite as starter.nix — name the substituter + path and pull at eval time;
  # inputAddressed = true because this path is input-addressed, so signature
  # trust (cache.solnix.io-1:5HAV..., in base.nix) does the integrity work.
  nix224 = builtins.fetchClosure {
    fromStore = "https://cache.solnix.io";
    fromPath = "/nix/store/w44py7y17i7z5c9mwhh62q5yzx681y1a-nix-2.24.15";
    inputAddressed = true;
  };

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
  inherit libc rtld ld sys base-tools systemPath nix nix224 cached starter gcc world early stock drivers kernelNd worldMan;
  # seedBuildTools -- the default build-tool set a bare solnix system passes as
  # buildTools so from-source builds resolve gmake/tar/grep/sed/gstrip/gzip/xz
  # from the store (not /usr/gnu). host-pkgs.nix wires it as the default for a
  # system eval; the gate/bhost build keeps buildTools=[] (byte-identical).
  inherit seedBuildTools;
  # iwm wifi: the driver module + wpa-pmk (iwm-driver), and the augmentation
  # helpers wireless-iwx.nix uses to render an iwm-aware driver DB and kernel
  # tree when hardware.wirelessIwm.attachAtBoot. mkIwmKernel/iwmFirmware take
  # the unfree opt-in so the blob stays out of any non-opted closure.
  inherit iwm-driver mkIwmDriversDb mkIwmKernel iwmFirmware wpa-pmk;
  inherit nvidia-oss-modules nvidiaGspFirmware;

  inherit (srcPkgs) zlib libxml2 openssl openssh bash nspr nss git libcExtra binutils gnumake gccWrapper vi pkgconf;
  inherit (srcPkgs) ncurses less htop top libevent tmux coreutils gnugrep gnused gnutar findutils diffutils jq gettext home-manager xorgproto lndir hostname libiconv;
  inherit (srcPkgs) gzip nano rsync smartmontools tree wget;
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
  inherit (toolchains) gcc14 clang gdb;
  # the CORE-OS slices, each with a computed DT_NEEDED closure (./slices.nix).
  inherit slices;
  inherit (slices) core-utils oamuser halt smf zfs kernel;
}
