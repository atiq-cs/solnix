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
# GRAPHICAL=1 layers the Xfce desktop closure on top of the minimal live root
# (live Xfce ISO, the 2nd NixOS-style variant). It needs a much bigger ramdisk:
# minimal root ~268MB + Xfce/xorg/gtk3 closure ~177MB = ~445MB used, so default
# RD_MB to 900 for graphical, 450 for minimal.
GRAPHICAL="${GRAPHICAL:-0}"
if [ "$GRAPHICAL" = 1 ]; then RD_MB="${RD_MB:-900}"; else RD_MB="${RD_MB:-450}"; fi
                                          # ldd-closure tool set is ~130MB du, ~215MB on UFS.
INSTALLER="${INSTALLER:-/var/tmp/solnix-install}"   # scripts/solnix-install, scp'd here
LABEL="${LABEL:-SOLNIX_INSTALL}"
GCP="${GCP:-/usr/gnu/bin/cp}"            # GNU cp (illumos cp -L differs)
# graphical closure list (built by the caller via nix-store -qR, one path/line);
# each path is copied verbatim into $RDROOT/nix/store. Default matches the
# gfx-closure.txt the caller generates on the build host.
GFX_CLOSURE="${GFX_CLOSURE:-/tmp/gfx-closure.txt}"

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
  etc
  boot/solaris/bin
  usr/lib/fs
  usr/lib/64
  usr/lib/security
  usr/lib/devfsadm
  usr/lib/sysevent
  usr/lib/inet
  usr/lib/cfgadm
"
mkdir -p "$RDROOT"/usr/sbin "$RDROOT"/usr/bin "$RDROOT"/usr/lib "$RDROOT"/dev "$RDROOT"/devices \
         "$RDROOT"/proc "$RDROOT"/system/contract "$RDROOT"/system/object "$RDROOT"/tmp \
         "$RDROOT"/var/run "$RDROOT"/var/tmp "$RDROOT"/mnt "$RDROOT"/a "$RDROOT"/root "$RDROOT"/nix \
         "$RDROOT"/etc/dev "$RDROOT"/etc/svc/volatile "$RDROOT"/system/boot "$RDROOT"/etc/dfs \
         "$RDROOT"/var/svc/manifest "$RDROOT"/var/svc/profile

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
  /usr/bin/grep /usr/bin/date /usr/bin/find /usr/bin/vi /usr/bin/file
  /usr/sbin/fcadm /usr/sbin/cfgadm /usr/lib/sysevent/syseventd
  /usr/lib/cfgadm/fp.so.1 /sbin/dlmgmtd
  /usr/sbin/svccfg /usr/sbin/svcadm /usr/bin/svcprop /usr/bin/svcs
  /lib/svc/bin/svc.configd /lib/svc/bin/svc.startd /lib/svc/bin/mfstscan"
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
  usr/bin/touch usr/bin/mktemp usr/bin/dd usr/bin/stat usr/bin/pwd
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
  usr/bin/gzip
  usr/sbin/zpool usr/sbin/zfs usr/sbin/format usr/sbin/fmthard usr/sbin/prtvtoc
  usr/sbin/tar
  usr/sbin/mkfs usr/sbin/newfs usr/sbin/fsck usr/sbin/installboot
  usr/sbin/fstyp usr/sbin/clri
  usr/sbin/bootadm usr/sbin/lofiadm usr/sbin/devfsadm usr/sbin/dladm
  usr/sbin/ipadm usr/sbin/ifconfig usr/sbin/prtconf usr/sbin/init
  usr/sbin/mount usr/sbin/umount usr/sbin/svcadm usr/sbin/svccfg usr/sbin/prtdiag
  usr/sbin/fdisk usr/sbin/format usr/sbin/zdb usr/sbin/dumpadm
  usr/sbin/fcadm usr/sbin/cfgadm usr/sbin/fcinfo
  usr/bin/svcs usr/bin/svcprop usr/bin/coreadm usr/sbin/coreadm
  usr/sbin/soconfig usr/sbin/ndd usr/bin/ps usr/bin/tty usr/bin/who
  usr/bin/login usr/bin/i86/ksh93 usr/bin/pgrep usr/bin/pkill usr/bin/logger
  usr/sbin/hostconfig usr/sbin/sysconfig usr/lib/saf/ttymon usr/lib/saf/sac
  usr/lib/utmpd usr/lib/pfexecd usr/lib/rad/rad
  usr/sbin/pmadm usr/sbin/sacadm usr/bin/coreadm usr/lib/utmpd
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
# /usr/bin/ksh (== /bin/ksh via the bin->usr/bin symlink) is the shebang of the
# stock SMF method scripts (manifest-import.real, mime-types-cache, ...). The
# curated LIVE_TOOLS copies only ksh93, so without this link `#!/bin/ksh`
# scripts fail to exec -> the method exits 127 -> system/manifest-import goes
# to maintenance -> milestone/single-user never onlines. Point it at ksh93.
rm -f "$RDROOT/usr/bin/ksh" 2>/dev/null; ln -s ksh93 "$RDROOT/usr/bin/ksh" 2>/dev/null || true
# /bin -> usr/bin (illumos convention; /etc/profile + method scripts use /bin/*).
[ -e "$RDROOT/bin" ] || ln -s usr/bin "$RDROOT/bin" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. make-be gotchas applied to the live root
# ---------------------------------------------------------------------------
log "applying gotchas (dir perms, /dev symlinks, driver-config, /etc essentials)"
# 3a. dir write perms (proto-style 0555 dirs break writers; harmless on a copy)
find "$RDROOT" -type d -exec chmod u+w {} + 2>/dev/null || true
chmod 1777 "$RDROOT/tmp" "$RDROOT/var/tmp" 2>/dev/null || true

