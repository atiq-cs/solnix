# solnix editions: `unstable` + `26.11` (release model)

Mirror NixOS's two-edition model: a rolling **unstable** and a frozen dated
**stable**. NixOS is at `26.05` + `unstable`; solnix's first frozen stable
targets the same cadence as NixOS `26.11` (Nov 2026), so solnix `26.11` tracks
the nixpkgs `26.11` base.

## The two editions

| | **unstable** | **26.11** (stable) |
|---|---|---|
| What | rolling; what we build now | frozen dated release |
| nixpkgs base | moving pin (fork input, bumped forward) | pinned to nixpkgs `release-26.11` commit |
| solnix-pkgs patch set | HEAD | frozen at a git tag `v26.11` |
| cache | rolling (current flat pool) | namespaced, immutable after freeze |
| `system.stateVersion` | `"unstable"` | `"26.11"` |
| support | none (rolling) | backports/security only, ~7 months |
| audience | contributors, latest packages | production/reproducible installs |

**Today's work IS the `unstable` edition.** No renaming needed — the fully-Nix
rebuild, GATE 1b-PURE, the AMIs in progress, all become "solnix unstable". The
`26.11` edition is a *future freeze* of unstable once it's release-worthy.

## What a release freezes (the 6 knobs)

1. **nixpkgs base rev** — `solnix-pkgs/flake.nix` input pin. unstable: bump
   forward periodically. 26.11: pin to nixpkgs `release-26.11` HEAD at freeze.
2. **solnix-pkgs patch-set rev** — the `patches/000N` + overlay. unstable: HEAD.
   26.11: git tag `v26.11` on solnix-pkgs; the release builds only from that tag.
3. **Cache namespace** — the current flat `s3://solnix-cache` becomes the
   `unstable` channel. Add `s3://solnix-cache/26.11/` (its own arch-manifest +
   narinfos). Store paths differ by hash anyway (the pin changes inputs → new
   hashes), so the two never collide; namespacing is for the *manifest/index*,
   not correctness. Read URLs: `cache.solnix.io` (unstable, current) and
   `cache.solnix.io/26.11` (or a `nix-channel`-style redirect).
4. **`system.stateVersion`** — add the option to `configurations/base.nix`
   (currently absent). Gates any future stateful-migration logic, like NixOS.
5. **Per-edition AMIs + ISOs** — `solnix-unstable-<date>` and `solnix-26.11`
   (minimal + graphical each). The Gate-A pipeline produces unstable images now;
   a release run rebuilds them from the `v26.11` tag.
6. **Channel subscription** — a user picks an edition by which nixpkgs+patch pin
   their config's `inputs.solnix-pkgs` follows: `.../tag/v26.11` (frozen) vs
   `.../branch/main` (rolling). No separate channel infra needed — the flake
   input IS the channel (Nix-native, no `nix-channel` daemon dance).

## Mechanics: how the fork carries both

`solnix-pkgs` = one repo, two refs:
- `main` (unstable): moving nixpkgs pin + patches at HEAD.
- tag `v26.11` (cut at freeze): the exact nixpkgs pin + patch set for 26.11.
  Security backports → a `release-26.11` branch, re-tagged `v26.11.1`, etc.

A downstream config selects its edition purely by the flake input:
```nix
# unstable
inputs.solnix-pkgs.url = "git+https://codeberg.org/gregburd/solnix-pkgs";
# 26.11
inputs.solnix-pkgs.url = "git+https://codeberg.org/gregburd/solnix-pkgs?ref=v26.11";
```

## Release criteria (when unstable → 26.11 freeze is allowed)

Don't freeze 26.11 until, on x86_64 at minimum:
- fully-Nix (Phase-3 complete): the core package set is real `.drv`-backed
  hermetic derivations (not `nix-store --add`), `nix-store -q --deriver` resolves.
- GATE A passed: a declarative-Nix AMI boots + `nix profile install` works.
- an installer ISO installs to disk + boots.
- the base `configurations/base.nix` + declarative modules stable.
aarch64/sparcv9/riscv join a later dated release as they reach the same bar
(a release can be x86_64-only first, like early NixOS ports).

## Not doing yet (YAGNI until unstable is release-worthy)

- No release-engineering automation (backport bot, channel-bump CI) until
  there's a first 26.11 to maintain.
- No `nix-channel` server; the flake input is the channel.
- Cache GC / channel EOL policy: deferred (append-only for now, per the
  cache-immutability decision in roadmap-fully-nixified.md).

## Immediate, cheap step (do now)

Add `system.stateVersion` (default `"unstable"`) to `configurations/base.nix` +
the declarative modules, so images built now already carry the edition marker
and a future 26.11 freeze is a pin+tag+namespace, not a retrofit.
