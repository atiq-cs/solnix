# solnix

A distribution of **illumos** built entirely with the **Nix** package manager and
the **NixOS module system** — the illumos analog of [NixOS] (Linux) and
[nixbsd] (FreeBSD/OpenBSD).

Describe an illumos machine declaratively in Nix; get a bootable, atomically
upgradeable, rollback-capable system backed by ZFS boot environments.

> **Status: planning / Phase 0.** No bootable system yet. This repo currently
> holds steering docs and the foundation spec. See the honest architecture and
> risk assessment below before assuming anything works.

## Why

illumos-gate is fully buildable from source today, ships ZFS + zones + bhyve +
LX-branded zones, and already has a native atomic-upgrade story (`beadm` boot
environments). Nix's immutable store + generation model maps cleanly onto that.
solnix marries the two.

## How (architecture in one breath)

Reuse NixOS's evaluator and module system verbatim; add an `*-illumos` platform
and a fine-grained `pkgs.illumos.*` world to a nixpkgs fork; drive services
through **SMF** (not systemd) via an `smf.services.*` module; bake `/nix/store`
paths into ELF RUNPATH with the **Solaris link-editor** (no GNU tooling); map each
Nix generation onto a **ZFS boot environment**. This is nixbsd's playbook,
retargeted to illumos.

## Architecture support (honest)

| Arch | Status | Phase |
|------|--------|-------|
| x86_64 (amd64) | Primary target | 1 |
| aarch64 | Out-of-tree illumos port exists; integrate it | 3 |
| SPARC v9 (sun4v) | Bit-rotting in-gate; revive with fork patches | 4 |
| RISC-V | No illumos port exists yet — research/upstream track | 5 |

Details and the rule against over-claiming: `.kiro/steering/architectures.md`.

## The two big risks

1. **Bootstrap must start on illumos.** illumos-gate does not cross-build from
   Linux; a stage0 must run on an illumos host before Nix can take over.
2. **SMF is deeply wired** into userland — it's the init system, not a swappable
   component.

## Repo map

- `flake.nix` — entry; `lib.solnixSystem`, `solnixConfigurations.*`, image
  `packages`. Parses today; full eval needs the nixpkgs fork (not yet).
- `lib/eval-config.nix` — solnix's forked NixOS evaluator entrypoint (skeleton).
- `modules/` — the module tree: `system/boot/init/smf.nix` (SMF init),
  `nixos-compat.nix` (systemd.* stubs), `module-list.nix`.
- `configurations/base.nix` — the Phase-1 target sample config (skeleton).
- `.kiro/steering/` — always-on project rules (product, architectures, illumos
  domain knowledge, Nix conventions). **Read these first.**
- `.kiro/specs/solnix-foundation/` — requirements / design / tasks for Phase 0–1.
- `docs/roadmap.md` — the phased plan and "done" gates.

## Prior art

- [nixbsd] — the FreeBSD/OpenBSD sibling we copy.
- illumos forks: OpenIndiana, OmniOS, SmartOS, Tribblix, DilOS.

[NixOS]: https://nixos.org
[nixbsd]: https://github.com/rhelmot/nixbsd
