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
  - **bhyve microVM control plane (Firecracker-equivalent)** — demand-driven,
    post-stable. A thin REST/API daemon over libvmmapi + stripped virtio-only
    device model + PVH fast-boot + bhyve-branded-zone jailing. Delivers
    Firecracker's use case (fast, minimal, API-driven, densely packed VMs)
    natively; a literal Firecracker port onto the aging Joyent KVM driver is
    explicitly rejected. Full analysis: docs/design-microvm-bhyve.md.
  Produce a prioritized catalog (desktop vs server tracks) and feed it into the
  package-build pipeline once the base distro is stable.

## Platform qualification

- **[PS-7] Qualify solnix on ALL EC2 instance types.** Not a priority now, but a
  real eventual requirement. So far we've only proven a narrow slice, and have
  already hit real gaps:
  - **TSC/PIT boot hang is instance-type/vCPU-correlated** — our built kernel
    needs `pit_is_broken=1`; even then, reliability varies by vCPU count. Proven
    reliable: m6i (Nitro, EBS) at ≤16 vCPU. Known-bad/untested: 32+ vCPU (hung
    ~60% before the fix), **c6id / instance-store NVMe** (didn't boot), **Nitro
    v5/v6** (ENA attach needs gate fix 17939 — verify it's in our kernel),
    Xen-era types (t2/m4 — booted early on via xnf), bare-metal `.metal`, and the
    high-core `.24xlarge`/`.48xlarge` sizes.
  - **What qualification means:** for each family/size, verify boot-to-multi-user
    reliability (a batch success rate, via `oi-boot-batch.sh`), correct NIC
    driver attach (ena/xnf/virtio as applicable), NVMe/EBS + instance-store disk,
    and console/serial. Build a per-instance-type support matrix (like the
    architecture matrix in `.kiro/steering/architectures.md`).
  - **Root causes to chase:** the TSC/PIT early-boot path at high vCPU counts;
    instance-store NVMe device support; ENA generations (17939 and later);
    IMDSv2 (org-enforced here) vs the metadata path. Several are kernel-level
    illumos work, not packaging.
  - **Deliverable:** a qualified-instance-types matrix + the fixes that widen it,
    so "solnix runs on EC2" means *any* type, not just m6i≤16vCPU. Track which
    types are certified per release.

## Sequencing note

These slot in **after** the roadmap's Phase 1 (bootable amd64) and Phase 2
(usable, self-hosting, installer, cache) are done. PS-2/PS-3 (Rust, libumem) can
start as soon as the world self-hosts; PS-1/PS-4/PS-5 (clang/latest-GCC/lldb)
are larger world-rebuilds best done once the GCC world + cache are proven; PS-6
is ongoing breadth work that rides on a stable base. Revisit this file when
Phase 2's gate is green.

## PS-8: aarch64 on server-class ARM (Graviton/SBBR) — deployment target

Make solnix-aarch64 boot on AWS Graviton + other server ARM (not for build speed —
cross-from-amd64 already handles builds — but as a DEPLOYMENT target). Requires
upstream arm64-gate work: GICv3/GICv3-ITS driver + ACPI/SBBR parser + SystemReady-SR
bringup (IPD 24 marks these nascent). Collaborate upstream (Rich Lowe/illumos).
Pairs with PS-7 (qualify all EC2 types). Multi-month; low priority vs package/boot goals.

> NOTE: PS-8 is now the headline of a full spec — .kiro/specs/solnix-cloud-hardware/
> (CH-1 ARM server kernel port GICv3+ACPI+SystemReady-SR; CH-2 AWS/Nitro; CH-3 Azure/
> Hyper-V; CH-4 GCP/gVNIC; CH-5 accelerators; CH-6 declarative cloud modules; CH-7
> per-instance device-audit CI; CH-8 upstream). Boot + run + expose ALL hardware on
> every cloud instance type, every arch. Pairs with PS-7.

## PS-9: network MTU / jumbo frames + audit of stale illumos defaults vs Linux/FreeBSD

Investigate and, where safe, modernize kernel/network defaults that illumos has left
conservative while Linux/FreeBSD have raised them.

### 9a. MTU / jumbo frames
- **Determine per-driver default MTU** on our built drivers. illumos NIC drivers
  default to the standard **1500** Ethernet MTU; jumbo support and the max frame size
  are per-driver `dladm` link properties (`dladm show-linkprop -p mtu <link>`,
  `dladm set-linkprop -p mtu=9000 <link>`). Confirm which of our shipped drivers
  advertise a jumbo `mtu` range (e1000g, igb, ixgbe, ena, bge, vioif, vmxnet3s, ...)
  and what their max is (commonly 9000/9216; some cap at ~8500 or lower).
- **AWS specifics**: EC2 supports 9001-byte jumbo frames within a VPC/placement group
  and 1500 to the internet gateway; ENA advertises up to 9216. Verify `ena` on solnix
  negotiates the jumbo MTU and that our cloud modules can set `mtu=9001` declaratively.
- **Answer the concrete questions**: default is 1500 (not 8500); jumbo (9000/9001) is
  supported *per driver via dladm*, not globally on by default. Document the matrix
  (driver -> default MTU, max MTU, jumbo y/n) and expose `mtu` in the crossbow/ipadm
  declarative network module (pairs with CH-6). Check path-MTU-discovery + TCP MSS
  clamping behave with jumbo mixed segments.

### 9b. Broader stale-defaults audit (illumos vs Linux/FreeBSD)
Survey conservative illumos tunables other OSes have modernized; propose safe bumps
(measure, don't cargo-cult). Candidates:
- **TCP**: initial congestion window (initcwnd 10, RFC 6928 — verify illumos default),
  default send/recv buffers + autotuning ceilings (`tcp_max_buf`, `tcp_recv_hiwat`,
  `send/recv autotuning`), TCP timestamps/SACK/window-scaling on by default, CUBIC vs
  NewReno as the default congestion control (illumos added CUBIC — is it default?),
  ECN, TFO.
- **Socket / net**: `somaxconn`/listen backlog cap, ephemeral port range
  (`tcp_smallest/largest_anon_port`), `tcp_conn_req_max_q`.
- **Filesystem / VM**: ZFS `zfs_arc_max` default sizing on modern RAM, `recordsize`
  defaults, dirty-data limits; page-cache/segmap sizing; `maxphys` (max I/O size —
  historically small on illumos vs Linux large-BIO); NVMe queue depths.
- **Process / limits**: default `rlim_fd_cur/max` (file-descriptor limits — illumos
  historically 256/65536 soft/hard), `maxusers`-derived table sizes, `maxpid`,
  thread/LWP limits, `ndd`/`ipadm` legacy tunables that have modern `ipadm` equivalents.
- **Crypto / entropy**: default RNG source, KCF provider ordering.
- **Scheduler / timers**: default scheduling class, tick/hz, high-res timer defaults.

Method: for each, compare the illumos default (source: `usr/src/uts/common/inet/`,
`/etc/system` tunable docs, `ipadm show-prop`) against current Linux
(`sysctl net.ipv4.*`, `/proc/sys`) and FreeBSD (`sysctl net.inet.*`) defaults, note
where illumos is materially behind, propose a solnix default (via `/etc/system`,
`ipadm`/`dladm` link/protocol props, or a tuning SMF service), and BENCHMARK before
adopting. Ship sane modern defaults in the base config + document the knobs.

Priority: post-stable, after the base distro + cache are green. Pairs with CH-6
(declarative cloud/network modules) and PS-7 (per-instance qualification, where jumbo
MTU on EC2 gets real-hardware validation).

## PS-10..PS-16: maintainer roadmap (2026-07-31) — HONEST scoping

These are the maintainer's 7-item directive. Marked by realistic effort. Items are DISPATCHED as work
or captured as specs; the kernel/GPU ports are MULTI-MONTH and will NOT complete in a single session.

### PS-10: aarch64 Graviton/Neoverse kernel port (GICv3 + ACPI/SBBR) [MULTI-MONTH]
Port the missing server-ARM bring-up so illumos-aarch64 boots on Graviton/Neoverse (currently EBBR/FDT +
GICv2 only). SOURCE MINING: NetBSD (arch/aarch64 + acpi + gicv3 = `dev/acpi`, `arch/arm/cortex/gicv3*`) and
FreeBSD (`sys/arm64/arm64/gicv3*`, `sys/dev/acpica`, `sys/arm64/acpica`) — both BSD-licensed, portable. Need:
(1) GICv3/GICv3-ITS driver, (2) ACPI parser + MADT/GTDT/SPCR tables (illumos has acpica in x86; port to arm64),
(3) SystemReady-SR/SBBR boot path, (4) Graviton ENA + EBS-NVMe already exist on x86 (reuse). THEN build
bootable aarch64 EC2 image + aarch64 ISOs (Graviton, RPi4/5 via existing n-hys FDT, Apple Silicon via m1n1/
Asahi-style FDT — separate). This is the CH-1 spec (.kiro/specs/solnix-cloud-hardware). Est: 3-6 months, upstream
collab (Rich Lowe / illumos arm64-gate). DISPATCHED: source-survey subagent (find+catalog the BSD GICv3/ACPI
code); implementation is a sustained effort, not one session.

### PS-11: real GPU — Wayland/X11 accelerated + display-manager (GDM-class) + VNC [MULTI-MONTH for HW; VNC now]
Current: software-rendered (lavapipe/llvmpipe) Xfce on Xvfb. For REAL GPU Vulkan: port a DRM/KMS substrate
(the NetBSD drm2 / FreeBSD drm-kmod LinuxKPI shim — see docs/gpu-parity-survey.md + netbsd-driver-substrate.md),
libinput/evdev/seatd for Wayland input, a compositor (COSMIC/wlroots), Xwayland bridge, and a display manager.
This is the ~1-2yr "wall" (DRM-UAPI + evdev/libinput/seatd). SHIPPABLE NOW: package a VNC server (x11vnc /
tigervnc) so the existing SW-desktop is remotely usable. DISPATCHED: VNC-server package build (immediate);
DRM/Wayland substrate = long-horizon spec (already in docs/desktop-gpu-research.md P-D2..P-D5).

### PS-12: ISO/IMG publish to solnix.io iso/ prefix + full metadata [DOABLE NOW]
On each ISO/IMG completion: upload to s3.solnix.io/solnix-cache/iso/ with .sha256/.sha512, a README (contents,
default accounts/secrets [currently NONE baked — installer creates none; live user 'solnix' passwordless on
graphical only], burn instructions (dd/rufus/balena), boot+installer steps, expected-hosts list, complete
driver list [252 drivers + 1339 driver_aliases], known-good/known-bad hardware matrix). DISPATCHED NOW for the
2 verified x86_64 ISOs.

### PS-13: platform-aware MTU + resource defaults at install time [DOABLE NOW — starting]
At install, detect platform + set MTU to the NIC's advertised max (AWS ENA 9001 VPC / up to 9216; jumbo where
the link supports it) via dladm, NOT a hardcoded 1500. GENERALIZE: audit install-time defaults that cap hardware
(maxphys/IO size, ZFS ARC ceiling, TCP buffer autotuning, fd limits, ncpu/thread caps, ephemeral ports) and set
them from detected hardware so the OS uses all available resources. Extends PS-9. DISPATCHED NOW: solnix-install
platform-MTU + a defaults-audit pass.

### PS-14: build/package ALL virtualization for every platform [MULTI-WEEK]
bhyve + viona + virtio(blk/net/scsi/9p) + bhyve-branded zones + LX-branded zones + native zones, per arch.
These are upstream illumos components — build + package + qualify (bhyve needs VT-x/AMD-V; zones are arch-generic).
DISPATCHED: bhyve+zones package-build track (x86_64 first, the others follow). Est multi-week.

### PS-15: NEW TASK — "KVM and Firecracker port and QEMU on solnix"
(a) QEMU on solnix (TCG + the illumos KVM/bhyve accel backends) — package it. (b) evaluate reviving/forwarding
the Joyent illumos-KVM driver + a Firecracker-equivalent. Captured as a standalone spec task. Est: research +
multi-week.

### PS-16: telemetry (solnix.io) + P2P BitTorrent binary-package distribution [SPEC PENDING from solnix.io team]
(a) Telemetry pieces solnix.io wants. (b) Collaborative BitTorrent P2P distribution of binary packages to the
solnix.io common cache AND peer solnix hosts, with a SECURITY model: per-package signing, validation,
multi-build reproducibility comparison before trust/install; possibly a solnix.io registry of every host's
public signing key + (ideally-avoided) human identity attestation. AWAITING the solnix.io team's written
request for specifics before implementation. Captured; do NOT build until the spec lands.

## Rust toolchain on illumos (blocks uutils/coreutils + Rust CLI tools)
STATUS: NOT PRESENT. The x86_64-solaris build fleet has a full C/C++ toolchain
(gcc-14/clang-21) but NO rustc/cargo. This blocks:
- uutils/coreutils (the Rust coreutils rewrite the maintainer requested)
- the modern Rust CLI ecosystem (ripgrep, fd, bat, eza, zoxide, sd, hyperfine,
  dust, choose, delta, ...) that the maintainer's nix-config uses.
illumos IS a supported (tier-3) Rust target (x86_64-unknown-illumos /
x86_64-pc-solaris). Bootstrapping options:
  (a) cross-compile rustc FROM the x86_64-linux build box to x86_64-illumos, or
  (b) use a stage0 illumos rustc if OI/pkgsrc ships one, then build cargo.
This is a multi-day bootstrap milestone of its own; once done, a large swath of
the maintainer's daily tools become buildable. Pairs with the "make solnix
declarative" (Nix-on-illumos + home-manager) milestone.

## PS-3 UPDATE (allocator decision framing, 2026-08-06)
Default allocator today = illumos libc malloc (stock). libumem (Bonwick/Adams slab) is present
(libumem.so.1 in base OS + seed) but opt-in (LD_PRELOAD / -lumem).
codeberg.org/gregburd/libumem = a MODERNIZED libumem. Making it the SOLNIX DEFAULT is attractive +
a real differentiator (better multithreaded scaling, per-CPU magazines, debugging features
UMEM_DEBUG). PLAN:
  1. Package codeberg.org/gregburd/libumem as a real solnix derivation (libumem.nix).
  2. Two adoption levels: (a) SHIP it + make it trivially opt-in (documented LD_PRELOAD / a
     `programs.libumem.enable` that sets the preload globally) — LOW RISK; (b) make it the SYSTEM
     DEFAULT malloc (e.g. via a libc malloc-interposition / crle default LD_PRELOAD, or building the
     userland against it) — HIGHER RISK, needs benchmarking + broad testing (some programs assume
     libc malloc internals / mallctl; libumem changes fragmentation + free() behavior).
  3. BENCHMARK before defaulting: libumem vs libc malloc on real workloads (build times / a daemon /
     pgbench-like) — adopt as default only if it wins without regressions, and keep a knob to revert.
  RECOMMENDATION: do (a) now (package + easy opt-in), gate (b) on benchmarks. It's a solnix
  differentiator worth doing, but "default allocator" is a measured decision, not a flip.

## PS-TOOLCHAIN (compiler/debugger versions, assessed 2026-08-06)
CURRENT STATE:
- Pure stdenv builds packages WITH **gcc 10.5.0** (illumos-gcc-10 in the seed) — the SAME primary
  compiler illumos-gate uses (gcc-10 primary + gcc-7 shadow). Deliberate: seed cut from illumos's
  own toolchain so packages compile as illumos expects.
- **gdb 17.2** shipped = the LATEST upstream gdb release. No upgrade needed.
- **binutils 2.46.1** (GNU) present on host; Solaris ld is the primary linker.
- **clang/LLVM: NOT in the fork** (clang = none).

CAN WE BUILD WITH LATEST gcc?
- gcc **14.3.0 already RUNS on the OI host** (/usr/gcc/14; used host-side by the split-debug/libumem
  work). So gcc-14 works on illumos.
- To build solnix PACKAGES with gcc-14: build gcc-14 as a real solnix derivation + swap into the
  stdenv (a bootstrap effort: gcc self-build on the pure stdenv + any illumos gcc-14 build fixes).
  Doable, not a flag flip. Latest is gcc-15 (2026) — newer than illumos-gate uses; unproven, more porting.
- PLAN: PS-TC-1 = package gcc-14 + gcc-14 stdenv variant (opt-in `stdenv.override` first, then
  candidate default after a rebuild sweep). Keep gcc-10 as the illumos-parity baseline.

CAN WE BUILD WITH clang?
- Not today. illumos supports clang (OI ships ooce/developer/clang; userland clang-buildable), so
  portable in principle, but requires packaging LLVM/clang as a solnix derivation (large build) +
  a clang-based stdenv. Kernel stays gcc; userland clang is the viable target.
- PLAN: PS-TC-2 = package LLVM/clang + a clangStdenv (post gcc-14; LLVM is one of the biggest bootstraps).

RECOMMENDATION: ship first release on gcc-10 (illumos parity) + gdb-17.2 (latest). Post-stable:
gcc-14 stdenv (PS-TC-1), then clang/LLVM (PS-TC-2).
