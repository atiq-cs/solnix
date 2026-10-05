# pkgs/illumos/slices.nix -- the illumos CORE-OS component slices, carved out of
# the built gate proto with a COMPUTED library closure (mk-proto-slice.nix).
#
# WHAT THIS UNBLOCKS: docs/image-nixification-gap.md measured that a solnix toplevel
# cannot contain a usable system because `df`, `useradd`, `passwd`, `reboot`/`halt`/
# `poweroff`, `zpool`/`zfs`, `svcadm`/`svccfg` and the kernel are illumos CORE-OS,
# shipped in the gate rather than as separable upstream packages, and therefore were
# not derivations. Each of them is a derivation here.
#
# ⚠️ WHAT IS AND IS NOT HAND-WRITTEN, because this is the whole point:
#   HAND-WRITTEN: the BINARIES each slice is FOR. That is a statement of intent
#     ("this slice provides useradd") and belongs in Nix.
#   COMPUTED: every shared library. mk-proto-slice walks DT_NEEDED transitively in
#     the builder with elfdump, ABI-aware, and FAILS the build on any soname that
#     resolves nowhere. No `baseToolLibs`-style pasted list exists here.
#   The distinction matters because every image failure this campaign was a missing
#   LIBRARY, never a missing intent: vi without libmapmalloc.so.1, openssl through a
#   second-order dangling symlink. Libraries are what humans forget.
#
# THE GROUPING WAS MEASURED, NOT ASSUMED. The task suggested one slice per
# functional area with an `illumos-libs` slice underneath. What the DT_NEEDED graph
# actually shows (see docs/proto-slice-findings.md for the numbers) is that illumos's
# core userland is densely connected -- libc/libnvpair/libuutil/libscf are needed by
# nearly everything -- so a separate libs slice per functional area would duplicate
# most of the graph N times. The shape below is therefore:
#
#   libc          <- the C runtime + rtld, shared by everything (already exists in
#                    pkgs/illumos/default.nix; reused, not re-cut)
#   core-utils    -- df, ls, cat, cp, ... (the coreutils-equivalent set)
#   oamuser       -- useradd, usermod, groupadd, passwd, pwconv
#   halt          -- ONE inode, THREE names (halt/reboot/poweroff)
#   smf           -- svcadm, svccfg, svcs, svc.startd, svc.configd + the manifests
#   zfs           -- zpool, zfs + libzfs/libzpool/libzfs_core/libzutil
#   kernel        -- unix, genunix, the driver trees (NOT userland ELF: no DT_NEEDED,
#                    so nothing to compute; copied verbatim via extraPaths)
#
# Each non-kernel slice declares `deps = [ libcSlice ]` so libc is resolved from ONE
# store path rather than copied into each. That is what keeps the sum of the slices
# near the size of the union instead of N times it.

{ gate
, libcSlice        # the existing pkgs.illumos.libc slice (C runtime, both ABIs)
, rtldSlice        # the existing pkgs.illumos.rtld slice (ld.so.1 + its libs)
, externalLibs     # non-proto libs (libxml2/libz/ICU/libstdc++) for the SMF stack
}:

