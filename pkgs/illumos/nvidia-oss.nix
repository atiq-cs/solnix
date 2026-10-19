# pkgs.solnix.nvidia-oss / nvidia-oss-cuda -- the vendored NVIDIA
# open-kernel-module illumos port (MNX / Nick Wilkens, pin 8da2326, NVIDIA
# 615.71.09), built through its OFF-HARDWARE compile gate. This is the
# "vendor-open-kernel-module" driver-port pattern: a verbatim upstream
# kernel-module tree + a solnix compile gate that proves the glue compiles
# against OUR illumos headers, WITHOUT a GPU.
#
# This file exposes TWO LICENSE-GATED ATTRIBUTES (the NixOS allowUnfree model):
#
#   nvidia-oss        DEFAULT. nvidia + nvidia_modeset + nvidia_i2c.
#                     meta.license = MIT. ZERO GPL obligation. The display /
#                     KMS / i2c / graphics path. Compile gate: gate-mit.
#
#   nvidia-oss-cuda   OPT-IN. adds nvidia_uvm (CUDA Unified Memory), which
#                     compiles NVIDIA's GPLv2 kernel-open/nvidia-uvm/
#                     uvm_common.c. meta.license = gpl2Only. GATED behind an
#                     explicit allowance (`enableCuda` / `allowGplv2Kernel`,
#                     default FALSE): a system that forbids GPL-only in
#                     kernel/base never realises it; a system that opts in gets
#                     it. Compile gate: gate-uvm.
#
# The gate does NOT build a loadable module (that needs nv-kernel.o from the
# ~2M-line RM in src/, a full link, and Turing+ hardware). Its job is the GATE:
# `gmake -f gate.mk <goal>` compiles EVERY glue .c to .o with NO nv-kernel.o,
# NO RM link, NO GPU (the upstream `objs:` machinery, split by license). A green
# build means the glue compiled clean against `illumosSrc`.
#
# NEGATIVE CONTROL: the build first proves the gate CAN fail -- it breaks a
# header include in one glue .c and asserts the compile FAILS -- so a green gate
# means something (docs/working-with-subagents.md: "a guard that cannot fail
# manufactures confidence").
#
# EC2-VERIFIED (2026-10-11, OI gcc 14.3.0 / gld 2.46.1, ILLUMOS_SRC = illumos-
# gate master): gate-mit = 34/34 objects CLEAN; gate-uvm = 130 objects, 1 file
# (uvm_illumos_stack.c) needs the thread_splitstack KPI reconciled against our
# headers (see PROVENANCE.md "Header delta"). Negative control FAILS as required.
#
# THE REAL MODULES: `nvidia-oss-modules` (MIT: nvidia, nvidia_modeset,
# nvidia_i2c) builds nv-kernel.o and nv-modeset-kernel.o from the RM source
# (`rmSrc`, the upstream tree at the pin fetched as a FOD, src/-FETCH.md), then
# `gmake` in kernel-illumos/, and FAILS CLOSED unless every module's undefined
# symbols resolve against `kernel` (pkgs.solnix.kernelNd): unix + genunix + the
# modules each one NEEDs. A negative-control module referencing a symbol no
# kernel exports must count exactly 1 first. solnix patches (../../src/drm-port/
# nvidia-oss/patches/*.patch) are applied to the copy at build time; the
# vendored tree is never edited. Not bound to any device: no image installs or
# add_drv's these (docs: X1E-NVIDIA-STATUS.md, the supervised first attach).

