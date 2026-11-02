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

### `modules/config/documentation.nix` — man, the man index, info, doc (help1, 2026-11-02)

Options, NixOS's names: `documentation.enable`, `man.enable`, `man.cache.enable` (NixOS default false; base.nix sets
it true), `info.enable`, `doc.enable`. When on:

- `worldMan` goes into the system profile (the base pages at `sw/share/man`); `extraOutputsToInstall += [ "man" ]`.
- **The index** (`man.cache.enable`): `environment.extraSetup` (NixOS's name; lib/build-env.nix `postBuild`) runs the
  world's `man -w -M $out/share/man` over the composed profile, writing `sw/share/man/whatis`. illumos apropos,
  whatis and `man -k` read that plain-text file (man.c whatapro), not a mandoc.db. Measured on the base profile:
  5186 entries. The build fails if no whatis is written.
- **info** (`info.enable`): texinfo 7.3 (pkgs/illumos/cli/texinfo.nix) in the profile, and `sw/share/info/dir`
  rebuilt by install-info from every `*.info` at build time (NixOS documentation.nix's extraSetup).
- **No /etc/man.conf.** illumos man(1) never opens it, and mandoc reads only lowercase `manpath` lines, so the
  `MANPATH` lines this module used to write were read by nothing. `documentation.man.manPath` is removed.

**Man in every context (install-be, not the shell):** with MANPATH unset, illumos man maps /usr/bin, /usr/sbin and
/sbin by inode to `/usr/share/man` (man.c `bintoman[]`), and info's compiled default path has `/usr/share/info`.
install-be now lays `/usr/share` as a real directory of per-entry links into the userland, with `man` and `info`
linking the system profile's `share/man` and `share/info` (`lay_usr_share`, test: scripts/test-install-be-share.sh).
That is the illumos form of NixOS man-db's `MANPATH_MAP /run/current-system/sw/bin /run/current-system/sw/share/man`.
It covers cron jobs, whose environment is only HOME LOGNAME PATH SHELL TZ (cron.c envinit; measured on dixi:
`/etc/default/init` variables do not reach them), `ssh host cmd`, sudo, and SMF methods. The links name the
system-path store path, not `$TOP/sw`, because community/zone-install.sh copies the /usr farm into zones whose store
holds system.path but not the toplevel. Per-user `~/.nix-profile` pages still need the login MANPATH; the non-login
shells get it once bash reads /etc/bashrc (SYS_BASHRC, wave6).

MANPATH itself is still set per login in `modules/config/shell-environment.nix` (every profile's share/man).

### Desktop help (desktop-cosmic-config.nix, pkgs/illumos/desktop/help.nix)

COSMIC 1.5 has no help system (no yelp, no `help:`/`man:` handler, no launcher plugin for manuals). The
`solnix-help` package adds NixOS's nixos-help analog (a "Solnix Manual" entry opening https://solnix.io/docs/), a
`x-scheme-handler/man` handler (`xdg-open man:ls` opens ls(1) in cosmic-term; anything that is not a page name is
refused), and a pop-launcher plugin (`man <word>` in the launcher lists whatis/apropos matches), linked into
/etc/pop-launcher/plugins/man (pop-launcher reads that directory, so the launcher is not rebuilt).

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
   installer toplevel carries `worldMan` (base man pages) and the man index. The
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
