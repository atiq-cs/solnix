#!/usr/bin/env bash
# oi-make-livecd.sh — build a solnix LIVE INSTALLER ramdisk + ISO staging tree
# on the illumos build host (T2.7 installer media / T2.13 ISO).
#
# Run ON the illumos build host as root. Produces, under $OUT (default
# /var/tmp/solnix-media), a self-contained ISO staging tree:
#
#   $OUT/iso/boot/...                        the illumos loader (BIOS+UEFI)
#   $OUT/iso/platform/i86pc/kernel/amd64/unix        the kernel
#   $OUT/iso/platform/i86pc/amd64/boot_archive       the LIVE ramdisk (UFS image)
#   $OUT/iso/platform/i86pc/amd64/boot_archive.hash
#   $OUT/loader64.efi                        copied out for the ESP (UEFI)
#
# then TARs $OUT/iso -> $OUT/solnix-iso-tree.tar.gz to ship to the assembler,
# which wraps it into a hybrid ISO (BIOS El Torito cdboot + UEFI ESP) + a
# dd-able USB GPT image and qemu-boot-tests both.
#
# WHY a UFS ramdisk (not cpio): the illumos loader loads boot_archive as
# `boot_archive_type=rootfs`; the kernel then mounts /ramdisk:a as the ROOT
# filesystem. The installed-system boot_archive is a small cpio (drivers only,
# then pivots to the ZFS bootfs). LIVE media has no ZFS root to pivot to, so its
# boot_archive IS the whole live root -- a UFS image the kernel mounts as `/`.
# (Kernel strings: "mounting ramdisk as hsfs" / "/ramdisk:a"; bootadm knows
# mc_fstype=="ufs".) This is the OI/OmniOS text-install-media convention.
#
# The live root is a MINIMAL slice of the running illumos root (~600-800MB, not
# the full 10.7G): kernel + all drivers + core libc/rtld + zfs/zpool/format/
# fmthard/installboot/bootadm + /sbin/sh + scripts/solnix-install. On boot it
# drops to a root shell that prints a solnix banner and how to run solnix-install
# against a scratch disk.
#
# Reuses the make-be gotchas: dir perms 0555->0755, essential /dev symlinks,
# driver-config files (name_to_major etc), ttya console.
set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/usr/gnu/bin:/sbin
OUT="${OUT:-/var/tmp/solnix-media}"
SRC="${SRC:-/}"                          # the running root we slice from
RD_MB="${RD_MB:-450}"                     # ramdisk size (MB); ldd-closure tool set is
                                          # ~130MB du, ~215MB on UFS. Tight for the loader heap.
INSTALLER="${INSTALLER:-/var/tmp/solnix-install}"   # scripts/solnix-install, scp'd here
LABEL="${LABEL:-SOLNIX_INSTALL}"

