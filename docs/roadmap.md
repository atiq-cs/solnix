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
