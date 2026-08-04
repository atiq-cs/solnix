#!/usr/bin/env bash
# oi-make-declarative-be.sh — seed a running illumos target so its boot
# environment is DECLARATIVE + nix-operational, reproducing the GATE-A deploy
# (the first declarative solnix AMI: ami-079ea8ce50a066d5f, edition=unstable).
#
# WHAT THIS IS (and is NOT):
#   This is the OVERLAY path — it lays the solnix *declarative userland* (the
#   composed system profile `sw`, the `nix` slice, `/etc/nix/nix.conf`, the
#   login PATH, the store DB) onto a target that ALREADY boots illumos. It does
#   NOT lay down a kernel/rtld/libc world; the target is a complete bootable OS
#   and baking the kernel into /nix would duplicate the running world.
#
#   The FULL bootable-from-scratch path (kernel + rtld + libc from the gate
#   proto, ESP + loader + boot_archive) is lib/make-be.nix / scripts/oi-make-be.sh.
#   Use THIS script when the base OS is already booting and you only need to add
#   the declarative Nix layer — which is exactly the GATE-A recipe.
#
# THE FLOW (reproducible pipeline; see docs/gate-a.md):
#   1. build the current-system toplevel on a Nix-capable illumos build host:
#        CS=$(nix-build --no-out-link \
#              -A solnixConfigurations.base.config.system.build.toplevel)
#      (Gate A used the reduced scratch/current-system.nix, which drops the
#      kernel-carrying systemPath; both realise to a /nix/store/<hash>-solnix-*
#      path with `sw -> solnix-system-path`, `nix -> nix-2.3.16`, and etc/.)
#   2. run THIS script on the build host to produce the transfer payload
#      (STAGE mode: closure.tar.gz + nixtools.tar.gz + db.dump), OR run it
#      directly on the target host to seed /nix in place (DEPLOY mode).
#   3. reboot/verify the target; scripts/oi-be-to-ami.sh then snapshots the
#      target's EBS volume and registers the AMI.
#
# STAGE vs DEPLOY (auto-detected; override with MODE=stage|deploy):
#   stage  — on the BUILD host: compute the CS closure, tar the closure store
#            paths + the /nix-tools nix runtime, and dump the store DB. Emits
#            $OUTDIR/{closure.tar.gz,nixtools.tar.gz,db.dump,closure.list} to
#            copy to the target. (This is what /scratch/gatea/ held for Gate A.)
#   deploy — on the TARGET host: create rpool/nix, extract the payload, load the
#            store DB (registers paths VALID), wire /run/current-system +
#            /etc/nix/nix.conf + login PATH + per-user dirs. Boots declarative.
#   Default: deploy if $OUTDIR/closure.tar.gz exists (payload present), else stage.
#
# Run as root on illumos. Idempotent + guarded. House style: NOTE:/TODO:.
set -euo pipefail

# ---------------------------------------------------------------------------
# config (all overridable via env)
# ---------------------------------------------------------------------------
MODE="${MODE:-}"                         # stage | deploy (auto if empty)
OUTDIR="${OUTDIR:-/scratch/gatea}"       # payload staging dir (both modes)
CS="${CS:-}"                             # current-system store path (stage mode)
NIXTOOLS="${NIXTOOLS:-/nix-tools}"       # host nix runtime (binaries + libs)
# tar for extraction on the target. The closure archive uses GNU long-name
# (@LongLink) entries for >100-char store paths, which illumos /usr/bin/tar
# cannot extract. Point TAR at a GNU tar (staged next to the payload on a
# minimal target that lacks one). Defaults to GNU `tar` on PATH.
TAR="${TAR:-tar}"
NIXSTORE="${NIXSTORE:-$NIXTOOLS/bin/nix-store}"
# The bundled nix binary links libreadline.so.8 etc. from the runtime-lib set;
# put them on LD_LIBRARY_PATH so nix-store runs on a minimal target that has no
# system readline/ncurses (RUNPATH alone is not enough on a fresh illumos BE).
export LD_LIBRARY_PATH="$NIXTOOLS/runtime-lib:$NIXTOOLS/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
POOL="${POOL:-rpool}"                    # target pool holding rpool/nix
NIXDS="${NIXDS:-$POOL/nix}"              # the /nix dataset created on the target
# per-user dirs are chowned for these logins (the KNOWN last-hurdle fix). Root +
# the base.nix admin logins. Override PERUSERS="root scott greg ..." as needed.
PERUSERS="${PERUSERS:-root scott greg}"
# Substituter: prefer the ORIGIN (s3.solnix.io/solnix-cache), NOT the CDN edge.
# WHY (documented in docs/gate-a.md): the cache.solnix.io CDN edge negative-caches
# a stale 404 for freshly-published hashes; the origin bucket serves them fine.
# Images therefore point nix at the origin to avoid the transient 404 on a hash
# published moments before boot. cache.solnix.io still works for aged content.
SUBSTITUTER="${SUBSTITUTER:-https://s3.solnix.io/solnix-cache}"
TRUSTED_KEY="${TRUSTED_KEY:-cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=}"

