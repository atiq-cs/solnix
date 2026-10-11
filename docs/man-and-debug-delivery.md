# Man pages, the `man` command, and separate debug symbols — system-wide delivery

Status: implemented (solnix modules + dixi.nix). Owner: build team.

Goal (maintainer directive): on every installed solnix system and every installer
image, `man <tool>` works for both the illumos base tools and every package in
the Nix profiles; and separate debug symbols are delivered so a crash is
debuggable with real source-level symbols in gdb.

Modeled on NixOS: `documentation.man.enable` (nixos/modules/misc/documentation.nix
+ mandoc.nix) and `environment.enableDebugInfo` (nixos/modules/config/debug-info.nix).

## What provides what (measured)

| Piece | Source | How it reaches a running system |
| --- | --- | --- |
| `man` / `mandoc` viewer | `pkgs.solnix.world` (gate `/usr/bin/man`, `/usr/bin/mandoc`) | Already on PATH via the base world. `man(1)` dispatches to `mandoc(1)`. |
| Profile package man pages | each package's `$out/share/man` | Linked into the system profile at `sw/share/man` (and `~/.nix-profile/share/man`). `environment.pathsToLink` already carries `/share/man`; `MANPATH` already suffixes `/share/man` onto every profile (modules/config/shell-environment.nix). No extra wiring. |
| illumos **base** man pages | `pkgs.solnix.worldMan` | The gap: `mk-proto-world` EXCLUDES `usr/share/man` to keep the runtime closure lean, so the installed BE has none. `worldMan` carries them under `share/man` as a doc-only store path; `documentation.man.enable` adds it to the system profile, so they land at `sw/share/man` and the existing MANPATH finds them. |
| Split debug symbols | each `mk-userland-pkg` package's `debug` output | `environment.enableDebugInfo` adds the `debug` output of every package that has one into the profile at `sw/lib/debug/.build-id`; gdb finds it by build-id (`NIX_DEBUG_INFO_DIRS` + `/etc/gdbinit`). |

This mirrors NixOS exactly: man pages and debug symbols are delivered through
PROFILE packages into `share/man` / `lib/debug`, not baked into the kernel/libc
base, and the env vars are profile-relative.

## The modules

### `modules/config/documentation.nix` — man pages (default on)

`documentation.enable` / `documentation.man.enable` (both default `true`, as on
NixOS). When on:

- adds `pkgs.solnix.worldMan` to `environment.systemPackages` (the illumos base
  man pages → `sw/share/man`);
- `environment.extraOutputsToInstall += [ "man" ]` — the NixOS-faithful wiring to
  pull any package's `man` output. solnix packages keep man in `$out` (see
  docs/design-manpages.md), so this is a no-op for the base set today, but it
  covers a future package that splits a `man` output;
- writes `/etc/man.conf` with the fallback `MANPATH` directives
  (`documentation.man.manPath`), for a `man` invocation with no login `MANPATH`.

MANPATH itself is already set per-login in `modules/config/shell-environment.nix`
(`profileRelativeSessionVariables.MANPATH = [ "/share/man" ]` suffixed onto every
`environment.profiles` entry), so profile man pages resolve with no change here.

### `modules/config/debug-info.nix` — split debug symbols (default off)

`environment.enableDebugInfo` (NixOS's name; default `false`). When on:

- `environment.extraOutputsToInstall += [ "debug" ]`;
- `environment.sessionVariables.NIX_DEBUG_INFO_DIRS = /run/current-system/sw/lib/debug`;
- writes `/etc/gdbinit` with `set debug-file-directory …` so a bare `gdb` (no env)
  still finds the tree.

`pkgs/illumos/mk-userland-pkg.nix` already produces the `debug` output: it splits
each ELF's DWARF with GNU `objcopy --only-keep-debug` + `--add-gnu-debuglink`,
keyed by a real `.note.gnu.build-id` note (injected because the Solaris linker
emits none), under `lib/debug/.build-id/<xx>/<rest>.debug`. The main output ships
stripped of DWARF but keeps CTF for mdb/dtrace. This module is only the delivery
side.

### `modules/config/system-path.nix` — making `extraOutputsToInstall` real

`lib/build-env.nix` only merges the store paths it is handed; its own
`extraOutputsToInstall` argument is a no-op on single-output slices. So to deliver
a package's `debug`/`man` output into the profile the way NixOS does, the extra
outputs must be added to `buildEnv`'s `paths`. `system-path.nix` now computes:

```nix
extraOutputPaths =
  systemPackages
  ++ concatMap (pkg:
       concatMap (o: optional (pkg ? ${o}) pkg.${o}) extraOutputsToInstall)
     systemPackages;
```

The `pkg ? <output>` guard is load-bearing: a single-output slice has no
`.debug`, and an unguarded access throws (verified by a negative control). So the
mixed solnix set is handled safely — `mk-userland-pkg` packages contribute a
`debug` output; from-source `mk-src-pkg` packages (git/curl/openssh/htop, which
strip debug and have no `debug` output) contribute nothing extra.

## dixi

`~/ws/nix-config/nixos/solnix/dixi.nix`:

- `documentation.man.enable` left at its default (`true`) → man pages work;
- `environment.enableDebugInfo = true` → split debug symbols for every package
  that ships a `debug` output, found by gdb via build-id.

## Installer image (TUI/GUI)

Two independent paths both carry man on the booted installer:

1. **toplevel path** — `configurations/installer.nix` imports `base.nix` and the
   base module list, so `documentation.man.enable` is on by default and the
   installer toplevel carries `worldMan` (base man pages) + `/etc/man.conf`. The
   `man`/`mandoc` binaries come from the world (already on PATH). Debug info is
   left OFF on the installer (keeps the image small).
2. **livecd script path** — `scripts/oi-make-livecd.sh` already stages
   `usr/bin/man`, `usr/bin/mandoc`, `usr/bin/col`, `usr/bin/nroff`,
   `usr/share/man`, and `etc/man.conf` into both the ISO live-root and the
   installed BE (gated by `SOLNIX_NO_MAN=1`, the first thing to drop if the image
   ceiling is approached). illumos `man(1)` searches `/usr/share/man` by default,
   so this path works via the gate's native section layout.

## Proof

- `nix eval` of the dixi toplevel (`--override-input solnix ~/ws/solnix`)
  evaluates all the new module code and reaches the gate proto fetch (which 404s
  on `s3.solnix.io` — a pre-existing infra gap, not this change; the stock `base`
  config 404s on the identical URL). Option values on dixi:
  `environment.enableDebugInfo = true`, `documentation.man.enable = true`,
  `environment.extraOutputsToInstall = ["debug","man"]`.
- `extraOutputPaths` self-check: a two-package set (one with a `debug` output, one
  without) + `extraOutputsToInstall = ["debug" "man"]` yields exactly three paths
  — both packages plus the one real `debug` output; the single-output package is
  not forced for `.debug`/`.man`. Negative control: dropping the `pkg ? debug`
  guard throws `attribute 'debug' missing`.
- On-target checks to run once the gate proto is published again (SAFE,
  read-only): `man htop` and `man ls` resolve a page; `ls /run/current-system/sw/lib/debug/.build-id`
  shows build-id dirs; `gdb -q -ex 'show debug-file-directory'` reports the
  sw/lib/debug tree.
