# nvidia-oss src/ — fetched as a pinned FOD, NOT vendored

The NVIDIA RM source (`src/`, 107 MB — mostly `src/nvidia/generated/g_bindata_*`,
the GSP firmware encoded as C arrays) builds `nv-kernel.o`, which is needed ONLY
for the final `.kmod` LINK (hardware-gated, far off). It is NOT needed for the
`gmake objs` COMPILE GATE (which compiles only the kernel-illumos/ + kernel-open/
glue). Vendoring 107 MB of generated binary-as-C would re-bloat the repo (we just
cut .git 79M->15M), so `src/` is excluded here and fetched reproducibly at build
time, the same way the illumos gate proto is a FOD.

Pin (verbatim, byte-identical, sha256-verified by the vendoring run):

    upstream : github.com/nwilkens/open-gpu-kernel-modules
    branch   : illumos
    commit   : 8da2326
    version  : NVIDIA 615.71.09
    path     : src/   (relative to the repo root)

To build nv-kernel.o (link stage only): fetch the upstream tree at commit 8da2326,
extract its src/ into this directory, then `gmake modules`. pkgs/illumos/nvidia-oss.nix
carries the FOD (fetchGit/fetchzip at the pin + sha) for the link/hardware target;
the default `gmake objs` gate does not use it.