# /usr/gnu/bin FIRST so `tar` resolves to GNU tar (the closure tar uses
# `-T <file-list>` + symlink preservation, unsupported by illumos /usr/bin/tar).
export PATH="$NIXTOOLS/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:/sbin:$PATH"

die() { echo "FATAL: $*" >&2; exit 1; }
log() { printf '\n=== %s ===\n' "$*" >&2; }

[ "$(id -u)" = 0 ] || die "run as root"

# auto-detect mode: payload present -> deploy, else stage.
if [ -z "$MODE" ]; then
  if [ -f "$OUTDIR/closure.tar.gz" ]; then MODE=deploy; else MODE=stage; fi
fi
log "mode=$MODE  outdir=$OUTDIR"

# ---------------------------------------------------------------------------
# STAGE — on the build host: build the transfer payload from a current-system.
# ---------------------------------------------------------------------------
if [ "$MODE" = stage ]; then
  [ -x "$NIXSTORE" ] || die "nix-store not found at $NIXSTORE (set NIXSTORE=)"

  # Resolve the current-system store path. Prefer $CS; else auto-detect the most
  # recent solnix-current-system / solnix-system-* path in the store.
  if [ -z "$CS" ]; then
    CS="$(ls -dt /nix/store/*-solnix-current-system /nix/store/*-solnix-system-* 2>/dev/null | head -1 || true)"
  fi
  [ -n "$CS" ] && [ -d "$CS" ] || die "current-system not found; build it and pass CS=/nix/store/<hash>-solnix-current-system"
  log "current-system = $CS"

  # structural sanity: the CS must carry the declarative layer we deploy.
  [ -e "$CS/sw" ]  || die "$CS has no sw/ (composed system profile)"
  [ -e "$CS/nix" ] || die "$CS has no nix/ (nix slice)"
  [ -e "$CS/sw/bin/nix-store" ] || die "$CS/sw/bin/nix-store missing (nix not on the profile)"

  mkdir -p "$OUTDIR"

  # 1. the closure of the current-system (all store paths it references).
  log "computing closure -> $OUTDIR/closure.list"
  "$NIXSTORE" -qR "$CS" | sort -u > "$OUTDIR/closure.list"
  echo "closure: $(wc -l < "$OUTDIR/closure.list") paths"

  # 2. tar the closure store paths (absolute, preserve perms + symlinks). GNU tar
  #    (/usr/gnu/bin) handles the -T file-list + symlink preservation the store
  #    needs; illumos /usr/bin/tar does not take -T. Recurse each listed store
  #    dir (no --no-recursion: GNU tar 1.35 applies --no-recursion to -T entries
  #    too, which would archive only empty dir stubs).
  log "tarring closure -> $OUTDIR/closure.tar.gz"
  ( cd / && tar -T <(sed 's,^/,,' "$OUTDIR/closure.list") -czpf "$OUTDIR/closure.tar.gz" ) \
    || die "closure tar failed"

  # 3. tar the /nix-tools nix runtime (binaries + runtime libs), so the target
  #    can `nix-store --load-db` and run nix WITHOUT compiling it there.
  [ -d "$NIXTOOLS" ] || die "nix runtime dir $NIXTOOLS not present"
  log "tarring nix runtime ($NIXTOOLS) -> $OUTDIR/nixtools.tar.gz"
  ( cd / && tar -czpf "$OUTDIR/nixtools.tar.gz" "${NIXTOOLS#/}" ) || die "nixtools tar failed"

  # 4. dump the store DB for the closure (registers the paths VALID on load).
  log "dumping store DB -> $OUTDIR/db.dump"
  "$NIXSTORE" --dump-db $(cat "$OUTDIR/closure.list") > "$OUTDIR/db.dump" \
    || die "nix-store --dump-db failed"

  # record the CS path so DEPLOY can wire /run/current-system without guessing.
  printf '%s\n' "$CS" > "$OUTDIR/current-system.path"
  : > "$OUTDIR/DONE"

  log "STAGE DONE"
  echo "payload in $OUTDIR:"
  ls -l "$OUTDIR"/closure.tar.gz "$OUTDIR"/nixtools.tar.gz "$OUTDIR"/db.dump "$OUTDIR"/closure.list "$OUTDIR"/current-system.path
  echo
  echo "Copy $OUTDIR to the target host and run this script there (MODE=deploy)."
  exit 0