# 3b. essential /dev symlinks (console/msglog/null; startd stdio). Include dld
#     (the GLDv3 control node) which dlmgmtd opens at start -- without it
#     network/datalink-management goes to maintenance and blocks ~52 dependent
#     services (filesystem/minimal, milestone/devices, single-user, ...).
for n in console msglog null zero tty syscon systty sysmsg random urandom poll dld dlpi; do
  [ -L "/dev/$n" ] && ln -sf "$(/usr/bin/readlink /dev/$n)" "$RDROOT/dev/$n" 2>/dev/null || true
done

# 3b'. gcc runtime libs (libstdc++/libgcc_s, BOTH ABIs) that some 32-bit system
#      daemons link (dlmgmtd links libstdc++ -> without it ld.so.1 fails to start
#      it -> datalink-management maintenance -> the 52-service cascade). Placed at
#      BOTH the RUNPATH location (/usr/gcc/14/lib) AND /usr/lib. Same provenance
#      as oi-make-be.sh step 6 (host gcc-14 runtime).
for abi in "" amd64; do
  _sd=/usr/gcc/14/lib${abi:+/$abi}
  for _dd in "$RDROOT/usr/lib${abi:+/$abi}" "$RDROOT/usr/gcc/14/lib${abi:+/$abi}"; do
    mkdir -p "$_dd"
    for l in libstdc++.so.6 libgcc_s.so.1; do
      [ -e "$_sd/$l" ] && ${GCP:-/usr/gnu/bin/cp} -L "$_sd/$l" "$_dd/$l" 2>/dev/null || true
    done
  done
done

# 3c. driver-config files (name_to_major etc. — without rootnex kernel panics)
mkdir -p "$RDROOT/etc/security"
for f in name_to_major name_to_sysnum driver_aliases driver_classes minor_perm \
         system path_to_inst vfstab nsswitch.conf passwd shadow group \
         hosts netconfig; do
  [ -e "/etc/$f" ] && cp "/etc/$f" "$RDROOT/etc/$f" 2>/dev/null || true
done
# /etc/mnttab MUST be an empty regular file (mntfs mounts over it at boot); do
# NOT copy the host's live mnttab (stale entries confuse the fs milestone).
: > "$RDROOT/etc/mnttab"
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
# 4. solnix-install + STANDARD illumos boot (svc.startd + seeded SMF repo).
#
# WHY svc.startd, not a bare-shell PID 1 (the v1 gap): the bare-shell can't run
# the illumos early-boot fs sequence correctly on a READ-ONLY ramdisk root
# (mnttab/proc/devfs never come up in the right order -> `mount: mnttab is not
# this fstype`, devfsadm can't write /dev, no /dev/dsk -> installer sees no
# disks). The CORRECT illumos live-media path is the real /sbin/init -> svc.startd
# running the stock milestones: filesystem/root -> filesystem/minimal (tmpfs on
# /tmp,/var/run,/system/volatile; mnttab; /dev writable) -> devices (devfsadm
# populates /dev/dsk/cNtNdN) -> single-user. We SEED /etc/svc/repository.db from
# lib/svc/seed/global.db (the oi-make-be.sh mechanism) so svc.configd has the
# stock service set; manifest-import then ADDS our live-installer service. Then
# site/solnix-live presents the banner + optional auto-install once /dev/dsk
# exists.
# ---------------------------------------------------------------------------
log "installing solnix-install + standard svc.startd boot"
mkdir -p "$RDROOT/usr/sbin"
cp "$INSTALLER" "$RDROOT/usr/sbin/solnix-install"
chmod 0555 "$RDROOT/usr/sbin/solnix-install"

# 4a. KEEP the real /sbin/init (the svc.startd launcher copied with sbin/). Do
#     NOT replace it with a bare shell. If a stale re-run left our old bare-shell
#     init in the tree, restore the real one from the source root.
if head -1 "$RDROOT/sbin/init" 2>/dev/null | grep -q ksh93; then
  log "restoring real /sbin/init (svc.startd launcher) over stale bare-shell init"
  cp "$SRC/sbin/init" "$RDROOT/sbin/init"
fi
chmod 0555 "$RDROOT/sbin/init" 2>/dev/null || true

# 4a'. WRITABLE ROOT on the RO ufs ramdisk. The kernel mounts /ramdisk:a
#      read-only; the stock fs-root/fs-usr remount uses the mountpoint-only form
#      (`mount -m -F ufs -o remount /`) which FAILS on a ramdisk. Empirically
#      `mount -F ufs -o remount,rw /devices/ramdisk:a /` WORKS. So:
#        (i)  patch fs-root to remount root rw via the EXPLICIT /devices/ramdisk:a
#             device early (before any writer runs), and
#        (ii) guard fs-usr's non-zfs root-remount block to skip when there is no
#             `/` vfstab entry (our ramdisk case) -- otherwise fs-usr's
#             mountpoint-only remount fails -> filesystem/usr maintenance.
log "patching fs-root (rw remount via /devices/ramdisk:a) + fs-usr (guard root remount)"
_fsroot="$RDROOT/lib/svc/method/fs-root"
if [ -e "$_fsroot" ] && ! grep -q solnix-ramdisk-rw "$_fsroot"; then
  awk '
    /^\. \/lib\/svc\/share\/fs_include.sh/ && !d {
      print; print ""
      print "# solnix-ramdisk-rw: remount the RO ufs ramdisk root read-write using the"
      print "# EXPLICIT ramdisk device (/devices/ramdisk:a); mountpoint-only remount fails."
      print "for _d in /devices/ramdisk:a /devices/ramdisk-root:a; do"
      print "  /sbin/mount -F ufs -o remount,rw \"$_d\" / >/dev/msglog 2>&1 && break"
      print "done"
      d=1; next
    }
    { print }
  ' "$_fsroot" > "$_fsroot.new" && mv "$_fsroot.new" "$_fsroot" && chmod 0555 "$_fsroot"
