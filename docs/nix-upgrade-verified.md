# solnix: install/upgrade BY NAME — report

**Node:** i-019790466e3349855 (3.148.206.214, m5.2xlarge, us-east-2). LEFT RUNNING.
**Nix:** 2.24.15, x86_64-solaris. **Package-set system string:** `x86_64-solaris`.

## Does `nix profile install <name>` work now? — YES.

Wiring: the solnix package set is exposed by the **pure by-name flake** at
`solnix-pkgs/pkgs/os-specific/illumos/phase3/by-name-flake/` as
`legacyPackages.x86_64-solaris.<pkg>`. Map it to `nixpkgs` in the flakes
registry, then `nix profile install nixpkgs#<pkg>` resolves by name with **NO
`--impure`**. This is exactly the mechanism `docs/design-nix-upgrade.md`
("Image install-experience fixes" §3) specifies.

## The gap I found + fixed (one line)

The by-name flake, its `pkgs.nix`, and all three pinned store inputs (fork
nixpkgs `qmvlnvf0…`, gnu-config `config.guess`/`config.sub` FODs) were present
and valid on the node. `flakes` + `nix-command` enabled, substituters wired.

**But eval failed:** the on-node `flake.lock` pinned the `solnixPkgs` input to a
**nonexistent** store path (`/nix/store/377ikqbp3imv8kvdi2shg18dkma9cx2f-solnix-pkgs`
— the baked-image path, never materialized on this node). Actual tree lives at
`/root/solnix-pkgs`. Fix = repoint that one input + re-lock:

```sh
# flake.nix solnixPkgs.url already = "path:/root/solnix-pkgs"; just re-lock it:
cd /root/solnix-pkgs/pkgs/os-specific/illumos/phase3/by-name-flake
nix flake update solnixPkgs        # (--update-input solnixPkgs on 2.24, deprecated alias)
```

No other wiring needed. The other two inputs (fork, gnu-config FODs) were
already pinned to valid local store paths.

## Acceptance test (verbatim, all on the node)

```
$ nix --version
nix (Nix) 2.24.15

# 1. register the solnix by-name flake as `nixpkgs`
$ nix registry add nixpkgs path:/root/solnix-pkgs/pkgs/os-specific/illumos/phase3/by-name-flake
$ nix registry list | grep '^user'
user   flake:nixpkgs path:/root/solnix-pkgs/pkgs/os-specific/illumos/phase3/by-name-flake

# 2. install BY NAME — NO --impure
$ nix profile install nixpkgs#coreutils      # rc=0
$ nix profile install nixpkgs#gnused         # rc=0

# 3. list shows them, resolved via legacyPackages.x86_64-solaris.<pkg>
$ nix profile list
Name:            coreutils
Flake attribute: legacyPackages.x86_64-solaris.coreutils
Store paths:     /nix/store/3wlwvk71i6dfwiq63kdakq02fig8m68p-coreutils
Name:            gnused
Flake attribute: legacyPackages.x86_64-solaris.gnused
Store paths:     /nix/store/mky1cdsy45vkbb60qlwnhkkywnwnyhh6-gnused

# 4. the installed-by-name binaries RUN (via ~/.nix-profile/bin)
$ ~/.nix-profile/bin/echo "hello from coreutils installed by name"
hello from coreutils installed by name
$ echo aXc | ~/.nix-profile/bin/sed s/X/b/
abc
$ ~/.nix-profile/bin/uname -sm
SunOS i86pc

# 5. remove + reinstall by name (proves clean install path, NO --impure)
$ nix profile remove gnused         # removed 1, kept 1
$ nix profile install nixpkgs#gnused    # rc=0, back to 2 packages

# 6. UPGRADE — re-evaluates the registry flake + re-resolves each package
$ nix profile upgrade --all
upgrading 'legacyPackages.x86_64-solaris.coreutils' from flake '…?lastModified=1787728698…'
                                                     to    '…?lastModified=1787728945…'
upgrading 'legacyPackages.x86_64-solaris.gnused'    from '…' to '…'      # rc=0
$ nix profile upgrade coreutils     # by-name upgrade also rc=0
```

Upgrade proof: after `touch`-ing the flake dir, `nix profile upgrade --all`
re-evaluated the flake, saw the new `lastModified`, and moved both entries to
the new locked URL — that is the exact re-resolution path that pulls a newer
package rev when the registry ref advances. (narHash matched here only because
content was byte-identical; the re-lock/re-eval fired regardless.)

Chose `coreutils`/`gnused` because they resolve to **already-valid store paths**
(built, not rebuilt) — install substitutes nothing and is instant. `hello`
evals fine (`hello-2.12.3`) but is neither in-store nor in the cache, so it
would trigger a from-source build; avoided per the anti-wedge rule.

## Canonical upgrade UX for long-term instances

```sh
# one-time (baked into the AMI): nixpkgs -> solnix by-name flake
nix registry add nixpkgs path:<solnix-by-name-flake-dir>

# thereafter, by NAME, no --impure:
nix profile install nixpkgs#htop      # install
nix profile list                      # what's installed
nix profile upgrade --all             # upgrade everything
nix profile upgrade htop              # upgrade one
nix profile remove htop               # uninstall
```

## What to bake into the AMI (so every instance upgrades by name OOTB)

`scripts/oi-make-declarative-be.sh` already implements the bake (steps 5, 5c,
5d): it installs `/etc/nix/registry.json` (maps `nixpkgs` → the baked
`solnix-flake` = this by-name flake), a classic `nix-env` shim at
`/etc/nix/nixpkgs` (`NIX_PATH=nixpkgs=/etc/nix/nixpkgs`), and copies the fork
nixpkgs source into the image `/nix/store` as a GC root. The baked flake is
placed at `/run/current-system/solnix-flake` and expects `solnixPkgs` under it
(`flakeDir + "/solnix-pkgs/pkgs/os-specific/illumos"`).

**One required fix in the bake (the same gap I hit):** the baked `flake.lock`'s
`solnixPkgs` input must be re-locked to point at wherever `solnix-pkgs` actually
lands in the image (`/run/current-system/solnix-flake/solnix-pkgs` or its store
path), **not** the stale `377ik…-solnix-pkgs` path currently in the lock. A
locked `path:` input is never fetched over the network — if that path is absent
the flake will not evaluate. So the bake must either (a) `nix flake update
solnixPkgs` after placing the tree, or (b) copy the tree to the exact store path
the lock pins and register it as a GC root. Also confirm the fork +
gnu-config-FOD inputs are baked local (5d already handles the fork; do the same
for the two FODs). Everything else (registry.json, NIX_PATH shim,
gcroots/auto 1777, `~/.nix-profile` → per-user profile, PATH prepend) is already
scripted and correct.

## Bottom line

`nix profile install <name>` + `nix profile upgrade` work end-to-end on the node
against the SOLNIX package set (x86_64-solaris), pure (no `--impure`), via the
registry `nixpkgs` → by-name-flake mapping. The only blocker was a stale
`solnixPkgs` lock entry; re-locking it fixed install-by-name and is the one item
the AMI bake must get right so every long-term instance upgrades by name out of
the box.