fi

# ---------------------------------------------------------------------------
# DEPLOY — on the target host: seed /nix from the payload + wire the system.
# ---------------------------------------------------------------------------
[ "$MODE" = deploy ] || die "unknown MODE=$MODE (want stage|deploy)"
[ -f "$OUTDIR/closure.tar.gz" ] || die "no closure.tar.gz in $OUTDIR (run STAGE first, then copy the payload here)"
[ -f "$OUTDIR/nixtools.tar.gz" ] || die "no nixtools.tar.gz in $OUTDIR"
[ -f "$OUTDIR/db.dump" ]         || die "no db.dump in $OUTDIR"

# the current-system path: from the staged sidecar, else $CS, else derive from
# the closure list (the CS path is the solnix-current-system / solnix-system-* entry).
if [ -z "$CS" ] && [ -f "$OUTDIR/current-system.path" ]; then
  CS="$(cat "$OUTDIR/current-system.path")"
fi
if [ -z "$CS" ] && [ -f "$OUTDIR/closure.list" ]; then
  CS="$(grep -E '/nix/store/[^/]*-solnix-(current-system|system-)' "$OUTDIR/closure.list" | head -1 || true)"
fi
[ -n "$CS" ] || die "cannot determine current-system path; pass CS=/nix/store/<hash>-solnix-current-system"
log "target current-system = $CS"

# 1. the /nix dataset (mounted /nix) on the target pool. Idempotent.
# If /nix is already a populated store (Gate-A seeded it on the root dataset,
# not a separate rpool/nix), reuse it in place: do NOT create/mount a dataset
# over a non-empty /nix (zfs refuses, and we would shadow the existing store).
if [ -d /nix/store ]; then
  log "/nix/store already present — reusing existing /nix in place (no dataset create)"
elif ! zfs list "$NIXDS" >/dev/null 2>&1; then
  log "creating $NIXDS (mountpoint /nix)"
  zfs create -o mountpoint=/nix -o compression=on "$NIXDS"
else
  log "$NIXDS already exists (reusing)"
fi
mkdir -p /nix/store /nix/var/nix

# 2. extract the closure + nix runtime into place (absolute paths in the tars).
# Use a GNU $TAR: the archive carries GNU @LongLink entries for long store
# paths, which illumos /usr/bin/tar cannot extract.
log "extracting closure.tar.gz -> / (tar=$TAR)"
( cd / && "$TAR" -xzpf "$OUTDIR/closure.tar.gz" ) || die "closure extract failed"
log "extracting nixtools.tar.gz -> /"
( cd / && "$TAR" -xzpf "$OUTDIR/nixtools.tar.gz" ) || die "nixtools extract failed"
[ -x "$NIXSTORE" ] || die "nix-store not present at $NIXSTORE after extract"

# 3. register the store DB (the linchpin — a bare store copy is NOT a usable
#    store until its DB is loaded; design-declarative-userland §C, risk #1).
log "loading store DB (nix-store --load-db)"
"$NIXSTORE" --load-db < "$OUTDIR/db.dump" \
  || die "nix-store --load-db failed (store would be unregistered)"
# verify the current-system path is now VALID (proves registration took).
"$NIXSTORE" --verify-path "$CS" >/dev/null 2>&1 \
  || echo "NOTE: verify-path $CS failed; store may be partially registered"