fi
_fsusr="$RDROOT/lib/svc/method/fs-usr"
if [ -e "$_fsusr" ] && ! grep -q "solnix: guard root remount" "$_fsusr"; then
  # open the guard right after `readvfstab / < $vfstab` in the non-zfs block
  awk '
    /readvfstab \/ < \$vfstab/ && !o {
      print
      print "\t# solnix: guard root remount -- skip when no / vfstab entry (ramdisk"
      print "\t# root, already remounted rw by fs-root via the explicit device)."
      print "\tif [ -z \"$mountp\" ]; then :; else"
      o=1; next
    }
    /mountfs -m \$mountp \$fstype \$mntopts -/ && !c {
      print; print "\tfi   # close solnix guard"; c=1; next
    }
    { print }
  ' "$_fsusr" > "$_fsusr.new" && mv "$_fsusr.new" "$_fsusr" && chmod 0555 "$_fsusr"
fi

# 4a-dlmgmt. dlmgmtd (network/datalink-management) creates its door in
#   /etc/svc/volatile/dladm, which is empty at boot (tmpfs). Create that dir in
#   the svc-dlmgmtd method before starting the daemon, else dlmgmtd can't make
#   its door -> datalink-management maintenance -> ~52-service cascade
#   (filesystem/minimal, milestone/devices, single-user, site/solnix-live).
_dlm="$RDROOT/lib/svc/method/svc-dlmgmtd"
if [ -e "$_dlm" ] && ! grep -q 'solnix: dlmgmt door dir' "$_dlm"; then
  awk '
    /^\/sbin\/dlmgmtd/ && !d {
      print "# solnix: dlmgmt door dir (tmpfs /etc/svc/volatile is empty at boot)"
      print "mkdir -p /etc/svc/volatile/dladm 2>/dev/null"
      print "/usr/bin/chown dladm:netadm /etc/svc/volatile/dladm 2>/dev/null || true"
      print; d=1; next
    }
    { print }
  ' "$_dlm" > "$_dlm.new" && mv "$_dlm.new" "$_dlm" && chmod 0555 "$_dlm"
fi

# 4a''. EMI wrapper: on the RO live root, boot-time early-manifest-import can
#       still exit non-zero (a service import quirk); make it non-fatal so it
#       never drops the installer to maintenance mode (the repo is already
#       fully pre-imported in 4f). Late manifest-import stays real.
_mimport="$RDROOT/lib/svc/method/manifest-import"
if [ -e "$_mimport" ] && ! grep -q 'solnix EMI wrapper' "$_mimport"; then
  cp "$_mimport" "$RDROOT/lib/svc/method/manifest-import.real"
  cat > "$_mimport" <<'WRAPEOF'
#!/sbin/sh
# solnix EMI wrapper: run the real manifest-import; for early-manifest-import
# always exit 0 so a quirk on the RO live root doesn't wedge boot (the shipped
# repository.db is already fully pre-imported at build time).
_real=/lib/svc/method/manifest-import.real
"$_real" "$@"; _rc=$?
case "$SMF_FMRI" in *early-manifest-import*) exit 0;; *) exit ${_rc:-0};; esac
WRAPEOF
  chmod 0555 "$_mimport"
fi

# 4b. SEED the SMF repository: copy seed/global.db to /etc/svc/repository.db.
#     The OFFLINE PRE-IMPORT of all manifests + profiles happens in 4f (below),
#     AFTER the manifests/profiles are written, so the ramdisk ships a
#     FULLY-IMPORTED repo (the OI live-media approach) -> boot-time
#     early-manifest-import has nothing to do + succeeds on a READ-ONLY root.
log "seeding SMF repository from seed/global.db"
mkdir -p "$RDROOT/etc/svc"
_seed=""
if [ -e "$RDROOT/lib/svc/seed/global.db" ]; then _seed="$RDROOT/lib/svc/seed/global.db"
elif [ -e /lib/svc/seed/global.db ]; then _seed=/lib/svc/seed/global.db; fi
if [ -n "$_seed" ]; then
  cp "$_seed" "$RDROOT/etc/svc/repository.db"
  chmod 0644 "$RDROOT/etc/svc/repository.db"
else
  echo "WARN: no seed/global.db found -- svc.startd will have an empty repo" >&2
fi

# 4c. SMF profile symlinks (oi-make-be.sh gotcha #8): generic/platform/name_service.
( cd "$RDROOT/etc/svc/profile" && \
  ln -sf generic_limited_net.xml generic.xml && \
  ln -sf platform_none.xml platform.xml && \
  ln -sf ns_dns.xml name_service.xml ) 2>/dev/null || true

