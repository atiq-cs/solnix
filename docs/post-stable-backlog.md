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

## PS-3 STATUS (2026-08-06): libumem PACKAGED + VERIFIED (64-bit), opt-in module written
- Recipe: solnix-pkgs pkgs/os-specific/illumos/libumem.nix (git rev 1da3fbca, hash sha256-kLRoGAc8...).
  Built: /nix/store/z1w683b46rd3drdh3p36gl2v82b6mwsn-libumem-2.2.0 (deriver resolves, host-free).
- VERIFIED as a drop-in allocator for 64-bit programs: interposer libumem_malloc.so.1 exports
  malloc/calloc/free DEFINED (elfdump: D <self>); `LD_PRELOAD=.../libumem_malloc.so.1 nix --version`
  runs correctly. (64-bit = essentially the entire Nix userland.)
- Opt-in module: modules/config/libumem.nix -> `solnix.programs.libumem.enable` (login-scoped
  LD_PRELOAD, default OFF). Listed in module-list.nix.
- REMAINING: (1) publish durable (needs signing key + s3 creds on a publish-capable host -- mechanical,
  fold into next fleet push); (2) wire pkgs.solnix.libumem into the eval overlay so the module resolves;
  (3) dual-ABI (32+64) build so the preload also covers 32-bit base-OS binaries (libumem.nix ABI TODO --
  needs two configure/make passes, install 64 under lib/64/); (4) BENCHMARK vs libc malloc before any
  system-default decision (level b).

## PS-3 SAFETY NOTE (2026-08-06): system-wide preload unsafe until dual-ABI (T2)
Verified on the demo host: a system-wide `LD_PRELOAD=libumem_malloc.so.1` (64-bit only) makes 32-bit
base-OS tools (grep, pmap, ...) fail "wrong ELF class: ELFCLASS64". So `solnix.programs.libumem.enable`
must NOT install a global /etc/profile.d preload until libumem ships dual-ABI (upstream T2 in
/tmp/libumem-upstream-tasks.md). Interim: a `with-libumem <cmd>` per-command wrapper (safe, 64-bit
programs only). Once T2 lands (both ABIs, lib/ + lib/64/), the runtime linker picks the matching class
per process and the global preload becomes safe.

## PS-TC-2 STATUS (2026-08-06): LLVM/clang 22.1.8 PACKAGED + clangStdenv proven
- clang 22.1.8 (latest STABLE; 23 is git-only) built as a real x86_64-solaris .drv
  (wbrsnb1r...-clang-22.1.8, deriver resolves), ON the pure gcc-10 stdenv. Target x86_64-pc-solaris2.11.
- C + C++ hello both compile + run, host-free (48-path closure). Durable @ cache (5HAV).
- clangStdenv: recipe pkgs/os-specific/illumos/phase3/clang-stdenv.nix (solnixClang + wrapper +
  solnixClangStdenv). PROOF: zlib 1.3.2 built clang-driven (.comment=clang 22.1.8, runs). Durable.
- illumos-LLVM fixes IN the recipe: unwrapped clang+llvm via cmake/ninja (null-bintools assert),
  -lkstat + libnsl MD5/mp syslibs, __xnet_*/-lsocket -lnsl, -idirafter for <cstdlib>, gcc-10 C++ RUNPATH.
- MINIMAL C/C++ clang: no compiler-rt/libcxx/lld yet. TODO: compiler-rt (sanitizers off), libcxx/
  libunwind (drop libstdc++ dep), lld. Built on 2.3.16 host; recipe drops into the 2.24 overlay.
- FOLLOW-UP: write clang-stdenv.nix into the 2.24 tranche-entry-224.nix overlay list (the on-host
  build was via the 2.3.16 tranche-toolchain flow; the recipe content is in artifacts/clang-latest-paths.txt).

## PS-BREADTH-GATES (2026-08-06): 3 systemic blockers gating many x86_64 packages
Found during the buildout lanes. Each is a SINGLE fix that unblocks a whole subtree:
1. **libtool $global_symbol_pipe empty on illumos** -> the `.la` link runs `nm ... | | sed` (empty pipe
   = syntax error). Blocks gnutls, gsasl, libidn (the TLS/i18n subtree). NM=gnm doesn't fix the
   configure-time probe. FIX: patch libtool's global_symbol_pipe detection for illumos (or inject a
   working `nm -B`/`gnm -p` pipe), fork-wide. HIGH VALUE (unblocks gnutls -> real HTTPS in curl/wget/
   libmicrohttpd, and the i18n libs).
2. **"Bad System Call" under the build for b2/bjam + icu pkgdata** -> blocks boost, icu4c, re2 (->icu),
   and the C++-build-tool class. illumos rejects a syscall b2/pkgdata makes. FIX: identify the syscall
   (truss the failing b2/pkgdata) + patch/stub it, or build icu/boost via cmake instead of b2. Unblocks
   the C++ library subtree.
3. **rhash-1.4.6 "Unknown target OS"** (cmake's hash dep) -> blocks the entire cmake-built graph
   (double-conversion/cjson/libcbor/mbedtls/zlib-ng/xxHash/abseil-cpp/json-glib/...). FIX: add illumos
   to rhash's OS detection (a configure/Makefile OS-case patch). VERY HIGH VALUE (cmake is a huge
   dependency hub). NOTE: cmake itself builds (cmake 4.3.4 done); this is rhash pulled by cmake-using pkgs.
Also per-pkg: nspr (ld), jemalloc (strerror_r return-type), libunwind (os-solaris.c:66 port bug),
termcap (needs -fPIC; superseded by ncurses). Lower value / individual ports.

