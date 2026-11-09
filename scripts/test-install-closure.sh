#!/usr/bin/env bash
# test-install-closure.sh -- self-check for solnix-install's closure-install logic.
# Extracts the REAL blocks from the script (so the test cannot drift from it) and
# runs them against a fake toplevel whose `install-be` is a stub, once correctly
# and once per sabotage. Every guard must FAIL on the defect it exists for.
# Runs anywhere (no illumos, no zfs, no nix): the privileged steps are stubbed.
set -u
SCRIPT="${1:-$(dirname "$0")/solnix-install}"
W=$(mktemp -d /tmp/icchk.XXXXXX)
trap 'find "$W" -mindepth 1 -delete 2>/dev/null; rmdir "$W" 2>/dev/null' EXIT
FAILED=

# --- extract --------------------------------------------------------------
awk '/^step "writing machine inputs into the boot environment"/,/^log "datasets: /' "$SCRIPT" \
  | sed 's,/sbin/sh "\$_TLD/bin/switch-to-configuration",sh "$_TLD/bin/switch-to-configuration",' > "$W/populate.sh"
awk '/^realise_toplevel\(\) \{/,/^\}/' "$SCRIPT" > "$W/realise.sh"
grep -q 'install-be' "$W/populate.sh" && grep -q 'install-be)' "$W/realise.sh" \
  || { echo "FAIL  extract: anchors moved"; exit 1; }
bash -n "$W/populate.sh" && bash -n "$W/realise.sh" || { echo "FAIL  extracted blocks are not valid shell"; exit 1; }

