# Design: declarative userland — `environment.systemPackages`, the system profile, login environment, and Nix-on-image

Status: design. Fills the gap between "solnix boots + reconciles SMF" (T2.x DONE,
docs/design-make-be.md §7, docs/design-smf-init.md) and "solnix is declarative
like NixOS." Today the toplevel composes only the *base illumos world*
(`pkgs.solnix.systemPath` = kernel/rtld/libc/ld/base-tools/externalLibs) plus
generated SMF + a tiny `/etc` overlay + the switch/rebuild tooling. There is no
userland layer: no way to add packages declaratively, no composed system profile,
no login-environment setup, and no `nix` binary on the booted image.

## A. What NixOS does (reference to mirror)
- A1 `config/system-path.nix`: `environment.systemPackages`, `pathsToLink`, `system.path = buildEnv{...}` (symlink farm merging bin/lib/share).
- A2 `system/activation/top-level.nix`: `ln -s ${system.path} $out/sw` -> `/run/current-system/sw` shared profile.
- A3 `config/shells-environment.nix`: `environment.sessionVariables`, `profiles`, `profileRelativeSessionVariables`, builds `set-environment`; profiles = [ /run/current-system/sw $HOME/.nix-profile /nix/var/nix/profiles/default ]; sets NIX_PROFILES/NIX_PATH/LOCALE_ARCHIVE.
- A4 `system/etc/etc.nix`: `environment.etc.<name>` -> the /etc farm.
- A5 `config/nix.nix` + `services/misc/nix-daemon.nix`: /etc/nix/nix.conf (nix.settings), nix pkg in system.path, seeded default profile, daemon.

## B. solnix implementation (new modules)
- modules/config/system-path.nix: `environment.systemPackages` + `system.path = pkgs.buildEnv{...}`. Reuse the existing systemPath merge (pkgs/illumos/default.nix:353) factored into lib/build-env.nix. Toplevel gains `ln -s ${config.system.path} $out/sw` (activation/default.nix ~line 416). Keep systemPath (kernel/libc base) SEPARATE from sw (userland) so broken systemPackages can't drop the kernel.
- modules/config/shell-environment.nix: generate /etc/profile.d/solnix-env.sh (the illumos /etc/profile ALREADY sources /etc/profile.d/*.sh — verified). PATH = sw + ~/.nix-profile + default profile; NIX_PROFILES; guarded aliases. POSIX sh-safe with a re-source guard. Do NOT touch /bin/sh. Do NOT set LOCALE_ARCHIVE (not glibc).
- modules/config/nix.nix: /etc/nix/nix.conf = { substituters=https://cache.solnix.io; trusted-public-keys=cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=; sandbox=false (illumos has no namespaces); build-users-group= (single-user Stage A); }. Move nix.settings real decl here (out of nixos-compat.nix). Add nix.package to systemPackages.
- etc runCommand (activation/default.nix ~line 382): union networking/users/shellEnv/nix generatedEtc + mkdir -p for nested paths (profile.d/, nix/).
- make-be.nix + solnix-install: copy profile.d/solnix-env.sh + nix/nix.conf; seed /nix/var/nix/profiles/default -> $TOPLEVEL/sw; `nix-store --dump-db $TOPLEVEL > BE/nix/.solnix-registration`; add a first-boot SMF transient oneshot that runs `nix-store --load-db < .solnix-registration` (registers the store DB) then self-disables.

## C. Nix on the image
- Ship nix 2.3.16 (the SAME classic nix the illumos build host runs -> proven-native). pkgs.solnix.nix = slice the host nix install (mk-illumos-component, RUNPATH-relocated) exposing nix-env/nix-store/nix-build/nix + libs (boost/sqlite/libsodium/openssl/curl/brotli/editline). Stage-A install verb is `nix-env -iA` (nix 2.3; `nix profile` is 2.4+).
- nix.conf: sandbox=false, single-user, cache.solnix.io substituter + key. Set ssl-cert-file / NIX_SSL_CERT_FILE to the illumos CA bundle (verify path).
- Store DB: bare store copy is NOT a usable store -> first-boot `nix-store --load-db` from a build-time `nix-store --dump-db` of the system closure. Fallback: `nix-store --register-validity`.
- Store size budget ~300-400MB (nix closure dominates), ZFS compression on.

## D. Staged rollout
- Stage A (next AMI): build-env + system-path + shell-environment + nix modules + pkgs.solnix.nix + toplevel $out/sw + etc union + make-be seeds. Default set: `environment.systemPackages = with pkgs.solnix; [ nix file less vim curl htop git ]`. Gate A: boot AMI, `echo $PATH` shows /run/current-system/sw/bin, `which nix-store` resolves, `nix-store -q /run/current-system` (store registered), file/less/vim/curl/htop/git run, `su - gburd` shows same PATH.
  - **Gate A PASSED** (ami-079ea8ce50a066d5f, edition unstable). The reproducible pipeline (build toplevel -> scripts/oi-make-declarative-be.sh -> scripts/oi-be-to-ami.sh), the 5 gate checks, and the origin-vs-CDN substituter rationale are in [gate-a.md](gate-a.md). oi-make-declarative-be.sh is the OVERLAY path (declarative userland onto an already-booting target), distinct from lib/make-be.nix's full bootable-from-scratch path.
- Stage B: run home-manager STANDALONE for gburd targeting x86_64-solaris; consume only portable subset (home.packages profile, dotfile symlinking, programs.* that generate files). Stub/drop systemd.user, dconf, GUI. solnix runs HM's activation script per-user (SMF oneshot or ~/.profile line).
- Stage C: translate ec2 home config kept tools (file/htop/perl/openssl/python3/git-config/ssh-config); drop xclip/_1password-cli/minio-client/console-ai; defer elixir/erlang/emacs/cmake. Gated on package-batch slicing each as pkgs.solnix.*.

## E. Risks
1. Store registration (load-db) unproven on the minimal BE — linchpin.
2. Sliced nix closure running on minimal image: every runtime lib (openssl/curl+CA bundle, sqlite, libsodium) RUNPATH-correct? CA-cert path for https cache especially.
3. nix-daemon on illumos: no systemd -> single-user Stage A; multi-user SMF daemon deferred.
4. sandbox=false + LOCALE_ARCHIVE: two NixOS defaults wrong on illumos — override/omit deliberately.
5. buildEnv collisions: ignoreCollisions masks conflicts; sw vs systemPath PATH order decides which binary wins — document.

## F. File/edit summary
New: lib/build-env.nix; modules/config/{system-path,shell-environment,nix}.nix; pkgs/illumos/nix.nix.
Edit: modules/module-list.nix (register 3 modules); modules/system/activation/default.nix ($out/sw ~L416, etc union ~L382); modules/nixos-compat.nix (remove nix.settings stub); lib/host-pkgs.nix (expose pkgs.buildEnv); lib/make-be.nix (copy profile.d + nix.conf, seed default profile, dump-db, register oneshot); scripts/solnix-install (same in 6b/7); configurations/base.nix (Stage-A systemPackages default set).
