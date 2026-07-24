# Development Environment

Where and how solnix work happens. Always-on operational context.

## Two hosts, two roles

| Host | Role | Notes |
|------|------|-------|
| **AWS EC2 (`numa` profile)** | Primary dev + build substrate | Account `713545428937`, region **us-east-2**. Burner dev account, no cost concerns — but still terminate idle instances (hygiene, not thrift). |
| **Maintainer's Sun UltraSPARC (home)** | SPARCv9 boot-test hardware | Runs OpenIndiana Hipster 2025.06 (illumos-31d3d510d0). For Phase 4 only. |

## AWS access

```bash
export AWS_PROFILE=numa            # static creds in ~/.aws/credentials, region us-east-2
aws sts get-caller-identity        # expect user/numa, account 713545428937
```

If creds expire, refresh per `~/.kiro/steering/aws-builder.md` (Isengard/ada) —
but the current `numa` profile uses static keys and works directly.

**Tag every resource** launched: `Owner=gregburd`, `Purpose=solnix-dev`,
`Expiry=<date>`. Terminate instances when idle. See the `aws-benchmark` skill for
the launch → tune → terminate workflow (we reuse its EC2 substrate, not its
benchmark specifics).

## Two kinds of EC2 host we need

1. **illumos build host (stage0).** An OpenIndiana Hipster instance to build
   illumos-gate and produce the seed toolchain (see `illumos-domain.md` — the
   gate does not cross-build from Linux). OpenIndiana publishes cloud/AMI-capable
   images; if no ready AMI exists in us-east-2 we import one (VM Import/Export)
   or build on a nested VM. **Open task T0.1.**
2. **Linux (NixOS) builder.** For everyday Nix cross-builds of `x86_64-illumos`
   once stage0 has seeded the toolchain. A regular large `x86_64` instance;
   expect long builds + huge closures, so size disk generously.

## Git

- Remote: `ssh://git@codeberg.org/gregburd/solnix.git` (`origin`), branch `main`.
- **Push as work progresses** (maintainer's standing instruction). Small, coherent
  commits; present-tense imperative subject ≤72 chars; body explains *why*.
- Never force-push, never rewrite pushed history, never push to `main` on shared
  repos without cause. (This is the maintainer's own repo — normal push to main
  is fine here.)

## Binary cache & channels (planned: solnix.io)

A binary cache / substituter is coming at **solnix.io** (the solnix analog of
`cache.nixos.org`) so users and CI don't rebuild the world. Design toward this
from the start:

- **Channel model:** `unstable` is the only channel for now (rolling, like
  nixos-unstable), until we can qualify a tagged release. Name flake outputs and
  docs so a future `stable`/release channel slots in without renaming.
- **Substituter:** e.g. `https://cache.solnix.io` with a signing key. Bake the
  substituter URL + trusted public key into the base configuration's
  `nix.settings` so installed systems pull binaries by default.
- **What gets cached:** the `pkgs.illumos.*` world, stdenv/bootstrap, and image
  closures — the expensive-to-build artifacts. The seed toolchain (T0.3) and the
  gate-derived derivations are the first worth caching.
- **Reproducibility is the contract:** cache hits require deterministic
  derivations — keep builds pure/pinned (fixed nixpkgs-fork rev, pinned illumos
  source commit) so a cached artifact is byte-identical to a local rebuild.
- **CI publishes to the cache:** the eventual build farm signs + pushes to
  solnix.io on `unstable`. Until it exists, builds are local on the EC2 host;
  design outputs so switching to a `nix copy`/post-build-hook push is a config
  change, not a rearchitecture.

## Reproducibility rule

Anything done on an EC2 host that matters (illumos build, seed extraction, Nix
setup) must be captured as a script or documented steps committed to this repo —
not left as a pet instance. Instances are cattle; the recipe is the asset.
