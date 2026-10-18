# Development Environment

Where and how solnix work happens. Always-on operational context.

## Two hosts, two roles

| Host | Role | Notes |
|------|------|-------|
| **AWS EC2 (`numa` profile)** | Primary dev + build substrate | Account `<ACCOUNT-REDACTED>`, region **us-east-2**. Burner dev account, no cost concerns — but still terminate idle instances (hygiene, not thrift). |
| **Maintainer's Sun UltraSPARC (home)** | SPARCv9 boot-test hardware | Runs OpenIndiana Hipster 2025.06 (illumos-31d3d510d0). For Phase 4 only. |

## AWS access

```bash
export AWS_PROFILE=numa            # static creds in ~/.aws/credentials, region us-east-2
aws sts get-caller-identity        # expect user/numa, account <ACCOUNT-REDACTED>
```

If creds expire, refresh per `~/.kiro/steering/aws-builder.md` (Isengard/ada) —
but the current `numa` profile uses static keys and works directly.

**Tag every resource** launched: `Owner=gregburd`, `Purpose=solnix-dev`,
`Expiry=<date>`. Terminate instances when idle. See the `aws-benchmark` skill for
the launch → tune → terminate workflow (we reuse its EC2 substrate, not its
benchmark specifics).

**Scope of the `numa` account: EC2 dev/build COMPUTE only.** Do NOT use the
`numa` AWS account for **asset storage** — no AWS S3 buckets for the seed,
packages, or images. `numa` is a burner for spinning up build hosts; nothing
durable is stored there (it also lacks S3/create-bucket perms by org policy).

**Asset storage = solnix.io's S3-compatible endpoint (when available).** solnix.io
will provide an **S3-protocol endpoint** for durable assets — the seed toolchain,
the binary cache (`pkgs.illumos.*`, images), etc. This is the standard Nix
binary-cache pattern: publish with `nix copy --to 's3://<bucket>?endpoint=<solnix.io endpoint>&region=...'`
and serve as a substituter. It speaks S3 but is **not** AWS S3 — point the
endpoint at solnix.io, use solnix.io credentials, never the `numa` profile.
Until the endpoint exists, assets stay on the EC2 build host and are
re-extractable via the committed scripts.

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

- Remote: `ssh://git@codeberg.org/solnix/solnix.git` (`origin`), branch `main`.
- **Push as work progresses** (maintainer's standing instruction). Small, coherent
  commits; present-tense imperative subject ≤72 chars; body explains *why*.
- Never force-push, never rewrite pushed history, never push to `main` on shared
  repos without cause. (This is the maintainer's own repo — normal push to main
  is fine here.)

## Binary cache & channels (solnix.io — LIVE)

The binary cache / substituter is **live** at solnix.io's S3-compatible endpoint
(the solnix analog of `cache.nixos.org`) so users and CI don't rebuild the world.

- **Substituter URL (consumers):** `https://s3.solnix.io/solnix-cache`
  (path-style, plain HTTPS, no credentials for reads — a standard Nix binary
  cache: `nix-cache-info` + `<hash>.narinfo` + `nar/*.nar.xz`).
- **Trusted public key:** `cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=`
  (secret half in `secrets/cache-signing.yaml`, sops-encrypted to the repo age key).
- **Baked into `configurations/base.nix`** (`nix.settings.substituters` +
  `trusted-public-keys`) so installed systems pull binaries by default.
- **Publish side:** `scripts/oi-cache-publish.sh` — signs + copies illumos store
  closures to the cache. Reads S3 creds (`secrets/s3-cache.yaml`) + the signing
  key from sops **in-shell**; never writes creds/secret to disk. See
  `docs/cache.md` for the layout, URL form, and the Nix-2.3.16 S3 gotcha.

- **Channel model:** `unstable` is the only channel for now (rolling, like
  nixos-unstable), until we can qualify a tagged release. Name flake outputs and
  docs so a future `stable`/release channel slots in without renaming.
- **Publish (asset side):** the store lives on solnix.io's S3 endpoint
  (`s3://solnix-cache`, endpoint `https://s3.solnix.io`, `us-east-1`, path-style).
  Publish with solnix.io credentials, **NOT** the AWS `numa` profile.
- **What gets cached:** the `pkgs.illumos.*` world, stdenv/bootstrap, and image
  closures — the expensive-to-build artifacts. Published so far (T2.3): the
  bootable `illumos-system-path` closure (libc/rtld/ld/external-libs/base-tools/
  sys/system-path) and the `illumos-gate-proto` seed FOD.
- **Reproducibility is the contract:** cache hits require deterministic
  derivations — keep builds pure/pinned (fixed nixpkgs-fork rev, pinned illumos
  source commit) so a cached artifact is byte-identical to a local rebuild.
- **CI publishes to the cache:** the eventual build farm signs + pushes on
  `unstable`. Today `scripts/oi-cache-publish.sh` does it from the dev box.

## Reproducibility rule

Anything done on an EC2 host that matters (illumos build, seed extraction, Nix
setup) must be captured as a script or documented steps committed to this repo —
not left as a pet instance. Instances are cattle; the recipe is the asset.
