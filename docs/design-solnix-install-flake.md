# `solnix-install --flake` — matching the NixOS console install experience

Read `nixos-install.sh` (now at `pkgs/by-name/ni/nixos-install/`, 345 lines) rather than reasoning from memory.

## What `nixos-install` actually does

Four steps, in order:

| step | `nixos-install` | `solnix-install` today |
|---|---|---|
| 1. **build the config** | `nix build <flake>#nixosConfigurations.<host>.config.system.build.toplevel` | **nothing** — copies the live root |
| 2. **copy the closure** | `nix copy` the toplevel to the target | `cpio` of hand-listed paths |
| 3. **activate** | `nixos-enter --root <mp> -c 'switch-to-configuration boot'` | relink profiles by hand, or `SELF_INSTALL` skips it |
| 4. **root password** | `nixos-enter --root <mp> -c passwd`, **interactive, at the end** | prompt + `openssl` hash |

Its flag surface is small: `--flake`, `--root`, `--system`, `--channel`, `--no-root-password`, `--no-bootloader`,
plus nix pass-throughs.

**Step 4 is the one I already match.** The root-password prompt added in `677c945b07` is the same idea in the
same place as upstream — good. **Steps 1–3 are the gap**, and step 1 is what "apply my nix-config" means.

## What already exists here

`flake.nix:70` exposes **`solnixConfigurations.<name>`** — explicitly *"the `nixosConfigurations` analog"* — and
`:93` already reaches `.config.system.build.toplevel`. Configurations present: `base`, `system`, `pkgs`,
`modules`, `pgfarm`. Files: `configurations/{base,gburd,pgfarm}.nix`.

So the machinery is there and **the installer simply does not use it**. That is the whole finding.

Missing: a `dixi` configuration. `nix-config` already has `"gburd@dixi"` with `platform = "x86_64-solaris"`
(`flake.nix:199`) and `home-manager/_mixins/users/gburd/hosts/dixi.nix`, so the *home-manager* half is ready.

## The target interface

```sh
solnix-install --flake /path/to/solnix#dixi --disk c1t001B448B485502D1d0
solnix-install --flake github:gregburd/solnix#dixi --disk c1t...   # once pushable
```

and for the maintainer's actual workflow — install, then build the host out with his own config:

```sh
solnix-install --disk c1t... --flake ~/ws/solnix#dixi
# first boot, as gburd:
home-manager switch --flake ~/ws/nix-config#gburd@dixi
```

## What must be true first

⚠️ **Step 1 cannot work until the toplevel contains a usable system**, and today it cannot: `df`, `useradd`,
`passwd`, `reboot`, `zpool`, `svcadm` and the kernel are illumos **core-OS** and are not derivations. That is
exactly what the gate FOD (step 1 of `docs/design-nixos-iso-methodology.md`) is for, and it is in flight.

So the honest sequencing is:

1. **gate FOD** — `unix`/`genunix`/core userland become store paths *(in flight)*
2. **slice the proto** into `illumos-core-utils`, `illumos-oamuser`, `illumos-halt`, `illumos-smf`, `illumos-zfs`
3. **`configurations/dixi.nix`** + a `dixi` entry in `solnixConfigurations`
4. **`solnix-install --flake`** — build, `nix copy`, activate; delete the `cpio` path lists
5. **home-manager** for `gburd` on first boot

## Interim: keep the prompts, but make them the fallback

The interactive prompts (root password, admin user, home layout, console size) close **real holes on the
substrate we have**, and image `l2` verified all four in the shipped artifact. They should become the
`--no-flake` path rather than being deleted — the same way `nixos-install` still supports `--channel` and
`-I` alongside `--flake`.

⚠️ But they must not be mistaken for the destination. `l2` is a good **OpenIndiana** installer. The maintainer
booted it, found `/nix` empty and `ldd /usr/bin/ls` unlinked to any store path, and said it *"feels very
openindiana-like"*. He was right.

## What `--flake` buys beyond convenience

* **The passwordless-root class disappears.** Users come from the config, so the media's `/etc/shadow` is never
  copied. My root-password prompt is a patch for a design difference, not a fix for an oversight.
* **The dangling-symlink class disappears.** A closure is computed; `vi` cannot lose `libmapmalloc.so.1` and
  `openssl` cannot lose its `lib` tree, because Nix knows the references.
* **`beadm` rollback becomes coherent** — generations are profile links into a shared store, which is why
  `/nix` had to move out of the boot environment (`8b70eb0209`).
