# lib/make-be.nix -- turn a solnix toplevel into a bootable disk.
#
# Emits a root-run script (it needs live ZFS, so it cannot run inside a Nix
# build) that does only the disk-level steps and leaves EVERYTHING inside the
# boot environment to the toplevel's own install-be step (IFACE-1), the same
# step scripts/solnix-install and `switch-to-configuration boot` run. So an
# image, an install and a generation switch produce the same BE.
#
# Layout (docs/design-nix-managed-base.md, the NixOS shape with one illumos
# departure): <pool>/nix is ONE shared dataset holding the store, the Nix DB
# and the profiles for every generation; each generation is its own BE
# <pool>/ROOT/<be> carrying only the early set (what runs before <pool>/nix is
# mounted: kernel, init, sh, zfs, ld.so.1 and their libs) as real files at
# their store paths inside the BE's own /nix.
#
# Steps: GPT label (ESP + pool), pool + <pool>/ROOT + BE + <pool>/nix,
# `nix copy` of the toplevel closure into <pool>/nix (the store DB is written,
# so no first-boot registration is needed), system profile generation 1,
# install-be into the BE, loader onto the ESP, bootfs.
{ pkgs
, toplevel
, disk ? "c1t1d0"          # whole scratch disk (never the running pool's)
, pool ? "spool"
, be ? "solnix-1"
}:

let
  makeBe = pkgs.writeScript "solnix-make-be" ''
    #!/usr/bin/bash
    set -euo pipefail
    export PATH=/usr/sbin:/usr/bin:/sbin
    DISK="''${DISK:-${disk}}"; POOL="''${POOL:-${pool}}"; BE="''${BE:-${be}}"
    TOP="''${TOPLEVEL:-${toplevel}}"
    ALT="''${ALTROOT:-/a}"
    CONS="''${SOLNIX_CONSOLE:-ttya}"
    die() { echo "make-be: FATAL: $*" >&2; exit 1; }
    log() { printf '\n=== %s ===\n' "$*" >&2; }
    [ "$(id -u)" = 0 ] || die "run as root"
    [ -e "/dev/rdsk/''${DISK}" ] || [ -e "/dev/rdsk/''${DISK}s0" ] || die "disk $DISK not present"
    zpool list -H -o name | grep -qx "$POOL" && die "pool $POOL already imported; refusing"
    # never the disk of an imported pool
    for p in $(zpool list -H -o name); do
      zpool status "$p" | grep -q "$DISK" && die "$DISK belongs to imported pool $p"
    done
    [ -x "$TOP/bin/install-be" ] || die "$TOP has no bin/install-be"

    log "GPT: ESP + pool slice on $DISK"
    zpool create -f solnixtmp "/dev/dsk/$DISK" >/dev/null 2>&1 || die "EFI label"
    zpool destroy solnixtmp
    RS=$(prtvtoc -h "/dev/rdsk/$DISK" | awk '$1==8{print $4}')
    RZ=$(prtvtoc -h "/dev/rdsk/$DISK" | awk '$1==8{print $5}')
    ES=256; EZ=524288; PS=$((ES + EZ)); PZ=$((RS - PS))
    printf '0 12 00 %s %s\n1 4 00 %s %s\n8 11 00 %s %s\n' $ES $EZ $PS $PZ $RS $RZ > /tmp/solnix.vtoc
    fmthard -s /tmp/solnix.vtoc "/dev/rdsk/$DISK" >/dev/null || die fmthard
    yes | mkfs -F pcfs -o fat=32,b=ESP "/dev/rdsk/''${DISK}s0" >/dev/null 2>&1 || true

    log "pool $POOL: ROOT/$BE + shared nix"
    zpool create -f -o altroot="$ALT" -o cachefile=none -O compression=on -O atime=off -m none \
      "$POOL" "/dev/dsk/''${DISK}s1"
    zfs create -o canmount=off -o mountpoint=legacy "$POOL/ROOT"
    zfs create -o canmount=noauto -o mountpoint=/ "$POOL/ROOT/$BE"
    zfs mount "$POOL/ROOT/$BE"
    # the shared store; mounted by the BE's inittab with `zfs mount -O`, so it must not automount.
    zfs create -o mountpoint=/nix -o canmount=noauto "$POOL/nix"
    S="$ALT/.solnix-store"; mkdir -p "$S"
    zfs set mountpoint=/.solnix-store/nix "$POOL/nix"; mkdir -p "$S/nix"; zfs mount "$POOL/nix"

    log "nix copy closure of $TOP -> $POOL/nix"
    nix copy --no-check-sigs --to "local?root=$S" "$TOP" || die "nix copy"
    nix-env --store "local?root=$S" -p /nix/var/nix/profiles/system --set "$TOP" || die "system profile"
    mkdir -p "$S/nix/var/nix/daemon-socket"
    # NixOS store permissions: root:nixbld 1775 (the daemon builds as nixbld*;
    # a normal user cannot write). NOT read-only: on illumos the daemon has no
    # private mount namespace in which to remount it rw (measured M10).
    chown root:30000 "$S/nix/store"; chmod 1775 "$S/nix/store"

    log "install-be (the toplevel's own step)"
    SOLNIX_ROOT="$ALT" SOLNIX_STORE_ROOT="$S" SOLNIX_POOL="$POOL" SOLNIX_BE="$BE" SOLNIX_CONSOLE="$CONS" \
      /sbin/sh "$TOP/bin/switch-to-configuration" install-be "$TOP" || die "install-be"

    log "loader on ESP, bootfs, menu"
    mkdir -p /tmp/solnix-esp; mount -F pcfs "/dev/dsk/''${DISK}s0" /tmp/solnix-esp
    mkdir -p /tmp/solnix-esp/EFI/Boot; cp "$ALT/boot/loader64.efi" /tmp/solnix-esp/EFI/Boot/bootx64.efi
    umount /tmp/solnix-esp
    installboot -fm "$ALT/boot/pmbr" "$ALT/boot/gptzfsboot" "/dev/rdsk/''${DISK}s0" >/dev/null 2>&1 || true
    zpool set bootfs="$POOL/ROOT/$BE" "$POOL"
    zfs set mountpoint="/$POOL" "$POOL"; mkdir -p "$ALT/$POOL/boot"
    printf 'title %s\nbootfs %s\n' "$BE" "$POOL/ROOT/$BE" > "$ALT/$POOL/boot/menu.lst"

    log "finalize"
    zfs umount "$POOL/nix"; zfs set mountpoint=/nix "$POOL/nix"
    rmdir "$S/nix" "$S" 2>/dev/null || true
    # the pool dataset (menu.lst home) is mounted INSIDE the BE under the altroot; unmount it first.
    sync; zfs umount "$POOL" 2>/dev/null || true
    zfs umount "$POOL/ROOT/$BE"; zpool export "$POOL" || die "export"
    log "DONE: $DISK pool=$POOL be=$BE toplevel=$TOP"
  '';
in
{
  script = makeBe;
  inherit toplevel;
}