## PS-BREADTH-GATE-4 (2026-08-06, escalated): xz-5.8.3 blocks meson AND wget
xz-5.8.3's liblzma fails to build on illumos (tuklib_physmem.c -- physmem detection). Originally seen
blocking wget (transitive via python3). NOW ALSO confirmed blocking the ENTIRE MESON subtree
(meson -> python3 -> xz-5.8.3): inih, opus, libspng, and all meson-built packages. This is a 4th
systemic breadth-gate, HIGHER priority than first scoped. FIX: port xz-5.8.3 tuklib_physmem.c for
illumos (the _SC_PHYS_PAGES/sysconf path -- illumos has sysconf(_SC_PHYS_PAGES) + getsysinfo; the
Solaris branch may just need the right #ifdef). We built plain `xz` (5.6.x) before; this is the newer
5.8.3 the current nixpkgs pins. Unblocks meson (-> the whole meson-built graph) + wget.

## PS-BREADTH second-order blockers (2026-08-07, from the cmake/meson/C++ wave)
The 4 systemic gates are open (cmake/meson/TLS/C++ = +28 pkgs). Remaining blockers are per-subtree
SECOND issues (each a real port, lower urgency than the gates were):
- **glib** -> subproject libsysprof-capture needs Linux-isms (byteswap.h, O_BINARY, mkostemp). Blocks
  the whole GTK/text stack: harfbuzz, fontconfig, pango, json-glib, gobject-introspection. FIX: port
  or disable libsysprof-capture on illumos. HIGH value (unblocks GTK/font subtree).
- **spdlog** -> illumos `struct tm` has NO `tm_gmtoff` (BSD ext illumos never added). FIX: patch
  os-inl.h to use timezone/altzone. Cascades -> doxygen -> libusb1 docs.
- **gnutls** -> a SECOND issue beyond the libtool-pipe: Solaris ld rejects --version-script, so
  libgnutls.so.30 never links + psktool undefined syms. Needs a real gnutls Solaris port (symbol
  versioning / GNU-ld). (libidn/gsasl/libtasn1/p11-kit DO build.)
- **zlib-ng** -> Solaris ld rejects GNU --version-script (CMake patch or GNU ld). Same ld-flavor class.
- **icu4c** -> genrb U_INVALID_FORMAT_ERROR (data-format port) -> blocks re2.
- **hwloc** -> PICL backend wants /usr/lib/64/libpicl.so.1 (host leak); disable PICL to build.
- **capnproto** -> stdenv nativeLibc/noLibc eval assertion (stdenv wiring, not a gate).
Common theme: Solaris-ld --version-script rejection (gnutls/zlib-ng) is itself a mini-gate worth a
generic fix (GNU-ld-for-version-scripts or a mapfile translation).

## PS-GATE-A/B DONE + port-to-2.24 follow-up (2026-08-07)
GATE A (gnutls on x86_64): DONE on the 2.3.16 tranche -- libgnutls.so.30 links, gnutls-cli 3.8.13
runs, host-free. Root cause was NOT --version-script: the tranche's illumosGnm fallback symlinked
Solaris /usr/bin/nm (not GNU nm) -> libtool global_symbol_pipe empty -> every -export-symbols-regex
link died `nm objs | | sed`. FIXES (in the 2.3.16 solaris-overlay.nix): (1) realGnm =
843364...-illumos-gnm (real GNU nm 2.46.1) for withGnm/gnm; (2) gnutls --disable-ld-version-script +
NM=gnm as a configureFlag (env NM clobbered by bintools hook) + withP11-kit=false + strip
net-tools/util-linux/which (eval recursion); (3) SYSTEMIC -L seed-syslibs on NIX_CFLAGS_COMPILE for
gettext/pkg-config/openssl/libevent/unbound/perl (nixpkgs pins illumos -lnsl/-lmd/-lmp with NO -L;
illumos gcc execs host ld directly, bypassing the wrapper -L). Built host-free: gnutls + gettext/
openssl-3.6.3/libevent/unbound/nettle/libtasn1/libidn2/libunistring/gmpCOnly/perl/pkg-config.
GATE B (glib/GTK): sysprof fix PROVEN (glib -Dsysprof=disabled, mirror nixpkgs FreeBSD) + 4 more
(cmake reuse prebuilt, zstd buildContrib=false, tcl HAVE_STRLCPY+socketlibs, sqlite --disable-tcl,
libffi doCheck=false -- all built). BLOCKED on: glib pulls python3-3.14.6 whose config.guess is too
old for illumos ("cannot guess build type") -- a python3-on-illumos port (config.guess refresh +
likely more). NOTE: the 2.24 lineage ALREADY built python3 3.14.6 (wave3) -- so on the 2.24 overlay
glib's python3 dep is satisfied; GATE B likely completes there.
FOLLOW-UP (high value): PORT the gate-A fixes (realGnm, gnutls --disable-ld-version-script, systemic
-L seed-syslibs) from the 2.3.16 solaris-overlay.nix into the 2.24 solaris-overlay-qmvlnvf0.nix so the
RELEASE lineage gets gnutls-x86 (real HTTPS in curl/wget) + glib (python3 already built on 2.24).

## PS-3 libumem 2.4.0 (2026-08-07): 6/7 upstream tasks FIXED
Our 7 filed tasks -> libumem 2.4.0 (via their 2.3.0 illumos-portability release) FIXED T1/T3/T4/T5/T6/T7.
Recipe now stock configure/make/make install (all downstream workarounds dropped). T2 dual-ABI only
DOCUMENTED upstream (two-pass -m32/-m64), not auto-built + gcc -m32 fails in our stdenv (seed cc has
no 32-bit link path: crtp.o wrong ELF class) -> needs a 32-bit toolchain (out of scope) -> global
preload stays UNSAFE for 32-bit base tools -> module stays login-scoped opt-in. New 2.4.0 upstream
behavior: (a) interposer calloc(n,sz)>~2KiB returns NULL (in_calloc 2KiB static-buffer guard defect --
report upstream); (b) double-free no longer aborts under UMEM_DEBUG (glibc-like log-not-crash; redzone
overrun still faults). Both = further reasons the preload is opt-in. libumem 2.4.0 published durable.

## gnutls-x86 REAL HTTPS PROVEN (2026-08-07) + fleet lineage correction
gnutls-3.8.13 on x86_64 (2.3.16/tranche-6 lineage): libgnutls.so.30 links, host-free; curlMinimal
8.21.0 (OpenSSL) built -> `curl https://cache.solnix.io/nix-cache-info` = full TLSv1.3 handshake,
CN=solnix.io cert, body returned, exit 0. REAL HTTPS on x86 works. Fixes: realGnm=GNU nm 2.46.1,
gnutls --disable-ld-version-script + NM=gnm, SYSTEMIC -L seed-syslibs on NIX_CFLAGS_COMPILE (curl/
gnutls/gettext/openssl -- the -lnsl->libmd/libmp gap). python3 config.guess fix: --build=
x86_64-pc-solaris2.11 + sed ac_sys_release=5.11 (empty uname -r) + disallowedReferences=[].
glib BLOCKED: gobject-introspection's python3-env.drv carries __json but not __structuredAttrs=false
-> bypasses the tranche's 2.3.16 stdenv adapter -> empty $stdenv (/setup missing). Needs Nix>=2.6
for the python env builder, OR thread __structuredAttrs=false into python3's env stdenvNoCC. On the
TRUE 2.24 lineage this adapter issue doesn't exist -> glib likely completes there.
FLEET LINEAGE CORRECTION: only 4 hosts are TRUE 2.24 (release lineage); 2 are 2.3.16/tranche-6 (a
PARALLEL lineage, hash-incoherent). RELEASE breadth must target the true-2.24 hosts. FOLLOW-UP: port
the gnutls realGnm/--disable-ld-version-script/-L-seed-syslibs fixes into the 2.24
solaris-overlay-qmvlnvf0.nix so the RELEASE gets gnutls-x86 + HTTPS.

## PS-PTY (2026-08-07): non-root nix source-build blocked by pseudoterminal-slave on illumos
Nix 2.24 UNCONDITIONALLY allocates a build pty for the builder's stdio (not just interactive). On
illumos a non-root user (gburd) can open /dev/ptmx (master) but grantpt/the slave open fails
"opening pseudoterminal slave: Permission denied" -- /usr/lib/pt_chmod (the setuid grantpt helper)
does not exist at that path on this illumos build, and devpts isn't a mountable FSType here. So
non-root SOURCE builds fail, though `nix profile install` from the CACHE works (no build). ROOT
builds: TBD (test above). The baked pty fix (pt_chmod chmod + vfstab devpts) was ineffective (wrong
path / non-mountable FS). REAL FIX OPTIONS: (a) patch Nix 2.24 buildLoop to fall back to a pipe when
the pty slave can't be opened (illumos patch #6, alongside the existing 5); (b) find illumos's actual
grantpt helper + make it work for non-root; (c) run builds as root / via a build-users-group + a
privileged pty setup. (a) is the cleanest -- add to nix-illumos-patches/224/. Until then: cache-install
works for users; source-builds need root or the patch.

## PS-FRESHBOOT (2026-08-07): DEFAULT AMI ami-027e4af3722f46dd9 fails fresh m5.large launch
Fresh launch-from-AMI smoke of the default identity-free AMI: 20+ min, SystemStatus=impaired, no SSH.
Console: reaches EFI loader -> ZFS pool rpool/ROOT/openindiana-2026:08:03 -> loads unix + boot_archive,
but never reaches multi-user/SSH (reboot cycles back to loader). So the DEFAULT AMI is NOT reliably
fresh-launchable -> NOT release-ready. NOTE: the PERSONAL test instance 3.12.148.116 IS up + working
(created/verified in the worker's build flow, not a cold AMI launch) -- so the SYSTEM works; the AMI
PACKAGING/first-boot is the issue. This is the pre-existing "OI-on-EC2 boots reliably only on fresh
launch + needs bootadm" problem, but bootadm alone wasn't sufficient here. INVESTIGATE: (a) is it an
ENA/DHCP/network-plumbing first-boot gap (the instance boots but network/sshd never comes up)? (b) a
boot_archive/BE-name mismatch (BE is openindiana-2026:08:03, not a solnix BE)? (c) the SMF first-boot
services (solnix-nix-register, network/physical:default) failing? Need console-serial or a
recovery-mount of the volume to see the multi-user boot log. This is the #1 release blocker for the
AMI -- the system is proven (personal instance works), the cold-boot packaging is not.

## PS-FLEET-HYGIENE (2026-08-07): upgraded hosts got a STALE fork (dupe hashes)
The host-upgrade copied an OLDER qmvlnvf0 fork (without recent overlay fixes: H39 cmake-SIGSYS, xz
CONFIG_SHELL print-fix) to the upgraded hosts. Result: wave6 on .14.255.246 RE-DERIVED the cmake fixes
from scratch + rebuilt 6 dupes at DIFFERENT hashes than the true-HEAD fork -- wasted work + registry
noise. ROOT: no `git` on the build hosts so the fork/overlay can't be pulled to HEAD; the fork itself
(qmvlnvf0) doesn't substitute from cache (404). FIX (fleet hygiene, do before more dispatch): (1) put
`git` on the build hosts (it's now BUILT for x86 -- install it), OR (2) rsync/export the CURRENT
solnix-pkgs overlay tree (the phase3 .nix files, small) to every host at dispatch time, OR (3) publish
the current fork to cache so hosts substitute the SAME fork. Until then, dispatch prompts must scp the
current phase3 overlay files to the host first. The 13 NEW wave6 pnames are fine (real+host-free); the
6 dupes are harmless (content-addressed, coexist) but avoidable.

## PS-GLIB / seed-syslibs pollution (2026-08-07): the GTK/font subtree gate
gnupg stack + meson tree + python3Packages LANDED (wave7). glib DEFERRED: correct fixes applied
(drop libsysprof-capture Linux-byteswap, -Dxattr=false, -Dnls=disabled) but the REAL blocker is
systemic seed-syslibs POLLUTION: the seed-syslibs Solaris libintl.so shadows GNU gettext on every
link (cc-cflags -L beats buildInput -L and NIX_LDFLAGS_BEFORE) + a GNU libintl.h leaks onto the include
path -> glib ggettext.c libintl_gettext undefined at link. Blocks glib -> harfbuzz/cairo/pango/
fontconfig/gpgme/graphene (the whole GTK/font tree). REAL FIX = slim the seed-syslibs slice (remove
its libintl/gettext so GNU gettext wins), which is a STAGE0 change that reinvalidates the whole store
(heavy -- schedule as a deliberate stage0 pass, like the mpfr/gawk crack wave7 also hit). HIGH value
(unblocks the GTK/font/desktop subtree). Also: enableMinimal on gnupg avoids the null-bintools
llvmPackages.clang eval trap (openldap/gnutls/libusb deps); the clangStdenv-eval-assertion class
(capnproto/nlopt/pinentry/rich->matplotlib) is a separate stdenv-eval gate to fix.

## PS-STRUCTUREDATTRS-2316 (2026-08-07): meson blocked on sparc by Nix 2.3.16 buildEnv
sparc tranche-9: python3 COMPLETED (+_bz2/_lzma via real shared bzip2/xz -- proven import bz2,lzma) +
gnupg deps (npth/libassuan/libksba) + ninja/re2c/zsh. meson BLOCKED: pkgs.buildEnv hard-codes
__structuredAttrs=true (builder.pl dies without NIX_ATTRS_JSON_FILE) + its list-of-sets attrs can't
flatten to plain env -- a Nix-2.3.16 infra gap (2.24 has native structuredAttrs, so meson works on the
x86 2.24 lineage). FIX for sparc: migrate sparc to Nix 2.24 (the deferred sparc-2.24 migration), OR a
structuredAttrs-free buildEnv reimpl for 2.3.16. gnupg on sparc blocked on freepgPatches gitlab %-URL
(shim store-name). Both are 2.3.16-lineage limits -> the real fix is the sparc 2.24 migration.

## PS-FIRSTBOOT-NETWORK (2026-08-08): CRITICAL — AMI fresh-launch network bring-up hangs (the REAL #1 AMI blocker)
The instance-type matrix (10 fresh launches, all families t3/c5/r5/m5/m6i/c6i/c7i) found: after the
cold-boot LOADER fix, the AMI boots the kernel fine (EFI->ZFS->multiuser console login) but then STALLS
at "Hostname: unknown" -- the illumos first-boot identity/network service (svc:/system/illumos/useragent
or the ec2 datasource/DHCP bring-up) logs once and NEVER completes DHCP+hostname+network -> sshd never
reachable, port 22 filtered, EC2 status=impaired. 9/10 fresh launches FAILED (instance-type-INDEPENDENT
-- not ENA/arch per-family; one earlier m5.large "PASS" was luck). Reboots sometimes advance hostname to
ip-172-31-* but SSH still didn't come up in the wait windows.
IMPACT: CORRECTS the earlier "fresh-launch-verified / releasable AMI" claim -- the AMI does NOT reliably
reach SSH on cold launch. The COLD-BOOT LOADER loop IS fixed (separate); this is a SECOND, first-boot
network/identity blocker. The v2026.08.07 release AMI is NOT reliably usable until this is fixed.
FIX (the true #1 AMI blocker now): debug the illumos EC2 first-boot network/identity bring-up --
useragent/ec2-datasource/DHCP (ipadm/dhcpagent on ena0). Likely: the ena0 DHCP client isn't started or
races the identity service; or the EC2 metadata/hostname fetch hangs. Fix so a FRESH launch reaches
network+sshd WITHOUT manual reboots, then re-run the 10-type matrix to validate. This gates a real EC2
release.
NOTE: ISO+IMG (local hardware) boot fine in QEMU (different first-boot path) -- this is EC2-fresh-launch
specific. The personal test instance 3.12.148.116 works because it was brought up through the build flow
(not a cold AMI launch).

## PS-FIRSTBOOT-NETWORK UPDATE (2026-08-08): deterministic failure FIXED; residual driver flake remains
Root cause of the 9/10 first-boot hang: DUAL DHCP addrobj on ena0 (ena0/dhcp AND ena0/v4, both persisted
from the builder the AMI was snapshotted from) -> dhcpagent binds both -> collision -> no lease ->
"Hostname: unknown" -> no sshd. Secondary: no default route (ssh "filtered"); sshd/cryptosvc in maintenance.
FIX (committed): scripts/metadata-shim.sh (self-heal every boot -- strip ena0/v4, add default route,
svcadm clear before enable, backgrounded retry worker so the SMF method exits fast) + beef/ouch-make-base-
ami.sh (strip ena0/v4 + stale lease/duid at bake). New AMI ami-0281fec66ad81824f: fresh m5.large+t3.large+
c5.xlarge PASS, no manual reboot -- the deterministic dual-addrobj class is FIXED.
RESIDUAL (honest, NOT guest-fixable): on a fraction of fresh launches the 2021-vintage gate ena driver
reports link-up but the DHCP exchange gets no response (ipadm refresh-addr times out); reboot/stop-start
don't recover. This is the known gate-ena cold-launch flake -> needs the NEWER illumos ena driver
(gate 17939+) or a driver-level fix. So fresh EC2 launch is now MOSTLY reliable (deterministic blocker
gone) but not 100% until the ena driver is updated -- a real upstream illumos-EC2 limitation.

## PS-FIRSTBOOT-NETWORK v2 (2026-08-08): the SHIM'S REBOOT is the dominant failure (fixable, dispatched)
Quantified ami-0281fec66ad81824f: ~29% (4/14) cold-launch success. DEFINITIVE root cause from console:
PASS <=> boots=1/reboots=0; FAIL <=> boots=2/reboots=1. ALL 14 got DHCP on the FIRST boot (dual-addrobj
fix CONFIRMED good). But an unconditional-ish reboot takes a host WITH a good lease and re-rolls the ena
DHCP dice -> ~7/10 lose the 2nd roll ("Hostname: unknown"). So the reboot AMPLIFIES the residual ena
flake instead of fixing anything. The shim's reboot is SUPPOSED to be conditional (only if no IP) -- so
either cur_ip races/mis-detects the bound lease, or a SEPARATE base-image reboot fires. FIX (dispatched
1940811e): recovery-mount to find the exact reboot trigger, make it truly conditional (never reboot if
ena has a DHCP lease; sentinel /var/lib/solnix/net-ok), re-cut, re-measure (target >=8/10). Expected to
lift reliability toward the ~100% first-boot-DHCP rate -- this is likely the LAST real AMI blocker (the
determinism was already fixed; this is the reboot amplifier). Residual after this = pure per-boot ena
driver flake (small, upstream, needs newer ena driver).

## PS-EC2-ENA-DRIVER (2026-08-08): DEFINITIVE — reliable EC2 cold-launch needs a newer illumos ena driver
FINAL diagnosis of the AMI cold-launch reliability. Two shim bugs FIXED (committed):
  1. dual-DHCP-addrobj bind conflict (ena0/dhcp + ena0/v4) -> collision. FIXED.
  2. false-negative reboot: shim cur_ip parsed the ADDR column, which reads '?' on the flaky ena path
     even when STATE=ok -> shim thought "no address" + rebooted a host that HAD a lease -> re-rolled
     the ena dice. FIXED (gate on installed IPv4 not STATE; net-ok sentinel; bounded reboot counter).
     Reboot-on-good-lease ELIMINATED (passing hosts boot exactly once).
THE REAL CEILING (NOT software-fixable): on a large fraction of fresh cold launches the 2021-vintage
gate ena driver brings the LINK up (ena0 link up 1000Mbps) but NO PACKET FLOWS -- dhcpagent never
completes a lease (ena0 bad address 0.0.0.0, no dhcp_bound), and NOTHING in-OS recovers it (svcadm
restart network/physical, ipadm disable/enable-if, pkill+recreate dhcpagent all leave it wedged; even
IMDS 169.254.169.254 is unreachable so a static-from-metadata fallback is impossible). The failure is
mostly per-host-persistent, so reboots don't converge. Pass rate on the best AMI (ami-01dbb2a6a5e56cee6,
rebootfix-v12): DHCP-window-dependent, 0-4/14 -- NOT release-grade.
VERDICT: the EC2 AMI is NOT reliably cold-launchable until the illumos ena driver is updated (gate
17939+ / a newer ena data-path) OR a VPC-DHCP-independent bring-up is engineered. This is an UPSTREAM
illumos-on-Nitro limitation, not a solnix packaging bug. The shim fixes are correct + committed; do NOT
iterate further on the shim. NEXT WORK ITEM: newer ena driver. MEANWHILE: local-hardware (ISO+IMG) is
the reliable install path; the AMI works but with a low/variable fresh-launch success rate (retry-launch
until one sticks, or use a working instance as a golden image via stop/start... which also doesn't fully
recover -- so retry-launch is the practical workaround).

## PS-EC2-ENA-DRIVER v2 (2026-08-08): CORRECTION -- the ena driver IS fixable, dispatched
Earlier "not software-fixable at our level" was WRONG -- it meant "not fixable in the first-boot SHIM";
the DRIVER itself is open-source illumos kernel code and absolutely fixable. Three code sources:
(1) illumos-gate ena (usr/src/uts/common/io/ena/ -- solnix ships OI's ~2021 build; gate HEAD has later
    fixes); (2) FreeBSD if_ena + ena_com HAL (in ~/ws/osv/bsd/sys/dev/ena/ + contrib/ena_com/ -- the
    canonical Amazon driver, v2.6.3/2021 HAL; FreeBSD 14.x has newer with data-path/reset fixes);
(3) OSv's ena port (~/ws/osv/drivers/ena.cc, has a feat/ena-aarch64 branch already built by the maintainer).
The wedge ("ena0 link up, no packets, dhcpagent no lease") is the 2021 ena data-path/reset -- FreeBSD
fixed this class in newer ena_com. PLAN (dispatched 392dfe76): update illumos ena to gate HEAD (may
already fix it) -> else port FreeBSD's current ena_com data-path/reset fixes -> build the illumos ena
kernel module -> inject into a fresh AMI -> measure >=9/10 cold-launch. This is the real EC2 fix +
directly serves the aarch64/Graviton goal (Graviton needs ena too -- the osv aarch64 ena branch is a head start).

## PS-EC2-ENA-DRIVER RESOLVED (2026-08-08): 🎉 100% Nitro cold-launch -- one-line ena MTU fix
The shipped ena was ALREADY illumos-gate HEAD (the "2021 OI ena" premise was wrong -- it has the 16373
reset + 17939 Nitro-v5/v6 LLQ fixes). The wedge was NOT a HAL/data-path bug: the ena driver defaulted
ena_mtu = ena_max_mtu (JUMBO 9216) at attach, and ena_m_setprop returns ENOTSUP so runtime lowering
(the shim's mtu 1400) silently failed. On many Nitro backends a queue with jumbo Rx buffers does not
reliably deliver small BROADCAST frames (the DHCP OFFER) on cold boot -> link-up, TX works, but
Recv=0/brdcstrcv=0 -> no lease. ONE-LINE FIX (ena.c ena_attach_device_init):
  ena->ena_mtu = min(ena->ena_max_mtu, ETHERMTU);   // 1500, matches FreeBSD if_ena
Diagnosed with mdb/kstat/snoop/dhcpagent on genuinely-wedged cold boots. Patch:
pkgs/illumos/patches/ena-default-mtu-1500.patch. Fixed ena module baked -> AMI ami-0cc154959d7d945ce.
RE-MEASURED: 30/30 (100%) fresh cold launches (m5/t3/c5), vs 0/10 baseline. TARGET >=9/10 CRUSHED.
solnix now RELIABLY cold-launches on EC2 Nitro. (No FreeBSD ena_com port needed.) NEXT: wire the patch
into the base-AMI bake (oi-inject-ena / beef-make-base-ami) so every future AMI ships the fixed ena;
re-cut the RELEASE AMI on ami-0cc154959d7d945ce (also fold in the patched nix + full package set).

## PS-EGRET-OVERLAY-LINEAGE (2026-08-11): egret AMI ships the tranche6-lineage overlay, not canonical
The egret fleet nodes (from the release AMI) use /root/solaris-overlay.nix (tranche6/2.3.16-lineage
layout), NOT the canonical merged qmvlnvf0 overlay (solaris-overlay-qmvlnvf0.nix with all H39/glib/
gnutls/pkg-config + wave1-17 fixes). So egret waves re-derive some fixes (wave21 re-cracked cmake-ranlib,
rhash-solaris; also fixed a fetchPypi empty-hash bug in the shim -- captured to
fetchurl-shim-egret-lineage.nix). FLEET-HYGIENE FIX (do before more egret waves): distribute the
CANONICAL qmvlnvf0 overlay + tranche-entry-224.nix to the egret nodes (scp from git/Codeberg-clone),
OR re-cut the egret base AMI with the canonical overlay baked. Until then egret waves may dup-derive +
miss late fixes. The wave21 shim fetchPypi fix (pickHash skips empty strings) should also merge into the
canonical shim. Publishing from egret is slow (new region path) -- fine, just grind.

## PS-AARCH64-PUBLISH (2026-08-11): aarch64 wave2 built ~30 pkgs, publish incomplete
aarch64 cross wave2 cracked native-bash-under-gcc14 (blocker #1) -> unblocked the coreutils family:
bash/coreutils/diffutils/findutils/gawk/gnugrep/gnused/gnutar/gzip/gnum4/gdbm/libffi/pcre2/expat/
file/tzdata/zlib/libiconv/libunistring/libxml2/readline/ncurses/gmp/mpfr/xz/bzip2/less (~30, up from 6).
All in-store on 18.119.119.138 (gcroots protect them). The agent died before writing the publish list
(aarch64-egret-publish2.txt had only the header) -- ground-truth store inventory recovered them.
oi-node-publish.sh publish of the 184 aarch64 paths is INCOMPLETE (some cache=000 curl-timeouts made
its HEAD-check wrongly skip; 1 "FAIL closure query" on the cross hello). TODO: finish the aarch64
publish (retry with longer curl timeouts in the publisher's HEAD check, or FORCE). Register the ~30
aarch64 pnames once durable. This also supplies several of the site-team audit's "dangling" aarch64
narinfos (illumos-aarch64-seed).

## PS-SG-GUARD (2026-08-11): 0.0.0.0/0 killed egret -> hard enforcement added
ROOT CAUSE of the egret account loss: another agent (not the orchestrator) added tcp/22 <- 0.0.0.0/0
to a security group, violating the burner account's T&C -> AWS shut the account down -> ALL instances
terminated (23-node fleet lost). This is the SECOND time a world-open SG rule cost a burner account
(first: the ouch->crackers migration, .infra/migration-ouch-to-crackers.md). A written steering rule
was insufficient -- agents kept adding it.
ENFORCEMENT (scripts/sg-guard.sh): all SG ingress changes must go through `sg-guard authorize`, which
REFUSES 0.0.0.0/0, ::/0, and any block >= /8 (exit 2, before any AWS call). `sg-guard audit [regions]`
scans for existing world-open rules; `sg-guard preflight <region>` MUST pass before any fleet launch
(aborts if a world-open rule exists). `sg-guard selftest` = runnable check of the refusal logic.
MANDATE for all future fleet work: (1) never call `aws ec2 authorize-security-group-ingress` directly
-- use `sg-guard authorize`; (2) run `sg-guard preflight <region>` before launching; (3) dispatch
prompts must forbid direct SG edits + require the guard. On a NEW account, run `sg-guard audit` first.

## PS-FRED-STALE-EXTRASYSLIBS (2026-08-12): reconstructed AMI ships a stale tranche
The fred build-base AMI (reconstructed from release-224-v2 IMG) bakes a /root/tranche-224.nix whose
extraSyslibs binding uses a hardcoded `src = /nix/store/qbl2q3v2...-extra-syslibs.tar.gz` -- a FOD that
was never published to the cache (404) and cannot rebuild (it is a tarball src, not derivable). This
blocks every cmake-graph package (cmakeMinimal wires extraSyslibs). Non-cmake packages build fine
(crypto wave got 1003 store paths). The canonical fork (solaris-overlay-qmvlnvf0.nix) already defines
extraSyslibs the RIGHT way: `runCommand "illumos-extra-syslibs"` linking from ${final.seedSyslibs}/
lib/amd64 (no tarball, fully rebuildable). FIX (agent d34a341b): surgically replace the node tranche's
extraSyslibs block with the runCommand form (seed-syslibs slice 4qh0sfp... IS in-store), fleet-wide.
BAKE INTO v3: when re-cutting the fred build-base AMI + the release IMG, ship the CANONICAL tranche +
overlay (not the stale baked one) so future reconstructions don't inherit this. This is PS-FLEET-
HYGIENE recurring: the release IMG's baked build env must track the canonical fork HEAD.

## PS-FRED-EXTRASYSLIBS-FIXED (2026-08-12): cmake unblocked fleet-wide
extra-syslibs fix applied 6/6 fred nodes (byte-identical tranche cksum 2788000278). TWO cracks:
(1) extraSyslibs -> runCommand from ${final.seedSyslibs}/lib/amd64 (no tarball FOD);
(2) cmakeMinimal ranlib/strip: the seed bintools slice has ar/as/ld/nm but NO ranlib/strip ->
    -DCMAKE_RANLIB/-DCMAKE_STRIP rewritten to ${final.coreutils}/bin/true (illumos `ar qc` writes the
    index; fixupPhase strips). cmake-minimal-4.3.4 fully builds on fred now.
Fix script: solnix-pkgs phase3/fix-tranche-224-extrasyslibs.py (idempotent). MUST bake the canonical
tranche+overlay into the v3 build-base AMI + the release IMG so reconstructions don't re-inherit the
stale lineage. gtk3 now instantiates past extra-syslibs; next blockers: toml-0.10.2 zero-placeholder
hash in the fetchurl-shim, then libepoxy->libglvnd version-script.

## Wave 25 (crypto) landed +24 + 2 systemic cracks (2026-08-12, fred)
+24 pkgs published host-free (libsodium/secp256k1/nettle/libgcrypt/cryptopp/libtomcrypt/libtommath/
libb2/rhash/libgpg-error/libassuan/libksba/npth/libtasn1/softhsm/libp11/pkcs11helper/libyubikey/...).
CRACKS (bake into overlay): (1) fetchurl-shim dead-mirror filter -- a dead gnupg.org mirror at the
head of mirror://gnupg abort()ed the whole fetch past tryEval; deadHosts drop-filter unblocked the
ENTIRE gnupg family at once. (2) rhash triple x86_64-pc-solaris2.11 (dot required). (3) libscrypt strip
GNU-ld -z,relro/--version-script. Also re-added extra-syslibs via nix-store --add-fixed (belt-and-
suspenders with the runCommand fix). cmake-dependent (xxhash/p11-kit/mbedtls/minisign) were SKIPPED
by wave25 (ran before the fleet-wide cmake fix) -- now buildable, re-queue them.

## PS-FRED-ROOT-DISK-TOO-SMALL (2026-08-12): reconstructed AMI root pool is 7.3G -> nodes wedge
The release-224-v2-derived AMI boots with a 7.3G zpool `spool` (autoexpand=off) even though the EBS is
100G -- the pool partition is ~8G (slice 1, 16236255 sectors), the other 92G unused. Build nodes fill
to 85-98% and wedge on cmake-graph builds. wave28 agent tried to grow the slice via LIVE fdisk ->
corrupted the pool (node lost; cleanly isolated, no unique data lost, forensic snap retained). LESSON:
NEVER live-fdisk/grow a mounted zpool slice.
IMMEDIATE workaround (proven on one node): attach a 2nd big EBS (200G), REBOOT to detect (illumos
nvme hot-plug needs a reboot -- devfsadm alone insufficient), `zpool create bpool c2t1d0`, set
TMPDIR=/bpool/tmp -> builds have space (cmake-minimal builds). BUT /nix/store stays on the 7.3G root ->
big closures still fill it.
DURABLE FIX (do this): re-cut the build-base AMI with the root pool expanded to fill the disk (grow
slice OFFLINE at AMI-build time via the Ubuntu-helper that has the pool exported, then zpool online -e;
OR build the release IMG with a first-boot zpool-autoexpand SMF service like cloud growfs). Then every
fred node launches with ~90G+ root. This + baking the canonical tranche + /dev/fd mount + good nix =
the proper v3 build-base AMI (currently ami-0bbf52c39d67d9aa3 is v2: networked but small-root + stale-
tranche + needs node-bootstrap).

## PS-AARCH64-FRED (2026-08-13): cross re-established + ceiling found (static-only)
aarch64 cross toolchain re-established on fred (reconstructed /root/entry-aarch64-224.nix, a Nix-2.24
cross entry using the live fork qmvlnvf0 + crossSystem aarch64-unknown-solaris2.11 + crossOverlays
solnix.aarch64Cross.cc; captured to solnix-pkgs phase3/entry-aarch64-224.nix). Proof cross-builds:
zlib + hello EM_AARCH64, deriver resolves, closure host-free (0 x86 leak). +5 NEW aarch64 pkgs
cross-built + published (EM_AARCH64): pcre, oniguruma, libyaml, libtasn1, nghttp2 (+re-proofs of
libffi/expat/pcre2/gdbm/zlib). aarch64 total now ~35.
CEILING (real): the seed cross gcc drives shared-lib links through its bundled GNU bfd ld, whose
libgcc mapfile (libgcc-unwind.map) is Solaris `$mapfile_version 2` format -> GNU ld rejects it. The
driver resolves ld from its own read-only seed tree so -B wrapper tricks don't reach it. WORKAROUND:
--disable-shared --enable-static (static libs + executables link clean -- that's the whole wave). FULL
shared-lib aarch64 needs the seed cross gcc REBUILT with Solaris ld as its internal linker (a toolchain
rebuild -- deferred). Blocked shared-dependent: sqlite(tcl)/gettext(bash)/libidn2(libiconv gnulib).
Cross-fetch fix: config.sub via risqcapital/gnu-config-mirror (savannah unreachable from node),
nix-store --add-fixed to the FOD path. Also hit the same 7.3G-root disk wall -> v3 AMI fixes it.

## PS-FRED-V3-AMI (2026-08-13): proper build-base AMI ami-01f92696a3c816147
v3 fixes the 7.3G-root wedge: 96G root (offline GPT-grow of the exported pool + first-boot
solnix-zpool-expand SMF for larger volumes), canonical tranche (cksum 2788000278, cmake works),
/dev/fd, good nix q9cgfd. Boot-tested: networked + cmake-minimal builds + 90G free after a full build.
us-west-2 copy ami-07ea683bff41089b3. Fleet launches on v3 now. Node still runs solnix-node-bootstrap.sh
once (pulls good nix + fork from cache). Capture scripts/fred-fix-base-ami.sh (the AMI-build helper).

## Wave 28b (cmake-graph) +32 + SYSTEMIC libffi-doCheck crack (2026-08-13, fred v3)
+32 pkgs + full cmake: xxhash/fmt/spdlog/nlohmann_json/abseil-cpp/re2/protobuf/protobuf-c/flatbuffers/
simdjson/yaml-cpp/jsoncpp/brotli/snappy/c-ares/msgpack-c/libcbor/minisign/s2n-tls/c-blosc2/minizip-ng/
double-conversion/cjson/utf8proc/cmark/pugixml/tinyxml-2/lz4/zstd/libdeflate/zlib-ng. All host-free,
published=99 failed=0. Registry crossed 1000 rows (1014).
SYSTEMIC CRACK (bake into overlay): libffi doCheck=false removes its dejagnu->expect(pty.h) test wedge
-- this was THE most common build-blocker across the batch (pty.h absent on illumos). Also: cmake
bootstrap -lkstat/-lsendfile + ranlib->ar-s/strip->host-strip shims; rhash solaris* triple; jitter-
entropy/s2n/zlib-ng strip -z relro/noexecstack/--version-script; spdlog tm_gmtoff patch; protobuf-c
protoc --proto_path wrapper + withGnm.
STILL BLOCKED (real ports): python3 cpython (config.guess fixed, stuck at socketmodule Py_SUNOS_VERSION
-- gates mbedtls/p11-kit); icu4c (uconv.cpp gcc -- gates msgpack-cxx/re2-icu). Both are known multi-
session ports.
PROCESS FIX: dispatch prompts must drop /tmp/.pubcreds + oi-node-publish.sh on the node BEFORE the
agent starts (waves 28b/29 built fine but published=0 -- creds weren't on those us-east-2 nodes yet;
orchestrator published after). Now all active nodes have creds.

## PS-GRAPHICS-STACK (2026-08-13): X11 achievable, Wayland/Vulkan/GDM need kernel DRM/KMS
Honest assessment of the graphics stack on illumos:
BUILT + durable: full X11 CLIENT library graph (~20: libX11/libxcb/xorgproto/libXext/libXrender/libXft/
  libXi/libXrandr/libXcursor/libXfixes/libXcomposite/libXdamage/libXinerama/libXtst/libxkbcommon/
  xtrans/libXau/libXdmcp/libICE/libSM) + GTK deps (glib/cairo-X/pango-X/gdk-pixbuf/harfbuzz/graphene/
  at-spi2/fontconfig/freetype).
NEXT (achievable, X11 path -- illumos SUPPORTS Xorg): 
  - gtk3/gtk4: blocked on libepoxy->libglvnd (Solaris ld rejects GNU --version-script; fixable: no-GL
    gtk3 OR route libglvnd link through GNU ld) + a toml-hash shim crack. A few cracks out.
  - Xorg SERVER: buildable on illumos (illumos ships Xorg via the xsvc/kernel-framebuffer path, NOT
    DRI/DRM). Needs pixman(done) + libdrm-FREE build (illumos has no libdrm) + the illumos video
    drivers (already in-kernel). This is the realistic desktop target: Xorg + a WM/DE over X11.
FUNDAMENTALLY HARD (kernel-level, multi-year, NOT package ports):
  - Wayland: needs GBM + DRM/KMS (/dev/dri, drm_* ioctls). illumos has NO DRM/KMS subsystem. wayland
    libs won't have a working backend without a kernel DRM port. wlroots/compositors likewise.
  - Vulkan / Mesa DRI / libGL: need a DRI driver + KMS. illumos GPU is Xorg-2D via kernel FB, no DRI.
    (Mesa softpipe/llvmpipe SOFTWARE rendering MIGHT build for GL-without-GPU, worth a probe, but not
    hardware-accelerated Vulkan.)
  - GDM / display-manager: needs systemd-logind + DRM. On illumos the path is XDM/a-SMF-launched Xorg,
    not GDM. 
STRATEGY: pursue the X11 desktop (Xorg server + GTK-over-X + a lightweight WM/DE). Wayland/Vulkan/GDM
are explicitly OUT until (if ever) illumos gains DRM/KMS -- document as a known non-goal for the
current era. A software-Mesa (llvmpipe) probe is the only near-term GL option.

## PS-GRAPHICS-STACK SUPERSEDED (2026-08-13): Wayland/Vulkan/COSMIC ARE achievable via NetBSD DRM
Correction: the earlier "Wayland/Vulkan/GDM = permanent non-goal (illumos has no DRM/KMS)" was too
pessimistic. NetBSD has a working, maintained Linux-DRM compat layer (src/sys/external/bsd/drm2 /
drmkms) running Mesa DRI on real GPUs -> an illumos DRM/KMS port is a PORTING problem with a proven
BSD reference (same pattern as the ena NIC crib from FreeBSD), not a from-scratch wall. Full phased
plan in docs/design-desktop-and-local-ai.md: G0 X11 desktop + llama.cpp-CPU (now) -> G1 DRM/KMS shim
(crib NetBSD drmkms, keystone) -> G2 Mesa/GBM -> G3 Vulkan (lavapipe SW first) -> G4 Wayland/wlroots/
smithay+XWayland -> G5 COSMIC + seatd greeter. Target: COSMIC DE + local LLMs (llama.cpp CPU near-term,
GPU once Vulkan lands; ollama needs Go). Exposed prereqs to track: Rust toolchain (COSMIC + LLM tools),
Go toolchain (ollama), seatd (logind replacement), libinput+evdev shim, a NetBSD-current source mirror
as the DRM crib. G0 + llama.cpp-CPU ship a usable graphical + local-AI solnix without the deep kernel
work; G1 unlocks the rest.

## Wave 31 (scientific) +34 + 3 strategic blockers surfaced (2026-08-13, fred v3)
+34 published (fftw/cgal/geos/hdf5/netcdf/boost[icu-free]/nlopt/pari/primesieve/cfitsio/wcslib/matio/
xtensor/xsimd/nanoflann/highs/osqp/coin-utils/mpdecimal/libmpc/gf2x/fplll/cddlib/symmetrica/cliquer/
lrcalc/bliss/libhomfly/nfft/librttopo/geographiclib/libnova/spectra). 0 failed. Registry climbing.
THREE strategic blockers (each gates a cluster -- worth dedicated ports):
1. GFORTRAN on illumos (MISSING): openblas hard-requires it + throws at eval -> blocks the whole BLAS
   cluster: openblas/flint/arb/symengine/superlu/clp/cbc/armadillo/blaze/ceres/sundials/lapack. A
   gfortran (gcc's fortran front-end) build for x86_64-solaris would unlock all of these + is needed
   for scientific Python (numpy/scipy) too. HIGH-VALUE port.
2. python3 C-ext symbol-export gap: cpython builds to 99% then fails linking a C-extension .so
   (_queue.cpython-314.so: undefined libpython symbols). An illumos shared-module symbol-export issue
   (the -z defs / export-dynamic / libpython linkage). Blocks kissfft/clipper/proj + the whole
   python3Packages C-ext class + gates a LOT (this is why wave19/32 python C-ext are fragile). Worth a
   focused cpython-illumos-linkage fix.
3. icu4c: genrb U_INVALID_FORMAT_ERROR (data build) -- gcc issue. Blocks libqalculate + full-ICU boost.
   Dodged via enableIcu=false where possible. Known individual port.

## PS-METAL-BOOT (2026-08-14): solnix v3 image doesn't boot on EC2 metal firmware
The DRM runtime proof needs /dev/kvm (only EC2 *.metal has it). Launched m6i.metal (us-east-1) with a
legacy-BIOS AMI (metal rejected the UEFI AMI). Result: SystemStatus=impaired, console stuck at the AWS
metal firmware POST countdown -- illumos LOADER NEVER RAN. Root cause: EC2 metal uses REAL UEFI/BIOS
firmware that differs from the Nitro-VM BIOS emulation the regular m5.4xlarge fleet boots on; the
solnix v3 image's loader is validated for the Nitro-VM path, not the metal firmware. Terminated after
~2.5h (cost hygiene; it never booted).
IMPLICATION: the DRM RUNTIME proof (modload the C1 drm module + QEMU virtio-gpu + KVM) is blocked on a
metal-boot-capable solnix image, which is its own loader/boot-path port (same class as the ena
cold-boot work). Options: (1) port the solnix loader for EC2 metal firmware (real work); (2) LOCAL
HARDWARE -- an x86 box w/ a GPU is the truest runtime+GPU target + avoids the metal-firmware issue;
(3) DEFER runtime -- the C1a-d + C2 + C3a stack COMPILES (the hard de-risk is done); runtime validation
is a separate boot+debug phase, best on local hw or after the metal-boot loader port.
NOTE: nested KVM on a regular EC2 VM is NOT an option (only metal exposes /dev/kvm). So EC2 runtime =
metal = needs the loader port. The compile-complete stack is the correct + valuable current milestone;
runtime GPU is gated on a boot-capable image on real (metal or local) hardware.

## PS-METAL-BOOT CONFIRMED (2026-08-14): both m6i.metal AND c5n.metal fail identically
Follow-up to PS-METAL-BOOT: tried c5n.metal (legacy-bios, classic Nitro firmware -- the maintainer's
suggested type) with the BIOS AMI. SAME result as m6i.metal: SystemStatus=impaired, empty console
(POST-stuck), illumos loader never ran, no SSH. Terminated (cost). CONCLUSION: the solnix v3 image
does not boot on EC2 metal firmware on EITHER metal generation -- a real illumos-loader-on-EC2-metal
gap, not instance-specific. The image boots fine on the regular Nitro-VM fleet (BIOS emulation) but the
bare-metal firmware path differs. EC2-metal runtime (the only EC2 /dev/kvm source) is GATED on a loader
port for EC2 metal firmware -- a distinct boot-path effort (ena-cold-boot class). The compile-complete
GPU stack (C1a-d kernel + C2 Mesa + C3a Venus/virgl) is unaffected + is the correct current milestone;
the DRM RUNTIME proof needs either (a) the EC2-metal loader port, or (b) LOCAL x86+GPU hardware (the
truer real-GPU-parity target). Recommend deferring EC2-metal runtime in favor of local hw for the real
GPU proof, and continuing compile-phase (C3 amdgpu scaffolding, llama.cpp-Vulkan build, R-P20+, breadth).

## PS-METAL-BOOT DEEPER (2026-08-14): installboot fix applied, metal STILL won't boot
Applied the real installer-bug fix (installboot stage1+stage2 on the ZFS pool slice s1, not the ESP s0
-- solnix-install was wrong; committed) + registered a legacy-bios metalboot AMI + launched c5n.metal
with the FIXED image. Result: STILL impaired, console COMPLETELY EMPTY (not even the AWS POST countdown
the earlier attempts showed) after ~20min. Terminated. 
So: 3+ metal attempts (m6i UEFI-reject, m6i BIOS impaired-POST, c5n BIOS impaired-POST, c5n FIXED-image
impaired-empty-console) all fail. The installboot fix was CORRECT + necessary (real bug, helps local
BIOS installs) but is NOT sufficient for EC2 metal. The empty console suggests EC2 metal's serial-console
capture and/or the illumos BIOS chain on metal firmware needs more than the pool-slice stage2 -- this is
a genuine multi-step illumos-on-EC2-metal boot port (SeaBIOS/CSM PMBR handling, serial console routing,
possibly the ena/nvme timing on metal), NOT a one-fix task.
DECISION: STOP burning metal on trial-and-error (~$4/hr, 4 attempts). EC2-metal runtime is a real port
effort. The RUNTIME GPU proof should target LOCAL x86+GPU HARDWARE (the true parity target anyway --
real GPU, real measurement, avoids the EC2-metal-firmware rabbit hole entirely). The compile-complete
GPU stack (C1a-d + C2 + C3a + C4-Vulkan) is the correct EC2-side milestone; runtime + real-GPU parity
is a local-hardware activity. EC2-metal-boot remains a documented backlog item (not the critical path).

## PS-GPU-QUOTA (2026-08-14): fred GPU quota auto-DENIED, needs a human support case
GPU (G-instance) quota on the fred account: requested 8 vCPU (L-DB2E81BA "Running On-Demand G and VT").
us-east-1 CASE_CLOSED after ~1h with quota still 0.0 = AUTO-DENIED (new account, no GPU usage history ->
AWS declines automated G-instance quota). Re-requested all regions (PENDING) + spot-G (L-3819A6DF).
ROOT: AWS does NOT auto-grant GPU quota to a fresh burner account -- it needs a MANUAL SUPPORT CASE
(console: Support -> Create case -> Service limit increase -> EC2 G instances, with a workload
justification). That is a human/console step the CLI can't do. => GPU RUNTIME on EC2 g4ad is gated on
the maintainer filing/approving that support case (or providing an account with GPU quota, or local
x86+GPU hardware). The amdgpu driver (device+TTM+rings compile) + the full accelerated stack are ready;
runtime (C3-amdgpu-d: firmware/power-up + live register programming) needs the real GPU behind that quota.
ACTION FOR MAINTAINER: file the EC2 G-instance quota support case on fred (or point at GPU hardware).


## PS-GPU-QUOTA CORRECTION (2026-08-14): the CLI DID file a real support case
Earlier claim ("can't file the GPU-quota support case from the CLI") was WRONG. `aws service-quotas
request-service-quota-increase` DOES open a real AWS support case: the current request is
Status=CASE_OPENED, CaseId 178672793100327 (us-east-1, L-DB2E81BA=8). It is in AWS's active review now.
The earlier CASE_CLOSED was a too-fast first attempt (closed ~1h, likely auto-triage on a fresh account).
So GPU quota is PROPERLY REQUESTED + PENDING AWS review -- monitor `list-requested-service-quota-change-
history`; when it flips to APPROVED/quota>0, launch g4ad + run the C3-amdgpu-d hardware checklist.
(Adding justification correspondence via the Support API needs a Business+ support plan; the quota case
proceeds through AWS review regardless.) No manual maintainer action strictly required -- just AWS review
time (GPU on a new account can take hours-days); local x86+GPU hw remains the faster alternative.

## PS-PYTHON3-CEXT CRACKED (2026-08-15, wave38): the central breadth bottleneck is DONE
python3 3.14.6 now builds with WORKING C EXTENSIONS on x86_64-solaris: import _queue (cpython-314.so),
ctypes, ssl (OpenSSL 3.6.3), sqlite3 (3.53.3) all succeed -- the illumos shared-module symbol-export gap
that blocked the whole python3Packages C-ext class is FIXED. Full cmake-4.3.4 also built (not just
cmakeMinimal). This unblocks the large python3Packages C-ext class + the full-cmake graph. NEXT: wire
gfortran through the gcc14 path (the fork's gfortran routes through gcc15 which isn't illumos-wired) so
numpy/scipy build on the (already-built) gfortran+openblas -- numpy is the marquee follow-on. Register
the python3Packages C-ext wave once numpy lands.

## PS-AARCH64-WAVE2 (2026-08-15): +6 pkgs, 2 cross fixes, 2 strategic blockers
aarch64 cross re-established on fred; +6 EM_AARCH64 host-free pkgs (libidn2/pcre/popt/lzo/libatomic_ops/
libpipeline, published). TWO cross-wide fixes (baked into entry-aarch64-wave.nix staticFix, applied
per-pkg to avoid rehashing the done-35): (1) unset GCC_EXEC_PREFIX (the x86 native cc setup-hook poisons
the cross gcc's cc1 search -> posix_spawnp fail); (2) --disable-shared --enable-static (the documented
GNU-ld Solaris-libgcc-mapfile wall). TWO strategic blockers gating the bigger aarch64 wave:
1. NATIVE gettext-1.0 (x86 build platform) configure conftest links -lmd/-lmp/-luutil/... with no -L ->
   "C compiler cannot create executables" (a native-build/solaris-overlay plumbing bug). Gates every
   autoreconf/gettext consumer: oniguruma/sqlite/libgpg-error/libgcrypt/libassuan/libedit/libsodium/
   libtasn1/nettle. FIX: add the extra-syslibs -L to the native gettext-1.0 build (same class as the
   x86 extra-syslibs fix).
2. cross pkg-config-0.29.2 internal-glib sub-configure fails -> gates nghttp2/json-c/snappy/c-ares/
   xxHash/brotli. + openssl-cross needs a Perl Configure target (aarch64-unknown-solaris2.11) -> gates
   curl/git/libssh2/libarchive/libpsl. C++ (nettle/gmp-cxx) hits the mapfile wall even for executables
   (g++/unwind not viable through GNU ld -> needs the seed gcc rebuilt w/ Solaris ld, the deep fix).

## PS-AARCH64-WAVE3 (2026-08-15): gettext -L crack -> +9 crypto/core aarch64 pkgs
Cracked the native gettext -L blocker (headline) + pkg-config-cross (same crack): the cross entry's
buildPackages illumos-cc-10.5.0 cc-wrapper predates the x86 H6 fix (no -L${seedSyslibs}/lib/amd64);
gettext-1.0's runtime sub-configure links -lmd/-lmp/-luutil/... with no -L -> "cannot create
executables". FIX (gettextSyslibsOverlay, entry-aarch64-wave3.nix): inject -L${extraSyslibs}/lib/amd64
(the seed-sourced FOD w/ bare .so links) into native gettext + pkg-config NIX_LDFLAGS + pin NM to the
GNU-format FOD nm. Also the -fPIE -pie crack (defeats the aarch64 GNU-ld copy-reloc-against-protected
wall on executables -> unblocked gawk). +9 EM_AARCH64 pkgs published (49 paths, 0 failed): oniguruma,
sqlite, libgpg-error, libtasn1, libsodium, libedit, libgcrypt, gawk, m4 (+ native gettext/pkg-config
build tools). aarch64 now ~42. Remaining: nettle (gmp-cxx C++ mapfile wall), gettext-target/libassuan
(bash->readline SHARED-lib mapfile wall) -- both need the seed gcc rebuilt w/ Solaris ld (the deep C++/
shared-lib fix), OR static-only variants.

## PS-AARCH64-WAVE4 (2026-08-15): openssl Perl-target crack -> +9 net/TLS (curl!)
Cracked openssl-cross: openssl 3.6.3 had no solaris64-aarch64 target + nixpkgs' configureScript map
lacked aarch64-solaris. FIX: (1) nixpkgs openssl/default.nix aarch64-solaris = ./Configure
solaris64-aarch64-gcc; (2) Configurations/55-solaris-aarch64.conf (crib solaris64-x86_64-gcc's
solaris-common -lsocket/-lnsl/-ldl + linux-aarch64 asm profile aarch64.S/bsaes). +9 EM_AARCH64 pkgs
published (80 paths, 0 failed): openssl, CURL (marquee, host-free), nghttp2, libssh2, libidn2, libxml2,
libyaml, expat, npth. aarch64 now ~64. New cracks (entry-aarch64-wave4.nix): staticSharedOverlay
(--disable-shared transitive), socketFix (aaSeedL -lsocket/-lnsl/-lmd/-lmp), pieFix (-fPIE compile-only
defeats the copy-reloc-against-protected wall), curlMinimal (drop libpsl->gtk-doc->broken py env).
REMAINING aarch64 ceiling: (1) NATIVE cmake C++ bootstrap wall (x86_64-solaris g++ can't build
cmake-minimal) -> gates zstd/lz4/json-c/jansson/brotli/snappy/c-ares (the cmake data/compression class);
unblocking native cmake opens that class. (2) cross bash (netopen.c internal_error illumos port) ->
gates libassuan/target-gettext. (3) C++ mapfile wall (nettle/gnutls need gmp-cxx) -> needs seed gcc w/
Solaris ld. The net/TLS + crypto cores are now DONE on aarch64 -- a usable base userland cross-builds.

## PS-NUMPY (2026-08-15): wiring PROVEN, 3 walls fixed, unattended build running
numpy retry: the FC=gcc14-gfortran (langFortran=true, NOT the gcc15-routed gfortran attr) + BLAS=openblas
(gcc14Stdenv) wiring is CORRECT + evaluates (in tranche-entry-224.nix). numpy has NOT landed (correcting a false-positive glob match on a .drv; the build was still in configure: gcc14->openblas->numpy). Three real build-tool/toolchain walls
fixed this session: (1) ninja illumos fork/execvp patch regenerated against the post-first-patch
baseline (ninja BUILT r6kl2n9k); (2) meson-python noCheck (patchelf absent, BUILT fwng8m8a); (3) THE
key one -- gcc14 libgfortran kinds.h empty: libgfortran/configure hardwires AM_FCFLAGS -Werror + the
seed cc-wrapper feeds a nonexistent -I<bootstrapLibs>/include -> -Wmissing-include-dirs+-Werror fails
every kind probe -> empty kinds.h. FIX (gcc14.nix FIX 5): sed -Wno-missing-include-dirs into BOTH
configure AND configure.ac (autoreconf regenerates configure). cython BUILT (61l18900). Handoff:
/root/numpy-handoff.md + /root/numpy-paths.txt. RESUME: poll the running build; when numpy lands,
publish + register + build scipy (same wiring). The wiring was never the blocker -- 3 build-tool bugs
were, all now fixed.


## PS-NUMPY CORRECTION (2026-08-15): numpy NOT built (false-positive corrected)
A glob (ls *numpy*/lib) matched a .drv-adjacent path -> I briefly + wrongly reported "NUMPY LANDED".
Ground truth: only numpy-2.5.1.DRV files exist (from wiring iterations); the output
lq4i84bqmh5pmhycvkry2l298lzrn48z-numpy-2.5.1 is NOT realized -- the build was still in configure. The
WIRING is proven (drv evaluates) + the 3 walls fixed + cython/ninja/meson-python built, but numpy the
OUTPUT isn't built. Re-launching numpy as a DETACHED nix-build (nohup + done-marker + poll -- the
death-resilient long-build pattern) rather than an interactive agent (which hit context limits twice on
this multi-hour gcc14->openblas->numpy chain). Poll the marker; publish+register when the output realizes.

## PS-AARCH64-WAVE5 (2026-08-15): native-cmake wire -> +11 compression/data class
Cracked the native-cmake wall by WIRING the cross build-platform cmake to the WORKING x86 cmake-minimal
(6kg8h3gl...-cmake-minimal-4.3.4, built by the x86 fixed tranche) via a cmakeWireOverlay in the native
overlay list -- cross pkgs use a functioning native cmake instead of rebuilding the broken one. +11
EM_AARCH64 pkgs published (39 paths, 0 failed): zstd/lz4/brotli/snappy/json-c/jansson/xxhash/libdeflate/
zlib-ng/c-ares/minizip. aarch64 now ~92. Cracks: pcre2/readline forced-static, gnugrep/bash->buildPackages
(dodge the aarch64-bash netopen wall), CXX-probe bypass (CMAKE_CXX_COMPILER_WORKS -- cmake project()
enables CXX + the cross g++ link hits the unwind-map wall) for C-only libs. THE remaining aarch64 ceiling:
the cross C++ mapfile/unwind-map wall (libgcc-unwind.map file-format-not-recognized) blocks any genuinely
C++ pkg that links a C++ executable/shared lib -> needs the seed gcc rebuilt with a Solaris-ld-compatible
unwind spec (the deep toolchain fix). aarch64 now cross-builds: coreutils + crypto + net/TLS(curl) +
compression/data -- a substantial base userland. Wave5 entry -> fork.

## PS-NUMPY DEFERRED (2026-08-15): NOT built -- override rehashes gcc14 into a failing rebuild
FINAL honest status after multiple multi-hour attempts: numpy is NOT built. Root cause of the last
failure (detached build, exit 100): the numpy override chain -- openblas.override{stdenv=gcc14Stdenv} +
python3Packages.overrideScope under gcc14Stdenv -- REHASHES gcc14 to a DIFFERENT gcc-wrapper-14.4.0.drv
(kw0hs6bw...) that rebuilds gcc14 from scratch and FAILS, cascading to blas/lapack/openblas/numpy. The
already-BUILT working gcc14 (k22k41z8q051gjxw5ysycbzwlpg1b1sn-gcc-14.4.0) + openblas
(yc302a4v...-openblas-0.3.33) are in-store, but the override doesn't REUSE them -- it re-derives.
THE FIX (bounded, for a future focused pass): pin the numpy/openblas override to REUSE the exact
built store paths (import them via builtins.storePath / a fixed cc, don't override stdenv in a way that
rehashes gcc14). i.e. build numpy against the pre-built openblas (yc302a4v) + the pre-built gcc14
(k22k41z8) as literal inputs, so nothing re-derives. What DID land: python3-cext (working), full cmake,
cython, ninja, meson-python, gfortran (k22k41z8), openblas (yc302a4v), + the 3 wall-fixes (ninja patch,
meson-python noCheck, gcc14 libgfortran -Werror/kinds.h). numpy DEFERRED -- the wiring is proven, the
remaining work is store-path-pinning the override so it stops re-deriving gcc14. Not claiming numpy built.

## PS-AARCH64-WAVE6 (2026-08-15): +17 userland incl a working shell (oksh)
+17 EM_AARCH64 C-only pkgs (200 paths published, 0 failed): oksh (WORKING aarch64 ksh -- the userland
headline), gnugrep/gnused/diffutils/gnupatch/which/file, gzip/bzip2/gnutar/cpio, jq(+oniguruma static),
wget(openssl TLS)/rsync/socat, nano, libevent. THE big unblock: crossBashOverlay (bash/runtimeShell ->
native buildPackages.bash) kills the target-bash netopen.c-wall drag that blocked EVERY patchShebangs
pkg. + pieFix (-fPIE dodges the copy-reloc-against-protected-libc-symbol wall), staticShared for
pcre2/oniguruma/readline/libedit/xz. aarch64 now has a USABLE userland: shell(oksh) + coreutils + text +
net(wget/rsync) + compression + jq + nano. Remaining: dash/mksh/tmux/findutils (various illumos/source
issues), + the C++ mapfile/unwind wall (caps all C++ pkgs -- the one deep fix: seed gcc w/ Solaris ld).
NOTE: wave5's cmakeWireOverlay + wave6's crossBashOverlay are the two key cross-userland enablers;
entry-aarch64-wave6.nix is the current base (built on wave4; wave5 cmake-wire should be folded in if not).
