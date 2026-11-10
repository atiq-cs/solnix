# pkgs.solnix.kernelNd -- the NON-DEBUG illumos kernel, built from illumos-gate
# source as its own derivation (NixOS keeps the kernel separate from userland too).
#
# WHY IT EXISTS: gate.nix runs nightly with illumos.sh's NIGHTLY_OPTIONS
# '-FnCDAmprt'; -F means "no non-DEBUG pass", so the proto's kernel is DEBUG.
# Measured on the first disk that reached svc.startd: every boot panics in the
# DEBUG-only so_integrity_check() (sockcommon_subr.c, `#ifdef DEBUG`) via
# so_tpi_fallback. docs/design-make-be.md gotchas #4/#5 already require a
# non-DEBUG kernel, with kernel/, platform/ and usr/kernel all of one DEBUG-ness.
#
# WHAT IT BUILDS: usr/src/tools, then usr/src/uts (intel, then i86pc), in a
# `bldenv +d` (non-DEBUG) environment -- nightly -t's order without the userland.
# Host /opt/onbld (dmake, bldenv) and gcc 10 are BUILD tools only. Userland stays the gate proto's; the kernel does not link it.
# The few uts modules that include $(ROOT)/usr/include get the gate proto's
# headers (same source rev; headers do not depend on DEBUG).
# Applied on top of the pinned source: scripts/patches/0001-tscc_pit-default-
# pit_is_broken.patch (gotcha #10; must be a source default, /etc/system is read
# too late), and 0002-tzmon-thinkpad-hkey-enable.patch (ThinkPad HKEY init, and
# _HOT/_CRT acted on after 3 consecutive readings with a clean power-off;
# _TMP == _CRT on a ThinkPad is the EC's critical alarm, never skipped. The patch
# header has the DSDT + live-hardware evidence), and
# 0003-usbecm-usb-pipe-xopen.patch (usbecm opened its data pipes with
# usb_pipe_open(), which USBA refuses on a USB 3 device, so RTL8153 USB-C
# adapters attached but never passed a frame), 0005-tzmon-thinkpad-dgpu-off.patch
# (ON by default, -B solnix-dgpu-off=0 opts out: a ThinkPad NVIDIA dGPU that only a
# generic driver holds -- vgatext, audiohd -- is offlined, put in D3hot and its root
# port's _PR3 power resource turned off, as Linux's D3cold does; idle in D0 it heated
# the X1E to the EC's cutoff), and 0006-xhci-ss-warm-reset.patch (a USB 3 root port
# whose link did not train -- SS.Inactive, Compliance, Cold Attach -- reads as
# connected and gets a warm reset, so a device plugged in before boot enumerates), and
# 0007-usbecm-link-state-on-disconnect.patch (an unplugged usbecm adapter reports link
# DOWN, and UP on reconnect, so IP drops IFF_RUNNING, dhcpagent removes its routes and
# traffic moves to the other interface), and 0008-xhci-readdress-after-port-reset.patch
# (a device hubd re-enumerates on the same port gets Reset Device + Address Device, so
# an adapter unplugged and plugged back in passes traffic again), and
# 0009-zfs-seek-hole-flush-mmap.patch (lseek SEEK_DATA/SEEK_HOLE flushes mmap'd pages first,
# as OpenZFS does; without it a just-mmap-written file reads as one hole and cp copies zeros), and
# 0010-opteron-pcbe-probe-perfevtsel.patch (pcbe.AuthenticAMD refuses to load when a PerfEvtSel0 write traps, so
# cap_util's cu_init never programs counters an AMD hypervisor rejects; EC2 m6a/c6a panic-looped from the 2nd boot), and
# 0012-poll-nested-wake.patch (an event inside an epoll that is itself in an epoll wakes the outer epoll_wait: the
# parent wakeup had no lock or flag the waiter could test, and a nested scan that found the socket's lock busy skipped
# it without re-arming its wakeup, so cosmic-comp slept with a client request unread until the mouse moved;
# scripts/test-poll-nested-wake.sh).
#
# OUTPUT: kernel/, platform/i86pc/{kernel,amd64}/, usr/kernel/ from the
# non-DEBUG build, plus boot/ (loader, forth, fonts) copied from the gate proto,
# so this has the same shape as the proto subset slices.nix's kernel slice takes.

