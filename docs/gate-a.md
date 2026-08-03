# GATE A — first declarative Nix-operational solnix AMI (PASSED)

Status: **PASSED**. The first declarative-Nix solnix AMI booted on EC2.

- AMI: `ami-079ea8ce50a066d5f` (edition `unstable`, us-east-2)
- current-system store path: `/nix/store/9yv48r2mqszy6ng90fwwg0p2vyvk9jjs-solnix-current-system`
  (16-path closure; `sw -> solnix-system-path`, `nix -> nix-2.3.16`, `etc/`)
- test instance: `i-050143e5450afefd3` (STOPPED after PASS)

Gate A is the declarative-userland milestone from
[design-declarative-userland.md](design-declarative-userland.md) §D (Stage A):
a solnix system whose userland layer (`sw` profile + `nix` + `/etc` wiring) is a
Nix current-system, laid over an already-bootable illumos BE, with a REGISTERED
store so `nix` actually works on the target.

## The 5 gate checks (all PASS)

Run on the booted AMI:

1. **PATH + a userland tool** — `echo $PATH` shows `/run/current-system/sw/bin`
   first, and a profile tool (`file`) runs from it.
2. **nix on PATH** — `which nix-store` resolves; `nix-store --version` = 2.3.16.
3. **nix operational against the cache** — pull + run a package from the solnix
   cache into the store (Gate A: `hello-pure` fetched from the cache and ran).
4. **deriver resolves** — `nix-store -q --deriver <path>` returns the `.drv`
   (proves the store DB was registered, not just a bare copy).
5. **rpool ONLINE + edition** — `zpool status rpool` ONLINE and
   `/etc/solnix-release` shows `EDITION=unstable`.

## The reproducible pipeline

One command per stage; the next declarative AMI (and the future 26.11 release
build) is a rebuild of exactly this:

```
# 1. build the current-system toplevel (on a Nix-capable illumos build host)
CS=$(nix-build --no-out-link \
      -A solnixConfigurations.base.config.system.build.toplevel)
#    Gate A used the reduced scratch/current-system.nix (drops the kernel-
#    carrying systemPath, since the target already IS a bootable illumos OS);
#    both realise to /nix/store/<hash>-solnix-* with sw + nix + etc.

# 2a. STAGE the transfer payload on the build host
CS="$CS" scripts/oi-make-declarative-be.sh          # MODE auto-detects: stage
#    -> $OUTDIR/{closure.tar.gz,nixtools.tar.gz,db.dump,closure.list}

# 2b. copy $OUTDIR to the target host, then DEPLOY (seed /nix in place)
scripts/oi-make-declarative-be.sh                   # MODE auto-detects: deploy
#    creates rpool/nix, extracts the closure + nix runtime, `nix-store
#    --load-db` (registers paths VALID), wires /run/current-system +
#    /etc/nix/nix.conf (ORIGIN substituter) + login PATH + per-user nix dirs.

# 3. reboot/verify the target (the 5 checks above), then image it
VOL_ID=<target EBS vol> scripts/oi-be-to-ami.sh     # snapshot -> register AMI
```

`scripts/oi-make-declarative-be.sh` captures the Gate-A recipe: it is the
OVERLAY path (declarative userland onto an already-booting target). The full
bootable-from-scratch path (kernel + rtld + libc from the gate proto, ESP +
loader + boot_archive) remains `lib/make-be.nix` / `scripts/oi-make-be.sh`.

## Origin vs CDN substituter (why the image points at the origin)

The image's `/etc/nix/nix.conf` uses the **origin** bucket
`https://s3.solnix.io/solnix-cache` as its substituter, NOT the
`cache.solnix.io` CDN edge.

Rationale (observed during Gate A, recorded in the imaging notes): the
`cache.solnix.io` CDN edge **negative-caches a stale 404** for a hash published
moments before boot — the edge cached "not found" before the object landed and
keeps serving 404 until the negative-cache TTL expires. The **origin** bucket
serves the freshly-published NAR fine. Since a declarative image is often built
against a hash published just before imaging, pointing `nix` at the origin
avoids the transient 404. (`cache.solnix.io` still resolves aged content
correctly — verified: `gettext-1.0-man` fetched via the CDN on both instances.)

`configurations/base.nix` / `modules/config/nix.nix` still default the
substituter to `cache.solnix.io` (the authoritative history-backed endpoint).
The deploy script overrides it to the origin at image time via `SUBSTITUTER=`;
override the script's `SUBSTITUTER=` back to the CDN once edge negative-caching
is fixed (single-line change, no rebuild).

## Editions: this pipeline builds `unstable`

Per [design-editions.md](design-editions.md): today's work IS the `unstable`
edition (rolling nixpkgs pin + solnix-pkgs at HEAD). A `26.11` release build is
the **same pipeline** run from the frozen `v26.11` fork tag — no new machinery,
just a different `inputs.solnix-pkgs` pin. Gate A passing is one of the
release criteria (design-editions.md "Release criteria") for the `unstable ->
26.11` freeze.
