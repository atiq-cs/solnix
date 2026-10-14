#!/usr/bin/bash
# make-installer-image.sh -- build the solnix installer media FROM A TOPLEVEL.
#
#   make-installer-image.sh <installer-toplevel> [outdir]
#     <installer-toplevel>  /nix/store/...-solnix-system-solnix-installer, already
#                           realised in this host's store (solnixConfigurations.installer)
#     [outdir]              default /var/tmp/solnix-media
#
# Output: <outdir>/solnix-iso-tree.tar.gz, the staging tree scripts/make-iso-usb.sh
# turns into the hybrid ISO + dd-able USB image (same format oi-make-livecd.sh made).
#
# PRECEDENT, in order:
#   NixOS  nixos/lib/make-iso9660-image.nix + iso-image.nix: the media's contents are
#          `storeContents = [ config.system.build.toplevel ]` -- one store path, and
#          Nix computes the closure. Nothing is enumerated by hand.
#   NixBSD lib/make-partition-image.nix + modules/system/boot/initmd.nix: the closure
#          goes INTO a UFS memory-disk image the kernel mounts as root (md0). That is
#          the illumos shape: the loader hands the boot_archive to the kernel as a
#          rootfs ramdisk (/ramdisk:a). It is also the ONLY shape that boots on
#          machines whose boot stick is invisible after the kernel starts (measured on
#          the X1 Carbon: scsa2usb never binds), so the store lives in the ramdisk, not
#          on a second filesystem on the stick.
#
# DEPARTURES, and why:
#   * a root-run script, not a sandboxed derivation: illumos has no unprivileged
#     makefs; newfs needs a lofi device (root). Same boundary as lib/make-be.nix.
#   * the store DB is written by `nix copy` into the image's own store, so there is
#     no nix-path-registration / load-db step at boot (NixOS needs one because its
#     squashfs is built in a sandbox without a DB).
#   * the closure must fit ONE contiguous low-4GB allocation (the EFI loader stages
#     the uncompressed archive below 4 GB: copy.c efi_loadaddr). Measured on the X1:
#     largest free block 816,119,808 B; an 859,832,320 B archive was refused. The
#     cap below FAILS the build instead of shipping media that will not load.
#
# What comes from where -- every file in the ramdisk is one of:
#   the toplevel's closure (nix copy) | what the toplevel's install-be lays |
#   the live overlays this script writes (each listed below, each explained).
# The running root of this build host contributes NOTHING; the acceptance suite
# (scripts/image-acceptance-test.sh) checks that.
set -euo pipefail
TOP="${1:?usage: make-installer-image.sh <installer-toplevel> [outdir]}"
OUT="${2:-/var/tmp/solnix-media}"
RD_MAX_RAW="${RD_MAX_RAW:-734003200}"      # 700 MiB: under the X1's 816,119,808 B block with headroom
UFS_OVERHEAD_PCT="${UFS_OVERHEAD_PCT:-12}" # UFS metadata + fragment slack over NAR bytes (asserted below by df)
RD_MIN_FREE_KB="${RD_MIN_FREE_KB:-32768}"  # runtime slack the live root needs (/root, /etc edits)
RD_NBPI="${RD_NBPI:-8192}"
POOL_NAME="${SOLNIX_LIVE_POOL:-rpool}"     # install-be needs a pool name; the live root never mounts one
# GNU first: this runs on the BUILD host (sed -i, df -i, find -L).
PATH=/usr/gnu/bin:/usr/sbin:/usr/bin:/sbin:$PATH
die() { echo "FATAL: $*" >&2; exit 1; }
log() { printf '\n=== %s ===\n' "$*" >&2; }
rl() { ls -ld "$1" 2>/dev/null | sed -n 's/.* -> //p'; }
[ "$(id -u)" = 0 ] || die "run as root (lofiadm/newfs/mount)"
case "$TOP" in /nix/store/*) : ;; *) die "toplevel must be a /nix/store path" ;; esac
[ -e "$TOP/bin/install-be" ] || die "$TOP has no bin/install-be: not an installer-capable solnix toplevel"
[ -e "$TOP/sw/bin/solnix-install" ] || die "$TOP has no sw/bin/solnix-install: not the installer configuration"
command -v nix-store >/dev/null || die "nix-store not on PATH"

# ---------------------------------------------------------------------------
# 1. CLOSURE SIZE GATE (before any work): NAR bytes == bytes on a UFS ramdisk.
# ---------------------------------------------------------------------------
log "closure of $TOP"
nix-store -qR "$TOP" > "$OUT.closure" 2>/dev/null || { mkdir -p "$(dirname "$OUT")"; nix-store -qR "$TOP" > "$OUT.closure"; }
NPATHS=$(wc -l < "$OUT.closure" | tr -d ' ')
: > "$OUT.sizes"
while read -r p; do echo "$(nix-store -q --size "$p") $p" >> "$OUT.sizes"; done < "$OUT.closure"
NAR=$(awk '{s+=$1} END {printf "%d", s}' "$OUT.sizes")
# install-be also lays REAL copies outside /nix/store: the kernel trees, /boot, the
# early set and the stock /etc+/var (bootadm walks real files; nothing earlier than
# the store can be a link into it). Measured on the first image build: the closure
# alone (542 MB ramdisk) filled up during install-be ("No space left on device" on
# kernel/, /boot/fonts, /dev) and bootadm then read a truncated unix. Count those
# copies explicitly, from the same store paths install-be copies them from.
# The kernel trees are hard links into the ramdisk's own store on the live root
# (install-be, SOLNIX_LIVE), so they add no bytes; the early set and the stock
# /etc+/var are still real copies.
RT_COPY=0
for p in $(grep -E -- '-(illumos-early|illumos-stock-etc-var)$' "$OUT.closure"); do
  RT_COPY=$(( RT_COPY + $(nix-store -q --size "$p") ))
done
NEED=$(( NAR + RT_COPY + (NAR + RT_COPY) * UFS_OVERHEAD_PCT / 100 + RD_MIN_FREE_KB * 1024 ))
echo "closure: $NPATHS paths, $NAR B NAR; + $RT_COPY B install-be real copies; with ${UFS_OVERHEAD_PCT}% UFS overhead + ${RD_MIN_FREE_KB} KB slack: $NEED B; cap $RD_MAX_RAW B" >&2
if [ "$NEED" -gt "$RD_MAX_RAW" ]; then
  echo "" >&2
  echo "The installer closure does not fit the boot_archive the EFI loader can stage." >&2
  echo "Largest store paths (NAR bytes):" >&2
  sort -rn "$OUT.sizes" | awk 'NR<=10' | awk '{printf "  %12d  %s\n", $1, $2}' >&2
  die "closure needs $NEED B > cap $RD_MAX_RAW B (RD_MAX_RAW). Shrink the closure; do NOT raise the cap past the measured 816,119,808 B X1 block."
fi
sort -rn "$OUT.sizes" | awk 'NR<=5' | awk '{printf "  %12d  %s\n", $1, $2}' >&2

# ---------------------------------------------------------------------------
# 2. UFS ramdisk sized from the measurement, mounted via lofi.
# ---------------------------------------------------------------------------
RD_MB=$(( (NEED + 1048575) / 1048576 ))
log "creating ${RD_MB} MB UFS ramdisk"
umount "$OUT/rd" 2>/dev/null || true
for l in $(lofiadm 2>/dev/null | awk -v f="$OUT/boot_archive" '$2==f{print $1}'); do lofiadm -d "$l" 2>/dev/null || true; done
[ -d "$OUT" ] && find "$OUT" -mindepth 1 -delete
mkdir -p "$OUT/rd" "$OUT/iso/platform/i86pc/amd64" "$OUT/iso/platform/i86pc/kernel/amd64"
RDIMG="$OUT/boot_archive"; RD="$OUT/rd"
mkfile "${RD_MB}m" "$RDIMG"
LOFI=$(lofiadm -a "$RDIMG")
cleanup() { umount "$RD" 2>/dev/null; lofiadm -d "$LOFI" 2>/dev/null; true; }
trap cleanup EXIT
# newfs asks "Construct a new file system? (y/n)" on a tty only; with stdin from
# /dev/null it does not prompt. NOT `yes | newfs`: under `set -o pipefail` the
# pipeline returns 141 because yes dies of SIGPIPE when newfs exits, so a
# SUCCESSFUL newfs read as a failure (measured: PIPESTATUS=141 0).
newfs -m 1 -i "$RD_NBPI" "${LOFI/dsk/rdsk}" </dev/null >"$OUT/newfs.out" 2>&1 \
  || { cat "$OUT/newfs.out" >&2; die "newfs failed"; }
mount -F ufs -o nologging "$LOFI" "$RD" || die "mount ramdisk failed"

# ---------------------------------------------------------------------------
# 3. THE CLOSURE: nix copy (writes store paths AND the image's own store DB).
# ---------------------------------------------------------------------------
log "nix copy $TOP -> ramdisk store"
nix --extra-experimental-features nix-command copy --no-check-sigs --to "local?root=$RD" "$TOP" >&2 \
  || die "nix copy into the ramdisk failed"
nix-store --store "local?root=$RD" --verify-path "$TOP" || die "toplevel not valid in the ramdisk store"
_n=$(nix-store --store "local?root=$RD" -qR "$TOP" | wc -l | tr -d ' ')
[ "$_n" = "$NPATHS" ] || die "ramdisk store holds $_n of $NPATHS closure paths"
nix-env --store "local?root=$RD" -p "$RD/nix/var/nix/profiles/system" --set "$TOP" >&2 \
  || die "could not set the media's system profile"

# ---------------------------------------------------------------------------
# 4. THE ROOT: the toplevel's own install-be, in live mode (no stage-2 pool mount;
#    the ramdisk root IS the store). Machine inputs first, as on a disk install.
# ---------------------------------------------------------------------------
mkdir -p "$RD/boot/solaris" "$RD/etc"
cat > "$RD/boot/solaris/bootenv.rc" <<EOF
setprop console text,ttya
setprop os_console text,ttya
setprop ttya-mode 115200,8,n,1,-
EOF
# text PRIMARY (keyboard stays on the framebuffer) + ttya MIRROR so a boot that
# dies on the X1 Extreme Gen5 Iris Xe GOP framebuffer console still prints the
# kernel's last line to serial (docs/hardware/x1-gen5-install/x1-gen5-boot-crash-analysis.md).
printf 'console="text,ttya"\nos_console="text,ttya"\n' > "$RD/boot/loader.conf"
: > "$RD/etc/path_to_inst"   # the media boots on unknown hardware: probe everything
log "install-be (SOLNIX_LIVE=1)"
SOLNIX_ROOT="$RD" SOLNIX_STORE_ROOT="$RD" SOLNIX_POOL="$POOL_NAME" SOLNIX_BE=live SOLNIX_CONSOLE=text,ttya SOLNIX_LIVE=1 \
  /sbin/sh "$RD$TOP/bin/install-be" "$TOP" >&2 || die "install-be failed"
grep -q 'zfs mount -O' "$RD/etc/inittab" && die "live root got a stage-2 zfs mount line (SOLNIX_LIVE ignored)"
# install-be builds an installed BE's boot_archive; the live root is itself the
# archive, so an inner one is only dead weight in RAM.
find "$RD/platform/i86pc/amd64" -mindepth 1 -name 'boot_archive*' -delete 2>/dev/null || true
find "$RD/platform/i86pc/amd64/archive_cache" -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. LIVE OVERLAYS: the only files this script writes into the root. Each one is
#    live-media behaviour, the analog of NixOS's installation-device.nix settings
#    that differ from an installed system.
# ---------------------------------------------------------------------------
log "live overlays"
LM=$(rl "$RD$TOP/sw/share/solnix/live-methods")
[ -n "$LM" ] && [ -d "$RD$LM" ] || die "toplevel has no sw/share/solnix/live-methods"
# materialize <path>: make $RD/<path> a REAL directory, replacing each symlinked
# component with a directory of per-entry links into what it pointed at (the shape
# install-be gives /lib). Writing through a link would modify the store -- on the
# build host, the HOST's store, since absolute /nix/store links resolve there.
materialize() {
  _acc="$RD"
  for _c in $(echo "$1" | tr / ' '); do
    _acc="$_acc/$_c"
    [ -h "$_acc" ] || continue
    _t=$(rl "$_acc")
    case "$_t" in /nix/store/*) : ;; *) die "materialize: $_acc -> $_t is not a store link" ;; esac
    rm -f "$_acc"; mkdir -p "$_acc"
    for _e in $(ls -A "$RD$_t"); do ln -s "$_t/$_e" "$_acc/$_e"; done
  done
  [ -d "$_acc" ] && [ ! -h "$_acc" ] || die "materialize: $1 is not a real directory"
}
# 5a. read-only-ramdisk SMF methods: these four point at the patched versions.
materialize lib/svc/method
_md="$RD/lib/svc/method"
for m in fs-root fs-usr svc-dlmgmtd manifest-import; do
  [ -e "$RD$LM/$m" ] || die "live-methods lacks $m"
  rm -f "$_md/$m"; ln -s "$LM/$m" "$_md/$m"
done
# 5a'. /etc/profile, /etc/hosts and /etc/default/login are links into the generation's etc (install-be, NixOS-style /etc/static);
# a write through it would modify the store -- on the build host, the HOST's store,
# since the link resolves there. Replace the link with a copy before appending, the
# media's own live overlay (as materialize does for lib/svc/method).
own_etc() {   # $1 = path under etc/: make it a real file holding what the link pointed at
  [ -h "$RD/etc/$1" ] || return 0
  _t=$(rl "$RD/etc/$1"); case "$_t" in /*) _src="$RD$_t" ;; *) _src="$RD/etc/$(dirname "$1")/$_t" ;; esac
  # a relative link into ../static resolves through etc/static -> <store>/etc
  [ -e "$_src" ] || _src="$RD$(rl "$RD/etc/static")/$1"
  cp "$_src" "$RD/etc/$1.own" && rm -f "$RD/etc/$1" && mv "$RD/etc/$1.own" "$RD/etc/$1" || die "copying /etc/$1 out of the store"
  chmod 0644 "$RD/etc/$1"
}
for _f in profile hosts default/login; do own_etc "$_f"; done
# 5b. root on the media logs in without a password (NixOS installation-device.nix:
#     initialHashedPassword = ""); solnix-install refuses to carry that to a disk.
awk -F: 'BEGIN{OFS=":"} $1=="root"{$2=""} {print}' "$RD/etc/shadow" > "$RD/etc/shadow.new" && mv "$RD/etc/shadow.new" "$RD/etc/shadow"
chmod 0400 "$RD/etc/shadow"
[ -f "$RD/etc/default/login" ] && sed -i 's/^CONSOLE=/#CONSOLE=/; s/^PASSREQ=YES/PASSREQ=NO/' "$RD/etc/default/login"
# 5c. installer entry points: on PATH via /run/current-system/sw/bin (5f).
for t in solnix-install solnix-zap solnix-diag solnix-motd solnix-generate-config; do
  [ -e "$RD$TOP/sw/bin/$t" ] || die "toplevel sw/bin lacks $t"
done
# 5c'. /root/README: the welcome + install steps + tools table (scripts/live/README),
#      a real file so it reads the same with the store unmounted. NixOS's analog
#      is the getty helpLine; solnix-motd points here.
_rm=$(rl "$RD$TOP/sw/share/solnix/README")
[ -n "$_rm" ] && [ -f "$RD$_rm" ] || die "toplevel has no sw/share/solnix/README"
mkdir -p "$RD/root" && cp "$RD$_rm" "$RD/root/README" && chmod 0644 "$RD/root/README" || die "writing /root/README"
# 5d. the live hostname answers locally (login-path DNS stall, measured ~3.5 s per lookup).
grep -qw solnix-installer "$RD/etc/hosts" 2>/dev/null || echo "127.0.0.1 solnix-installer" >> "$RD/etc/hosts"
# 5e. the media starts with NO resolver and NO persistent addresses; solnix-autonet
#     plumbs the first wired NIC by DHCP (the build host's would poison DNS elsewhere).
: > "$RD/etc/resolv.conf"
[ -f "$RD/etc/ipadm/ipadm.conf" ] && { grep -v '_aobjname=' "$RD/etc/ipadm/ipadm.conf" > "$RD/etc/ipadm/ipadm.conf.n"; mv "$RD/etc/ipadm/ipadm.conf.n" "$RD/etc/ipadm/ipadm.conf"; }
# 5e'. MOUNT /etc/svc/volatile + /system/volatile AS TMPFS BEFORE svc.startd.
#     On a normal illumos root these ARE swap/tmpfs (measured on the build host:
#     "/etc/svc/volatile on swap"), where svc.configd keeps its NONPERSISTENT
#     repository (repository_door) and its core path (/etc/svc/volatile/core.configd.%p).
#     svc.startd mounts them early -- but its mount depends on first remounting the
#     root read-write, and on this UFS RAMDISK the stock mountpoint-only remount
#     FAILS (the very reason fs-root is patched). So on the live root volatile was
#     left a plain directory ON the 37-MB UFS ramdisk; svc.configd's working repo +
#     a daemon core then filled it and SMF died behind the login prompt (MEASURED:
#     "svc.configd no space left on device" -> "ufs realloccg /: file system full"
#     -> "svc.startd: Repository server out of resources").
#     Fix: an inittab sysinit entry, which init(1M) runs in order BEFORE
#     smf::sysinit:svc.startd, mounts both as swap/tmpfs. A tmpfs mount over a
#     directory needs no writable backing fs, so it works on the still-RO ramdisk.
#     This is the structural root cause (volatile belongs in RAM, as on any illumos
#     root), not symptom relief.
if ! grep -q '^vol::sysinit' "$RD/etc/inittab"; then
  _volcmd='/sbin/mount -F tmpfs -o size=256m swap /system/volatile >/dev/msglog 2>&1; /sbin/mount -F tmpfs -o size=256m swap /etc/svc/volatile >/dev/msglog 2>&1'
  awk -v c="$_volcmd" '
    /::sysinit:/ && !d { print "vol::sysinit:" c " </dev/console"; d=1 }
    { print }
    END { if (!d) exit 7 }
  ' "$RD/etc/inittab" > "$RD/etc/inittab.n" && mv "$RD/etc/inittab.n" "$RD/etc/inittab" \
    || die "could not insert the volatile-tmpfs sysinit line into inittab"
  grep -q '^vol::sysinit' "$RD/etc/inittab" || die "volatile-tmpfs sysinit line not present after edit"
fi
# 5f. login motd + PATH (GNU tools first: illumos diff prints "No differences encountered").
cat >> "$RD/etc/profile" <<'EOF'
# solnix installer media
PATH=/run/current-system/sw/bin:/usr/gnu/bin:/usr/sbin:/usr/bin:/sbin; export PATH
[ -z "${SOLNIX_MOTD_SHOWN:-}" ] && { solnix-motd 2>/dev/null; SOLNIX_MOTD_SHOWN=1; export SOLNIX_MOTD_SHOWN; }
EOF

# ---------------------------------------------------------------------------
# 6. OFFLINE SMF PRE-IMPORT: the read-only live root cannot import manifests at
#    boot, so import every manifest + apply the profiles now, with the IMAGE's own
#    svccfg (from its store, against its own repository).
# ---------------------------------------------------------------------------
log "pre-importing SMF manifests into the ramdisk repository"
# the image's own svccfg + svc.configd (store paths, valid in this host's store
# because the closure was realised here), not the build host's SMF tools.
WORLD=$(rl "$RD$TOP/world")
SVCCFG="$WORLD/usr/sbin/svccfg"; SVCCFG_CONFIGD_PATH="$WORLD/lib/svc/bin/svc.configd"; export SVCCFG_CONFIGD_PATH
[ -x "$SVCCFG" ] && [ -x "$SVCCFG_CONFIGD_PATH" ] || die "world has no svccfg/svc.configd"
_dtd="$RD/usr/share/lib/xml/dtd/service_bundle.dtd.1"
_nimp=0; _nfail=0
for _m in $(find -L "$RD/lib/svc/manifest" "$RD/var/svc/manifest" -name '*.xml' 2>/dev/null); do
  if SVCCFG_CHECKHASH=1 SVCCFG_DTD="$_dtd" SVCCFG_REPOSITORY="$RD/etc/svc/repository.db" "$SVCCFG" import "$_m" >/dev/null 2>&1
  then _nimp=$((_nimp+1)); else _nfail=$((_nfail+1)); echo "WARN: import failed: ${_m#$RD}" >&2; fi
done
for _p in generic.xml platform.xml name_service.xml site/solnix.xml; do
  [ -e "$RD/etc/svc/profile/$_p" ] || continue
  SVCCFG_DTD="$_dtd" SVCCFG_REPOSITORY="$RD/etc/svc/repository.db" "$SVCCFG" apply "$RD/etc/svc/profile/$_p" \
    || die "svccfg apply $_p failed"
done
echo "pre-imported $_nimp manifests ($_nfail failed)" >&2
[ "$_nimp" -gt 50 ] || die "only $_nimp manifests imported -- the live root would not reach single-user"
# importing ran a private svc.configd: purge the runtime state it left (a stale
# init.state makes PID 1 re-exit in a SIGKILL loop, measured on earlier media).
find "$RD/etc/svc/volatile" -mindepth 1 -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. GATES on the finished root, then gzip. Each failed silently on old media.
# ---------------------------------------------------------------------------
log "verifying the live root"
for need in sbin/init etc/inittab lib/svc/bin/svc.startd etc/svc/repository.db platform/i86pc/kernel/amd64/unix \
            kernel/amd64/genunix dev/console dev/null run/current-system nix/var/nix/profiles/system; do
  [ -e "$RD/$need" ] || [ -h "$RD/$need" ] || die "live root lacks /$need"
done
[ "$(rl "$RD/run/current-system")" = "$TOP" ] || die "/run/current-system is not $TOP"
# every absolute symlink in the root must resolve INSIDE it (a dangling link is
# a missing file at boot: the vi/df/openssl class of defect)
# (targets on runtime filesystems -- devfs, proc, tmpfs, ctfs -- exist only after boot)
find "$RD" -type l 2>/dev/null | while read -r l; do
  t=$(rl "$l")
  case "$t" in /dev/*|/devices/*|/proc/*|/system/*|/tmp/*|/var/run/*|/etc/svc/volatile/*) continue ;; esac
  case "$t" in /*) [ -e "$RD$t" ] || [ -h "$RD$t" ] || echo "DANGLING: ${l#$RD} -> $t" ;; esac
done > "$OUT.dangling"
_dang=$(grep -c . "$OUT.dangling" || true)
[ "$_dang" = 0 ] || { head -20 "$OUT.dangling" >&2; die "$_dang absolute symlinks in the live root resolve to nothing"; }
_freek=$(df -k "$RD" | awk 'NR==2{print $4}')
[ "$_freek" -ge "$RD_MIN_FREE_KB" ] || die "ramdisk has only ${_freek} KB free (< $RD_MIN_FREE_KB): UFS overhead above ${UFS_OVERHEAD_PCT}%"
_freei=$(df -i "$RD" | awk 'NR==2{print $4}')
[ "$_freei" -ge 5000 ] || die "ramdisk has only $_freei free inodes; lower RD_NBPI"
echo "live root OK: ${_freek} KB + $_freei inodes free, 0 dangling links" >&2
sync; umount "$RD"; lofiadm -d "$LOFI"; trap - EXIT
RAW=$(wc -c < "$RDIMG" | tr -d ' ')
[ "$RAW" -le "$RD_MAX_RAW" ] || die "raw boot_archive $RAW B > cap $RD_MAX_RAW B"
gzip -1 -c "$RDIMG" > "$OUT/iso/platform/i86pc/amd64/boot_archive"
echo "boot_archive: $RAW B raw (EFI staging size), $(wc -c < "$OUT/iso/platform/i86pc/amd64/boot_archive" | tr -d ' ') B gzipped" >&2

# ---------------------------------------------------------------------------
# 8. ISO staging tree: the loader + kernel come FROM THE TOPLEVEL's kernel slice,
#    never from this host's /boot.
# ---------------------------------------------------------------------------
log "ISO staging tree"
KS=$(rl "$TOP/kernel-slice")
[ -n "$KS" ] && [ -d "$KS/boot" ] || die "toplevel has no kernel-slice/boot"
( cd "$KS" && tar cf - boot ) | ( cd "$OUT/iso" && tar xf - )
chmod -R u+w "$OUT/iso/boot"
cp "$KS/platform/i86pc/kernel/amd64/unix" "$OUT/iso/platform/i86pc/kernel/amd64/unix"
cp "$KS/boot/loader64.efi" "$OUT/loader64.efi"
cp "$KS/boot/cdboot" "$OUT/cdboot"
# brand the menu (make-iso-usb.sh rewrites loader.conf; menu.4th is ours to patch)
_mt="$OUT/iso/boot/forth/menu.4th"
grep -q 'Welcome to illumos' "$_mt" && sed -i 's/Welcome to illumos/Welcome to solnix /' "$_mt"
echo "$TOP" > "$OUT/iso/.solnix-toplevel"
( cd "$OUT" && tar cf - iso loader64.efi cdboot | gzip -1 > solnix-iso-tree.tar.gz )
log "DONE: $OUT/solnix-iso-tree.tar.gz (toplevel $TOP, $NPATHS store paths)"
echo "next: scripts/make-iso-usb.sh $OUT/solnix-iso-tree.tar.gz <outdir>  (SOLNIX_NO_MEDIA_STORE=1: the store is in the ramdisk)" >&2