# --- a fake toplevel: bin/switch-to-configuration with an install-be stub ---
# The stub lays what IFACE-1 promises; SABOTAGE selects one way to get it wrong.
mk_toplevel() {  # $1 = store root; prints the toplevel path
  local SR="$1" TL=/nix/store/00000000000000000000000000000000-solnix-system-test
  # the real toplevel's layout (modules/system/activation/default.nix)
  mkdir -p "$SR$TL/bin" "$SR$TL/kernel-slice/platform/i86pc/kernel/amd64" "$SR$TL/kernel-slice/kernel/amd64"
  : > "$SR$TL/activate"; : > "$SR$TL/early-paths"; : > "$SR$TL/bin/install-be"
  : > "$SR$TL/kernel-slice/platform/i86pc/kernel/amd64/unix"; : > "$SR$TL/kernel-slice/kernel/amd64/genunix"
  # the generation's etc (an absolute store link, as in the real toplevel) with one declared user's keys
  mkdir -p "$SR/nix/store/11111111111111111111111111111111-solnix-etc/etc/ssh/authorized_keys.d"
  echo 'ssh-ed25519 AAAA test' > "$SR/nix/store/11111111111111111111111111111111-solnix-etc/etc/ssh/authorized_keys.d/gburd"
  ln -s /nix/store/11111111111111111111111111111111-solnix-etc/etc "$SR$TL/etc"
  cat > "$SR$TL/bin/switch-to-configuration" <<'STC'
#!/bin/sh
# test stub of IFACE-1 install-be
case "$1" in
install-be)
  R="$SOLNIX_ROOT"; P="$SOLNIX_POOL"
  for d in platform/i86pc/kernel/amd64 platform/i86pc/amd64 kernel/amd64 sbin etc lib/svc/bin etc/svc \
           boot/defaults boot/forth boot/fonts nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-illumos-early/sbin; do mkdir -p "$R/$d"; done
  echo k > "$R/platform/i86pc/kernel/amd64/unix"; echo g > "$R/kernel/amd64/genunix"
  echo ba | gzip > "$R/platform/i86pc/amd64/boot_archive"
  echo init > "$R/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-illumos-early/sbin/init"
  echo sh > "$R/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-illumos-early/sbin/sh"
  echo ap > "$R/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-illumos-early/sbin/autopush"
  ln -s /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-illumos-early/sbin/autopush "$R/sbin/autopush"
  ln -s /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-illumos-early/sbin/init "$R/sbin/init"
  ln -s ../nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-illumos-early/sbin/sh "$R/sbin/sh"
  printf 'ap::sysinit:/sbin/autopush -f /etc/iu.ap\nnx::sysinit:/sbin/zfs mount -O %s/nix\nvr::sysinit:/sbin/sh -c '"'"'/sbin/zfs list -H -o canmount,name -r -t filesystem %s/var 2>/dev/null | ...'"'"'\nsmf::sysinit:/lib/svc/bin/svc.startd\n' "$P" "$P" > "$R/etc/inittab"
  : > "$R/lib/svc/bin/svc.startd"; : > "$R/etc/svc/repository.db"
  for f in loader64.efi pmbr gptzfsboot loader.rc defaults/loader.conf forth/loader.4th; do : > "$R/boot/$f"; done
  echo x > "$R/boot/fonts/fonts.dir"
  for f in passwd shadow group; do echo "root:x:0:0::/root:/bin/sh" > "$R/etc/$f"; done
  mkdir -p "$R/etc/ssh/authorized_keys.d"; echo 'ssh-ed25519 AAAA test' > "$R/etc/ssh/authorized_keys.d/gburd"
  chmod 0444 "$R/etc/ssh/authorized_keys.d/gburd"
  echo 'AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u' > "$R/etc/ssh/sshd_config"
  case "${SABOTAGE:-}" in
    no-stage2)    sed -i '/zfs mount -O/d' "$R/etc/inittab" ;;
    # /var state left inside the BE: a switch loses it and a rollback reverts it.
    no-vr)        sed -i '/^vr::/d' "$R/etc/inittab" ;;
    # a sysinit line ahead of autopush opens the console first: no ldterm all boot.
    ap-late)      sed -i '/^ap::/d' "$R/etc/inittab"; echo 'ap::sysinit:/sbin/autopush -f /etc/iu.ap' >> "$R/etc/inittab" ;;
    # autopush linked into the shared store, which is not mounted when ap:: runs
    ap-shared)    rm -f "$R/sbin/autopush"; ln -s /nix/store/ffffffffffffffffffffffffffffffff-userland/sbin/autopush "$R/sbin/autopush" ;;
    live-copy)    : > "$R/etc/solnix-live-shell" ;;
    clobber-cons) echo 'console="ttya"' > "$R/boot/loader.conf" ;;
    shadow-link)  rm -f "$R/etc/shadow"; ln -s /nix/store/x-etc/etc/shadow "$R/etc/shadow" ;;
    # the real-world defect: init linked to an early set that exists only on the shared
    # <pool>/nix, which is not mounted when init runs.
    init-shared)  rm -f "$R/sbin/init"; ln -s /nix/store/ffffffffffffffffffffffffffffffff-early-on-pool-only/sbin/init "$R/sbin/init" ;;
    # a real file, but somewhere the early-boot path does not belong
    init-odd)     mkdir -p "$R/var/x"; echo i > "$R/var/x/init"; rm -f "$R/sbin/init"; ln -s /var/x/init "$R/sbin/init" ;;
    no-loader)    rm -f "$R/boot/loader64.efi" ;;
    trunc-ba)     head -c 10 "$R/platform/i86pc/amd64/boot_archive" > "$R/ba.t"; mv "$R/ba.t" "$R/platform/i86pc/amd64/boot_archive" ;;
    drop-presets) rm -f "$R/etc/svc/profile/site/solnix-install.xml" ;;
    # the real-world defect: the stock /etc laid OVER the installer's machine inputs
    # (the X1's NVMe boot hung after cpu5 with the stock bootstrap path_to_inst).
    stock-pti)    echo '#path_to_inst_bootstrap_1' > "$R/etc/path_to_inst" ;;
    stock-hostid) echo '' > "$R/etc/hostid" ;;
    # declared keys that sshd would ignore or refuse
    no-akf)       echo 'UsePAM yes' > "$R/etc/ssh/sshd_config" ;;
    akd-link)     rm -f "$R/etc/ssh/authorized_keys.d/gburd"; ln -s /nix/store/11111111111111111111111111111111-solnix-etc/etc/ssh/authorized_keys.d/gburd "$R/etc/ssh/authorized_keys.d/gburd" ;;
    akd-mode)     chmod 0644 "$R/etc/ssh/authorized_keys.d/gburd" ;;
    fail)         exit 3 ;;
  esac ;;
*) exit 0 ;;
esac
STC
  [ "${NO_INSTALL_BE:-0}" = 1 ] && sed -i 's/^install-be)/install-everything)/' "$SR$TL/bin/switch-to-configuration"
  echo "$TL"
}

