# Phase 3 — Package breadth, cloud/AI drivers, fork parity, runtimes, desktop

The "everything for illumos is on solnix" push. Large + highly parallel: fan out
package batches across agents, all compiled (GCC + Clang, latest) against the
sliced libc via the Solaris ld, each published SIGNED to the solnix.io cache
(the registry). Track gcc-vs-clang build status per package.

Prereqs: modern toolchains (gcc-14 + clang, in progress) + the Phase-2 gate.

## T3.1 — Mirror the OpenIndiana Hipster package set (x86_64)

Build and cache every package OpenIndiana Hipster ships, for solnix x86_64.
- **Inventory first:** enumerate the Hipster catalog (`pkg list -af` against
  pkg.openindiana.org/hipster, or the oi-userland manifest set) → a machine
  -readable list of FMRIs + versions. This is the master registry target.
- **Dependency-order the build:** topologically sort so build deps come first
  (compilers/make/autoconf/pkg-config/cmake/ninja → base libs → everything).
- **Fan out:** batches of independent packages across parallel agents; each
  builds as `pkgs.illumos.*`/overlay, RUNPATH-relocated, publishes signed to
  the cache. A build-status ledger (built / failed / gcc-only / clang-ok).
- **Gate per batch:** each package realises + its binaries run on illumos
  (ldd-clean) + is fetchable from the cache. Gate overall: the Hipster FMRI set
  is reproducible from the solnix cache.

## T3.2 — Cloud device drivers (EC2 / Azure / GCP)

Ensure solnix has the drivers + libraries to run as a first-class guest on the
big three clouds. Identify missing pieces vs illumos-gate, build them.
- **EC2/Nitro:** ena (have it) — verify + ENA v5/v6 (gate fix 17939), NVMe/EBS,
  the AWS metadata path. **Azure:** Hyper-V/`hv_*` netvsc/storvsc/vmbus drivers
  (do they exist in illumos? likely the big gap). **GCP:** virtio-net/virtio-scsi
  /gVNIC. Inventory what illumos-gate has vs each cloud needs; build/port the
  missing drivers; package + cache them. Gate: solnix boots + networks as a
  guest on each cloud (EC2 proven; Azure/GCP = new work).

## T3.3 — AI/LLM enablement (drivers + libraries)

The pieces to run AI/LLM inference on solnix: llama.cpp/`llm`, vLLM, Anthropic's
ds4 (verify the reference), Microsoft BitNet, etc.
- **GPU/accelerator drivers:** the hard gap — illumos GPU support (NVIDIA
  CUDA? AMD ROCm?) is minimal. Inventory realistically: CPU-only inference
  (llama.cpp, BitNet's bitnet.cpp — CPU-optimized) is tractable FIRST; GPU is a
  major driver-porting effort (flag honestly, likely long-horizon).
- **Runtime libs:** BLAS/OpenBLAS, the Python ML stack (numpy/torch — torch on
  illumos is a real port), CUDA/cuDNN userland if/when GPU lands.
- Build CPU-inference paths first (llama.cpp, bitnet.cpp), package + cache;
  scope GPU as a tracked sub-effort. Gate: run a small LLM (e.g. a quantized
  model via llama.cpp) on solnix, CPU inference.

## T3.4 — OmniOS + SmartOS packages & major features

Bring the notable software + features from the sibling illumos distros.
- **OmniOS:** its curated server package set + `omnios-build` extras; the
  `pkg`/IPS server tooling analogs (we replace IPS, but the underlying tools/
  libs matter). LTS server tooling.
- **SmartOS:** the headline features — **bhyve** (in-gate), **KVM** (SmartOS
  port), **LX-branded zones** (Linux-binary zones, in-gate), `vnd`, `mdata`,
  the Triton/vmadm tooling model.
- Inventory each distro's delta over illumos-gate; build/package + cache.

## T3.5 — Core Solaris/illumos features packaged & configurable

Ensure the crown-jewel features are present, packaged, and exposed via solnix
config modules (not just present in the world):
- **Crossbow** networking (dladm/ipadm/vnics/etherstubs/flows) — a
  `networking` module surface beyond T2.9's basics.
- **Zones** (native) — a `zones` module (zonecfg/zoneadm as declarative config).
- **LX-branded zones** (run Linux binaries).
- **bhyve** (VM hosting), **ZFS** (feature-flag parity + a `zpool`/dataset
  module), **DTrace**, **SMF** (have it), **FMA**, **Comstar**/iSCSI.
- Each: packaged + a solnix module to configure it declaratively. Gate per
  feature: create/run the thing from a solnix config (e.g. a zone, a vnic, a
  bhyve guest).

## T3.6 — Language runtimes & bootstrapping

Bootstrap the runtimes needed to build modern software (Neovim, Rust binutils,
etc.), each packaged + cached:
- **Perl** (have 5.42 on host — package it), **Python** (3.x — package + pip
  ecosystem), **TCL/TK**, **LuaJIT** (for Neovim), **Ruby** as needed.
- **Rust** — the big one: bootstrap rustc+cargo for x86_64-solaris. illumos is a
  supported Rust target tier; try the official Rust bootstrap first (stage0 from
  upstream + build std for solaris). If the normal bootstrap can't be seeded on
  illumos, fall back to **crustc** (https://github.com/FractalFir/crustc) — a
  Rust→C backend that can bootstrap rustc without a prior rustc. Then cargo,
  rustup-analog, and the Rust binutils (ripgrep/fd/eza/etc.).
- **Gate:** build Neovim (needs LuaJIT + tree-sitter) and a Rust binary (e.g.
  ripgrep) on solnix, both run.

## T3.7 — Wayland + modern desktop

The packages for a modern graphical desktop on solnix:
- **Wayland** + a compositor (wlroots-based, e.g. sway/labwc), or start with
  Xorg where illumos support is more mature and bridge to Wayland.
- Mesa/DRI (illumos GPU/DRM support reality-check — may be llvmpipe/software
  first), libinput, fontconfig, GTK/Qt, a terminal, and a minimal desktop
  session. OpenIndiana ships MATE — mine its desktop package set (overlaps T3.1).
- Gate: a solnix system boots to a graphical Wayland (or X) session.

## Method (applies to all)

- **Massively parallel:** many packages are independent → fan out batches across
  agents. Dependency-order within a batch; independent batches run concurrently.
- **Dual toolchain:** build with gcc-14 and clang; record which each package
  needs; prefer the newest working compiler.
- **Everything signed → the cache** (the registry). Reproducible/pinned.
- **Honesty:** GPU drivers, Azure/GCP drivers, torch, and a full Wayland stack
  are genuinely hard illumos gaps — inventory realistically, build the tractable
  CPU/software paths first, flag the multi-quarter porting efforts as tracked
  sub-projects, don't pretend they're a quick package build.
