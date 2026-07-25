# Phase 2 — A usable solnix

Phase 1 gate is met: solnix boots to `multi-user-server` on EC2. Phase 2 turns
"boots" into "usable, self-hosting, installable, cached." Governed by the same
steering docs. Tasks are ordered roughly by "what stands between boots and
daily-usable."

## P2 gate

Install solnix to disk from media, reboot into it reliably, log in over SSH,
`nixos-rebuild`-style switch a config change, and roll back — on amd64. Builds
pull from the solnix.io cache instead of rebuilding.

## Tasks

### Reliability & login (the two gaps from the Phase-1 gate)
- [x] **T2.1** Fix the ~50% intermittent early-kernel TSC hang on Nitro/KVM
      (`startup_smap`/`startup_modules` race). Kernel-level: bisect what differs
      on the hanging boots; may be a known illumos KVM/Nitro TSC issue. Until
      fixed, document the retry-to-boot workaround. *(reliability)*
- [x] **T2.2** Get interactive SSH login working: fix `cryptosvc`
      (`cryptoadm start` fails opening `/dev/cryptoadm` — missing device/driver
      in boot_archive or /dev) so the crypto framework comes up; then sshd +
      a login user. Also fix the other 4 peripheral svcs in maintenance
      (hal/keymap/intrd/ipmp) or disable those not needed. Target: `svcs -x`
      clean + `ssh root@solnix`. *(login)*

### Binary cache (solnix.io — NOW LIVE)
- [x] **T2.3** Publish `pkgs.illumos.*` closures + the seed to the solnix.io S3
      cache (`s3://solnix-cache`, endpoint https://s3.solnix.io, path-style).
      Generate a cache signing key (store in sops), sign + `nix copy` the store
      paths, expose the substituter. Bake the substituter + public key into the
      base config. Verify a clean host pulls a path from the cache. *(cache)*
- [ ] **T2.4** Repoint the seed FOD + gate derivation `url`/`src` at the
      solnix.io cache/object store (was local `file://`). *(cache)*

### Generations & install
- [x] **T2.5** Map Nix generations onto ZFS boot environments: `beadm`
      create/activate a BE per generation; `switch-to-configuration` activates
      within a BE; rollback = `beadm activate` the previous. *(generations)*
      DONE + gate-verified on EC2 (GATE A live switch, GATE B new-BE +
      reboot-into-new-gen + rollback). See docs/design-generations.md.
- [x] **T2.6** Nixify `make-be` into `lib/make-be.nix` (from the working
      `scripts/oi-make-be.sh`), consuming `system.build.toplevel` +
      `system.build.smfManifests`. *(build system)*
- [ ] **T2.7** Installer + live media: an install ISO/image + a `nixos-install`
      analog that lays a solnix config onto a target disk's ZFS root. *(install)*
- [x] **T2.8** Full `configurations/base.nix` evaluation through the fork
      (`eval-config` + `pkgs.illumos` + the module tree) → `system.build.toplevel`
      is a real store path, image built via the cross/native flow. *(integration)*

### Breadth (grows continuously)
- [ ] **T2.9** Networking (`dladm`/`ipadm`) module, users/groups module, the
      common nixos service modules pulled via `extPath`. *(config surface)*
- [ ] **T2.10** Package breadth: a meaningful slice of illumos userland +
      common third-party software building as `pkgs.illumos.*` / overlays.

## Sequencing

T2.1 + T2.2 (reliability + login) and T2.3 (cache publish) are independent and
highest-value — do first, in parallel. T2.5-T2.8 (generations, nixify, install,
full eval) form the "installable + upgradeable" core. T2.9-T2.10 (breadth) run
continuously. The post-stable backlog (clang/Rust/libumem/latest-GCC/lldb/fork
parity, docs/post-stable-backlog.md) rides on top once the P2 gate is green.
