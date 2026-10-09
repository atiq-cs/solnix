# NixOS parity audit: what NixOS sets up for a working system, and what solnix does

solnix aims to be exactly Nix (AGENTS.md). This table walks the mechanisms a NixOS
install has in place after first boot and records, for each, solnix's status:

- **DONE**: solnix does the NixOS thing (or its direct illumos equivalent).
- **GAP**: NixOS does it, solnix does not yet; the plan column says how.
- **N/A on illumos**: illumos cannot do the NixOS thing, or has a native mechanism
  that already covers it; the row says why.

NixOS module paths are relative to `nixos/modules/` in nixpkgs
(`/nix/store/0pci4p12dvimf6d7p4674ykvcjwsaq6a-source` on floki). solnix paths are
relative to this repo. "Measured" means on the X1 (dixi), generation
`a9rxaq1r...-solnix-system-dixi` (BE solnix-2), unless a row says otherwise.

| # | NixOS mechanism | NixOS module | solnix status | Evidence / why | Plan |
|---|---|---|---|---|---|
| 1 | Managed /etc: `/etc/static` -> the generation's etc store path, each managed file `/etc/X -> /etc/static/X`; `mode` entries are copies; `/etc/.clean` tracks copies | `system/etc/etc.nix`, `system/etc/setup-etc.pl` | **DONE** | Before: install-be COPIED every toplevel etc file into the BE (measured: 19 of 21 regular files `cmp`-identical real files, no `/etc/static`). Now install-be lays `etc/static` and links each managed file; see "Managed /etc" below for the copy set and its reasons. | Per-entry `mode` option if a module ever needs a writable managed file beyond the fixed set. |
| 2 | Accounts: passwd/shadow/group from `users.users`/`users.groups`, merged with existing entries when `users.mutableUsers` | `config/users-groups.nix`, `config/update-users-groups.pl` | **DONE** | `modules/config/users.nix` generates them; install-be merges them into the stock files (a declared user with no hash keeps the BE's password, the mutableUsers rule). They stay real files: `passwd`, `useradd` and the installer write them (solnix-install refuses a symlinked passwd/shadow/group). | none |
| 3 | `nix.conf`, `nix-daemon`, `nixbld*` build users, `trusted-users`, sandbox | `config/nix.nix`, `services/system/nix-daemon.nix` | **DONE** (sandbox N/A) | `modules/config/nix.nix`: /etc/nix/nix.conf from `nix.settings`, nixbld group 30000 + 32 users, `svc:/system/nix-daemon` online (measured). `sandbox = false`: illumos has no Linux mount/user namespaces or seccomp. | Zones as a build sandbox is a separate design question. |
| 4 | NIX_PATH, root channel, flake registry (`nix.nixPath`, `system.defaultChannel`, `/etc/nix/registry.json`, `nixpkgs.flake.setNixPath`) | `config/nix-channel.nix`, `config/nix-flakes.nix`, `misc/nixpkgs-flake.nix`, `installer/cd-dvd/channel.nix` | **DONE (departs: nixpkgs= is solnix's package set)** | `modules/config/nix-channel.nix`. NIX_PATH = `solnix=<this generation's package set>:nixpkgs=<same>:/nix/var/nix/profiles/per-user/root/channels`, exported by `/etc/profile.d/solnix-env.sh`, per-user channels first (NixOS's extraInit, now run for every shell as NixOS does). SMF `solnix-channel-init` (NixOS's nix-channel-init) installs the same expression into root's channels profile once, so `nix-env -iA solnix.<pkg>` works for every user through `~/.nix-defexpr/channels_root`. `/root/.nix-channels` written when absent (tmpfiles `f`), subscribed to the release channel. `/etc/nix/registry.json`: `solnix` -> the codeberg flake. Measured on the X1 (toplevel qbvl6nd7): `nix-env -qaA solnix.htop` = htop-3.4.1 as gburd, root and nobody; control without channels_root: "attribute 'solnix' ... not found"; `<solnix>` and `<nixpkgs>` give the flake's htop drv (v4q0nrlx). | Why nixpkgs= is not nixpkgs: x86_64-solaris nixpkgs' stdenv does not evaluate and its bootstrap is in no cache, so `<nixpkgs>` packages could never build here. `nix-shell -p` needs nixpkgs' mkShell: not available yet. No `nixpkgs` registry entry for the same reason. |
| 5 | System profile + generations + rollback (`/nix/var/nix/profiles/system-N-link`, boot menu per generation, `nixos-rebuild --rollback`) | `system/activation/top-level.nix`, `installer/tools/nixos-rebuild` | **DONE** (BE per generation) | Measured: `system -> system-2-link`, BEs solnix-1 / solnix-2; `switch-to-configuration boot` makes BE `solnix-N` for generation N; `solnix-rebuild rollback` activates the previous BE. The bootloader-menu-per-generation of NixOS is a ZFS boot environment here (illumos-native, and it also snapshots /etc and /var). | none |
| 6 | `/run/current-system`, `/run/booted-system` | `system/activation/activation-script.nix`, `system/boot/stage-2-init.sh` | **DONE** | install-be sets both per BE (step 7); measured `/run/current-system -> a9rxaq1r...`. `switch` relinks `/run-current-system` live. | none |
| 7 | GC roots for current/booted system and profiles | `services/system/nix-daemon.nix`, `activation-script.nix` (tmpfiles `L+`) | **DONE** | install-be step 7: `gcroots/profiles`, `current-system`, `booted-system`, stale staging `auto/` roots dropped. Measured present on dixi. | none |
| 8 | `/etc/os-release`, `/etc/lsb-release`, `nixos-version` (`--json`, `--revision`), `system.nixos.release`/`codeName`/`label` | `misc/version.nix`, `misc/label.nix`, `installer/tools/nixos-version.sh` | **DONE** | Before: no `/etc/os-release` (measured), `/etc/solnix-release` was a NAME/ID/EDITION stub, no version command. Now `modules/config/release.nix`: `solnix.release`, os-release with NixOS's fields, `solnix-version`. lsb-release is not written: no illumos consumer reads it. | none |
| 9 | Release channels (`nixos-26.05`, `nixos-unstable`), `system.stateVersion` | `misc/version.nix` (`stateVersion`), channel infra (Hydra) | **GAP** (documented) | No stateVersion option (configurations/dixi.nix notes it is deliberately unset). The cut procedure is below ("Cutting 26.11"). | Add `system.stateVersion` when the first stateful migration needs it. |
| 10 | `environment.etc` (arbitrary entries, `text`/`source`/`mode`/`user`/`group`) | `system/etc/etc.nix` | **PARTIAL** | solnix has `environment.generatedEtc` (name -> text) plus per-module carriers (`networking.generatedEtc`, `users.generatedEtc`, `nix.generatedEtc`); no `source`, `mode`, `user`, `group`. | Grow `generatedEtc` into `environment.etc` when a module needs `source` or a mode; the copy set covers today's needs. |
| 11 | `environment.variables`, `sessionVariables`, `profileRelativeSessionVariables`, `/etc/profile`, `/etc/set-environment` | `config/shells-environment.nix`, `config/system-environment.nix`, `programs/environment.nix` | **DONE** | `modules/config/shell-environment.nix` generates `/etc/profile` and `/etc/profile.d/solnix-env.sh` (POSIX sh, ksh93-safe). PATH puts `/run/current-system/sw/bin` first. | none |
| 12 | `/etc/shells`, `users.defaultUserShell`, `environment.shells` | `config/shells-environment.nix` | **GAP** (minor) | Measured: `/etc/shells` absent. illumos `getusershell(3C)` falls back to a built-in list (/bin/sh, /bin/ksh, /bin/csh, /usr/bin/bash, ...) when the file is absent, so chsh/ftpd still work for stock shells; a store-path shell would be rejected. | Generate `/etc/shells` from `environment.shells` once a user's shell is a store path. |
| 13 | PAM (`security.pam.services`, generated `/etc/pam.d/*`) | `security/pam.nix` | **N/A on illumos** (stock) | illumos reads one `/etc/pam.conf` (no pam.d), shipped by the gate's stock /etc; it is not a managed file. sshd runs with `UsePAM yes` (installer enforces it: OpenSSH's own crypt check fails open on this build). | Manage pam.conf only if a module needs a PAM change. |
| 14 | sudo, `security.wrappers` (setuid wrappers in `/run/wrappers/bin`) | `security/sudo.nix`, `security/wrappers/default.nix` | **DONE (RBAC underneath)** | wrappers: install-be copies the gate's setuid programs into `/run/wrappers/bin` with their owner and mode. sudo: `modules/config/sudo.nix` (`security.sudo.enable`), a real program in system.path (`scripts/sudo.sh`): cmd, `-u`, `-i`, `-s`, `-E`, `-n`, `-l` (profiles -l), `-v`/`-k` no-ops, `--`, unknown flags rc 1, exit status passed through. Measured on the X1: 15 cases incl. args with spaces kept, `sudo sh -c 'exit 7'` rc 7, `-u gburd` PATH = the system PATH. Negative control: as nobody (no RBAC profile) pfexec silently runs unprivileged (uid 60001, rc 0); sudo refuses rc 1 with a message. | Departs from NixOS: no sudoers; the policy is RBAC profiles (users.users.<n>.profiles), as for pfexec. |
| 15 | Activation scripts (`system.activationScripts`), `switch-to-configuration` | `system/activation/activation-script.nix`, `switch-to-configuration-ng` | **DONE** (fixed set) | `activate` = svccfg apply/import + svcadm; `switch-to-configuration switch|boot|test|list-generations|install-be`. No free-form `system.activationScripts` option (modules/config/coreadm.nix notes it). | Add the option when a module needs a hook. |
| 16 | tmpfiles (`systemd.tmpfiles.rules`) | `system/boot/systemd/tmpfiles.nix` | **N/A on illumos** (stub) | No systemd-tmpfiles. `systemd.tmpfiles.rules` exists only as an accept-and-ignore stub (`modules/nixos-compat.nix`); install-be and SMF start methods create state dirs. | Translate rules into an SMF oneshot if upstream modules start depending on them. |
| 17 | Documentation (`documentation.man`, man cache in the profile) | `misc/documentation.nix`, `misc/man-db.nix` | **PARTIAL** | `man` is on the system PATH (measured `sw/bin/man`); `update-man-index` is disabled because it wrote into a store path. No generated whatis cache. | Build the whatis index into system.path as NixOS's generateCaches does. |
| 18 | Locale, timezone (`i18n.defaultLocale`, `time.timeZone`) | `config/i18n.nix`, `config/locale.nix` | **DONE** (illumos form) | `solnix.defaults.locale`/`timeZone` -> `/etc/default/init` (TZ, LANG, LC_ALL), read by init and login (measured). No LOCALE_ARCHIVE: illumos is not glibc. | Rename to `i18n.defaultLocale`/`time.timeZone` aliases for config portability. |
| 19 | Hostname, `/etc/hosts` (`networking.hostName`, `networking.hosts`) | `tasks/network-interfaces.nix`, `config/networking.nix` (hosts) | **hostname DONE; hosts GAP** | `/etc/nodename` from `networking.hostName` (measured). `/etc/hosts` is the gate's stock file (only localhost); NixOS adds `127.0.0.2 <hostname>`. | Generate `/etc/inet/hosts` from `networking.hosts` + hostName. |
| 20 | resolv.conf (resolvconf, `networking.nameservers`) | `config/resolvconf.nix`, `tasks/network-interfaces.nix` | **DONE** (copy) | `networking.nameservers` -> `/etc/resolv.conf`; the solnix-net DHCP path rewrites it from the lease (measured rewritten at runtime), so it is a real copy, as NixOS's resolvconf-managed file is not a store link either. | none |
| 21 | SSH host keys generated on first boot (`services.openssh.hostKeys`) | `services/networking/ssh/sshd.nix` | **DONE** | sshd's start method runs `ssh-keygen -A` (configurations/base.nix); keys measured in /etc/ssh, 0600. `sshd_config` is generated. | none |
| 22 | `nix.gc`, `nix.optimise` (timers) | `services/misc/nix-gc.nix`, `services/misc/nix-optimise.nix` | **PARTIAL** | `auto-optimise-store`, `min-free`/`max-free` in nix.conf (first-boot-defaults.nix) give GC-on-low-space; no periodic `nix-collect-garbage --delete-older-than` job. | An SMF-timed or cron entry when generations accumulate. |
| 23 | ld.so cache / `nix-ld` | `config/ldso.nix`, `programs/nix-ld.nix` | **N/A on illumos** | Every solnix binary's RUNPATH pins its libraries into the store; /lib and /usr/lib are per-entry link farms install-be builds so `ld.so.1` resolves before /nix mounts. | none |
| 24 | Kernel modules / sysctl (`boot.kernel.sysctl`, `boot.kernelModules`) | `config/sysctl.nix`, `system/boot/kernel.nix` | **DONE** (illumos form) | `/etc/system` is generated (configurations/base.nix) and `/etc/system.d/*` assembled into `.self-assembly` by install-be. Both stay real files: they are boot-archive inputs. | none |
| 25 | Service manager (systemd units) | `system/boot/systemd.nix` | **N/A on illumos** (SMF) | `smf.services` generates DTD-validated manifests; `systemd.*` options are accept-and-ignore stubs so upstream modules evaluate. | Tier-2 translation systemd.services -> smf.services. |
| 26 | Installer (`nixos-install`, `nixos-generate-config`) | `installer/tools/tools.nix` | **DONE** (install), GAP (generate-config) | `solnix-install` runs the toplevel's own install-be (IFACE-1), as nixos-install runs switch-to-configuration. No hardware-config generator: illumos carries the machine's device bindings in `path_to_inst`, which the installer copies. | none |
| 27 | `nixos-rebuild` (`switch|boot|test|build|dry-build --flake`, `--rollback`, `list-generations`) | `pkgs/by-name/ni/nixos-rebuild-ng` | **DONE** | `solnix-rebuild` and `nixos-rebuild` are one script: switch, boot, test, build (./result, no root), dry-build, `--rollback`, rollback, list-generations; `--flake ref[#host]` (default `#$(hostname)`), `/etc/nixos/flake.nix` as the default flake; nix build options passed through word-for-word; nixos-rebuild-only flags (`--install-bootloader`, `--use-remote-sudo`, ...) accepted. Measured on the X1: `nixos-rebuild build --flake ~/ws/nix-config#dixi` -> ./result = a9rxaq1r (the running generation, as expected for an unchanged flake); `dry-build` rc 0; parser tests with a stub nix: `--option "a b" "c d"` kept as words; unknown option, two actions, missing --flake argument and build without a flake each rc 1. | `dry-activate` is refused (no activation diff yet). |
| 28 | Read-only store, store owned by root, `nixbld` group | `services/system/nix-daemon.nix`, `system/boot/stage-2.nix` (ro bind mount) | **PARTIAL** | Measured: `/nix/store` `drwxrwxr-t root nixbld`, as NixOS. NixOS also remounts the store read-only (bind mount); `rpool/nix` is `readonly=off` because the daemon writes it and illumos has no per-mount ro bind of a subtree. | lofs ro mount of /nix/store over itself is possible; needs a measurement of nix-daemon writing through a separate rw path. |

## Managed /etc (row 1): what install-be does now

NixOS (`setup-etc.pl`): `/etc/static` is an atomically replaced link to the
generation's `etc` store path; every file of it becomes `/etc/X -> /etc/static/X`,
except entries with a `mode`, which are copied (and recorded in `/etc/.clean` so a
later generation can remove them). Obsolete links into `/etc/static` are removed.

solnix (`modules/system/activation/install-be.sh`, step 3):

- `etc/static -> <toplevel>/etc` (a store path, so it resolves once `<pool>/nix`
  is mounted; nothing that reads it runs before that mount, see below).
- each managed regular file: `/etc/X -> /etc/static/X`;
- each managed symlink (the TLS bundle names): `/etc/X -> /etc/static/X` too, so
  a generation that drops one leaves a link into `static` that the cleanup pass
  recognises, as NixOS does;
- obsolete links: any `/etc` link into `/etc/static/` whose target no longer exists
  is removed (NixOS `cleanup`);
- copied files (NixOS's `mode` set), fixed in install-be with the reason for each:

| file | why it is a real copy |
|---|---|
| passwd, shadow, group, user_attr | merged with the stock accounts; `passwd(1)`, `useradd(1M)` and solnix-install write them (solnix-install fails on a symlinked passwd/shadow/group). |
| resolv.conf | the DHCP path rewrites it from the lease (measured: rewritten since boot on dixi). |
| system, system.d/* | boot-archive inputs read by the kernel through the archive, before `<pool>/nix` is mounted; a link into the store would be dangling there (`filelist.ramdisk` lists `etc/system`, `etc/system.d`). |
| default/init | read by `init(1M)` at sysinit time, before inittab's `zfs mount -O <pool>/nix` line runs. |
| inittab | the line that mounts `<pool>/nix`; install-be edits it. |
| ssh/sshd_config, default/login | solnix-install edits them on the target (PermitRootLogin no, UsePAM yes; PASSREQ, CONSOLE). |
| nodename | the gate's `svc:/system/identity:node` writes it on a hostname change; it is also read early by the network services. |
| coreadm.conf | `coreadm -U` (svc:/system/coreadm start method) imports it into SMF and RENAMES it to `coreadm.conf.old` (measured on dixi: `coreadm.conf` absent, `coreadm.conf.old` byte-identical to the toplevel's). A link would be renamed the same way; the copy keeps today's behaviour. |
| crypto/pkcs11.conf | install-be filters it (drops pkcs11_tpm) and `cryptoadm` rewrites it at runtime (measured rewritten since boot). |

Everything else in the toplevel's etc is a link: bashrc, default/solnix-mtu,
inet/ntp.conf, ipf/ipf.conf, logadm.d/solnix.conf, motd, nix/nix.conf,
nsswitch.conf, profile, profile.d/solnix-env.sh, os-release, solnix-release,
ssl/certs/*. None of these is read before `<pool>/nix` is mounted: inittab's
first sysinit line is that mount, ahead of svc.startd (install-be step 4).

Consumer measurements for linked files are in "Measurements" below.

## Release labels (row 8)

`modules/config/release.nix`:

- `solnix.release` (default `"unstable"`), `solnix.codeName`, `solnix.revision`
  (the solnix git revision the system was built from, null when unknown);
- `/etc/os-release` with NixOS's field set: NAME, ID=solnix, ID_LIKE=nixos,
  VERSION, VERSION_CODENAME, VERSION_ID, BUILD_ID, PRETTY_NAME, HOME_URL,
  DOCUMENTATION_URL, SUPPORT_URL, BUG_REPORT_URL, DEFAULT_HOSTNAME;
- `/etc/solnix-release`: the shell-sourceable stamp (NAME, ID, RELEASE,
  EDITION, VERSION_ID, REVISION, ROLES) that scripts/solnix-selftest reads;
- `solnix-version` on the system PATH (nixos-version's interface: no argument
  prints `<release> (<codename>)`, `--revision`/`--hash`, `--json`);
- the motd's first line names the release.

`solnix.edition` (modules/config/edition.nix) stays as the channel name a
configuration tracks and defaults to `solnix.release`.

## Cutting 26.11 (documented, not done)

NixOS cuts a release by branching `release-26.05` in nixpkgs, setting
`lib/.version` on the branch, and pointing the `nixos-26.05` channel at Hydra's
tested evaluations of that branch; `nixos-unstable` keeps following master.
solnix does the same with its two repos (docs/design-editions.md has the freeze knobs):

1. In solnix-pkgs: branch `release-26.11` from `main` with the nixpkgs input pinned
   to nixpkgs `release-26.11`; tag `v26.11`.
2. In solnix: branch `release-26.11`; on that branch set
   `solnix.release` default to `"26.11"` and `solnix.codeName` to the chosen name
   (modules/config/release.nix), and point `inputs.solnix-pkgs` at
   `?ref=release-26.11`. `main` stays `"unstable"`.
3. Channels: `solnix-unstable` follows `main`; `solnix-26.11` follows
   `release-26.11`. The flake ref is the channel for flake users; for classic
   users, `system.defaultChannel` (modules/config/nix-channel.nix) becomes the
   codeberg archive of `release-26.11`, which `/root/.nix-channels` subscribes to. The binary cache namespaces the 26.11 index
   (docs/design-editions.md knob 3).
4. Images: rebuild the installer media from the branch; its os-release then reads
   `VERSION_ID=26.11`.

## Measurements

(filled in as each is taken; REAL = measured on dixi with the command shown)

- REAL (before this change) `/etc` state of generation a9rxaq1r: every toplevel
  etc regular file is a real copy (`cmp` same) except passwd/shadow/group/user_attr
  (merged) and coreadm.conf (absent, see above); ssl/certs/* are links.
- REAL `/etc` files rewritten since boot (`find /etc -newer /etc/nodename`):
  crypto/pkcs11.conf, driver_*, dumpadm.conf, mnttab, name_to_major, minor_perm,
  path_to_inst, resolv.conf, svc/profile/*.xml, svc/repository*, dhcp/*, devices/*,
  dev/*.