die()  { echo "FATAL: $*" >&2; exit 1; }
log()  { printf '\n=== %s ===\n' "$*" >&2; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$INSTALLER" ] || die "installer $INSTALLER not present (scp scripts/solnix-install there first)"

# --- clean any prior attempt (lofi + mounts) --------------------------------
log "cleaning prior attempt"
umount "$OUT/rd" 2>/dev/null || true
for l in $(lofiadm 2>/dev/null | awk 'NR>1{print $1}'); do
  case "$(lofiadm 2>/dev/null | awk -v L="$l" '$1==L{print $2}')" in
    "$OUT"/*) umount "$l" 2>/dev/null || true; lofiadm -d "$l" 2>/dev/null || true;;
  esac
done
rm -rf "$OUT"
mkdir -p "$OUT/iso/boot" "$OUT/iso/platform/i86pc/kernel" "$OUT/iso/platform/i86pc/amd64" "$OUT/rd"

RDROOT="$OUT/rd"
RDIMG="$OUT/boot_archive"

# ---------------------------------------------------------------------------
# 1. create + newfs the UFS ramdisk image, mount via lofi
# ---------------------------------------------------------------------------
log "creating ${RD_MB}MB UFS ramdisk image (staging; right-sized + gzipped at the end)"
mkfile "${RD_MB}m" "$RDIMG"
LOFI=$(lofiadm -a "$RDIMG") || die "lofiadm -a failed"
log "lofi = $LOFI ; newfs"
yes | newfs -m 1 "${LOFI/dsk/rdsk}" >/dev/null 2>&1 || newfs -m 1 "$LOFI" >/dev/null 2>&1 || \
  newfs "$LOFI" >/dev/null 2>&1 || die "newfs failed"
mount -F ufs -o nologging "$LOFI" "$RDROOT" || die "mount ramdisk failed"

# ---------------------------------------------------------------------------
# 2. populate the live root: copy the essential subtrees from the running root.
#    NOT the whole 10.7G — just what boots + partitions + zpools + installs.
# ---------------------------------------------------------------------------
log "populating live root (MINIMAL essential subtrees from $SRC)"
# The BIOS loader stages the WHOLE boot_archive into a limited heap; a 2.7G
# image OOMs it ("No rootfs module provided"). So keep the live root tiny
# (~350MB): drivers + libc closure + the zfs/format/installboot tools. Do NOT
# copy platform/i86pc/amd64 (it holds only the host's own boot_archive junk,
# no drivers) or the desktop/scripting cruft in /usr/lib.
#
# 64-bit tool closure lives in /lib (incl /lib/amd64) + /usr/lib/amd64.
COPY_DIRS="
  platform/i86pc/kernel
  kernel
  usr/kernel
  lib
  sbin
  usr/lib/fs
  usr/lib/64
  etc/svc/profile
  etc/default
  etc/security
"
mkdir -p "$RDROOT"/usr/sbin "$RDROOT"/usr/bin "$RDROOT"/usr/lib "$RDROOT"/dev "$RDROOT"/devices \
         "$RDROOT"/proc "$RDROOT"/system/contract "$RDROOT"/system/object "$RDROOT"/tmp \
         "$RDROOT"/var/run "$RDROOT"/var/tmp "$RDROOT"/mnt "$RDROOT"/a "$RDROOT"/root "$RDROOT"/nix \
         "$RDROOT"/etc/dev "$RDROOT"/etc/svc/volatile "$RDROOT"/system/boot "$RDROOT"/etc/dfs

for d in $COPY_DIRS; do
  [ -e "$SRC/$d" ] || continue
  mkdir -p "$RDROOT/$(dirname "$d")"
  ( cd "$SRC" && tar -cf - "$d" ) | ( cd "$RDROOT" && tar -xf - ) || echo "WARN: copy $d had errors" >&2
done

# /usr/lib libs: copy ONLY the ldd closure of the installer tools (not the whole
# 336MB /usr/lib/amd64 which is mostly gstreamer/db/etc cruft). The full /lib
# tree above already carries the /lib/64 half of the closure; here we add the
# /usr/lib half. Compute the closure with ldd, copy each referenced .so (follow
# symlinks so the real file lands + recreate the soname link).
log "copying ldd closure of installer tools from /usr/lib"
CLOSURE_TOOLS="/sbin/zpool /sbin/zfs /usr/sbin/format /usr/sbin/fmthard
  /usr/sbin/prtvtoc /usr/sbin/newfs /usr/sbin/mkfs /usr/sbin/installboot
  /usr/sbin/bootadm /usr/sbin/devfsadm /usr/sbin/dladm /usr/sbin/ipadm
  /usr/sbin/ifconfig /usr/sbin/prtconf /usr/sbin/init /usr/sbin/mount
  /usr/sbin/umount /usr/bin/ksh93 /usr/bin/bash /sbin/sh /sbin/init
  /usr/bin/ls /usr/bin/cp /usr/bin/tar /usr/bin/sed /usr/bin/awk
  /usr/bin/grep /usr/bin/date /usr/bin/find /usr/bin/vi /usr/bin/file"
for t in $CLOSURE_TOOLS; do
  [ -e "$SRC$t" ] && ldd "$SRC$t" 2>/dev/null | awk '{print $3}'
done | grep '^/usr/lib' | sort -u | while read -r libpath; do
  rel="${libpath#/}"
  # /usr/lib/64 is a symlink to amd64 in our tree; normalize the DEST so mkdir
  # doesn't try to mkdir over the symlink. Source read follows the symlink fine.
  dest_rel=$(echo "$rel" | sed 's,^usr/lib/64/,usr/lib/amd64/,')
  mkdir -p "$RDROOT/$(dirname "$dest_rel")"
  cp "$SRC/$rel" "$RDROOT/$dest_rel" 2>/dev/null || true
done
# Do NOT glob-copy /usr/lib/*.so* or /usr/lib/amd64/*.so* wholesale — that
# pulls ~650MB of unrelated libs (libicudata, libopenal, ...) and overflows the
# ramdisk. The ldd closure above already copied EXACTLY the libs the tools link.

# the installer tools: copy ONLY the specific binaries solnix-install +
# the live shell need, NOT all of /usr/bin (which holds git w/ 150 hardlinks
# @5MB, ghostscript @34MB, etc — tar-without-hardlink-preservation would
# explode git alone to ~800MB). Curated list keeps the ramdisk tiny.
LIVE_TOOLS="
  sbin/sh sbin/init sbin/zpool sbin/zfs sbin/mount sbin/umount sbin/uname
  sbin/autopush sbin/dhcpagent sbin/ifconfig
  usr/bin/ksh93 usr/bin/bash usr/bin/cat usr/bin/ls usr/bin/cp usr/bin/mv
  usr/bin/mkdir usr/bin/rmdir usr/bin/rm usr/bin/ln usr/bin/sed usr/bin/nawk
  usr/bin/grep usr/bin/egrep usr/bin/fgrep usr/bin/tar usr/bin/cpio
  usr/bin/awk usr/bin/gawk
  usr/bin/date usr/bin/id usr/bin/find usr/bin/sort usr/bin/head usr/bin/tail
  usr/bin/tr usr/bin/cut usr/bin/wc usr/bin/strings usr/bin/uname usr/bin/df
  usr/bin/du usr/bin/echo usr/bin/printf usr/bin/expr usr/bin/dirname
  usr/bin/basename usr/bin/hostname usr/bin/sleep usr/bin/kill usr/bin/chmod
  usr/bin/chown usr/bin/chgrp usr/bin/mount usr/bin/umount usr/bin/sync
  usr/bin/yes usr/bin/file usr/bin/vi usr/bin/more usr/bin/less usr/bin/tee
  usr/bin/env usr/bin/test usr/bin/true usr/bin/false usr/bin/sh usr/bin/pfexec
  usr/bin/digest usr/bin/openssl usr/bin/od usr/bin/xargs usr/bin/mkfile
  usr/sbin/zpool usr/sbin/zfs usr/sbin/format usr/sbin/fmthard usr/sbin/prtvtoc
  usr/sbin/mkfs usr/sbin/newfs usr/sbin/fsck usr/sbin/installboot
  usr/sbin/bootadm usr/sbin/lofiadm usr/sbin/devfsadm usr/sbin/dladm
  usr/sbin/ipadm usr/sbin/ifconfig usr/sbin/prtconf usr/sbin/init
  usr/sbin/mount usr/sbin/umount usr/sbin/svcadm usr/sbin/svccfg usr/sbin/prtdiag
  usr/sbin/fdisk usr/sbin/format usr/sbin/zdb usr/sbin/dumpadm
"
# build an INCLUDE list of paths that exist, then tar them in one pass so tar
# PRESERVES hardlinks (the amd64/ isaexec dispatch dirs come along per-tool).
: > /tmp/solnix-tools.list
for t in $LIVE_TOOLS; do
  [ -e "$SRC/$t" ] && echo "$t" >> /tmp/solnix-tools.list
  # bring the 64-bit ISA variant if present (isaexec dispatches to it)
  d=$(dirname "$t"); b=$(basename "$t")
  [ -e "$SRC/$d/amd64/$b" ] && echo "$d/amd64/$b" >> /tmp/solnix-tools.list
done
# tar the curated list in ONE pass (preserves hardlinks). illumos tar has no
# working -I/-T include-file, so pass the paths as args via xargs (the list is
# ~110 entries, well under ARG_MAX).
( cd "$SRC" && tr '\n' ' ' < /tmp/solnix-tools.list | xargs tar -cf - 2>/dev/null ) \
  | ( cd "$RDROOT" && tar -xf - ) 2>/dev/null || echo "WARN: tool copy had errors" >&2

# /sbin/sh ships as a symlink to the 32-bit ../usr/bin/i86/ksh93 (needs 32-bit
# libs we don't carry). Repoint it at the 64-bit /usr/bin/ksh93 (which is the
# real AMD64 shell, not an isaexec stub) so init can exec a shell. Same for the
# amd64 variant symlink chain.
rm -f "$RDROOT/sbin/sh"
ln -s ../usr/bin/ksh93 "$RDROOT/sbin/sh"
[ -e "$RDROOT/usr/bin/amd64/ksh93" ] || { mkdir -p "$RDROOT/usr/bin/amd64"; ln -s ../../bin/ksh93 "$RDROOT/usr/bin/amd64/ksh93" 2>/dev/null || true; }
# a couple of core tools are also isaexec/i86 links; point /usr/bin/sh at ksh93.
rm -f "$RDROOT/usr/bin/sh" 2>/dev/null; ln -s ksh93 "$RDROOT/usr/bin/sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. make-be gotchas applied to the live root
# ---------------------------------------------------------------------------
log "applying gotchas (dir perms, /dev symlinks, driver-config, /etc essentials)"
# 3a. dir write perms (proto-style 0555 dirs break writers; harmless on a copy)
find "$RDROOT" -type d -exec chmod u+w {} + 2>/dev/null || true
chmod 1777 "$RDROOT/tmp" "$RDROOT/var/tmp" 2>/dev/null || true

# 3b. essential /dev symlinks (console/msglog/null; startd stdio)
for n in console msglog null zero tty syscon systty sysmsg random urandom poll; do
  [ -L "/dev/$n" ] && ln -sf "$(/usr/bin/readlink /dev/$n)" "$RDROOT/dev/$n" 2>/dev/null || true
done

# 3c. driver-config files (name_to_major etc. — without rootnex kernel panics)
mkdir -p "$RDROOT/etc/security"
for f in name_to_major name_to_sysnum driver_aliases driver_classes minor_perm \
         system path_to_inst mnttab vfstab nsswitch.conf passwd shadow group \
         hosts netconfig; do
  [ -e "/etc/$f" ] && cp "/etc/$f" "$RDROOT/etc/$f" 2>/dev/null || true
done
cp /etc/security/device_policy "$RDROOT/etc/security/device_policy" 2>/dev/null || true
[ -f "$RDROOT/etc/hostid" ] || printf '0x1b0b57ec\n' > "$RDROOT/etc/hostid"

# 3c'. devfsadm link-generator modules + devlink.tab — WITHOUT these devfsadm
#      can't create the /dev/dsk + /dev/rdsk cNtNdN links, so zpool/format/the
#      installer can't find any disk. Only ~210KB.
[ -d /usr/lib/devfsadm ] && ( cd / && tar -cf - usr/lib/devfsadm ) | ( cd "$RDROOT" && tar -xf - ) 2>/dev/null || true
for f in devlink.tab; do [ -e "/etc/$f" ] && cp "/etc/$f" "$RDROOT/etc/$f" 2>/dev/null || true; done

# 3d. ttya console (serial — so qemu -nographic shows the banner)
mkdir -p "$RDROOT/boot/solaris"
cat > "$RDROOT/boot/solaris/bootenv.rc" <<'EOF'
setprop console text
EOF

# ---------------------------------------------------------------------------
# 4. drop in scripts/solnix-install + a first-boot banner via /etc/rc/init
# ---------------------------------------------------------------------------
log "installing solnix-install + live banner"
mkdir -p "$RDROOT/usr/sbin"
cp "$INSTALLER" "$RDROOT/usr/sbin/solnix-install"
chmod 0555 "$RDROOT/usr/sbin/solnix-install"

# PID-1 model: illumos /sbin/init is a thin wrapper that execs svc.startd; a
# ramdisk without a full SMF repo makes it exit -> SIGKILL respawn loop. For a
# pure installer live env we REPLACE /sbin/init with our own PID-1 shell wrapper
# that NEVER exits (loops re-spawning the interactive shell). The kernel execs
# /sbin/init as PID 1; making it our looping script gives the installer UX with
# no SMF. Keep the real init at /sbin/init.real in case someone wants SMF.
[ -e "$RDROOT/sbin/init.real" ] || cp "$SRC/sbin/init" "$RDROOT/sbin/init.real" 2>/dev/null || true
cat > "$RDROOT/sbin/init" <<'EOF'
#!/usr/bin/ksh93
# solnix live-installer PID 1. Must NEVER exit (kernel SIGKILL-respawns PID 1).
PATH=/usr/sbin:/usr/bin:/sbin:/usr/gnu/bin; export PATH TERM=vt100 TMPDIR=/tmp
# The ramdisk root (/ramdisk:a, ufs) is mounted READ-ONLY and cannot be
# remounted rw. The illumos live-media model instead mounts the pseudo
# filesystems + tmpfs over the writable dirs. mount(1M) needs the mnttab fs
# live first (else "Invalid argument" writing /etc/mnttab), and /proc for ps.
# CRITICAL ORDERING: the generic mount(1M) opens /etc/mnttab O_RDWR at startup;
# on our READ-ONLY ramdisk root that open fails and mount aborts before doing
# anything (deadlock: can't mount mnttab because mount needs mnttab writable).
# Break it by invoking the fstype-specific mntfs helper DIRECTLY (it does the
# mount(2) syscall without the generic's mnttab open). Once mnttab is the live
# mntfs, subsequent generic mounts work.
/usr/lib/fs/mntfs/mount mnttab /etc/mnttab >/dev/console 2>&1 || \
  /usr/sbin/mount -F mntfs mnttab /etc/mnttab >/dev/console 2>&1 || \
  echo "[solnix] WARN: mnttab mount failed" >/dev/console
/usr/sbin/mount -F proc proc /proc >/dev/console 2>&1 || true
/usr/sbin/mount -F ctfs ctfs /system/contract >/dev/console 2>&1 || true
/usr/sbin/mount -F objfs objfs /system/object >/dev/console 2>&1 || true
# Make the ramdisk root WRITABLE. illumos ufs remount needs BOTH the device and
# the mountpoint: `mount -F ufs -o remount,rw <dev> <mnt>` (the mnt-only form
# gives "Invalid argument"). The root device for a boot_archive ramdisk is
# /devices/ramdisk:a. With rw root, devfsadm can create /dev/dsk links, the
# installer can write /a, temp files, etc.
_root_dev=$(/usr/bin/awk '$2=="/"{print $1; exit}' /etc/mnttab 2>/dev/null)
[ -n "$_root_dev" ] || _root_dev=/devices/ramdisk:a
for _d in "$_root_dev" /devices/ramdisk:a /devices/ramdisk-root:a; do
  if /usr/sbin/mount -F ufs -o remount,rw "$_d" / >/dev/console 2>&1; then
    echo "[solnix] root remounted rw via $_d" >/dev/console; break
  fi
done
# /devices (devfs) so devfsadm has the physical tree; /dev (dev fs) writable so
# devfsadm can create the /dev/dsk + /dev/rdsk cNtNdN links.
/usr/sbin/mount -F devfs /devices /devices >/dev/console 2>&1 || true
/usr/sbin/mount -F dev /dev /dev >/dev/console 2>&1 || true
# tmpfs over dirs that MUST be writable even if the root remount somehow failed
# (belt-and-braces; harmless when root is already rw). /a is a real mountpoint
# the installer replaces with the target ZFS BE.
for d in /tmp /var/run /var/tmp; do
  mkdir -p $d 2>/dev/null
  /usr/sbin/mount -F tmpfs swap $d >/dev/console 2>&1 || true
done
chmod 1777 /tmp /var/tmp 2>/dev/null
# bring up device nodes so zpool/format/installboot see the disks
/usr/sbin/devfsadm >/dev/console 2>&1 || true
# AUTO-INSTALL hook: if /etc/solnix-autoinstall names a target disk, run the
# installer non-interactively (for the automated qemu install test), print a
# clear DONE/FAIL marker, then drop to a shell. Otherwise interactive.
if [ -r /etc/solnix-autoinstall ]; then
  _tgt=$(cat /etc/solnix-autoinstall 2>/dev/null)
  # "auto" => pick the first whole disk with an s0 node that isn't the boot
  # cdrom (the scratch NVMe/blkdev target attached for the install test).
  if [ "$_tgt" = auto ] || [ -z "$_tgt" ]; then
    for _c in /dev/rdsk/c*t*d0s0 /dev/rdsk/c*d0s0; do
      [ -e "$_c" ] || continue
      _d=$(basename "$_c"); _d=${_d%s0}
      _tgt=$_d; break
    done
  fi
  echo "[solnix] AUTO-INSTALL to ${_tgt:-<none found>}" >/dev/console
  /usr/sbin/format </dev/null >/dev/console 2>&1 || true
  if [ -n "$_tgt" ]; then
    ( SOLNIX_POOL=rpool SOLNIX_ALLOW_RPOOL=1 /usr/sbin/solnix-install "$_tgt" \
        && echo "SOLNIX_AUTOINSTALL_RESULT: DONE" \
        || echo "SOLNIX_AUTOINSTALL_RESULT: FAIL rc=$?" ) >/dev/console 2>&1
  else
    echo "SOLNIX_AUTOINSTALL_RESULT: FAIL no-target-disk" >/dev/console
  fi
fi
while : ; do
  /etc/solnix-live-shell </dev/console >/dev/console 2>&1
  echo "" >/dev/console
  echo "[solnix] installer shell exited; respawning. Ctrl-D again to loop." >/dev/console
  sleep 1
done
EOF
chmod 0555 "$RDROOT/sbin/init"

# optional auto-install marker (AUTOINSTALL_DISK=c1t1d0 for the automated test)
if [ -n "${AUTOINSTALL_DISK:-}" ]; then
  echo "$AUTOINSTALL_DISK" > "$RDROOT/etc/solnix-autoinstall"
  log "auto-install marker set: target=$AUTOINSTALL_DISK"
fi

# init spawns our live shell directly (no SMF/svc.startd needed in the ramdisk).
# We replace /sbin/init above with a looping PID-1 wrapper; this inittab is only
# a fallback if a real init ever runs. Keep it SMF-free.
cat > "$RDROOT/etc/inittab" <<'EOF'
ap::sysinit:/sbin/autopush -f /etc/iu.ap
co:234:respawn:/etc/solnix-live-shell </dev/console >/dev/console 2>&1
EOF
# If svc.startd is too heavy for the ramdisk we fall back to a pure-shell init
# (see loader boot-args below: init=/etc/solnix-live-shell bypasses inittab).
cat > "$RDROOT/etc/solnix-live-shell" <<'EOF'
#!/usr/bin/ksh93
PATH=/usr/sbin:/usr/bin:/sbin:/usr/gnu/bin
export PATH TERM=vt100 TMPDIR=/tmp
cat <<'BANNER'

  ############################################################
  #                                                          #
  #        The Solnix Operating System — Live Installer      #
  #                  (x86_64 / illumos)                      #
  #                                                          #
  ############################################################

  This is the solnix live installer environment (ramdisk root).

  To install solnix to a disk:

    1. List disks:      format </dev/null   (Ctrl-D to exit)
    2. Install:         solnix-install <target-disk>
                        e.g.  solnix-install c1t1d0
    3. Reboot:          init 6   (remove the install media)

  solnix-install partitions the disk (ESP + ZFS), creates rpool,
  installs a boot environment, and runs installboot.

BANNER
exec /usr/bin/ksh93 2>/dev/null || exec /sbin/sh
EOF
chmod 0555 "$RDROOT/etc/solnix-live-shell"
# autopush needs iu.ap; copy if present, else stub
[ -e /etc/iu.ap ] && cp /etc/iu.ap "$RDROOT/etc/iu.ap" 2>/dev/null || : > "$RDROOT/etc/iu.ap"

cat > "$RDROOT/etc/solnix-release" <<EOF
The Solnix Operating System — live installer media
built: $(date -u +%FT%TZ 2>/dev/null || date)
host:  $(uname -a)
EOF

# path_to_inst so device enumeration works
[ -f "$RDROOT/etc/path_to_inst" ] || cp /etc/path_to_inst "$RDROOT/etc/path_to_inst" 2>/dev/null || : > "$RDROOT/etc/path_to_inst"

# ---------------------------------------------------------------------------
# 5. finalize the ramdisk: unmount, then GZIP it. The illumos loader auto-
#    decompresses a gzipped boot_archive (strings: "%s.gz", inflate, zf_open);
#    the kernel then mounts /ramdisk:a. Gzip cuts the on-media size ~4x and, more
#    importantly, the loader only reads the compressed file from media then
#    inflates — but it still needs the DECOMPRESSED image to fit its heap, so the
#    raw image is kept tight (RD_MB). Keep BOTH the .gz name the loader expects.
# ---------------------------------------------------------------------------
log "finalizing ramdisk"
df -k "$RDROOT" 2>/dev/null | awk 'NR==2{print "live root: "$3"KB used / "$2"KB total"}' >&2
sync
umount "$RDROOT" || die "umount ramdisk failed"
lofiadm -d "$LOFI" || true
log "gzipping ramdisk (loader auto-inflates)"
gzip -1 -c "$RDIMG" > "$RDIMG.gz"
ls -la "$RDIMG" "$RDIMG.gz" >&2

# ---------------------------------------------------------------------------
# 6. assemble the ISO staging tree: loader + kernel + the ramdisk boot_archive
# ---------------------------------------------------------------------------
log "assembling ISO staging tree"
# 6a. the whole /boot loader tree (cdboot, isoboot, loader, forth/, defaults/)
( cd / && tar -cf - boot ) | ( cd "$OUT/iso" && tar -xf - )
# 6b. kernel
mkdir -p "$OUT/iso/platform/i86pc/kernel/amd64" "$OUT/iso/platform/i86pc/amd64"
cp "$SRC/platform/i86pc/kernel/amd64/unix" "$OUT/iso/platform/i86pc/kernel/amd64/unix"
# 6c. the live boot_archive (our GZIPPED UFS ramdisk) + hash. The loader inflates
#     it; the kernel mounts the inflated image as /ramdisk:a (rootfs).
cp "$RDIMG.gz" "$OUT/iso/platform/i86pc/amd64/boot_archive"
( cd "$OUT/iso/platform/i86pc/amd64" && digest -a sha1 boot_archive > boot_archive.hash 2>/dev/null ) || \
  ( cd "$OUT/iso/platform/i86pc/amd64" && sha1sum boot_archive | awk '{print $1}' > boot_archive.hash ) || \
  : > "$OUT/iso/platform/i86pc/amd64/boot_archive.hash"

# 6d. loader.conf: text console, load our ramdisk as rootfs, autoboot the live
#     shell. init=/etc/solnix-live-shell bypasses SMF for a pure installer UX.
cat > "$OUT/iso/boot/loader.conf" <<'EOF'
loader_logo="illumos"
console="text"
autoboot_delay="5"
boot_archive_load="YES"
boot_archive_type="rootfs"
boot_archive_name="/platform/i86pc/amd64/boot_archive"
boot_archive.hash_load="YES"
boot_archive.hash_type="hash"
boot_archive.hash_name="/platform/i86pc/amd64/boot_archive.hash"
kernel="/platform/i86pc/kernel/amd64/unix"
bootfile="unix"
boot-args="-B init=/etc/solnix-live-shell"
EOF

# 6e. copy the UEFI loader out so the assembler can build the ESP FAT image
cp /boot/loader64.efi "$OUT/loader64.efi"
cp /boot/cdboot "$OUT/cdboot" 2>/dev/null || true

# 6f. tar up the staging tree for shipping
log "packing solnix-iso-tree.tar.gz"
( cd "$OUT" && tar -cf - iso loader64.efi cdboot 2>/dev/null | gzip -1 > solnix-iso-tree.tar.gz )
ls -la "$OUT"/solnix-iso-tree.tar.gz "$OUT/iso/platform/i86pc/amd64/boot_archive"

log "DONE: staging tree at $OUT/iso ; tarball $OUT/solnix-iso-tree.tar.gz"
echo "scp $OUT/solnix-iso-tree.tar.gz back, then assemble the hybrid ISO + USB img locally." >&2
