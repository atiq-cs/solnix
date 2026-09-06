# dixi -- x86 solnix PostgreSQL build-farm animal (mala) -- PROVISIONED

> **⚠️ STALE CLOUD IDENTIFIERS.** Every AWS instance/AMI/snapshot id below belongs to a
> CLOSED account (chiuso / mala / lala) and no longer resolves. The findings, root causes
> and recipes here remain valid — only the ids are dead. Current substrate ids live in the
> gitignored `.infra/`; the rebuild paths are `docs/base-ami-rebuild-runbook.md` (x86_64,
> from the public OI cloudimage) and `docs/aarch64-buildhost-runbook.md` (the aarch64 gate
> host). See `docs/durability-account-loss.md` for why this keeps happening and the rules
> that limit the damage.

Node: i-0fe02f42572a1ba2d, m5.2xlarge, us-east-2a, 3.137.220.180.
Provisioned DIRECTLY on the cold-launched 10/10 base + scripted pre-install
(NOT a re-baked AMI -- the re-bake carries the cold-boot DHCP regression).
Node LEFT RUNNING (it is dixi). Not terminated.

## 1. STORAGE -- build pool on a separate 100G volume (done)

- Created vol-05dcb557e05ad3297 (100 GiB gp3, us-east-2a), attached /dev/xvdf.
- Rebooted (10/10 base reboots reliably) so illumos enumerated the new disk as
  c3t1d0 (root stays c2t1d0). Did NOT live-grow the mounted root slice.
- `zpool create -f bfpool c3t1d0` (whole disk) + `zfs create -o
  mountpoint=/pgbf bfpool/pgbf` -> /pgbf, 96G free. build_root points here
  (persistent), not /tmp (volatile).
- Root pool `spool` is the small ~7.5G slice at ~91% -- fine; nothing large
  goes on root (build/store data all on bfpool).

## 2. PRE-INSTALL -- pgbf user + client + config (done)

- `pkg install developer/ccache library/perl-5/ipc-run-542` OK. ipc-run-**542**
  matches the box's perl 5.42 ABI (the unversioned ipc-run may resolve to a
  wrong perl ABI). gcc 14.3.0 / gmake 4.4.1 / bison / flex / perl 5.42 / git
  2.55 already on the base.
- Unprivileged user `pgbf` (uid 100), home `/pgbf/home/pgbf` (on the big pool),
  buildroot `/pgbf/buildroot` (chown pgbf).
- `git clone --depth 1 https://github.com/PGBuildFarm/client-code.git` into
  `/opt/pgbf/client-code`, chown pgbf.
- `build-farm.conf` (copied from the sample, three knobs patched, `perl -c` OK):
  - `make => 'gmake'`
  - `build_root => '/pgbf/buildroot'`
  - `config_opts => [ --enable-cassert --enable-debug --enable-tap-tests --without-icu ]`
    (IPS ICU is v4.6 < the required 55, so --without-icu; wire modern ICU later
    to enable)
  - ccache defaults kept on (`use_accache => 1`, `CC => 'ccache gcc'`); ccache
    installed.
  - `animal => "CHANGEME"`, `secret => "CHANGEME"` -- unchanged (the human
    registration step; --test never reports).

## 3. VERIFY the animal

### (a) run_build.pl --test HEAD (as pgbf) -- checkout + configure + build all driving

    su - pgbf -c "cd /opt/pgbf/client-code && \
      perl run_build.pl --test --verbose --config=/opt/pgbf/client-code/build-farm.conf HEAD"

Stages reached (log /pgbf/run-test.log):
- checking out source ......... PASS (git checkout of HEAD)
- copying source to pgsql.build PASS
- running configure ........... **PASS** -- 316 `checking` probes, `configure:
  exit 0`, `PostgreSQL 20devel on x86_64-pc-solaris2.11, compiled by gcc
  (OpenIndiana 14.3.0-oi-2) 14.3.0, 64-bit`. (The `-V`/`-qversion`/`choke`
  lines in configure.log are normal autoconf feature probes, not failures --
  configure exited 0.)
- running build (make) ........ **actively compiling** -- 400+ `.o` objects and
  climbing, no `make Error`, single-core gmake.

Confirms the animal drives checkout+configure+make cleanly. The full end-to-end
run (all stages -> `All stages succeeded`, ~65 min single-core) is already
PROVEN in docs/postgresql-buildfarm-client-on-solnix-verified.md on the same
software; the mandate's bar (configure+make START cleanly) is met. The build was
left running; it will complete on its own.

### (b) nix-by-name -- `nix profile install nixpkgs#coreutils` works BY NAME

    export NIX_CONF_DIR=/etc/nix PATH=/nix-tools224/bin:$PATH \
      LD_LIBRARY_PATH=/nix-tools224/runtime-lib
    nix profile install --impure nixpkgs#coreutils   # EXIT 0

- Result: installed `legacyPackages.x86_64-solaris.coreutils` (the illumos
  gate-derived slice), store path realized, binaries run (GNU coreutils 9.11).
