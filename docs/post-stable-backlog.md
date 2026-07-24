# solnix — Post-Stable Backlog

Work deferred until solnix is **up, stable, and usable** (Phase 1 bootable +
Phase 2 self-hosting complete). Requested by the maintainer 2026-07-24. These are
NOT Phase-0/1 blockers — schedule them once we have a functional solnix that
boots, self-hosts, and pulls from the solnix.io cache.

## Toolchain / language runtimes

- **[PS-1] Recompile everything with clang.** Once the GCC-based world is stable,
  do a full-world rebuild with clang as the primary compiler (illumos supports
  clang as a shadow today; promote it to primary). Compare correctness + perf;
  keep whichever is the better default per component. Cache both if useful.
- **[PS-4] Latest GCC + GDB.** Move the world off gcc-10 to the newest illumos
  gcc (13/14+) and ship the latest GDB. Track illumos-gcc upstream. This likely
  precedes or pairs with PS-1 (modern toolchains all around).
- **[PS-5] lldb support.** Provide lldb (pairs with the clang work) as a
  first-class debugger alongside mdb/GDB.

## Packages

- **[PS-2] Rust for solnix.** Build a Rust toolchain (rustc + cargo) targeting
  `x86_64-solaris`/illumos and publish it to the cache. illumos is a supported
  Rust target tier; wire it as a `pkgs.illumos`/overlay package. Prereq for
  building Rust software (incl. any rustfs/tooling).
- **[PS-3] libumem as a candidate default allocator.** Build
  `codeberg.org/gregburd/libumem` as a solnix package. Benchmark it against the
  stock allocator; if it's stable and faster (expected), make it the default
  allocator. Add it to the cached packages either way.

## Feature / fork parity

- **[PS-6] Harvest features from other illumos distros/forks** and schedule them
  for building + packaging in solnix — **both desktop and server**:
  - OpenIndiana (Hipster desktop: MATE/GNOME, X/Wayland bits, broad userland),
  - OmniOS (minimal server/LTS tooling),
  - SmartOS/illumos-joyent (zones/hypervisor niceties, mdata, vnd),
  - Tribblix (lightweight tooling), DilOS.
  - Core illumos features to ensure are packaged: zones, bhyve, LX-branded
    zones, DTrace, FMA, OpenZFS feature-flag parity, crossbow networking
    (dladm/ipadm), SMF service catalog.
  Produce a prioritized catalog (desktop vs server tracks) and feed it into the
  package-build pipeline once the base distro is stable.

## Sequencing note

These slot in **after** the roadmap's Phase 1 (bootable amd64) and Phase 2
(usable, self-hosting, installer, cache) are done. PS-2/PS-3 (Rust, libumem) can
start as soon as the world self-hosts; PS-1/PS-4/PS-5 (clang/latest-GCC/lldb)
are larger world-rebuilds best done once the GCC world + cache are proven; PS-6
is ongoing breadth work that rides on a stable base. Revisit this file when
Phase 2's gate is green.
