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
  srcPkgs = import ./base-src.nix { gate = gate'; libcSlice = libc; inherit world gcc; };

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
  inherit libc rtld ld sys base-tools systemPath nix nix224 cached starter gcc world early stock drivers kernelNd;
  inherit (srcPkgs) zlib libxml2 openssl openssh bash nspr nss git libcExtra binutils gnumake gccWrapper vi;
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