# 4d. the live-installer method: banner + (optional) auto-install to /dev/console.
#     Runs as an SMF service AFTER single-user so /dev/dsk exists.
mkdir -p "$RDROOT/lib/svc/method"
cat > "$RDROOT/lib/svc/method/solnix-live" <<'METHODEOF'
#!/sbin/sh
. /lib/svc/share/smf_include.sh
PATH=/usr/sbin:/usr/bin:/sbin; export PATH
{
  echo ""
  echo "[solnix] live-installer service starting (fs writable, devfsadm done)"
  /usr/sbin/devfsadm 2>&1 || true
  echo "[solnix] disks visible:"; ls /dev/dsk 2>/dev/null | head
  if [ -r /etc/solnix-autoinstall ]; then
    _tgt=$(cat /etc/solnix-autoinstall 2>/dev/null)
    if [ "$_tgt" = auto ] || [ -z "$_tgt" ]; then
      for _c in /dev/rdsk/c*t*d0s0 /dev/rdsk/c*d0s0; do
        [ -e "$_c" ] || continue
        _d=$(basename "$_c"); _d=${_d%s0}; _tgt=$_d; break
      done
    fi
    echo "[solnix] AUTO-INSTALL to ${_tgt:-<none found>}"
    /usr/sbin/format </dev/null 2>&1 || true
    if [ -n "$_tgt" ]; then
      SOLNIX_POOL=rpool SOLNIX_ALLOW_RPOOL=1 /usr/sbin/solnix-install "$_tgt" \
        && echo "SOLNIX_AUTOINSTALL_RESULT: DONE" \
        || echo "SOLNIX_AUTOINSTALL_RESULT: FAIL rc=$?"
    else
      echo "SOLNIX_AUTOINSTALL_RESULT: FAIL no-target-disk"
    fi
  fi
} > /dev/console 2>&1
exit $SMF_EXIT_OK
METHODEOF
chmod 0555 "$RDROOT/lib/svc/method/solnix-live"

mkdir -p "$RDROOT/lib/svc/manifest/site"
cat > "$RDROOT/lib/svc/manifest/site/solnix-live.xml" <<'MANIEOF'
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type="manifest" name="solnix:live">
  <service name="site/solnix-live" type="service" version="1">
    <single_instance/>
    <dependency name="su" grouping="require_all" restart_on="none" type="service">
      <service_fmri value="svc:/milestone/single-user:default"/>
    </dependency>
    <dependency name="devices" grouping="require_all" restart_on="none" type="service">
      <service_fmri value="svc:/milestone/devices:default"/>
    </dependency>
    <exec_method type="method" name="start" exec="/lib/svc/method/solnix-live" timeout_seconds="1800">
      <method_context><method_credential user="root"/></method_context>
    </exec_method>
    <exec_method type="method" name="stop" exec=":true" timeout_seconds="60">
      <method_context><method_credential user="root"/></method_context>
    </exec_method>
    <property_group name="startd" type="framework">
      <propval name="duration" type="astring" value="transient"/>
    </property_group>
    <instance name="default" enabled="true"/>
    <template><common_name><loctext xml:lang="C">solnix live installer</loctext></common_name></template>
  </service>
</service_bundle>
MANIEOF

