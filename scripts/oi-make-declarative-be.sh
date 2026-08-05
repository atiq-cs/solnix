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
# 2.24 release: the nix runtime is /nix-tools224 (the relocatable 2.24 nix from
# the bootstrap tarball). The image ships this dir + puts /nix-tools224/bin on
# PATH (the from-source 2.24 nix drv is not on the cache; the runtime dir IS the
# nix, exactly as the 2.3.16 images shipped /nix-tools).
NIXTOOLS="${NIXTOOLS:-/nix-tools224}"    # host nix runtime (binaries + libs)
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
# CA bundle for the baked ssl-cert-file (2.24 nix needs it for TLS substitute).
CA_SRC="${CA_SRC:-/etc/certs/ca-certificates.crt}"

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
  # 2.24: nix ships as $NIXTOOLS (/nix-tools224), NOT a baked CS/nix slice, and
  # nix-store lives on PATH via $NIXTOOLS/bin — so the CS/nix + CS/sw/bin/nix-store
  # checks the 2.3.16 layout required are dropped here.
  [ -x "$NIXSTORE" ] || die "nix-store not found at $NIXSTORE (set NIXSTORE=)"

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

# 5. /etc/nix/nix.conf + registry.json — prefer the toplevel's declarative
# copies (5HAV key, experimental-features=flakes, ssl-cert-file, s3-origin
# substituter). Fall back to writing them if the CS has no etc/ overlay.
log "installing /etc/nix/nix.conf + registry.json (5HAV, s3 origin $SUBSTITUTER)"
mkdir -p /etc/nix
if [ -f "$CS/etc/nix/nix.conf" ]; then
  cp -L "$CS/etc/nix/nix.conf" /etc/nix/nix.conf 2>/dev/null || cp "$CS/etc/nix/nix.conf" /etc/nix/nix.conf
else
  cat > /etc/nix/nix.conf <<EOF
substituters = $SUBSTITUTER https://cache.solnix.io
trusted-public-keys = $TRUSTED_KEY
experimental-features = nix-command flakes
ssl-cert-file = $NIXTOOLS/ca-bundle.crt
sandbox = false
build-users-group =
max-jobs = auto
EOF
fi
chmod 0644 /etc/nix/nix.conf
[ -f "$CS/etc/nix/registry.json" ] && { cp -L "$CS/etc/nix/registry.json" /etc/nix/registry.json 2>/dev/null || cp "$CS/etc/nix/registry.json" /etc/nix/registry.json; chmod 0644 /etc/nix/registry.json; }

# 5b. the 2.24 nix runtime's baked ssl-cert-file must resolve: ensure the CA
# bundle exists at $NIXTOOLS/ca-bundle.crt (copy from the host CA if missing).
if [ ! -f "$NIXTOOLS/ca-bundle.crt" ] && [ -f "$CA_SRC" ]; then
  cp "$CA_SRC" "$NIXTOOLS/ca-bundle.crt" && echo "  installed $NIXTOOLS/ca-bundle.crt from $CA_SRC"
fi

# 5c. CLASSIC by-name entrypoint. The flakes path (registry.json above) makes
# `nix profile install --impure nixpkgs#<pkg>` resolve by name. Classic
# `nix-env -iA` needs a NIX_PATH target whose default import IS the package set:
# the baked solnix-flake dir itself has only flake.nix (no default.nix), so
# pointing <nixpkgs> at it makes nix-env import flake.nix + collide. Ship a tiny
# shim dir /etc/nix/nixpkgs whose default.nix imports the flake's pkgs.nix for
# x86_64-solaris; point NIX_PATH at THAT, and symlink each user's
# ~/.nix-defexpr/nixpkgs -> it so BOTH `nix-env -f '<nixpkgs>' -iA <pkg>` AND
# the channel-style `nix-env -iA nixpkgs.<pkg>` resolve by name.
# --impure is required for the flakes path because pkgs.nix uses
# builtins.storePath (banned in pure eval); nix-env is impure by default.
log "installing classic nix-env shim /etc/nix/nixpkgs (nix-env -iA by name)"
mkdir -p /etc/nix/nixpkgs
cat > /etc/nix/nixpkgs/default.nix <<'EOF'
# solnix classic nix-env entrypoint: the illumos package set (x86_64-solaris).
# Imports the baked by-name flake's pkgs.nix so `nix-env -iA <pkg>` and
# `nix-env -iA nixpkgs.<pkg>` resolve without --impure (nix-env is impure).
import /run/current-system/solnix-flake/pkgs.nix { system = "x86_64-solaris"; }
EOF
chmod 0644 /etc/nix/nixpkgs/default.nix