# run_populate <label> <expect: ok|die> <die-message-regex> [env...]
# A die must carry the message of the guard that exists for THAT defect; a die for any
# other reason (e.g. a harness bug) is a FAIL, so a control cannot pass by accident.
run_populate() {
  local label="$1" expect="$2" want="$3"; shift 3
  local R="$W/be.$label" SR="$W/sr.$label"; mkdir -p "$R" "$SR"
  local TL; TL=$(env "$@" bash -c "$(declare -f mk_toplevel); mk_toplevel '$SR'")
  ( set -u
    [ $# -gt 0 ] && export "$@"
    ALTROOT="$R"; STORE_PREFIX="$SR"; TOPLEVEL="$TL"; _TLD="$SR$TL"
    POOL=rpool; BE=solnix-1; BEDS=rpool/ROOT/solnix-1; TARGET=cXtYdZ; TARGET_CONSOLE=text; HOME_BASE=/home
    die() { echo "DIE: $*"; exit 1; }; log() { :; }; step() { :; }
    spin_start() { :; }; spin_stop() { :; }; run_to() { shift; "$@"; }
    _readlink() { [ -h "$1" ] || return 1; ls -ld "$1" | sed -n 's/.* -> //p'; }
    . "$W/populate.sh"
    echo "REACHED-END"
  ) > "$R.out" 2>&1
  local got=die; grep -q '^REACHED-END' "$R.out" && got=ok
  if [ "$got" = die ] && ! grep -m1 '^DIE:' "$R.out" | grep -qE "$want"; then got="die-for-the-wrong-reason"; fi
  if [ "$got" = "$expect" ]; then
    echo "PASS  $label -> $got $( [ "$got" = die ] && grep -m1 '^DIE:' "$R.out" | cut -c1-110)"
  else
    echo "FAIL  $label: expected $expect, got $got"; sed 's/^/      | /' "$R.out" | tail -8; FAILED=1
  fi
  [ "$label" = good ] && { cp "$R/etc/svc/profile/site/solnix-install.xml" "$W/presets.xml" 2>/dev/null; cp "$R/boot/loader.conf" "$W/loader.conf"; }
}

echo "=== populate + BE verification: correct install-be ==="
run_populate good ok x
grep -q "name='system/filesystem/autofs'.*enabled='false'" "$W/presets.xml" && ! grep -q "name='network/ssh'" "$W/presets.xml" \
  && echo "PASS  presets profile: autofs off, nothing for the unshipped network/ssh" || { echo "FAIL  presets profile content"; FAILED=1; }
grep -q '#' "$W/loader.conf" && { echo "FAIL  loader.conf contains '#'"; FAILED=1; } || echo "PASS  loader.conf has no '#'"
echo "=== NEGATIVE CONTROLS: each sabotage of install-be's output must be refused ==="
while read -r s re; do
  run_populate "$s" die "$re" SABOTAGE="$s"
done <<'CASES'
no-stage2    no stage-2 'zfs mount -O
no-vr        no 'vr' line mounting rpool/var
ap-late      first sysinit line is not ap
ap-shared    sbin/autopush resolves outside the BE or dangles
live-copy    live-media file /etc/solnix-live-shell
clobber-cons (overwrote the installed console|replaced the machine input /boot/loader.conf)
shadow-link  /etc/shadow is a symlink into the store
init-shared  left the BE without: sbin/init
init-odd     sbin/init resolves outside the BE
no-loader    left the BE without: boot/loader64.efi
trunc-ba     truncated gzip
drop-presets removed the machine input /etc/svc/profile/site/solnix-install.xml
stock-pti    replaced the machine input /etc/path_to_inst
stock-hostid replaced the machine input /etc/hostid
no-akf       sshd_config does not read /etc/ssh/authorized_keys.d
akd-link     no real /etc/ssh/authorized_keys.d/gburd
akd-mode     authorized_keys.d/gburd is not root-owned 0444
fail         install-be failed \(rc=3\)
CASES

echo "=== realise_toplevel gate: a toplevel without install-be is refused ==="
run_realise() {  # <label> <expect> [env...]
  local label="$1" expect="$2"; shift 2
  local SR="$W/rr.$label"; mkdir -p "$SR"
  local TL; TL=$(env "$@" bash -c "$(declare -f mk_toplevel); mk_toplevel '$SR'")
  ( set -u
    ALTROOT="$W/rra.$label"; mkdir -p "$ALTROOT/var/tmp"; STORE_MODE=overlay; FLAKE_REF=""; TOPLEVEL="$TL"
    POOL=rpool; NIXROOT="$W/nr.$label"; MEDIA_STORE_MNT=""
    die() { echo "DIE: $*"; exit 1; }; log() { :; }; step() { :; }; spin_start() { :; }; spin_stop() { :; }
    run_to() { shift; "$@"; }
    _readlink() { [ -h "$1" ] || return 1; ls -ld "$1" | sed -n 's/.* -> //p'; }
    _nixroot_mount() { :; }
    # nix stubs: realise is a no-op; nix-env --set writes the profile links like nix-env does.
    _nix_env() { case "$1" in nix-env) shift; while [ "$1" != -p ]; do shift; done
                   mkdir -p "$(dirname "$2")"; ln -s "$4" "$2-1-link"; ln -s "$(basename "$2")-1-link" "$2" ;; esac; }
    . "$W/realise.sh"
    # realise_toplevel reads the toplevel at $STORE_PREFIX$TOPLEVEL; point the empty prefix at the fake store
    STORE_PREFIX_FAKE="$SR"
    eval "$(declare -f realise_toplevel | sed 's,STORE_PREFIX="",STORE_PREFIX="$STORE_PREFIX_FAKE",')"
    realise_toplevel
    [ "$(_readlink "$SR/nix/var/nix/profiles/system")" = system-1-link ] && [ "$(_readlink "$SR/nix/var/nix/profiles/system-1-link")" = "$TL" ] \
      && echo "PROFILE-OK"
    echo "REACHED-END"
  ) > "$W/rr.$label.out" 2>&1
  local got=die; grep -q '^REACHED-END' "$W/rr.$label.out" && got=ok
  if [ "$got" = "$expect" ]; then echo "PASS  $label -> $got $(grep -m1 -E '^(DIE:|PROFILE-OK)' "$W/rr.$label.out" | cut -c1-110)"
  else echo "FAIL  $label: expected $expect, got $got"; sed 's/^/      | /' "$W/rr.$label.out" | tail -6; FAILED=1; fi
}
run_realise with-install-be ok
grep -q PROFILE-OK "$W/rr.with-install-be.out" || { echo "FAIL  system profile not system-1-link -> toplevel"; FAILED=1; }
run_realise without-install-be die NO_INSTALL_BE=1