# site profile: enable the live service + disable peripheral services that fail
# in the minimal ramdisk so they don't wedge boot.
mkdir -p "$RDROOT/etc/svc/profile/site"
cat > "$RDROOT/etc/svc/profile/site/solnix.xml" <<'PROFEOF'
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type="profile" name="solnix">
  <service name="site/solnix-live" version="1" type="service"><instance name="default" enabled="true"/></service>
  <service name="network/smtp" version="1" type="service"><instance name="sendmail" enabled="false"/></service>
  <service name="network/sendmail-client" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="system/hal" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="system/keymap" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="system/intrd" version="1" type="service"><instance name="default" enabled="false"/></service>
  <!-- disable the non-essential services that fail in the minimal ramdisk
       (missing support tools/files) so they don't cascade to maintenance mode
       and block single-user. None are console-installer dependencies.
       NOTE do NOT disable system/sysevent (milestone/devices REQUIRES it); with
       the gcc runtime libs present (3b') syseventd starts fine. -->
  <service name="system/rbac" version="1" type="service"><instance name="default" enabled="false"/></service>
  <!-- Fibre Channel services (npiv_config, fc-fabric) must NOT be disabled:
       devices-fc-fabric.xml declares <dependent name='devices' require_all>
       svc:/milestone/devices, so disabling fc-fabric strands milestone/devices
       (and therefore single-user) forever. In the no-FC qemu/console env both
       methods no-op: fc-fabric only runs luxadm when /etc/cfg/fp/fabric_WWN_map
       exists (it doesn't -> exit 0), and npivconfig's `fcadm create-port-list`
       returns 0 with no HBA. The FC tools (fcadm/cfgadm/fp.so.1) are shipped in
       LIVE_TOOLS/COPY_DIRS so both services START cleanly -> devices onlines. -->
  <service name="system/ca-certificates" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="system/dbus" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="system/fcoe_initiator" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="system/pkgserv" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="system/zones-monitoring" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="system/name-service-cache" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="network/rpc/bind" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="network/ipsec/ipsecalgs" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="network/ipsec/policy" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="application/opengl/ogl-select" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="application/desktop-cache/gio-module-cache" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="application/print/service-selector" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="application/print/server" version="1" type="service"><instance name="default" enabled="false"/></service>
</service_bundle>
PROFEOF

# optional auto-install marker (AUTOINSTALL_DISK=c1t1d0 for the automated test)
if [ -n "${AUTOINSTALL_DISK:-}" ]; then
  echo "$AUTOINSTALL_DISK" > "$RDROOT/etc/solnix-autoinstall"
  log "auto-install marker set: target=$AUTOINSTALL_DISK"
fi

# 4e. inittab: the STOCK illumos inittab runs svc.startd. Copy the source root's
#     inittab (has smf::sysinit svc.startd). Fallback stub if absent.
cp "$SRC/etc/inittab" "$RDROOT/etc/inittab" 2>/dev/null || cat > "$RDROOT/etc/inittab" <<'INITEOF'
ap::sysinit:/sbin/autopush -f /etc/iu.ap
smf::sysinit:/lib/svc/bin/svc.startd >/dev/msglog 2>&1 </dev/console
INITEOF
# a console banner shell for interactive use (invoked from console-login).
cat > "$RDROOT/etc/solnix-live-shell" <<'SHELLEOF'
#!/usr/bin/ksh93
PATH=/usr/sbin:/usr/bin:/sbin:/usr/gnu/bin
export PATH TERM=vt100 TMPDIR=/tmp
cat /etc/solnix-banner 2>/dev/null
exec /usr/bin/ksh93 2>/dev/null || exec /sbin/sh
SHELLEOF
chmod 0555 "$RDROOT/etc/solnix-live-shell"
cat > "$RDROOT/etc/solnix-banner" <<'BANNEREOF'

  ############################################################
  #        The Solnix Operating System - Live Installer      #
  #                  (x86_64 / illumos)                      #
  ############################################################

  solnix live installer (ramdisk root). To install to a disk:
    1. List disks:  format </dev/null   (Ctrl-D to exit)
    2. Install:     solnix-install <target-disk>   e.g. c1t1d0
    3. Reboot:      init 6   (remove the install media)

BANNEREOF
# autopush needs iu.ap; copy if present, else stub
[ -e /etc/iu.ap ] && cp /etc/iu.ap "$RDROOT/etc/iu.ap" 2>/dev/null || : > "$RDROOT/etc/iu.ap"

cat > "$RDROOT/etc/solnix-release" <<EOF
The Solnix Operating System - live installer media
built: $(date -u +%FT%TZ 2>/dev/null || date)
host:  $(uname -a)
EOF

# path_to_inst so device enumeration works
[ -f "$RDROOT/etc/path_to_inst" ] || cp /etc/path_to_inst "$RDROOT/etc/path_to_inst" 2>/dev/null || : > "$RDROOT/etc/path_to_inst"

# 4g. root console login (oi-make-be.sh gotcha #9): clear root's password + point
#     root's shell at ksh93 so the maintenance/console login works with an empty
#     password (the copied host /etc/shadow has the host's root hash). Also allow
#     empty-password console login. Without this the sulogin maintenance prompt
#     rejects root -> no way to recover a failed boot.
if [ -e "$RDROOT/usr/bin/ksh93" ]; then _rsh=/usr/bin/ksh93; else _rsh=/sbin/sh; fi
awk -F: -v sh="$_rsh" 'BEGIN{OFS=":"} $1=="root"{$7=sh} {print}' \
  "$RDROOT/etc/passwd" > "$RDROOT/etc/passwd.new" && mv "$RDROOT/etc/passwd.new" "$RDROOT/etc/passwd"
awk -F: 'BEGIN{OFS=":"} $1=="root"{$2=""} {print}' \
  "$RDROOT/etc/shadow" > "$RDROOT/etc/shadow.new" && mv "$RDROOT/etc/shadow.new" "$RDROOT/etc/shadow"
chmod 0400 "$RDROOT/etc/shadow"
[ -f "$RDROOT/etc/default/login" ] && sed -i 's/^CONSOLE=/#CONSOLE=/; s/^PASSREQ=YES/PASSREQ=NO/' "$RDROOT/etc/default/login" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4f. PRE-IMPORT all manifests + apply profiles into repository.db (OFFLINE).
#     Runs LAST in section 4 so every manifest (incl. site/solnix-live) + profile
#     (incl. site/solnix.xml) is already on disk. svccfg reads the db directly
#     via SVCCFG_REPOSITORY (no running svc.configd/door). A fully-imported repo
#     means boot-time early/late manifest-import find nothing to do + succeed on
#     the READ-ONLY ramdisk root -> boot proceeds to the fs/devices milestones
#     (devfsadm -> /dev/dsk) + single-user -> site/solnix-live.
# ---------------------------------------------------------------------------
if [ -e "$RDROOT/etc/svc/repository.db" ]; then
  log "pre-importing all SMF manifests + profiles into repository.db (offline)"
  chmod 0644 "$RDROOT/etc/svc/repository.db"
  _dtd=/usr/share/lib/xml/dtd/service_bundle.dtd.1
  [ -e "$RDROOT$_dtd" ] && _dtd="$RDROOT$_dtd"
  _nimp=0
  for _m in $(find "$RDROOT/lib/svc/manifest" -name '*.xml' 2>/dev/null); do
    SVCCFG_CHECKHASH=1 SVCCFG_DTD="$_dtd" \
    SVCCFG_REPOSITORY="$RDROOT/etc/svc/repository.db" \
      /usr/sbin/svccfg import "$_m" >/dev/null 2>&1 && _nimp=$((_nimp+1)) \
      || echo "WARN: svccfg import failed for $_m" >&2
  done
  log "pre-imported $_nimp manifests into repository.db"
  for _p in "$RDROOT/etc/svc/profile/generic.xml" \
            "$RDROOT/etc/svc/profile/platform.xml" \
            "$RDROOT/etc/svc/profile/name_service.xml" \
            "$RDROOT/etc/svc/profile/site/solnix.xml"; do
    [ -e "$_p" ] || continue
    SVCCFG_DTD="$_dtd" SVCCFG_REPOSITORY="$RDROOT/etc/svc/repository.db" \
      /usr/sbin/svccfg apply "$_p" >/dev/null 2>&1 \
      && echo "applied profile $(basename "$_p")" >&2 \
      || echo "WARN: svccfg apply $_p failed" >&2
  done
  # DETERMINISTIC disables: svccfg apply of a profile does not reliably flip
  # general/enabled for every service offline; set it explicitly for the
  # non-essential services that fail in the minimal ramdisk (missing tools /
  # desktop) and would otherwise cascade to maintenance.
  # NOTE: do NOT disable network/npiv_config or system/device/fc-fabric --
  # milestone/devices REQUIRES fc-fabric (require_all), so disabling it blocks
  # the milestone. Instead we ship the FC tools (fcadm/cfgadm + cfgadm plugins +
  # FC libs, see COPY_DIRS/LIVE_TOOLS) so those services START cleanly.
  for _svc in system/rbac:default network/rpc/bind:default \
              system/name-service-cache:default network/ipsec/ipsecalgs:default \
              network/ipsec/policy:default application/opengl/ogl-select:default \
              application/desktop-cache/gio-module-cache:default \
              application/print/service-selector:default system/hal:default \
              system/keymap:default system/intrd:default system/pkgserv:default \
              system/zones-monitoring:default system/dbus:default \
              system/fcoe_initiator:default; do
    SVCCFG_REPOSITORY="$RDROOT/etc/svc/repository.db" \
      /usr/sbin/svccfg -s "$_svc" setprop general/enabled = boolean: false >/dev/null 2>&1 || true
  done
  chmod 0600 "$RDROOT/etc/svc/repository.db"
fi

# ---------------------------------------------------------------------------
# 4h. GRAPHICAL layer (GRAPHICAL=1): bake the Xfce desktop closure into the live
#     ramdisk + autostart a live Xfce session. This turns the minimal console
#     ISO into the live-desktop ISO (the 2nd NixOS-style variant). Everything
#     above (svc.startd + writable-root + devfsadm + solnix-install) is REUSED
#     verbatim; this only ADDS: the Xfce/xorg/gtk3 nix closure under
#     /nix/store, a passwordless live 'solnix' user, a ~/.xinitrc Xfce session,
#     an "Install The Solnix Operating System" .desktop launcher, and a rewrite
#     of the solnix-live SMF method to start Xvfb + the Xfce session as that
#     user (headless-proof path; a real framebuffer swaps Xvfb->gfx-drm Xorg or
#     enables the slim SMF service -- see DISPLAY-MANAGER.md).
# ---------------------------------------------------------------------------
if [ "$GRAPHICAL" = 1 ]; then
  log "GRAPHICAL: baking Xfce desktop closure into live root"
  [ -f "$GFX_CLOSURE" ] || die "GRAPHICAL=1 but no closure list at $GFX_CLOSURE (generate with nix-store -qR)"
  mkdir -p "$RDROOT/nix/store"
  _n=0
  while read -r _p; do
    [ -n "$_p" ] || continue
    [ -e "$_p" ] || { echo "WARN: closure path missing: $_p" >&2; continue; }
    # copy the whole store path preserving perms/symlinks (tar keeps the RO
    # 0555 store perms; harmless on the RO ramdisk).
    ( cd / && tar -cf - "${_p#/}" ) | ( cd "$RDROOT" && tar -xf - ) 2>/dev/null && _n=$((_n+1)) \
      || echo "WARN: copy $_p had errors" >&2
  done < "$GFX_CLOSURE"
  log "GRAPHICAL: copied $_n store paths into live /nix/store"

  # libgcc_s/libstdc++/libatomic -- the desktop RUNPATH ends in /usr/gcc/14/lib/
  # amd64 for these (NOT in /nix/store; xfce4-session/slim/twm/libSM link them).
  # Copy just those (~4MB) via tar so the soname symlinks come along; illumos
  # `cp -P` is recursive-only, so tar is the right tool (matches this script's
  # idiom). Not the 51MB gcc runtime dir (asan/tsan etc. are dead weight).
  mkdir -p "$RDROOT/usr/gcc/14/lib/amd64"
  ( cd /usr/gcc/14/lib/amd64 && tar -cf - \
      libgcc_s.so.1 libstdc++.so.6 libstdc++.so.6.0.33 libatomic.so.1 libatomic.so.1.2.0 2>/dev/null ) \
    | ( cd "$RDROOT/usr/gcc/14/lib/amd64" && tar -xf - ) 2>/dev/null || echo "WARN: gcc runtime lib copy had errors" >&2

  # fonts: the closure has NO fonts and the OI host has none installed, so GTK
  # falls back to Xvfb's builtin bitmap fonts (fixed/cursor) -- proven usable in
  # the pd1d Xvfb smoke. Copy the OI system fonts IF present (better rendering);
  # otherwise the desktop still runs with builtin fonts.
  if [ -d /usr/share/fonts ]; then
    mkdir -p "$RDROOT/usr/share"
    ( cd /usr/share && tar -cf - fonts ) | ( cd "$RDROOT/usr/share" && tar -xf - ) 2>/dev/null || true
  fi

  # the passwordless live user 'solnix' (uid 1000). Home on the RO ramdisk is
  # fine for a live session; the session writes XDG dirs to /tmp (tmpfs).
  log "GRAPHICAL: creating live 'solnix' user + Xfce session files"
  grep -q '^solnix:' "$RDROOT/etc/passwd" 2>/dev/null || \
    echo 'solnix:x:1000:1000:Solnix Live:/home/solnix:/usr/bin/ksh93' >> "$RDROOT/etc/passwd"
  grep -q '^solnix:' "$RDROOT/etc/shadow" 2>/dev/null || \
    echo 'solnix:::::::::' >> "$RDROOT/etc/shadow"
  grep -q '^solnix:' "$RDROOT/etc/group" 2>/dev/null || \
    echo 'solnix::1000:' >> "$RDROOT/etc/group"
  mkdir -p "$RDROOT/home/solnix/Desktop"

  # resolve the actual store hashes present in the closure (the caller's list is
  # authoritative; pick the non-debug dirs by name).
  _find1() { ls -d $RDROOT/nix/store/*$1* 2>/dev/null | grep -v -- -debug | head -1; }
  _rel()  { echo "${1#$RDROOT}"; }   # strip ramdisk prefix -> in-guest path
  XORGSRV=$(_rel "$(_find1 xorg-server-1.20)")
  XKBCOMP=$(_rel "$(_find1 xkbcomp-)")
  XKBCFG=$(_rel "$(_find1 xkeyboard-config-)")
  XFWM4=$(_rel "$(_find1 xfwm4-)")
  PANEL=$(_rel "$(_find1 xfce4-panel-)")
  SESSION=$(_rel "$(_find1 xfce4-session-)")
  XFCONF=$(_rel "$(_find1 xfconf-)")
  SETTINGS=$(_rel "$(_find1 xfce4-settings-)")
  THUNAR=$(_rel "$(_find1 thunar-)")
  XTERM=$(_rel "$(_find1 xterm-)")
  TWM=$(_rel "$(_find1 twm-)")

  # ~/.xinitrc -- the pd1d Xfce body (xfconfd -> xfwm4/panel/xfsettingsd/xterm ->
  # exec xfce4-session). Driven by the live-session launcher below.
  cat > "$RDROOT/home/solnix/.xinitrc" <<XINITEOF
#!/bin/sh
# solnix live .xinitrc -- Xfce 4.18 session (software render).
export PATH="$XFWM4/bin:$PANEL/bin:$SESSION/bin:$XFCONF/bin:$SETTINGS/bin:$THUNAR/bin:$XTERM/bin:$XKBCOMP/bin:/usr/bin:/usr/sbin:/sbin"
export XKB_CONFIG_ROOT="$XKBCFG/share/X11/xkb"
export HOME=/home/solnix XDG_CONFIG_HOME=/tmp/solnix-xdg XDG_CACHE_HOME=/tmp/solnix-cache XDG_RUNTIME_DIR=/tmp/solnix-run
mkdir -p "\$XDG_CONFIG_HOME" "\$XDG_CACHE_HOME" "\$XDG_RUNTIME_DIR" 2>/dev/null
chmod 700 "\$XDG_RUNTIME_DIR" 2>/dev/null
"$XFCONF/lib/xfce4/xfconf/xfconfd" &
"$XFWM4/bin/xfwm4" &
"$PANEL/bin/xfce4-panel" &
"$SETTINGS/bin/xfsettingsd" &
"$XTERM/bin/xterm" -geometry 100x30 &
exec "$SESSION/bin/xfce4-session"
XINITEOF
  chmod 0755 "$RDROOT/home/solnix/.xinitrc"

  # the prominent "Install The Solnix Operating System" desktop launcher: an
  # xterm running the installer front-end (lists disks then installs).
  cat > "$RDROOT/home/solnix/Desktop/install-solnix.desktop" <<DESKEOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Install The Solnix Operating System
Comment=Partition a disk and install solnix onto it (ZFS boot environment)
Exec=$XTERM/bin/xterm -title "Install Solnix" -geometry 100x34 -e /usr/sbin/solnix-install-tui
Icon=drive-harddisk
Terminal=false
Categories=System;
DESKEOF
  chmod 0755 "$RDROOT/home/solnix/Desktop/install-solnix.desktop"

  # the installer front-end the launcher runs: a tiny menu wrapping solnix-
  # install (list disks -> confirm -> install). A text front-end in an xterm is
  # the lazy, reliable installer UI (matches the console ISO's flow, launched
  # from the desktop).
  cat > "$RDROOT/usr/sbin/solnix-install-tui" <<'TUIEOF'
#!/usr/bin/ksh93
PATH=/usr/sbin:/usr/bin:/sbin; export PATH
cat /etc/solnix-banner 2>/dev/null
echo
echo "Detecting disks..."; /usr/sbin/devfsadm 2>/dev/null || true
_disks=$(ls /dev/rdsk/c*t*d0s0 /dev/rdsk/c*d0s0 2>/dev/null | sed 's,.*/,,; s,s0$,,' | sort -u)
if [ -z "$_disks" ]; then echo "No target disks found. (format </dev/null to inspect.)"; echo; echo "Press Enter to close."; read _; exit 1; fi
echo "Available target disks:"; i=1; for d in $_disks; do echo "  $i) $d"; i=$((i+1)); done
echo; printf 'Install solnix to which disk (name, e.g. c1t0d0; or q to quit)? '
read _t; [ "$_t" = q ] && exit 0
printf 'This ERASES %s. Type YES to proceed: ' "$_t"; read _c
[ "$_c" = YES ] || { echo "Aborted."; exit 0; }
SOLNIX_POOL=rpool SOLNIX_ALLOW_RPOOL=1 /usr/sbin/solnix-install "$_t" && \
  { echo; echo "Install complete. Remove the media and reboot (init 6)."; } || \
  echo "Install FAILED (rc=$?)."
echo; echo "Press Enter to close."; read _
TUIEOF
  chmod 0555 "$RDROOT/usr/sbin/solnix-install-tui"

  # the live X launcher: start Xvfb :0 (software framebuffer -- the only X
  # server we have; no gfx-drm Xorg DDX on illumos, see SESSION.md) then run the
  # Xfce session as 'solnix' against it. On real hardware/VM with a framebuffer
  # Xorg you'd point at that Xorg + a VT; here Xvfb is the reproducible headless
  # proof. Logs to /tmp/solnix-x.log + /tmp/solnix-xvfb.log.
  cat > "$RDROOT/usr/sbin/solnix-live-desktop" <<DTEOF
#!/sbin/sh
PATH=$XORGSRV/bin:$XKBCOMP/bin:/usr/bin:/usr/sbin:/sbin; export PATH
export XKB_CONFIG_ROOT=$XKBCFG/share/X11/xkb
_disp=:0
# start the software framebuffer X server (Xvfb) detached.
$XORGSRV/bin/Xvfb \$_disp -screen 0 1280x800x24 -ac -nolisten tcp >/tmp/solnix-xvfb.log 2>&1 &
_xpid=\$!
sleep 8
if [ ! -S /tmp/.X11-unix/X0 ]; then echo "[solnix] Xvfb failed to start (see /tmp/solnix-xvfb.log)"; fi
# run the Xfce session AS the live user against that display (auto-login, no pw).
su - solnix -c "DISPLAY=\$_disp HOME=/home/solnix /bin/sh /home/solnix/.xinitrc" >/tmp/solnix-x.log 2>&1 &
echo "[solnix] live Xfce desktop launching on \$_disp (Xvfb pid \$_xpid); log /tmp/solnix-x.log"
DTEOF
  chmod 0555 "$RDROOT/usr/sbin/solnix-live-desktop"

  # rewrite the solnix-live SMF method to ALSO launch the desktop after the
  # console banner (graphical media). /dev/dsk is already populated (devfsadm
  # ran at the devices milestone).
  cat > "$RDROOT/lib/svc/method/solnix-live" <<'GMETHODEOF'
#!/sbin/sh
. /lib/svc/share/smf_include.sh
PATH=/usr/sbin:/usr/bin:/sbin; export PATH
{
  echo ""
  echo "[solnix] GRAPHICAL live media: fs writable, devfsadm done"
  /usr/sbin/devfsadm 2>&1 || true
  echo "[solnix] disks visible:"; ls /dev/dsk 2>/dev/null | head
  echo "[solnix] starting live Xfce desktop (Xvfb software framebuffer)..."
  /usr/sbin/solnix-live-desktop 2>&1 || echo "[solnix] desktop launcher returned non-zero"
  sleep 6
  echo "[solnix] Xvfb log:";  tail -20 /tmp/solnix-xvfb.log 2>/dev/null
  echo "[solnix] session log:"; tail -30 /tmp/solnix-x.log 2>/dev/null
  echo "[solnix] X socket:"; ls -la /tmp/.X11-unix 2>/dev/null
  echo "[solnix] X clients running?"; ps -ef 2>/dev/null | grep -E 'Xvfb|xfce|xterm|xfwm4' | grep -v grep
} > /dev/console 2>&1
exit $SMF_EXIT_OK
GMETHODEOF
  chmod 0555 "$RDROOT/lib/svc/method/solnix-live"

  # graphical banner
  cat > "$RDROOT/etc/solnix-banner" <<'GBANNEREOF'

  ############################################################
  #   The Solnix Operating System - Live DESKTOP + Installer #
  #                  (x86_64 / illumos)                      #
  ############################################################

  A live Xfce desktop is starting (software-rendered X). On the desktop:
    * a terminal + a file manager (Thunar)
    * "Install The Solnix Operating System" launcher on the Desktop
  Or install from this console:
    solnix-install-tui        (guided)   OR   solnix-install <disk>

GBANNEREOF

  log "GRAPHICAL: desktop layer baked (user solnix, .xinitrc, installer launcher, Xvfb autostart)"
fi

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

# 6d. loader.conf: text+ttya console, load our ramdisk as rootfs. STANDARD boot
#     (no init override) so /sbin/init -> svc.startd runs the fs milestones.
cat > "$OUT/iso/boot/loader.conf" <<'EOF'
loader_logo="illumos"
console="text,ttya"
ttya-mode="115200,8,n,1,-"
autoboot_delay="5"
boot_archive_load="YES"
boot_archive_type="rootfs"
boot_archive_name="/platform/i86pc/amd64/boot_archive"
boot_archive.hash_load="YES"
boot_archive.hash_type="hash"
boot_archive.hash_name="/platform/i86pc/amd64/boot_archive.hash"
kernel="/platform/i86pc/kernel/amd64/unix"
bootfile="unix"
boot-args="-v"
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