# 5d. BAKE the fork nixpkgs source tree into the target /nix/store. The by-name
# flake's pkgs.nix does `builtins.storePath /nix/store/<hash>-nixpkgs-patched`,
# a ~610MB flat-dir path (unknown-deriver, no references) that is NOT part of
# the toplevel closure. On a FRESH image it must be fetched to EVALUATE any
# by-name install. It IS published+signed (5HAV) and substitutable from the s3
# ORIGIN, but the cache.solnix.io CDN edge negative-caches a stale 404 for it
# (bare GET -> 404 cf-cache HIT), so relying on the CDN wedges by-name install.
# Baking it local makes by-name work out of the box regardless of CDN state
# (this is exactly the proven-on-AMI behavior). Idempotent: skip if present.
log "baking fork nixpkgs source into /nix/store (by-name eval dep)"
FORK="$(grep -oE '/nix/store/[a-z0-9]+-nixpkgs-patched[^\"[:space:]]*' "$CS/solnix-flake/pkgs.nix" 2>/dev/null | head -1 || true)"
if [ -n "$FORK" ]; then
  if [ -d "$FORK" ] && "$NIXSTORE" --verify-path "$FORK" >/dev/null 2>&1; then
    echo "  fork already local + valid: $FORK"
  else
    echo "  substituting fork from origin ($SUBSTITUTER): $FORK"
    "$NIXTOOLS/bin/nix" copy --from "$SUBSTITUTER" --to /nix \
      --option trusted-public-keys "$TRUSTED_KEY" "$FORK" 2>&1 \
      || echo "NOTE: fork substitute failed; by-name eval will fetch it at first use (needs a working substituter)"
  fi
else
  echo "NOTE: could not locate fork nixpkgs path in $CS/solnix-flake/pkgs.nix; by-name eval will substitute it at first use"
fi

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
# solnix login environment (declarative, Nix 2.24). Full PATH: sw + nix-tools224 + base OS.
export PATH=/run/current-system/sw/bin:/nix-tools224/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:/sbin:/usr/ccs/bin
export NIX_PROFILES="/nix/var/nix/profiles/default $HOME/.nix-profile"
export NIX_CONF_DIR=/etc/nix
export LD_LIBRARY_PATH=/nix-tools224/runtime-lib:/nix-tools224/lib:/nix-tools224/lib/amd64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
# by-name install: flakes registry maps nixpkgs -> the solnix illumos flake;
# NIX_PATH points at the classic shim (/etc/nix/nixpkgs/default.nix) so
# `nix-env -iA <pkg>` resolves the illumos package set by name.
export NIX_PATH="nixpkgs=/etc/nix/nixpkgs"
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
    printf '\n# __SOLNIX_PATH: declarative userland on PATH (bash + ksh)\nPATH=/run/current-system/sw/bin:/nix-tools224/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:/sbin:/usr/ccs/bin\nexport PATH\nLD_LIBRARY_PATH=/nix-tools224/runtime-lib:/nix-tools224/lib:/nix-tools224/lib/amd64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\nexport LD_LIBRARY_PATH\nNIX_CONF_DIR=/etc/nix; export NIX_CONF_DIR\nNIX_PATH=nixpkgs=/etc/nix/nixpkgs; export NIX_PATH\n' >> "$prof"
  fi
  # channel-style classic by-name: ~/.nix-defexpr/nixpkgs -> the shim so
  # `nix-env -iA nixpkgs.<pkg>` resolves without -f. Idempotent (ln -sfn).
  mkdir -p "$home/.nix-defexpr"
  ln -sfn /etc/nix/nixpkgs "$home/.nix-defexpr/nixpkgs"
  chown -h "$u" "$home/.nix-defexpr" "$home/.nix-defexpr/nixpkgs" 2>/dev/null || true
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

# scrub build-time core files + set the managed coreadm policy. Scrub the live
# target root + set the managed coreadm policy before this BE is imaged.
# NOTE: no -xdev — /export/home etc. are separate ZFS datasets; -xdev would
# skip them and leave cores in the image.
log "core-scrub + coreadm policy (no core files in the image)"
find / \( -name 'core' -o -name 'core.[0-9]*' \) -type f 2>/dev/null | while read -r c; do
  file "$c" 2>/dev/null | grep -qi 'core file' && { rm -f "$c" && echo "  scrubbed: $c"; }
done
mkdir -p /var/cores && chmod 1777 /var/cores
cat > /etc/coreadm.conf <<'CADM'
COREADM_GLOB_PATTERN=/var/cores/core.%f.%p.%t
COREADM_GLOB_CONTENT=default
COREADM_INIT_PATTERN=/var/cores/core.%f.%p.%t
COREADM_INIT_CONTENT=default
COREADM_GLOB_ENABLED=yes
COREADM_PROC_ENABLED=no
COREADM_GLOB_SETID_ENABLED=no
COREADM_PROC_SETID_ENABLED=no
COREADM_GLOB_LOG_ENABLED=yes
CADM
coreadm -u 2>/dev/null || true

sync
log "DEPLOY DONE — target BE is declarative + nix-operational"
echo "current-system: $CS"
echo "substituter:    $SUBSTITUTER (origin)"
echo "Next: reboot/verify (5 gate checks in docs/gate-a.md), then scripts/oi-be-to-ami.sh"
echo "  VOL_ID=<the target's EBS vol> scripts/oi-be-to-ami.sh   # snapshot -> AMI"