{ gate                    # the gate proto (headers + boot/)
, rev ? "ac45d71fc2b04a5422e72a14b54dd1e746e7be07"
, srcHash ? "1yhpjbxjynjrwd11vf456aw9hln3ydbc9qsgd5a0k73l8hfsmq87"  # nix-prefetch-url --unpack
, tarHash ? "37684f1076bf971c598e618cb4efd31f16e6f0742c9077c20d927a21dd368d7c" # sha256 of the .tar.gz
, patches ? [ ../../scripts/patches/0001-tscc_pit-default-pit_is_broken.patch
              ../../scripts/patches/0002-tzmon-thinkpad-hkey-enable.patch
              ../../scripts/patches/0003-usbecm-usb-pipe-xopen.patch
              ../../scripts/patches/0005-tzmon-thinkpad-dgpu-off.patch
              ../../scripts/patches/0006-xhci-ss-warm-reset.patch
              ../../scripts/patches/0007-usbecm-link-state-on-disconnect.patch
              ../../scripts/patches/0008-xhci-readdress-after-port-reset.patch
              ../../scripts/patches/0009-zfs-seek-hole-flush-mmap.patch
              ../../scripts/patches/0010-opteron-pcbe-probe-perfevtsel.patch
              ../../scripts/patches/0012-poll-nested-wake.patch ]
, onbld ? "/opt/onbld"
, gcc ? "/usr/gcc/10"
, perlVersion ? "5.42"
, perlVariant ? "-thread-multi"
, buildRoot ? "/var/tmp"
}:

derivation {
  name = "illumos-kernel-nd";
  system = "x86_64-solaris";
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin:/sbin";
  src = import ./fetch-tarball.nix {
    url = "https://github.com/illumos/illumos-gate/archive/${rev}.tar.gz";
    sha256 = tarHash; narHash = srcHash;
  };
  inherit gate rev onbld gcc perlVersion perlVariant buildRoot;
  patches = builtins.concatStringsSep " " (map (p: "${p}") patches);

  args = [ "-c" ''
    set -eu
    export LOGNAME=root USER=root SHELL=/usr/bin/bash
    for t in $onbld/bin/bldenv $onbld/bin/i386/dmake $onbld/bin/i386/cw \
             $onbld/bin/i386/ctfconvert $onbld/bin/i386/ctfmerge $gcc/bin/gcc; do
      [ -x "$t" ] || { echo "FATAL: missing build tool $t" >&2; exit 1; }
    done

    # Fixed path: build paths land in CTF/DWARF, a random one breaks reproducibility.
    WORK="$buildRoot/solnix-kernel-nd-build"; GATE="$WORK/illumos-gate"
    [ -e "$WORK/.lock" ] && { echo "FATAL: $WORK/.lock exists (another build?)" >&2; exit 1; }
    [ -d "$WORK" ] && find "$WORK" -mindepth 1 -delete
    mkdir -p "$GATE" "$WORK/home"; : > "$WORK/.lock"
    export HOME="$WORK/home"
    cp -a "$src/." "$GATE/"; chmod -R u+w "$GATE"; cd "$GATE"
    for p in $patches; do echo "=== patch $p"; patch -p1 --fuzz=0 < "$p"; done
    grep -q '^int pit_is_broken = 1;' usr/src/uts/i86pc/os/tscc_pit.c \
      || { echo "FATAL: pit_is_broken default not applied" >&2; exit 1; }
    grep -q '^	tzmon_hkey_enable();' usr/src/uts/i86pc/io/tzmon/tzmon.c \
      || { echo "FATAL: tzmon ThinkPad HKEY patch not applied" >&2; exit 1; }
    # tzmon must act on _CRT (debounced), never skip it: the X1E's "_TMP == _CRT"
    # is the EC's critical alarm, and skipping it left the hardware cutoff to act.
    # ... and act ONCE per episode: re-sending SIGPWR on every 2 s re-poll flooded
    # the console through a 61 s shutdown (measured under KVM).
    # ... and RE-SEND it every TZ_RESEND_PERIOD while the episode lasts: init drops a
    # SIGPWR that arrives before svc.startd reports a run level, so acting only once
    # left an early-boot alarm unanswered at 128 C (measured under KVM).
    grep -q '(hrtime_t)TZ_RESEND_PERIOD \* NANOSEC' usr/src/uts/i86pc/io/tzmon/tzmon.c \
      && grep -q '^#define	TZ_RESEND_PERIOD	30' usr/src/uts/i86pc/io/tzmon/tzmon.h \
      || { echo "FATAL: tzmon debounced _HOT/_CRT with periodic re-send not applied" >&2; exit 1; }
    if grep -q '&& !tzp->acted' usr/src/uts/i86pc/io/tzmon/tzmon.c; then
      echo "FATAL: tzmon still acts only once (an early-boot SIGPWR is dropped by init)" >&2; exit 1; fi
    if grep -qE 'crt_sentinel|NOT shutting down' usr/src/uts/i86pc/io/tzmon/tzmon.c; then
      echo "FATAL: tzmon still skips a _CRT reading" >&2; exit 1; fi
    # the diagnosis-only output is gone: the EC sensor dump on every over-limit line,
    # the zone kstat that carried the EC fields, and the dGPU "nothing done" notes.
    if grep -qE 'EC TMP0-7|TSL0-3|kstat_create\("tzmon"|ec_gput|nothing done' usr/src/uts/i86pc/io/tzmon/tzmon.c; then
      echo "FATAL: tzmon still has the thermal-diagnosis output (EC dump, zone kstat, dGPU skip notes)" >&2; exit 1; fi
    grep -q '"!tzmon: solnix-dgpu-off: %s: %d function(s) at "' usr/src/uts/i86pc/io/tzmon/tzmon.c \
      && grep -q '"!tzmon: Thermal zone (%s) back to "' usr/src/uts/i86pc/io/tzmon/tzmon.c \
      || { echo "FATAL: tzmon dGPU-off / back-to notes are not log-only" >&2; exit 1; }
    grep -q '^	tzmon_dgpu_off(dip);' usr/src/uts/i86pc/io/tzmon/tzmon.c \
      || { echo "FATAL: tzmon dGPU power-off patch not applied" >&2; exit 1; }
    # ... ON by default (unset = on, "0" opts out), and allowed to detach the generic
    # drivers that bind a driverless dGPU; the opt-in-only version did neither.
    T=usr/src/uts/i86pc/io/tzmon/tzmon.c
    grep -q '"solnix-dgpu-off", -1);' $T && grep -q 'v = (strcmp(s, "0") != 0);' $T \
      && grep -q '{ "vgatext", "audiohd", NULL }' $T && grep -q 'TZMON_DGPU_VENDOR	0x10de' $T \
      || { echo "FATAL: tzmon dGPU power-off is not default-on / generic-driver aware" >&2; exit 1; }
    if grep -q 'opt-in with -B solnix-dgpu-off=1' $T; then
      echo "FATAL: tzmon dGPU power-off is still opt-in only" >&2; exit 1; fi
    X=usr/src/uts/common/io/usb/hcd/xhci/xhci_hub.c
    grep -q '^uint_t xhci_ss_warm_reset = 1;' $X && grep -q 'reg |= XHCI_PS_WPR;' $X \
      && grep -q 'xhci_port_needs_warm_reset(reg))' $X \
      || { echo "FATAL: xhci USB 3 warm-reset patch not applied" >&2; exit 1; }
    E=usr/src/uts/common/io/usb/clients/usbecm/usbecm.c
    if ! grep -q 'usb_pipe_xopen(ecmp->ecm_dip, &in_xdesc' $E || grep -q 'usb_pipe_open(ecmp->ecm_dip' $E; then
      echo "FATAL: usbecm usb_pipe_xopen patch not applied" >&2; exit 1; fi
    grep -q 'usbecm_link_down(ecmp);' $E && grep -q 'usbecm_link_up(ecmp);' $E \
      || { echo "FATAL: usbecm link-state-on-disconnect patch not applied" >&2; exit 1; }
    grep -q 'xhci_command_reset_device(xhcip,' usr/src/uts/common/io/usb/hcd/xhci/xhci_usba.c \
      || { echo "FATAL: xhci re-address-after-port-reset patch not applied" >&2; exit 1; }
    grep -q "solnix: flush any mmap()'d data first" usr/src/uts/common/fs/zfs/zfs_vnops.c \
      || { echo "FATAL: zfs SEEK_HOLE mmap-flush patch not applied" >&2; exit 1; }
    grep -q 'wrmsr(opd.opd_pesf(0), 0x1300c0ULL);' usr/src/uts/intel/pcbe/opteron_pcbe.c \
      && grep -q '^#include <sys/ontrap.h>' usr/src/uts/intel/pcbe/opteron_pcbe.c \
      || { echo "FATAL: opteron_pcbe PerfEvtSel0 probe patch not applied" >&2; exit 1; }
    # the parent of a nested epoll is woken through pcache_wake() and DP_POLL sleeps on pc_wake_lock (0012)
    grep -q 'pcache_wake(pl->pcl_parent_pc);' usr/src/uts/common/syscall/poll.c \
      && grep -q '&pcp->pc_wake_lock, deadline);' usr/src/uts/common/io/devpoll.c \
      || { echo "FATAL: poll nested-wake patch not applied" >&2; exit 1; }
    # ... and a nested scan that finds a resource's lock busy reports it pending, never skips it (0012, change 2)
    grep -q 'ps_flags |= POLLSTATE_ULBUSY;' usr/src/uts/common/syscall/poll.c \
      && grep -q 'POLLSTATE_ULBUSY;' usr/src/uts/common/io/devpoll.c \
      || { echo "FATAL: poll nested-wake busy-lock change not applied" >&2; exit 1; }
    if grep -q 'cv_broadcast(&pl->pcl_parent_pc->pc_cv);' usr/src/uts/common/syscall/poll.c; then
      echo "FATAL: pcache_wake_parents still does a bare cv_broadcast" >&2; exit 1; fi

    # env file: the gate.nix edits, plus no smatch (its binary lives in the
    # workspace tools proto, which +t does not build).
    cp usr/src/tools/env/illumos.sh solnix.sh
    sed -i '/^export SHADOW_CCS=gcc14/d; /^export SHADOW_CCCS=gcc14/d; /^export ON_CLOSED_BINS=/d' solnix.sh
    sed -i "s,^export CODEMGR_WS=.*,export CODEMGR_WS=\"$GATE\"," solnix.sh
    {
      # no t: bldenv re-reads NIGHTLY_OPTIONS after `+t` and a `t` there would
      # point CTFCONVERT/CTFMERGE at the (unbuilt) workspace tools proto.
      echo "export NIGHTLY_OPTIONS='-nCAmpr'"
      echo 'export SHADOW_CCS= SHADOW_CCCS= ENABLE_SMATCH='
      echo 'unset ON_CLOSED_BINS'
      echo "export PERL_VERSION=$perlVersion PERL_VARIANT=$perlVariant"
      echo "export STAFFER=$LOGNAME MAILTO=$LOGNAME"
      echo "export VERSION=solnix-$(echo "$rev" | cut -c1-12)"
      echo "export GNUC_ROOT=$gcc"
      # no -k: the first error fails the build instead of scrolling past
      echo 'export MAKEFLAGS=e'
    } >> solnix.sh

    ROOT="$GATE/proto/root_i386"
    mkdir -p "$ROOT/usr"
    cp -a "$gate/usr/include" "$ROOT/usr/include"; chmod -R u+w "$ROOT"

    # nightly -t's sequence, restricted to what the kernel needs: bootstrap +
    # install the workspace tools (this rev links with its own sgs ld at
    # $ONBLD_TOOLS/bin/amd64/ld, which the host onbld package does not ship),
    # then uts. bldenv's default t points ONBLD_TOOLS at that tools proto.
    cat > "$WORK/uts.sh" <<'EOS'
    set -eu
    # bldenv exports TMPDIR=/tmp, and gcc writes its .s temporaries there. /tmp on
    # the build host is swap-backed (~0.7-1.2 GB), so a kernel build that overlaps
    # another build dies "error writing to /tmp/cc*.s: No space left on device"
    # (measured, ipnet.c and emlxs_thread.c). Use the build tree's disk instead.
    export TMPDIR="$CODEMGR_WS/../tmp"; mkdir -p "$TMPDIR"
    echo "RELEASE_BUILD=[''${RELEASE_BUILD-unset}] ONBLD_TOOLS=$ONBLD_TOOLS ROOT=$ROOT"
    [ "''${RELEASE_BUILD+set}" = set ] || { echo "FATAL: bldenv did not select non-DEBUG" >&2; exit 1; }
    M=/opt/onbld/bin/i386/dmake
    echo "=== tools: bootstrap"; cd "$SRC/tools" && $M -e TARGET=install bootstrap
    echo "=== tools: install";   $M TOOLS_PROTO="$TOOLS_PROTO" -e install
    [ -x "$ONBLD_TOOLS/bin/amd64/ld" ] || { echo "FATAL: tools build left no $ONBLD_TOOLS/bin/amd64/ld" >&2; exit 1; }
    echo "=== uts"
    cd "$SRC" && $M rootdirs
    # install_h = nightly's sysheaders step; it also GENERATES sources (qlc ql_fw_table.c)
    cd "$SRC/uts" && $M all_h && $M install_h
    # intel first (genunix + genassym prereqs, then every module), then i86pc
    cd "$SRC/uts/intel" && $M install.prereq && $M install
    cd "$SRC/uts/i86pc" && $M install
    EOS
    $onbld/bin/bldenv +d solnix.sh "bash $WORK/uts.sh"

    # --- assertions on the result -------------------------------------------
    U=$ROOT/platform/i86pc/kernel/amd64/unix; G=$ROOT/kernel/amd64/genunix
    S=$ROOT/kernel/fs/amd64/sockfs
    for f in $U $G $S; do [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }; done
    # strings -a, not grep: illumos grep counts 0 in the DEBUG gate genunix too
    # (measured), so a grep check could never fail. logsubr.c prints this only #ifdef DEBUG.
    if [ "$(strings -a $G | grep -c 'DEBUG enabled')" != 0 ]; then echo "FATAL: genunix is DEBUG" >&2; exit 1; fi
    if elfdump -s $S | grep -w so_integrity_check; then
      echo "FATAL: sockfs has the DEBUG-only so_integrity_check" >&2; exit 1; fi
    # pit_is_broken must be initialized data (.data), not .bss
    sec=$(elfdump -s $U | awk '$NF=="pit_is_broken"{print $(NF-1)}' | head -1)
    case "$sec" in .data*) echo "OK pit_is_broken in $sec";;
      *) echo "FATAL: pit_is_broken in [$sec], expected .data" >&2; exit 1;; esac
    # usbecm imports usb_pipe_xopen and no longer imports usb_pipe_open (USB 3 adapters)
    M=$ROOT/kernel/drv/amd64/usbecm
    elfdump -s $M | awk '$NF=="usb_pipe_xopen"' | grep -q . \
      || { echo "FATAL: $M does not import usb_pipe_xopen" >&2; exit 1; }
    if elfdump -s $M | awk '$NF=="usb_pipe_open"' | grep -q .; then
      echo "FATAL: $M still imports usb_pipe_open" >&2; exit 1; fi
    # pcbe.AuthenticAMD calls on_trap (the PerfEvtSel0 probe, 0010)
    A=$ROOT/usr/kernel/pcbe/amd64/pcbe.AuthenticAMD
    elfdump -s $A | awk '$NF=="on_trap"' | grep -q . \
      || { echo "FATAL: $A does not call on_trap (0010 not compiled in)" >&2; exit 1; }
    # genunix defines pcache_wake (0012) and the /dev/poll driver (drv/poll) imports it
    elfdump -s $G | awk '$NF=="pcache_wake" && $4=="FUNC" && $8!="UNDEF"' | grep -q . \
      || { echo "FATAL: $G does not define pcache_wake (0012 not compiled in)" >&2; exit 1; }
    elfdump -s $ROOT/kernel/drv/amd64/poll | awk '$NF=="pcache_wake" && $8=="UNDEF"' | grep -q . \
      || { echo "FATAL: drv/poll does not call pcache_wake (0012 not compiled in)" >&2; exit 1; }

    mkdir -p "$out/platform/i86pc" "$out/usr"
    cp -a "$ROOT/kernel" "$out/kernel"
    cp -a "$ROOT/platform/i86pc/kernel" "$out/platform/i86pc/kernel"
    mkdir -p "$out/platform/i86pc/amd64"
    [ -d "$ROOT/platform/i86pc/amd64" ] && cp -a "$ROOT/platform/i86pc/amd64/." "$out/platform/i86pc/amd64/"
    cp -a "$ROOT/usr/kernel" "$out/usr/kernel"
    cp -a "$gate/boot" "$out/boot"
    echo "=== kernel-nd: $(find "$out" -type f | wc -l | tr -d ' ') files ==="
    # cd out first: illumos rmdir(2) of the cwd fails with EINVAL
    cd /; find "$WORK" -mindepth 1 -delete || true; rmdir "$WORK" || true
  '' ];
}