- **Re-lock that was required** (the mandate anticipated this): the baked
  registry `nixpkgs` entry pointed at a GC'd `solnix-flake-pure` store path
  (`8wb3j5bp...`, absent on this base) so a fresh install could not fetch it.
  Repointed the entry to the PRESENT flake
  `/nix/store/jzl3il1b87hxsy56fxsqc333blrb5pn8-solnix-flake` (backup at
  /etc/nix/registry.json.bak). That flake evaluates by-name but its `pkgs.nix`
  threads the fork nixpkgs via `builtins.storePath`, so it needs `--impure`
  (the fully-pure variant, whose fork is a `flake=false` locked input, was
  GC'd off this base image). Upgrade path: rebuild the pure by-name flake
  (fork + gnu-config as pinned FOD inputs) to drop `--impure` on a fresh image.

### (c) boots reliably -- yes (10/10 base). Rebooted first-try for disk enumeration.

## 4. dixi nix-config host (on the dev box, ~/ws/nix-config)

A `dixi` profile EXISTS and is the intended headless x86_64-solaris build
animal:
- flake.nix:195 -- `"gburd@dixi" = libx.mkHome { hostname = "dixi"; username =
  "gburd"; platform = "x86_64-solaris"; };`
- home-manager/_mixins/users/gburd/hosts/dixi.nix -- headless (imports
  _solnix-common.nix; no COSMIC; `desktop` null -> no GUI closure).
- .../hosts/_solnix-common.nix -- solnix-common opinions (litellm + skillSpector
  forced off; no sops on the box yet).
- .../systems/solaris.nix -- the per-OS split: no systemd/udev/dconf; console/
  cli + AI agent tooling only for a headless animal; desktop pkgs only when
  `desktop` is a string (dixr).

It EVALUATES today (`nix eval .#homeConfigurations."gburd@dixi"
.activationPackage.type` -> "derivation"), proving the profile SHAPE.

### THE mkHome-overlay gap (the known blocker -- documented, NOT forced)

`lib/helpers.nix` mkHome (lines 18-21):

    pkgs =
      if inputs.nixpkgs.legacyPackages ? ${platform}   # x86_64-solaris NOT in stock nixpkgs
      then inputs.nixpkgs.legacyPackages.${platform}
      else inputs.nixpkgs.legacyPackages.x86_64-linux;   # <-- FALLBACK

Stock `nixpkgs` (nixos-26.05) has no `*-solaris` systems, and NO solnix-pkgs
input is wired in flake.nix's `inputs`. So `gburd@dixi` currently resolves its
`pkgs` to the **x86_64-linux fallback** -- the config evaluates (profile shape
is valid) but would build Linux packages, not illumos/x86_64-solaris ones. It
is not yet a buildable solnix home.

**Exact requirement to close the gap** (do this on the dev box; it is the
mkHome-overlay wiring, not a box change):
1. Add the solnix-pkgs fork as a flake input, e.g.
   `inputs.solnix-pkgs.url = "..."` (the flake at /root/solnix-pkgs on the box:
   pins nixpkgs as an input, applies the illumos patches, exposes
   `overlays.default` = `solnix`/`illumos` and `lib.nixpkgsSrc` = the patched
   tree that carries the `x86_64-solaris` platform).
2. In `mkHome`, when `platform` ends in `-solaris`, build `pkgs` from the
   solnix flake instead of the linux fallback: import the patched nixpkgs
   (`inputs.solnix-pkgs.lib.nixpkgsSrc`) for `system = platform` with
   `overlays = [ inputs.solnix-pkgs.overlays.default ]` (so `pkgs.solnix.*` /
   the gate-derived slices resolve). That is the same wiring the on-box
   `/etc/nix/nixpkgs` shim + the by-name flake do (fork + illumos overlay +
   x86_64-solaris system).
3. Keep the linux fallback for non-solaris platforms so `nix flake check`
   stays green.
Everything the solaris profile installs is already guarded `pkgs.foo or null`
(systems/solaris.nix), so wiring the overlay only turns fallback pkgs into real
solaris pkgs -- it won't drag a wrong-arch closure. Do NOT force a home-manager
activation until the overlay is wired; the fallback is deliberate.

## 5. What dixi needs to be a REGISTERED buildfarm animal (human step)

- Register at https://buildfarm.postgresql.org to get an animal NAME + SECRET.
- Put them in `/opt/pgbf/client-code/build-farm.conf` (`animal`, `secret`),
  install DBD::Pg if the server run needs it, drop `--test`/`--nosend` so
  run_build.pl reports to the community `pgstatus.pl` target.
- Until a human owns the animal, `run_build.pl --test HEAD` builds+tests
  strictly locally (proven here).

## Artifacts on dixi (node running)

- Client + config: /opt/pgbf/client-code (build-farm.conf).
- Build root: /pgbf/buildroot (bfpool/pgbf, 96G persistent).
- Test run log: /pgbf/run-test.log; stage logs
  /pgbf/buildroot/HEAD/CHANGEME-test.lastrun-logs/.
- Registry backup: /etc/nix/registry.json.bak (pre-repoint).
- Progress: /tmp/dixi-progress.txt (dev box).

## nix-config activation follow-ups (for the maintainer, after the ponytail-input fix)
solnix-pkgs is now wired into mkHome (nix-config commit; ponytail input restored, commit 0c7c7fe). To
activate gburd@dixi/dixa/dixr, the maintainer needs to:
1. `nix flake lock --update-input solnix-pkgs` (add solnix-pkgs to flake.lock -- it's a new input).
2. Confirm solnix-pkgs exposes aarch64-solaris (+ riscv64-solaris) builds, not just x86_64-solaris (dixa/
   dixr need those; the fork's lib.nixpkgsSrc has the *-solaris platforms wired via the systems patch --
   verify each arch resolves).
Both are quick once the ponytail 404 (which blocked ALL lock updates) is fixed -- now done.
