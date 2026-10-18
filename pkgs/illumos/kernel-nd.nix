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
# too late), and 0002-tzmon-thinkpad-hkey-enable.patch (the X1E halts on a false
# 128 C _TMP: the patch does the ThinkPad HKEY init AND makes tzmon refuse to act
# on a _TMP that equals _CRT exactly without approaching through _HOT -- a sensor
# sentinel, not heat. The patch header has the DSDT + live-hardware evidence).
#
# OUTPUT: kernel/, platform/i86pc/{kernel,amd64}/, usr/kernel/ from the
# non-DEBUG build, plus boot/ (loader, forth, fonts) copied from the gate proto,
# so this has the same shape as the proto subset slices.nix's kernel slice takes.

{ gate                    # the gate proto (headers + boot/)
, rev ? "ac45d71fc2b04a5422e72a14b54dd1e746e7be07"
, srcHash ? "1yhpjbxjynjrwd11vf456aw9hln3ydbc9qsgd5a0k73l8hfsmq87"  # nix-prefetch-url --unpack
, patches ? [ ../../scripts/patches/0001-tscc_pit-default-pit_is_broken.patch
              ../../scripts/patches/0002-tzmon-thinkpad-hkey-enable.patch ]
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
  src = builtins.fetchTarball {
    url = "https://github.com/illumos/illumos-gate/archive/${rev}.tar.gz";
    sha256 = srcHash;
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
    grep -q 'crt_sentinel_logged' usr/src/uts/i86pc/io/tzmon/tzmon.c \
      || { echo "FATAL: tzmon _CRT sentinel guard not applied" >&2; exit 1; }

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