# 4. wire /run/current-system -> CS (illumos ln -sfn follows an existing
#    symlink-to-dir; rm -f first). Both /run/current-system and the Gate-A
#    /run-current-system name are linked so either lookup resolves.
log "wiring /run/current-system -> $CS"
mkdir -p /run
rm -f /run/current-system /run-current-system 2>/dev/null || true
ln -s "$CS" /run/current-system
ln -s "$CS" /run-current-system

# default profile -> the composed userland sw (so PATH + nix resolve).
mkdir -p /nix/var/nix/profiles
rm -f /nix/var/nix/profiles/default
ln -s "$CS/sw" /nix/var/nix/profiles/default

# 5. /etc/nix/nix.conf — ORIGIN substituter (CDN-lag rationale in the header +
#    docs/gate-a.md), single-user, no sandbox (illumos has no Linux namespaces).
log "installing /etc/nix/nix.conf (origin substituter $SUBSTITUTER)"
mkdir -p /etc/nix
cat > /etc/nix/nix.conf <<EOF
# /etc/nix/nix.conf — solnix declarative image (oi-make-declarative-be.sh).
# Substituter is the ORIGIN bucket, not the cache.solnix.io CDN edge: the edge
# negative-caches stale 404s for freshly-published hashes (see docs/gate-a.md).
substituters = $SUBSTITUTER
trusted-public-keys = $TRUSTED_KEY
sandbox = false
build-users-group =
max-jobs = auto
EOF
chmod 0644 /etc/nix/nix.conf

# 6. login PATH: prepend /run/current-system/sw/bin for the target logins.
#    The toplevel's own /etc/profile.d/solnix-env.sh (if present in the CS etc/
#    overlay) is the declarative source; install it, and also write a minimal
#    profile.d snippet as a fallback for a reduced CS that has no etc/.
log "wiring login PATH (/run/current-system/sw/bin first)"
mkdir -p /etc/profile.d
if [ -f "$CS/etc/profile.d/solnix-env.sh" ]; then
  cp -L "$CS/etc/profile.d/solnix-env.sh" /etc/profile.d/solnix-env.sh 2>/dev/null \
    || cp "$CS/etc/profile.d/solnix-env.sh" /etc/profile.d/solnix-env.sh
else
  cat > /etc/profile.d/solnix-env.sh <<'EOF'
# solnix login environment (declarative). sw/bin first on PATH.
export PATH=/run/current-system/sw/bin:$PATH
export NIX_PROFILES="/nix/var/nix/profiles/default"
EOF
fi
chmod 0644 /etc/profile.d/solnix-env.sh
# belt-and-suspenders for shells that do not source /etc/profile.d/*: append a
# guarded PATH line to each per-user ~/.profile (idempotent via a marker).
for u in $PERUSERS; do
  # read home from /etc/passwd directly: a minimal illumos target may lack
  # `getent`, and `home=$(getent ...)` under set -e would abort the script.
  home="$(awk -F: -v u="$u" '$1==u{print $6}' /etc/passwd 2>/dev/null || true)"
  [ -n "$home" ] && [ -d "$home" ] || continue
  prof="$home/.profile"
  if ! grep -q '__SOLNIX_PATH' "$prof" 2>/dev/null; then
    printf '\n# __SOLNIX_PATH: declarative userland on PATH\nPATH=/run/current-system/sw/bin:$PATH\nexport PATH\n' >> "$prof"
  fi
done

# 7. per-user single-user Nix dirs (THE known last-hurdle fix): each user needs
#    /nix/var/nix/{profiles,gcroots}/per-user/<user> OWNED BY THAT USER, or
#    single-user nix commands fail with a permissions error at first use.
log "creating + chowning per-user nix dirs ($PERUSERS)"
for u in $PERUSERS; do
  id "$u" >/dev/null 2>&1 || { echo "NOTE: user $u absent; skipping per-user dirs"; continue; }
  for base in profiles gcroots; do
    d="/nix/var/nix/$base/per-user/$u"
    mkdir -p "$d"
    chown "$u" "$d" 2>/dev/null || echo "NOTE: chown $u $d failed"
  done
done

sync
log "DEPLOY DONE — target BE is declarative + nix-operational"
echo "current-system: $CS"
echo "substituter:    $SUBSTITUTER (origin)"
echo "Next: reboot/verify (5 gate checks in docs/gate-a.md), then scripts/oi-be-to-ami.sh"
echo "  VOL_ID=<the target's EBS vol> scripts/oi-be-to-ami.sh   # snapshot -> AMI"
