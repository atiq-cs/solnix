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

{ illumosSrc                 # store path to an illumos-gate SOURCE tree with
                             # usr/src/uts/{i86pc,intel,common} (the kernel
                             # headers the NVIDIA Makefile -I's as ILLUMOS_SRC).
, solnixDev                  # pkgs.solnix.solnix-dev: gcc + gas + gmake on PATH
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
in
{
  inherit nvidia-oss nvidia-oss-cuda;
  # default attribute is the MIT package.
  default = nvidia-oss;
}