{ illumosSrc                 # store path to an illumos-gate SOURCE tree with
                             # usr/src/uts/{i86pc,intel,common} (the kernel
                             # headers the NVIDIA Makefile -I's as ILLUMOS_SRC).
                             # For the real modules this must be kernel's rev.
, solnixDev                  # pkgs.solnix.solnix-dev: gcc + gas + gmake on PATH
, kernel ? null              # pkgs.solnix.kernelNd: the symbol-resolution
                             # reference for nvidia-oss-modules (required there)
, gate ? null                # the gate proto: usr/include for the headers the
                             # gate build generates (sys/priv_names.h, ...)
  # The kernel C flags carry -msave-args (illumos amd64 ABI, for mdb/DTrace
  # argument recovery), an illumos-only gcc option: solnix's from-source gcc
  # (upstream 14.3.0) rejects it, the build host's OpenIndiana gcc 14 accepts
  # it. A build tool, like kernel-nd's host gcc 10; nothing it links ships.
, kernelGcc ? "/usr/gcc/14"
  # The upstream tree at the pin, which carries the RM source src/ (107 MB, not
  # vendored; src-FETCH.md). nix-prefetch-url --unpack of the archive URL.
, rmSrc ? builtins.fetchTarball {
    url = "https://github.com/nwilkens/open-gpu-kernel-modules/archive/8da2326c626cdd08130538f0f5f9a1f985054f4a.tar.gz";
    sha256 = "19r6wrm4067pq89nr63dppnbv85q5rmpwb2pp0kz85ymn69lg4lh";
  }
, patchDir ? ../../src/drm-port/nvidia-oss/patches
, binutils ? null            # GNU binutils slice (gld/gobjcopy). null => host g*.
, lib ? null                 # nixpkgs lib for lib.licenses; null => string tags.
  # LICENSE GATE (NixOS allowUnfree model). nvidia-oss-cuda is only realisable
  # when the caller opts in; otherwise forcing it is an eval error naming the
  # license, exactly like allowUnfree. Default FALSE keeps base MIT-clean.
, enableCuda ? false         # opt in to the CUDA/UVM package (nvidia_uvm)
, allowGplv2Kernel ? false   # alias: accept a GPLv2-only kernel module in base
, system ? "x86_64-solaris"
, nvossSrc ? builtins.path {
    # The vendored tree lives under src/drm-port/nvidia-oss, NOT next to this
    # .nix (which is pkgs/illumos/). Point `path` there explicitly. Drop the
    # 2.1M-line RM src/ (the objs gate never reads it) + _out + .git from the
    # input hash.
    path = ../../src/drm-port/nvidia-oss;
    name = "nvidia-oss-gate-src";
    filter = let base = toString ../../src/drm-port/nvidia-oss;
      in path: type:
        let rel = builtins.substring (builtins.stringLength base + 1)
                    (builtins.stringLength (toString path)) (toString path);
        in !(
             rel == "src" || (builtins.substring 0 4 rel) == "src/"
          || type == "directory" && baseNameOf path == "_out"
          || baseNameOf path == ".git"
        );
  }
}:

let
  # license tags: use lib.licenses when a nixpkgs lib is supplied, else strings.
  mit      = if lib != null then lib.licenses.mit      else "mit";
  gpl2Only = if lib != null then lib.licenses.gpl2Only else "gpl2Only";

  # the shared compile-gate derivation; `goal` selects the license set.
  mkGate = { goal, license, pname }:
    derivation {
      name = pname;
      inherit system illumosSrc solnixDev goal;
      nvossSrc = nvossSrc;
      binutils = if binutils == null then "" else binutils;
      builder = "/usr/bin/bash";
      PATH = "/usr/bin:/usr/sbin:/usr/gnu/bin";
      # meta is a passthru attr set (not used by the builder); exposed below.
      passthru = { inherit license goal; };
      args = [ "-c" ''
        set -eu
        export PATH="$solnixDev/bin''${binutils:+:$binutils/usr/bin:$binutils/bin}:/usr/bin:/usr/sbin:/usr/gnu/bin"

        [ -d "$illumosSrc/usr/src/uts/common" ] || {
          echo "FATAL: illumosSrc=$illumosSrc has no usr/src/uts/common (not a gate source tree)" >&2; exit 1; }
        command -v gmake >/dev/null || { echo "FATAL: no gmake (solnix-dev not on PATH)" >&2; exit 1; }
        command -v gcc   >/dev/null || { echo "FATAL: no gcc" >&2; exit 1; }
        command -v gld >/dev/null || command -v ld >/dev/null \
          || { echo "FATAL: no ld/gld" >&2; exit 1; }
        command -v ctfconvert >/dev/null || echo "note: no ctfconvert (objs gate does not need it)" >&2

        WORK=$(mktemp -d /tmp/nvoss-gate.XXXXXX)
        cp -r "$nvossSrc" "$WORK/nvidia-oss"
        chmod -R u+w "$WORK/nvidia-oss"
        KI="$WORK/nvidia-oss/kernel-illumos"
        [ -f "$KI/gate.mk" ] || { echo "FATAL: gate.mk missing from vendored tree" >&2; exit 1; }

        # NEGATIVE CONTROL: prove the gate CAN fail (break a header include).
        echo "=== negative control: break a header include, expect FAIL ===" >&2
        sh "$KI/build-objs-negctl.sh" "$illumosSrc" "$goal" >"$WORK/neg.log" 2>&1 || {
          echo "FATAL: negative control itself errored:" >&2; tail -20 "$WORK/neg.log" >&2; exit 1; }
        grep -q "FAILS as required" "$WORK/neg.log" || {
          echo "FATAL: negative control did NOT confirm the gate can fail:" >&2
          tail -20 "$WORK/neg.log" >&2; exit 1; }
        echo "negative control OK: $(grep 'FAILS as required' "$WORK/neg.log")" >&2

        # THE GATE: compile every glue .o for the requested license set.
        echo "=== gate: gmake -f gate.mk $goal (off-hardware, no nv-kernel.o) ===" >&2
        NVOSS_DIR="$KI" sh "$KI/build-objs-gate.sh" "$illumosSrc" "$goal" >"$WORK/gate.log" 2>&1 || {
          echo "FATAL: compile gate ($goal) failed:" >&2; tail -60 "$WORK/gate.log" >&2; exit 1; }
        cat "$WORK/gate.log" >&2

        mkdir -p "$out"
        cp "$WORK/gate.log" "$out/gate-$goal.log"
        cp "$WORK/neg.log"  "$out/negctl-$goal.log"
        objs=$(find "$KI/_out" -name '*.o' 2>/dev/null | wc -l | tr -d ' ')
        {
          echo "nvidia-oss compile gate: pname=${pname} goal=$goal objects=$objs"
          echo "license=${if lib != null then license.spdxId or "GPL-2.0-only" else license}"
          echo "illumosSrc=$illumosSrc"
          echo "NOTE: COMPILE gate (no nv-kernel.o link, no GPU). Turing+ only; not Pascal/X1."
        } > "$out/GATE-RESULT.txt"

        cd /; rm -rf "$WORK" || true
        echo "=== ${pname} ($goal): $objs objects compiled, negative control green ===" >&2
      '' ];
    };

  # DEFAULT: MIT path. nvidia + nvidia_modeset + nvidia_i2c. No license flag.
  nvidia-oss = (mkGate { goal = "gate-mit"; license = mit; pname = "nvidia-oss"; }) // {
    meta = {
      description = "NVIDIA open-kernel-module illumos port (MIT: nvidia + nvidia_modeset + nvidia_i2c)";
      license = mit;
      # Turing+ GSP generation; NOT Pascal / the X1 dGPU.
      platforms = [ "x86_64-solaris" ];
    };
  };

  # OPT-IN: CUDA/UVM path. Adds nvidia_uvm (GPLv2 uvm_common.c). GATED.
  # Forcing this attribute without opting in is an eval error naming the
  # license -- the NixOS allowUnfree pattern applied to a GPLv2-only kernel
  # module in base.
  cudaAllowed = enableCuda || allowGplv2Kernel;
  nvidia-oss-cuda =
    if !cudaAllowed then
      throw ("nvidia-oss-cuda includes nvidia_uvm, whose "
        + "kernel-open/nvidia-uvm/uvm_common.c is GPL-2.0-only (NVIDIA CUDA "
        + "Unified Memory). It is refused by default so base stays MIT-clean. "
        + "To build it, pass enableCuda = true (or allowGplv2Kernel = true), "
        + "e.g. `pkgs.solnix.nvidia-oss-cuda.override { enableCuda = true; }` "
        + "or set it in your system config. See src/drm-port/nvidia-oss/"
        + "LICENSE-AUDIT.md.")
    else
      (mkGate { goal = "gate-uvm"; license = gpl2Only; pname = "nvidia-oss-cuda"; }) // {
        meta = {
          description = "NVIDIA open-kernel-module illumos port + nvidia_uvm (CUDA UVM) -- GPLv2 opt-in";
          license = gpl2Only;
          platforms = [ "x86_64-solaris" ];
        };
      };
  # THE REAL MIT MODULES, linked and checked against `kernel` (see header).
  # nvidia_uvm is not built here: it is GPLv2 (nvidia-oss-cuda's opt-in) and at
  # gate rev ac45d71 it does not compile (thread_splitstack, PROVENANCE.md).
  nvidia-oss-modules =
    if kernel == null || gate == null then
      throw "nvidia-oss-modules needs kernel (pkgs.solnix.kernelNd) and gate (the gate proto)"
    else derivation {
      name = "nvidia-oss-modules-615.71.09";
      inherit system illumosSrc kernel gate rmSrc kernelGcc;
      nvossSrc = nvossSrc;
      patches = builtins.concatStringsSep " "
        (map (p: "${patchDir}/${p}")
          (builtins.filter (p: builtins.match ".*\\.patch" p != null)
            (builtins.attrNames (builtins.readDir patchDir))));
      negctl = ../../src/drm-port/nvidia-oss/kernel-illumos/negctl-unresolved.c;
      builder = "/usr/bin/bash";
      PATH = "/usr/bin:/usr/sbin:/usr/gnu/bin";
      args = [ "-c" ''
        set -eu
        export PATH="$kernelGcc/bin:/usr/gnu/bin:/usr/bin:/usr/sbin"
        for t in gcc gmake gld gobjcopy patch; do
          command -v $t >/dev/null || { echo "FATAL: no $t on PATH" >&2; exit 1; }
        done
        echo 'int x;' | gcc -msave-args -mcmodel=kernel -c -x c - -o /dev/null \
          || { echo "FATAL: $kernelGcc/bin/gcc lacks -msave-args (needs the illumos gcc)" >&2; exit 1; }
        [ -d "$illumosSrc/usr/src/uts/common/sys/i2c" ] || { echo "FATAL: illumosSrc lacks sys/i2c" >&2; exit 1; }
        U=$kernel/platform/i86pc/kernel/amd64/unix; G=$kernel/kernel/amd64/genunix
        for f in $U $G; do [ -f $f ] || { echo "FATAL: no $f" >&2; exit 1; }; done

        # The upstream tree (with src/) plus the solnix files of the vendored
        # copy: one tree, so the build is the upstream `gmake modules` layout.
        W=$(mktemp -d /tmp/nvoss-mods.XXXXXX); T=$W/nv
        cp -r "$rmSrc" $T; chmod -R u+w $T
        # the vendored copy must be the same tree as the fetched pin (minus src/)
        for f in kernel-illumos/Makefile kernel-illumos/nvidia/nvidia_ddi.c \
                 kernel-illumos/nvidia-modeset/nvidia_modeset_illumos.c version.mk utils.mk; do
          cmp -s $T/$f $nvossSrc/$f || { echo "FATAL: vendored $f differs from the pinned upstream" >&2; exit 1; }
        done
        cd $T
        for p in $patches; do
          echo "=== patch $p" >&2
          patch -p1 --fuzz=0 --no-backup-if-mismatch < $p
        done
        grep -q 'nv_rm_is_initialized()' kernel-illumos/nvidia-modeset/nvidia_modeset_illumos.c \
          || { echo "FATAL: nvidia_modeset RM-init guard not applied" >&2; exit 1; }

        # Fixed id string: the default embeds whoami@hostname and the date.
        mk="NV_BUILD_USER=solnix NV_BUILD_HOST=nix DATE=true TARGET_OS=SunOS TARGET_ARCH=x86_64"
        J=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
        gmake -C src/nvidia -j$J $mk >$W/nvk.log 2>&1 \
          || { echo "FATAL: nv-kernel.o" >&2; tail -40 $W/nvk.log >&2; exit 1; }
        gmake -C src/nvidia-modeset -j$J $mk >$W/nvm.log 2>&1 \
          || { echo "FATAL: nv-modeset-kernel.o" >&2; tail -40 $W/nvm.log >&2; exit 1; }
        O=kernel-illumos/_out/SunOS_x86_64
        # CTFCONVERT= : the RM objects carry no DWARF, ctfconvert refuses them.
        # KERNEL_INC replaces the Makefile's `-idirafter /usr/include` (the
        # host's headers) with the gate proto's, the same rev as illumosSrc.
        KINC="-nostdinc -I$illumosSrc/usr/src/uts/i86pc -I$illumosSrc/usr/src/uts/intel"
        KINC="$KINC -I$illumosSrc/usr/src/uts/common -isystem $(gcc -print-file-name=include)"
        KINC="$KINC -idirafter $gate/usr/include"
        gmake -C kernel-illumos -j$J ILLUMOS_SRC=$illumosSrc CTFCONVERT= KERNEL_INC="$KINC" \
          _out/SunOS_x86_64/nvidia.kmod _out/SunOS_x86_64/nvidia_modeset.kmod \
          _out/SunOS_x86_64/nvidia_i2c.kmod _out/SunOS_x86_64/nvidia.aliases >$W/ki.log 2>&1 \
          || { echo "FATAL: kernel-illumos modules" >&2; tail -40 $W/ki.log >&2; exit 1; }

        # --- GATE: unresolved = 0 against the kernel, fail closed ------------
        # Illumos nm, not gnm (gnm -p prints nothing on these ET_REL modules).
        # Each module's deps are unix + genunix + its DT_NEEDED modules, found
        # along krtld's default path. __dtrace_probe_* are not counted: krtld
        # rewrites those calls to nops (intel/amd64/krtld/kobj_reloc.c).
        NM=/usr/bin/nm
        unres() {  # <module> <out-list>; prints "<undefined> <unresolved>"
          m=$1; deps="$U $G"
          for d in $(elfdump -d $m | awk '$2=="NEEDED"{print $4}'); do
            if [ $d = drv/nvidia ]; then deps="$deps $O/nvidia.kmod"; continue; fi
            hit=
            for r in platform/i86pc/kernel kernel usr/kernel; do
              p=$kernel/$r/''${d%/*}/amd64/''${d#*/}; [ -f $p ] && { hit=$p; break; }
            done
            [ -n "$hit" ] || { echo "FATAL: $m needs $d, not in $kernel" >&2; exit 1; }
            deps="$deps $hit"
          done
          for d in $deps; do $NM -p $d; done | awk '$2 ~ /^[TDBRCW]$/ {print $3}' | sort -u > $W/ks
          $NM -p $m | awk '$2=="U" {print $3}' | sort -u > $W/u
          comm -23 $W/u $W/ks | grep -v '^__dtrace_probe_' > $2 || true
          echo "$(wc -l < $W/u | tr -d ' ') $(grep -c . $2 || true)"
        }

        # NEGATIVE CONTROL: one undefined symbol no kernel has -> must count 1.
        gcc -m64 -D_KERNEL -D_ELF64 -Dsun -D__sun -D__SVR4 -ffreestanding -fno-builtin \
          -mcmodel=kernel -mno-red-zone -mno-mmx -mno-sse -msave-args -O2 -nostdinc \
          -I$illumosSrc/usr/src/uts/i86pc -I$illumosSrc/usr/src/uts/intel \
          -I$illumosSrc/usr/src/uts/common -isystem "$(gcc -print-file-name=include)" \
          -c $negctl -o $W/negctl.o
        /usr/bin/ld -ztype=kmod -o $W/negctl $W/negctl.o
        unres $W/negctl $W/negctl.unres > $W/cnt; set -- $(cat $W/cnt)
        [ "$2" = 1 ] && grep -qx solnix_negctl_no_such_symbol $W/negctl.unres \
          || { echo "FATAL: negative control counted $2 unresolved, expected 1" >&2; exit 1; }
        echo "negative control OK: negctl undefined=$1 unresolved=1 (solnix_negctl_no_such_symbol)" >&2

        mkdir -p $out/kernel/drv/amd64 $out/share/nvidia-oss
        : > $out/share/nvidia-oss/GATE-RESULT.txt
        for mod in nvidia nvidia_modeset nvidia_i2c; do
          f=$O/$mod.kmod
          unres $f $W/$mod.unres > $W/cnt; set -- $(cat $W/cnt)
          # a kernel module has kernel references; few means nm printed nothing
          [ "$1" -ge 40 ] || { echo "FATAL: $mod has only $1 undefined (nm broken?)" >&2; exit 1; }
          echo "$mod: bytes=$(wc -c < $f | tr -d ' ') undefined=$1 unresolved=$2 needed=$(elfdump -d $f | awk '$2=="NEEDED"{printf "%s,", $4}')" \
            | tee -a $out/share/nvidia-oss/GATE-RESULT.txt >&2
          [ "$2" = 0 ] || { echo "FATAL: $mod has $2 unresolved:" >&2; sed 's/^/  /' $W/$mod.unres >&2; exit 1; }
          cp $f $out/kernel/drv/amd64/$mod
        done
        cp kernel-illumos/nvidia/nvidia.conf kernel-illumos/nvidia-modeset/nvidia_modeset.conf \
           kernel-illumos/nvidia-i2c/nvidia_i2c.conf $out/share/nvidia-oss/
        cp $O/nvidia.aliases kernel-illumos/devlink.tab kernel-illumos/README.md $out/share/nvidia-oss/
        echo "kernel=$kernel" >> $out/share/nvidia-oss/GATE-RESULT.txt
        chmod 0555 $out/kernel/drv/amd64/*
        cd /; find $W -delete || true
        echo "=== nvidia-oss-modules: 3 modules, unresolved=0, negative control green ===" >&2
      '' ];
    } // {
      meta = {
        description = "NVIDIA open GPU kernel modules for illumos (nvidia, nvidia_modeset, nvidia_i2c), linked against kernelNd";
        license = mit;
        platforms = [ "x86_64-solaris" ];
      };
    };
in
{
  inherit nvidia-oss nvidia-oss-cuda nvidia-oss-modules;
  # default attribute is the MIT package.
  default = nvidia-oss;
}