echo "=== seed_target_store: host mode never copies the build host's own system ==="
awk '/^seed_target_store\(\) \{/,/^\}/' "$SCRIPT" > "$W/seed.sh"
bash -n "$W/seed.sh" || { echo "FAIL  seed_target_store extract"; FAILED=1; }
run_seed() {  # <mode> -> prints what nix copy was asked to copy, or NOCOPY
  ( LIVE_SYSTEM=/nix/store/hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh-solnix-system-buildhost
    TOPLEVEL=/nix/store/tttttttttttttttttttttttttttttttt-solnix-system-image
    STORE_MODE=$1; ALTROOT="$W/seed.$1"; NIXROOT="$W/seednr.$1"; POOL=spool; COPIED=NOCOPY
    die() { echo "DIE: $*"; exit 1; }; log() { :; }; step() { :; }; spin_start() { :; }; spin_stop() { :; }
    _nixroot_mount() { :; }; _nixroot_umount() { :; }; run_to() { shift; "$@"; }
    _nix_env() { shift; COPIED="$*"; for p in $*; do case "$p" in /nix/store/*) mkdir -p "$NIXROOT$p";; esac; done; }
    . "$W/seed.sh"; seed_target_store; echo "$COPIED" )
}
_sh=$(run_seed host); _so=$(run_seed overlay)
case "$_sh" in NOCOPY) echo "PASS  host mode: nothing seeded" ;; *) echo "FAIL  host mode seeded: $_sh"; FAILED=1 ;; esac
case "$_so" in *buildhost*tttt*) echo "PASS  overlay (live media) mode still seeds the media closure + toplevel" ;; *) echo "FAIL  overlay seed: $_so"; FAILED=1 ;; esac

echo "=== shared /var: the installer and the migration create the same datasets ==="
_vi=$(sed -n 's/^VAR_SHARED="\(.*\)"$/\1/p' "$SCRIPT"); _vm=$(sed -n 's/^VAR_SHARED="\(.*\)"$/\1/p' "$(dirname "$SCRIPT")/solnix-migrate-var")
if [ -n "$_vi" ] && [ "$_vi" = "$_vm" ]; then echo "PASS  VAR_SHARED matches: $_vi"
else echo "FAIL  VAR_SHARED differs: solnix-install '$_vi', solnix-migrate-var '$_vm'"; FAILED=1; fi

echo "=== the live-root copy is gone from the script ==="
for pat in 'tar cEfX' 'SELF_INSTALL' 'OVERLAY=1' 'cd "\$SRCROOT"' 'copy the running root'; do
  if grep -q "$pat" "$SCRIPT"; then echo "FAIL  '$pat' still in $SCRIPT"; FAILED=1; else echo "PASS  no '$pat'"; fi
done

[ -z "$FAILED" ] && echo "ALL INSTALL-CLOSURE CHECKS PASS" || { echo "INSTALL-CLOSURE CHECKS FAILED"; exit 1; }
