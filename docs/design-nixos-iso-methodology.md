# Adopting NixOS's minimal-ISO methodology for solnix

Read the actual NixOS sources rather than reasoning from memory:
`nixos/modules/installer/cd-dvd/installation-cd-{minimal,base}.nix`, `iso-image.nix`,
`nixos/modules/profiles/installation-device.nix`.

## The finding that reframes everything

**`installation-cd-minimal.nix` is 21 lines.** In full:

```nix
{ lib, ... }: {
  imports = [ ../../profiles/minimal.nix ./installation-cd-base.nix ];
  documentation.man.enable = lib.mkOverride 500 true;
  documentation.doc.enable = lib.mkOverride 500 true;
  fonts.fontconfig.enable = lib.mkOverride 500 false;
  isoImage.edition = lib.mkOverride 500 "minimal";
}
```

That is the whole minimal installer. Everything else is **composed from profiles**, and the media's contents
come from a single line in `iso-image.nix:948`:

```nix
isoImage.storeContents = [ config.system.build.toplevel ];
```

**One derivation. Nix computes the closure.** Our `oi-make-livecd.sh` is ~2,500 imperative lines with **84
lines of hand-maintained path lists** and zero `/nix/store` content for the base userland.

Every image bug this campaign hit follows from that difference: `vi` missing `libmapmalloc.so.1`, `/dev` with 0
of 13 nodes, `df` a dangling symlink, `openssl` unrunnable via a *second-order* dangling symlink, `reboot`
absent because `[ -e ] &&` skips silently. **All five are "a human forgot a list entry."** A computed closure
cannot have them.

## ⚠️ The most important difference is not the ISO — it is the installer

NixOS's installer **also** ships passwordless accounts (`installation-device.nix:45,49` —
`initialHashedPassword = ""` for both `nixos` and `root`). So our live media doing that is *correct and
matches upstream*.

The difference is what happens next:

| | NixOS | solnix (today) |
|---|---|---|
| installed users come from | **`configuration.nix`** | **copied `/etc/{passwd,shadow}` from the media** |
| result | media passwords never reach disk | **passwordless root inherited onto disk** |

`nixos-install` *builds* the target from a config; it never copies the live root. That is **structurally** why
NixOS has no passwordless-root-on-disk bug, and why `677c945b07` (prompting for a root password, undoing
`PASSREQ=NO`) is a **patch for a design difference**, not a fix for an oversight. Worth keeping — but the real
answer is a declarative target.

## What to adopt, and what must differ

| NixOS mechanism | adopt? | solnix form |
|---|---|---|
| `storeContents = [ toplevel ]`, closure computed | **YES — the whole point** | needs core-OS derivations first (see below) |
| tiny composed profile files | **YES** | `modules/config/installation-device.nix` + an edition module |
| installer builds target from config | **YES — fixes the root-password class** | `configurations/dixi.nix` → `solnix-install --config` |
| `isoImage.makeUsbBootable` / `makeEfiBootable` | already equivalent | GPT + ESP + BIOS, working since `69ddb0d342` |
| `hardware.enableAllHardware` | already equivalent | `COPY_DIRS` ships whole kernel trees, 215/216 drivers |
| `console.packages += terminus_font` | **CANNOT** | illumos console font is a **fixed 8×16 with no larger built-in**; we lower resolution instead — a genuine platform difference, not a shortcut |
| `boot.postBootCommands` reading `/proc/cmdline` | adapt | illumos has no `/proc/cmdline`; use boot properties (already used for `usb_kb_path`) |
| squashfs | **no** | illumos live root is a UFS ramdisk via `lofi`; no squashfs support |
| systemd/getty autologin | **no** | SMF; `svc:/system/console-login` |

## The blocker, measured

Against `docs/registry/hipster-packages.tsv` (10,608 rows):

* **available as derivations**: `openssl` (43), `which` (61), `curl` (8), `git` (20), `less` (2)
* **NOT available — illumos core-OS**: `df` (`SUNWcsu`), `useradd`/`passwd` (`cmd/oamuser`),
  `reboot`/`halt`/`poweroff` (`cmd/halt`, one binary + `argv[0]` links), `zpool`/`zfs`, `svcadm`/`svccfg` (SMF),
  and the kernel itself

So `storeContents = [ toplevel ]` is **not reachable today**: the toplevel cannot contain a `df` that does not
exist as a derivation.

`pkgs/illumos/gate.nix` is honest about this in its own header — it *ingests* a prebuilt proto as a store path,
with the FOD that would *build* it explicitly deferred.

## Order of work

1. **`gate.nix` becomes a real FOD** running `oi-gate-build.sh` with a pinned `outputHash` — days, mostly build
   impurity.
2. **Slice the proto** with `mk-userland-pkg.nix`: `illumos-core-utils`, `illumos-oamuser`, `illumos-halt`
   (carrying its `argv[0]` links), `illumos-smf`, `illumos-zfs`.
3. **A `toplevel` derivation** that depends on those + the Nix-native tools already in the registry.
4. **Ramdisk built from the closure** — delete the 84 lines of path lists. Dangling symlinks and missing
   libraries become *impossible*, not *gated against*.
5. **`solnix-install --config configurations/dixi.nix`** — build the target from a config instead of copying the
   live root. This is what removes the inherited-password class entirely and makes
   *"install, then home-manager for `gburd`"* a single declarative step.
6. **Then** the edition files collapse to NixOS scale: a ~20-line `installation-cd-minimal` equivalent.

## Honest position

Steps 1–2 are the project; 4–5 are the payoff. Until then the interactive prompts (root password, admin user,
home layout, console size) are the **right patch** — they close real holes on the substrate we actually have.
But every gate added to `oi-make-livecd.sh` this campaign is a symptom, and the cure is deleting the path
lists, not guarding them better.
