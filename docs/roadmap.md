# solnix Roadmap

Phased plan. Each phase has a single, testable "done" gate. Do not start a phase
before the previous gate is green. Architecture scope per phase is governed by
`.kiro/steering/architectures.md` (amd64 first, always).

The North Star: a user describes an illumos machine in a Nix module and gets a
bootable, upgradeable, rollback-capable system — for everything illumos-gate and
its forks offer.

---

## Phase 0 — Foundations & de-risking (research + prototype)

Prove the two things that can kill the project before investing in breadth.

- **P0.1 Stage0 spike.** Stand up an illumos build host (OmniOS/OpenIndiana VM or
  zone). Build illumos-gate the normal way (`nightly.sh`). Confirm we can produce
  a proto area + toolchain we can feed to Nix. *This is the highest-risk item —
  do it first.*
- **P0.2 Nix-on-illumos spike.** Get `nix` building/running on the illumos host
  (expect a nix fork, à la nixbsd's cppnix). Build one trivial derivation.
- **P0.3 RUNPATH spike.** Prove we can bake `/nix/store` RUNPATHs with the Solaris
  linker and inspect with `elfdump` — no GNU tooling. One linked binary that
  resolves its libs from the store.

**Gate:** a hand-built Nix derivation on illumos links against a store libc and
runs. Documented reproducibly.

---

## Phase 1 — Minimal bootable amd64 system

The nixbsd "base VM" milestone, amd64 only.

- **P1.1** Add `x86_64-illumos` platform to the nixpkgs fork; bootstrap stdenv
  with the seed toolchain from Phase 0.
- **P1.2** `pkgs.illumos.*`: fine-grained world — `libc`, `sys` (kernel + genunix),
  Solaris `ld`, `ld.so.1`, the base tools needed to boot to multi-user.
- **P1.3** Fork NixOS `eval-config.nix`; stand up the module tree; `nixos-compat`
  stubs.
- **P1.4** `smf.nix` init module: generate + import SMF manifests/methods; boot to
  the `multi-user` milestone.
- **P1.5** `make-be.nix` / image builder: produce a ZFS-root image with a boot
  environment and the illumos `loader`.
- **P1.6** Cross-build the image from a Linux builder.

**Gate:** `configurations/base` builds an image on Linux, boots in QEMU to the
`multi-user-server` SMF milestone, `svcs` is clean, and a smoke test passes.

---

## Phase 2 — Usable amd64 distribution

Make it a system you'd actually run.

- **P2.1** Generation ↔ boot-environment mapping: `switch-to-configuration` +
  `beadm` activate/rollback. Prove rollback boots the previous generation.
- **P2.2** Installer + install ISO/live media; `nixos-install` analog.
- **P2.3** Networking (illumos `dladm`/`ipadm`), users/groups, SSH, and the common
  service modules ported from nixos via `extPath` where possible.
- **P2.4** Package breadth: get a meaningful slice of illumos userland +
  common third-party software building. Track "everything illumos" as a set.
- **P2.5** Substituter/binary cache so users aren't forced into >8h builds.

**Gate:** install solnix to disk from media, reboot into it, `nixos-rebuild`-style
switch, and roll back — all on amd64 hardware/VM.

---

## Phase 3 — aarch64

Integrate the out-of-tree aarch64 illumos port (Hayashi Naoyuki) as a source
input; wire `aarch64-illumos` to a real toolchain; boot on QEMU/RPi. Contribute
fixes upstream. Gate: base config boots to multi-user on aarch64.

---

## Phase 4 — SPARC v9 (sun4v)

Revive the in-gate sun4v path, leaning on Tribblix/DilOS patches. Expect
toolchain/CTF pain. Boot on an emulator or real T-series. Gate: base config boots
to multi-user on sun4v.

---

## Phase 5 — RISC-V (research track)

There is no illumos RISC-V port today. Deliverable is either an upstream
port effort or a documented out-of-scope decision — **not** a Nix packaging task.
Do not represent RISC-V as "supported" until an OS exists to package.

---

## Feature backlog (arch-independent, slot into P2+)

Zones · bhyve · LX-branded zones · OpenZFS feature-flag parity · KVM (verify
availability) · fork feature parity (OmniOS/OpenIndiana/SmartOS/Tribblix).

## Guiding rule

One architecture, one init backend, one image type, fully working end-to-end
beats four half-wired ones. Breadth after depth.

---

## Phase 1 de-risking update (2026-07-23)

Design research (docs/design-nixpkgs-illumos.md) found nixpkgs **already ships
Solaris scaffolding** — `kernels.solaris`, `isSunOS`, `x86_64-solaris` double,
`illumos` doubles group, `ld-solaris-wrapper.sh`, and gcc solaris configure
flags. So P1.1 (platform tuple) is a *small diff extending existing code*, not
greenfield. Canonical tuple decided: **`x86_64-solaris`** (triple
`x86_64-unknown-solaris2.11`), "illumos" branded at the attribute layer.

The main Phase-1 novel work is therefore: (a) a *pure* stdenv path from our seed
(stock nixpkgs selects impure-native `stagesNix` for x86_64-solaris today),
(b) the `pkgs.illumos.*` world, (c) RUNPATH-via-`elfedit`, (d) the SMF init
module (docs/design-smf-init.md).

---

## Post-stable backlog

Once Phase 1 (bootable) + Phase 2 (usable/self-hosting/cache) are done, see
**docs/post-stable-backlog.md** for the deferred work: recompile-with-clang,
Rust toolchain, libumem-as-default-allocator, latest GCC/GDB, lldb, and
desktop+server feature/fork parity.

---

## Phase 2.5 — Distributed cache, release 2026.08, published ISO

After the Phase-2 gate (installable/usable), see
**.kiro/specs/solnix-phase2.5-release/tasks.md**:
- **T2.11** Opt-in BitTorrent-backed distributed package cache: every solnix
  system can seed the store paths it holds + fetch missing ones from a secure
  peer swarm, signature-verified, falling back to solnix.io. Integrated into the
  installer (opt-in prompt), the packages (P2P daemon + SMF service), and a
  config module. Trust stays with cache signatures; peers only move bytes.
- **T2.12** Cut release **2026.08** (date-tagged; pin fork/gate/closure; publish
  signed to the unstable channel).
- **T2.13** Build the install **.iso**, smoke-test install-from-ISO, drop it in
  `../solnix.io/` for the site team to publish + advertise.

---

## Phase 3 — Breadth (parallel) + aarch64

Two big parallel tracks (specs added):
- **.kiro/specs/solnix-phase3-breadth/** — mirror the OpenIndiana Hipster package
  set for x86_64 (the master registry target), then cloud drivers (EC2/Azure/
  GCP), AI/LLM enablement (CPU-inference first; GPU is a hard long-horizon gap),
  OmniOS+SmartOS packages/features (bhyve/KVM/LX zones), core Solaris features
  packaged+configurable (Crossbow/Zones/LX-zones/bhyve/ZFS/DTrace), language
  runtimes (Perl/Python/TCL-TK/LuaJIT/Rust-via-official-or-crustc), and Wayland+
  desktop. All built with gcc-14 AND clang, signed to the cache. Massively
  parallel: fan out package batches across agents.
- **.kiro/specs/solnix-aarch64/** — bootstrap solnix on aarch64 by integrating
  the out-of-tree Hayashi Naoyuki illumos-aarch64 port (harder than x86_64; QEMU
  boot first). Runs in parallel; long track.

Honesty rule holds: GPU/Azure/GCP drivers, torch, full Wayland are real illumos
gaps — inventory realistically, build tractable paths first, flag multi-quarter
porting as tracked sub-projects.

## Community telemetry (opt-out-off, default-private) 2014 T2.14, LOWER PRIORITY

Client reporter feeding the live search.solnix.io/telemetry (aggregates at
solnix.io/pulse). Default `solnix.privacy.enable=true` = install nothing / send
nothing. Shares the privacy switch with T2.11 P2P seed. No PII; per-day rotating
nonce; SMF timer; best-effort. Land LATE in the publication run; never gates the
release. Full spec: docs/design-telemetry-client.md; task: solnix-phase2.5 T2.14.

## Cloud Hardware Enablement (spec: .kiro/specs/solnix-cloud-hardware)

Boot + run + expose ALL hardware on AWS/EC2, Azure, GCP across all architectures.
- **CH-1 ARM server kernel port** (GICv3/GICv3-ITS driver + aarch64 ACPI/SBBR
  parser + SystemReady-SR UEFI boot + SMMUv3) — prereq for ALL cloud ARM
  (Graviton/Cobalt/Axion). Upstream-first to arm64-gate/IPD 24. Long pole.
- **CH-2 AWS/Nitro** (ENA v5/v6, EFA, local NVMe, vIOMMU; + Graviton after CH-1)
- **CH-3 Azure/Hyper-V** (VMBus/hv_*/netvsc/storvsc/MANA; + Cobalt ARM) — biggest gap
- **CH-4 GCP/KVM** (gVNIC/IDPF/virtio; + Axion ARM)
- **CH-5 accelerators** (GPU/NPU enumeration; compute libs in T3.3)
- **CH-6** declarative cloud/hardware modules + per-cloud image builders
- **CH-7** per-instance device-audit CI matrix (pairs with PS-7)
- **CH-8** upstream collaboration (drivers land in illumos, not a solnix fork)
Mostly post-stable; x86 Azure/GCP driver work can start pre-stable to make solnix
a first-class guest on all three clouds' x86 before the ARM port lands.

## Builder federation (spec: .kiro/specs/solnix-builder-federation)

A daily, LLM-free builder that drains solnix.io's work queue and publishes through the
signed submit flow (contract and measured deviations: .kiro/steering/builder-queue.md).
- **B1** queue credential + contract alignment with the infra team: the queue's POSTs
  are gated by a shared secret, not the ed25519 builder identity; `manpage-missing` is
  not an allowed reason; GET returns counts only.
- **B2** `scripts/solnix-builder.py`: claim -> recipe -> nix build -> publish gate ->
  cache-submit.py -> complete, heartbeat on a thread; dry-run against a local queue.
- **B3** where it runs: bhost/EC2 OpenIndiana until the store-tool stdenv lands
  (docs/pending/builders-need-store-tools.md), then any solnix system from cron.
- **B4** the man-page corpus the infra team asked for: illumos-man (the gate's
  /usr/share/man, reviewed for solnix), coreutils + userland with man pages, distro
  pages where solnix ships that distro's tool.
- **B5** federation pieces that are ours (fetch shim, attestations) after the infra
  team's signed work-queue.json and reputation feeds.
