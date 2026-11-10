# libld.nix -- illumos libld.so.4 (amd64) built from the pinned gate source plus scripts/patches/0011, the output-relocation
# sort on the output symbol index (illumos ld put .SUNW_reloc's symbol groups in heap-address order, so rust's librustc_driver
# differed between hosts: /scratch/solnix/libld1/). Store tools only (./libld-build.sh), compiled by the seed instance's gcc 14
# (unwrapped: the wrapper's -R would put gcc.lib in its RUNPATH), as gcc15 is. default.nix's `ld` (gcc15 and the system instance) is the gate's ld slice with this libld.so.4 in place.
# ld.so.1's copy (rtld) stays the gate's: ld.so.1 never sorts output relocations.
{ src, gate, gcc, binutils, ldStock, libc, tools, world, patch, system ? "x86_64-solaris" }:
let
  drvAttrs = {
    name = "libld-0011"; inherit system src gate gcc binutils ldStock libc tools patch;
    gccLib = gcc.lib;   # sgsmsg (a build tool) links libgcc_s
    worldPath = "${world}/usr/bin:${world}/usr/sbin:${world}/bin";
    pathGate = ./path-gate.sh; illumosBin = ./illumos-bin.sh;
    builder = "/usr/bin/bash"; args = [ ./libld-build.sh ];
  };
# buildKey: 1:1 with the drv, the same on every host and under --check (gcc15-src.nix)
in derivation (drvAttrs // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON drvAttrs)); })