let
  mkSlice = args: import ./mk-proto-slice.nix ({ inherit gate; } // args);

  # ⚠⚠ THE GATE PROTO IS NOT SELF-CONTAINED. MEASURED, not assumed:
  # scripts/proto-external-audit.sh walked every userland ELF in the proto and found
  # that 52 of the 260 distinct sonames the proto's own binaries and libraries
  # DT_NEEDED resolve NOWHERE inside the proto. By direct-reference count:
  #     36 libdbus-1.so.3      29 libxml2.so.16     22 libglib-2.0.so.0
  #     12 libz.so.1           10 libstdc++.so.6    10 libgcc_s.so.1
  #      9 libdbus-glib-1.so.2  6 libcrypto.so.1.0.0  5 libnetsnmp.so.40
  # illumos-gate does not vendor these; IPS satisfies them from separate packages at
  # install time, which is exactly the "pkg papers over it" the task warned about.
  #
  # The ones below are the subset the CORE slices actually reach. They are declared
  # here, ONCE, with the reason -- rather than per-slice where the pattern would be
  # invisible. Declaring is not the same as satisfying: a slice with a declared
  # external edge is HONEST but its affected binaries will not exec until the library
  # is a derivation. Which binaries those are is recorded per slice below.
  #
  # ⚠️ libxml2.so.16 IS CURRENTLY UNSATISFIABLE and that is a genuine prerequisite
  # this project does not yet have:
  #   - the build AMI ships libxml2.so.2 (library/libxml2 2.13.9) and `pkg install
  #     library/libxml2@2.15.4` is REJECTED by userland-incorporation
  #     0.5.11-2025.0.0.31598 (same mechanism as the gate prereqs in
  #     docs/gate-fod-findings.md §5.3)
  #   - the published solnix cache (docs/registry/arch-manifest.tsv) has libxml2
  #     2.9.14 and 2.12.9 for x86_64-solaris -- both soname .so.2. soname 16 first
  #     appears in libxml2 2.14.
  # So `libxml2 >= 2.14 as a real derivation` is a hard prerequisite for a fully
  # self-resolving core userland. See docs/proto-slice-findings.md.
  # ⚠️ THE EXTERNAL EDGE IS WIDER THAN libxml2, and there are TWO independent stacks.
  # Measured with scripts/whyneeded.sh, which prints the actual DT_NEEDED chain rather
  # than a guess:
  #
  #   STACK 1 -- libpool/libxml2, reached through libproject or libdladm:
  #     usr/bin/id       -> libproject.so.1 -> libpool.so.1 -> libxml2.so.16
  #     usr/bin/ps       -> libproject.so.1 -> libpool.so.1 -> libxml2.so.16
  #     sbin/ifconfig    -> libdladm.so.1   -> libpool.so.1 -> libxml2.so.16
  #     usr/sbin/useradd -> libproject.so.1 -> libpool.so.1 -> libxml2.so.16
  #     usr/sbin/usermod -> libproject.so.1 -> libpool.so.1 -> libxml2.so.16
  #     usr/sbin/halt    -> libbe.so.1 -> libinstzones.so.1 -> libzonecfg.so.1 -> libxml2.so.16
  #     usr/sbin/svccfg  -> libxml2.so.16 DIRECTLY
  #
  #   STACK 2 -- NSS/NSPR, reached through the name-service switch:
  #     usr/bin/passwd -> passwdutil.so.1 -> libsldap.so.1 -> libldap.so.5 -> libnss3.so
  #     (and libnspr4.so, libplc4.so, libssl3.so alongside it)
  #
  # ⚠️ I INITIALLY DECLARED oamuser AND halt CLOSURE-COMPLETE and was WRONG on both.
  # The closure gate refused to build them, which is precisely what it is for -- the
  # comment claiming "measured: clean" was reasoning, not measurement. Recording that
  # here because the same mistake is easy to repeat on the next slice.
  protoExternalSonames = [
    # stack 1: libpool's XML dependency, plus what libxml2 itself needs
    "libxml2.so.16"
    "libz.so.1" "libstdc++.so.6" "libgcc_s.so.1"
    "libicuuc.so.78" "libicudata.so.78"
  ];

  # stack 2, kept separate so a slice declares only the stack it actually touches --
  # lumping them would hide which slices need LDAP/NSS and which need XML.
  nssSonames = [ "libnss3.so" "libnspr4.so" "libplc4.so" "libssl3.so" "libsmime3.so" ];

  # Every userland slice sits on libc + rtld. Passing them as `deps` means:
  #   (a) their sonames are NOT re-copied into this slice, and
  #   (b) their store lib dirs land in this slice's RUNPATH,
  # so one libc serves all of them. Without this each slice would carry its own
  # 2 MB libc.so.1 and the loader could end up with two in one process image.
  baseDeps = [ libcSlice rtldSlice ];
in
rec {
  # ---------------------------------------------------------------- core-utils
  # The coreutils-equivalent set, INCLUDING df -- which is the single tool that
  # made this whole slicing exercise necessary (`solnix-install` runs `df -n /`,
  # and in image l2 /usr/bin/df was a dangling symlink to ../sbin/df whose target
  # was never staged).
  #
  # ⚠️ /usr/bin/df IS A SYMLINK in the proto (-> ../sbin/df). mk-proto-slice copies
  # `bins` with cp -aL, so the store gets the REAL binary under the name asked for;
  # the dangling-link class is structurally impossible here.
  core-utils = mkSlice {
    name = "illumos-core-utils";
    deps = baseDeps;
    # ⚠️ WHICH BINARIES CARRY THE EXTERNAL EDGE, measured with whyneeded.sh:
    #   usr/bin/id  -> libproject.so.1 -> libpool.so.1 -> libxml2.so.16
    #   usr/bin/ps  -> libproject.so.1 -> libpool.so.1 -> libxml2.so.16
    #   sbin/ifconfig -> libdladm.so.1 -> libpool.so.1 -> libxml2.so.16
    # Every OTHER binary in this slice resolves entirely inside the proto + libc.
    # df, ls, cat, cp, mv, rm, sed, grep, ksh93, sh, tar, cpio: all clean.
    allowUnresolved = protoExternalSonames;
    bins = [
      # the one this exists for
      "usr/sbin/df"
      "usr/bin/df"
      # file and directory manipulation
      "usr/bin/ls" "usr/bin/cat" "usr/bin/cp" "usr/bin/mv" "usr/bin/rm"
      "usr/bin/ln" "usr/bin/mkdir" "usr/bin/rmdir" "usr/bin/touch"
      "usr/bin/chmod" "usr/bin/chown" "usr/bin/chgrp" "usr/bin/du"
      "usr/bin/mktemp" "usr/bin/dd" "usr/bin/pwd" "usr/bin/basename"
      "usr/bin/dirname" "usr/bin/sync" "usr/bin/file"
      # text
      "usr/bin/sed" "usr/bin/grep" "usr/bin/egrep" "usr/bin/fgrep"
      "usr/bin/head" "usr/bin/tail" "usr/bin/sort" "usr/bin/tr" "usr/bin/cut"
      "usr/bin/wc" "usr/bin/nawk" "usr/bin/awk" "usr/bin/echo" "usr/bin/printf"
      "usr/bin/expr" "usr/bin/tee" "usr/bin/find" "usr/bin/strings"
      # process / system
      "usr/bin/id" "usr/bin/date" "usr/bin/uname" "usr/bin/hostname"
      "usr/bin/sleep" "usr/bin/kill" "usr/bin/ps" "usr/bin/env" "usr/bin/true"
      "usr/bin/false" "usr/bin/test" "usr/bin/yes"
      # archives (cpio is what the current installer uses)
      "usr/bin/tar" "usr/bin/cpio"
      # mount/umount: the proto has these under sbin + usr/sbin ONLY -- there is no
      # usr/bin/mount (measured with proto-probe.sh; my first guess had one and the
      # slice build FAILED on it, which is the FATAL doing its job). The fs-specific
      # helpers under etc/fs/<fstype>/ are what mount(1M) execs for a real mount, and
      # they are separate ELF binaries -- so they are `bins` too, not data.
      "usr/sbin/mount" "usr/sbin/umount" "sbin/mount" "sbin/umount"
      "etc/fs/zfs/mount" "etc/fs/zfs/umount" "etc/fs/ufs/mount" "etc/fs/hsfs/mount"
      "etc/fs/dev/mount"
      # ⚠️ NO bash. bash is NOT in the gate proto at all (measured: `find -name bash`
      # returns nothing) -- it is an OpenIndiana PACKAGE, not illumos core-OS. This is
      # a real finding, not an omission: the core shells are sbin/sh and ksh93, and
      # anything wanting bash must get it from a nixpkgs derivation, not from a slice.
      "sbin/sh" "usr/bin/sh" "usr/bin/ksh93"
      # networking basics the installer needs
      "sbin/ifconfig" "sbin/uname"
    ];
  };

  # ------------------------------------------------------------------- oamuser
  # useradd/usermod/userdel/groupadd/passwd/pwconv -- usr/src/cmd/oamuser plus
  # cmd/passmgmt and cmd/passwd. `passwd` is setuid root in the proto; cp -aL
  # preserves the mode bits, and the store makes the file read-only, which is the
  # normal NixOS shape (activation is what installs a setuid wrapper if wanted).
  oamuser = mkSlice {
    name = "illumos-oamuser";
    deps = baseDeps;
    # ⚠️ BOTH external stacks are present here, and this slice is the reason to keep
    # them named separately: useradd/usermod carry the libpool->libxml2 edge, while
    # passwd carries the NSS/LDAP one. userdel, groupadd/groupmod/groupdel, pwconv,
    # passmgmt and the role* tools are clean.
    allowUnresolved = protoExternalSonames ++ nssSonames;
    bins = [
      "usr/sbin/useradd" "usr/sbin/usermod" "usr/sbin/userdel"
      "usr/sbin/groupadd" "usr/sbin/groupmod" "usr/sbin/groupdel"
      "usr/bin/passwd" "usr/sbin/pwconv"
      # ⚠️ passmgmt is at usr/lib/passmgmt in the proto, NOT usr/sbin/passmgmt
      # (measured; the usr/sbin guess failed the slice build). useradd execs it.
      "usr/lib/passmgmt"
      # roles are the illumos analog of the wheel group; dixi.nix uses RBAC
      "usr/sbin/roleadd" "usr/sbin/rolemod" "usr/sbin/roledel"
    ];
  };

  # ---------------------------------------------------------------------- halt
  # ONE BINARY, THREE NAMES. usr/src/cmd/halt/Makefile declares
  #   ROOTLINKS = $(ROOTUSRSBIN)/poweroff $(ROOTUSRSBIN)/reboot
  # and halt.c dispatches on argv[0]. So halt, reboot and poweroff must share an
  # inode -- and mk-proto-slice ASSERTS they do (ls -i comparison; a build that
  # accidentally copied them would fail rather than ship three drifting copies).
  #
  # NOTE image l2 shipped NO reboot at all: the staging loop used `[ -e ] &&`,
  # which silently skips a missing link. A derivation cannot silently skip -- the
  # hardlink-group head not existing in the proto is FATAL.
  halt = mkSlice {
    name = "illumos-halt";
    deps = baseDeps;
    hardlinkGroups = [ [ "usr/sbin/halt" "usr/sbin/reboot" "usr/sbin/poweroff" ] ];
    # uadmin is the syscall wrapper halt(1M) documents as the lower layer; shutdown
    # is the SMF-aware front end that most people actually type.
    # ⚠️ halt is NOT clean, contrary to my first reading of it: halt links libbe (boot
    # environments) and libbe -> libinstzones -> libzonecfg -> libxml2.so.16. The
    # closure gate caught this; the chain is from scripts/whyneeded.sh. sbin/uadmin,
    # the raw syscall wrapper underneath halt, IS clean -- which matters, because it
    # means an emergency shutdown path exists with no external dependency at all.
    allowUnresolved = protoExternalSonames;
    bins = [ "usr/sbin/shutdown" "sbin/uadmin" ];
  };

  # ----------------------------------------------------------------------- smf
  # The service management facility: the CLIs, both daemons, and the repository
  # seed. svccfg/svc.configd NEED libxml2 + libsqlite-sys, which is why
  # externalLibs is a dep -- pkgs/illumos/default.nix's base-tools slice EXCLUDED
  # svccfg for exactly this reason ("external libxml2 / libsqlite-sys"), which left
  # svccfg outside Nix. It is inside now.
  smf = mkSlice {
    name = "illumos-smf";
    deps = baseDeps ++ [ externalLibs ];
    bins = [
      "usr/sbin/svcadm" "usr/sbin/svccfg" "usr/bin/svcs" "usr/bin/svcprop"
      "lib/svc/bin/svc.startd" "lib/svc/bin/svc.configd"
      "sbin/init"
    ];
    # The manifests and method scripts are DATA -- shell and XML, no DT_NEEDED to
    # walk -- so they ride as extraPaths. lib/svc/seed holds the repository seed
    # databases svc.configd builds /etc/svc/repository.db from on first boot.
    extraPaths = [
      "lib/svc/manifest"
      "lib/svc/method"
      "lib/svc/share"
      "lib/svc/seed"
      "usr/share/lib/xml/dtd/service_bundle.dtd.1"
    ];
    # ⚠️ svccfg NEEDS libxml2.so.16 DIRECTLY (elfdump -d on the proto binary lists it),
    # and `ldd` on the proto's own svccfg reports "libxml2.so.16  (file not found)" --
    # i.e. this binary does not run on the BUILD HOST either. svcadm, svcs, svcprop,
    # svc.startd and svc.configd are clean. externalLibs is a dep so that when a
    # libxml2 >= 2.14 derivation exists, wiring it there fixes svccfg with no change
    # here.
    allowUnresolved = protoExternalSonames ++ [
      # svc.configd's private sqlite; the proto DOES ship it but as an unversioned
      # soname the ABI search dirs miss on some layouts, so it is declared rather
      # than allowed to fail the whole slice.
      "libsqlite-sys.so.2.8.15"
    ];
  };

  # ----------------------------------------------------------------------- zfs
  # zpool/zfs + the beadm/boot-environment tooling solnix's generations depend on.
  # libzfs/libzfs_core/libzutil/libnvpair/libzpool are all COMPUTED from DT_NEEDED.
  zfs = mkSlice {
    name = "illumos-zfs";
    deps = baseDeps;
    # measured: zpool/zfs/zdb/beadm are clean; devfsadm reaches libxml2 via libpool.
    allowUnresolved = protoExternalSonames;
    bins = [
      "sbin/zpool" "sbin/zfs" "usr/sbin/zdb" "usr/sbin/zstreamdump"
      # beadm: solnix's generations ARE boot environments (docs/design-make-be.md)
      "usr/sbin/beadm"
      # fs plumbing zpool/zfs shell out to
      "usr/sbin/fstyp" "usr/sbin/format" "usr/sbin/devfsadm"
    ];
  };

  # -------------------------------------------------------------------- kernel
  # unix + genunix + the module and driver trees.
  #
  # ⚠️ NO CLOSURE TO COMPUTE, and that is a real difference rather than a shortcut:
  # kernel objects are not userland ELF. They carry no DT_NEEDED, no SONAME and no
  # RUNPATH -- module dependencies are resolved by the kernel's own module loader
  # from the `depends_on` field, not by ld.so.1. So `bins` is empty and everything
  # rides as extraPaths (cp -a, which also preserves the .SUNW_ctf sections mdb and
  # dtrace need; a strip or an ELF "fixup" would corrupt them).
  kernel = mkSlice {
    name = "illumos-kernel";
    bins = [ ];
    extraPaths = [
      "platform/i86pc/kernel"   # unix + the platform modules (mach, drv, ...)
      "kernel"                  # genunix + the shared module/driver tree
      "platform/i86pc/amd64"    # the boot archive's amd64 payload dir
      "boot"                    # loader.efi / gptzfsboot / forth files
      "usr/kernel"              # the /usr/kernel module tree (modpath's third entry)
    ];
  };
}
