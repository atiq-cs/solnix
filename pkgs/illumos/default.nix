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

let
  # GATE A: the gate proto as a store path (ingest variant; full build FOD later).
  gate = import ./gate.nix { };

  # buildEnv — the symlink-farm merge, factored out of `systemPath` (below) into
  # lib/build-env.nix so the declarative userland (modules/config/system-path.nix)
  # composes its profile the same way. systemPath now CALLS it (design §B).
  buildEnv = import ../../lib/build-env.nix { };

  mkIllumosComponent = args: import ./mk-illumos-component.nix ({ gate = gate; } // args);

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

  # externalLibs — the non-proto third-party libs the SMF stack NEEDs but the
  # gate proto does NOT ship: libxml2, zlib, ICU (uc+data), and the gcc C++/unwind
  # runtime (libstdc++, libgcc_s). Sliced from the HOST's IPS/gcc install (see
  # provenance below) since sandbox=false permits host-impure inputs for Phase 1.
  #
  # WHY these six, and ONLY these six: svc.startd/svcs/svccfg/svc.configd reach
  # libxml2 (via libzonecfg/libtopo/libpool/libbrand); libxml2 NEEDs libz +
  # libicuuc; libicuuc NEEDs libicudata + libstdc++ + libgcc_s; libstdc++ NEEDs
  # libgcc_s. Every OTHER NEEDED of these six (libm, libc, libpthread) comes from
  # the libc slice. So the closure is exactly closed at these six + libc. Verified
  # on the host with elfdump -d (32-bit variants), gate ac45d71fc2.
  #
  # ABI: sliced BOTH classes (lib = 32-bit for the 32-bit SMF stack, lib/amd64 =
  # 64-bit for future 64-bit consumers). Like libc, the loader picks the matching
  # class, so carrying both is safe. Siblings resolve via $ORIGIN (they all live
  # in one lib dir per ABI); libm/libc/libpthread come cross-component from the
  # libc slice via depRunpaths. The host RUNPATH leak (/usr/gcc/14/lib) baked into
  # these libs is SCRUBBED by elfedit dyn:runpath (overwrites DT_RUNPATH+DT_RPATH).
  #
  # PROVENANCE (design risk #3 — TODO(P2): build from source or slice from a
  # pinned IPS pkg / gate, not the host copies):
  #   libxml2.so.16   IPS  library/libxml2      (/usr/lib[/amd64]/libxml2.so.16)
  #   libz.so.1       IPS  library/zlib         (/usr/lib[/amd64]/libz.so.1)
  #   libicuuc.so.78  IPS  library/icu-78       (/usr/lib[/amd64]/libicuuc.so.78)
  #   libicudata.so.78 IPS library/icu-78       (/usr/lib[/amd64]/libicudata.so.78)
  #   libstdc++.so.6  gcc-14 runtime            (/usr/gcc/14/lib[/amd64]/libstdc++.so.6)
  #   libgcc_s.so.1   gcc-14 runtime            (/usr/gcc/14/lib[/amd64]/libgcc_s.so.1)
  # gcc-14 chosen because the host libxml2/icu were built against it (their
  # RUNPATH is /usr/gcc/14/lib); a mismatched gcc runtime risks a missing symbol.
  #
  # NOTE: mkIllumosComponent copies from $gate/<path>. These libs are NOT in the
  # gate proto, so externalLibs uses `extraFiles` (a src->dst remap with cp -aL)
  # to copy the real objects from their host absolute paths under the SONAME name.
  externalLibs = mkIllumosComponent {
    name = "external-libs";
    files = [ ]; # everything is a symlink on the host; deref via extraFiles below
    # extraFiles does `cp -aL`, dereferencing the host's versioned symlinks
    # (libxml2.so.16 -> libxml2.so.16.1.3) so the in-store file IS the SONAME the
    # loader looks up, with real content — not a dangling link to a version we
    # didn't copy. `files` (plain cp -a) would preserve the symlink and break.
    extraFiles = [
      # --- 32-bit (the SMF stack is 32-bit) ---
      { src = "/usr/lib/libxml2.so.16";              dst = "usr/lib/libxml2.so.16"; }
      { src = "/usr/lib/libz.so.1";                  dst = "usr/lib/libz.so.1"; }
      { src = "/usr/lib/libicuuc.so.78";             dst = "usr/lib/libicuuc.so.78"; }
      { src = "/usr/lib/libicudata.so.78";           dst = "usr/lib/libicudata.so.78"; }
      { src = "/usr/gcc/14/lib/libstdc++.so.6";      dst = "usr/lib/libstdc++.so.6"; }
      { src = "/usr/gcc/14/lib/libgcc_s.so.1";       dst = "usr/lib/libgcc_s.so.1"; }
      # --- 64-bit (future 64-bit consumers) ---
      { src = "/usr/lib/amd64/libxml2.so.16";        dst = "usr/lib/amd64/libxml2.so.16"; }
      { src = "/usr/lib/amd64/libz.so.1";            dst = "usr/lib/amd64/libz.so.1"; }
      { src = "/usr/lib/amd64/libicuuc.so.78";       dst = "usr/lib/amd64/libicuuc.so.78"; }
      { src = "/usr/lib/amd64/libicudata.so.78";     dst = "usr/lib/amd64/libicudata.so.78"; }
      { src = "/usr/gcc/14/lib/amd64/libstdc++.so.6"; dst = "usr/lib/amd64/libstdc++.so.6"; }
      { src = "/usr/gcc/14/lib/amd64/libgcc_s.so.1";  dst = "usr/lib/amd64/libgcc_s.so.1"; }
    ];
    # $ORIGIN reaches siblings in the same dir; but a 32-bit lib in usr/lib and a
    # 64-bit lib in usr/lib/amd64 don't see each other via one $ORIGIN rule, and
    # mkIllumosComponent's default $ORIGIN parts assume lib/amd64. Bake both
    # dirs as $out-absolute so every intra-slice ref resolves regardless of ABI.
    selfLibDirs = [ "usr/lib" "usr/lib/amd64" ];
    depRunpaths = libcLibDirs; # libm/libc/libpthread from the libc slice
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
    depRunpaths = [ "${libc}/lib" ] ++ [ "${externalLibs}/usr/lib" ];
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
    paths = [ sys rtld libc ld base-tools externalLibs ];
    pathsToLink = null;      # link everything (kernel/platform/lib/usr/...).
    ignoreCollisions = true; # slices are disjoint by design; last wins on clash.
  };

  # Modern compiler toolchains (backlog PS-1 clang / PS-4 latest-GCC/GDB, pulled
  # forward): gcc14 + clang + gdb sliced from the OI host IPS install and RUNPATH-
  # relocated into the store, the foundation the package-batch work builds on.
  # See ./toolchains.nix + docs/design-toolchains.md.
  toolchains = import ./toolchains.nix { inherit mkIllumosComponent libc; };

  # nix (pkgs.solnix.nix) — the classic Nix 2.3.16 the host runs, ingested so it
  # ships on the image (design §C). First cut = host /nix-tools ingest; see the
  # TODO in ./nix.nix for the proper mk-illumos-component slice.
  nix = import ./nix.nix { };

  # nix224 (pkgs.solnix.nix224) — the store-path Nix 2.24.15, RUNPATH-correct
  # (runs with no LD_LIBRARY_PATH), ships on PATH via the system profile the
  # NixOS way. This is the shipped nix (nix.package default), replacing the
  # /nix-tools224 bootstrap that must never appear on a shipped image PATH.
  # Substitutable from cache.solnix.io (5HAV-signed, durable).
  nix224 = builtins.storePath /nix/store/jxn55a9725j8ba9hkqila89s66abszhr-nix-2.24.15;

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
  inherit gate libc rtld ld sys base-tools systemPath externalLibs nix nix224 cached starter;
  inherit (toolchains) gcc14 clang gdb;
}
