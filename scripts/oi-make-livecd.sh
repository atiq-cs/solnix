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
if [ "$GRAPHICAL" = 1 ]; then RD_MB="${RD_MB:-900}"; else RD_MB="${RD_MB:-820}"; fi
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

# /etc/svc/volatile is a RUNTIME tmpfs (empty at boot). COPY_DIRS pulls it from
# the build host, dragging in the host's LIVE svc.startd/init runtime state --
# most fatally /etc/svc/volatile/init.state, which PID1 init reads at startup.
# A stale init.state makes the fresh-booted init immediately re-exit -> the
# kernel SIGKILL-restart loop ("init(8) exited on fatal signal 9: restarting
# automatically", forever, before svc.startd ever runs). Purge everything the
# host left here; the dir must be empty (the dladm subdir is recreated at boot
# by bootenv). This was intermittent: the loop only appeared when the build host
# happened to have a poisoned init.state at copy time.
rm -rf "$RDROOT"/etc/svc/volatile/* "$RDROOT"/etc/svc/volatile/.[!.]* 2>/dev/null || true

# bootadm's filelist manifests (boot/solaris/filelist.{ramdisk,safe}) name the
# paths packed into the INSTALLED boot_archive. COPY_DIRS grabs boot/solaris/bin
# (create_ramdisk et al.) but NOT the parent boot/solaris/, so these files were
# missing -> in a SELF-INSTALL the copied BE has no filelist -> `bootadm
# update-archive` -> "archive filelist is empty" -> boot_archive not built (step 9).
# Copy them explicitly so the installed BE can build its boot_archive.
for f in boot/solaris/filelist.ramdisk boot/solaris/filelist.safe; do
  [ -e "$SRC/$f" ] && cp -p "$SRC/$f" "$RDROOT/$f" 2>/dev/null || true
done

# /usr/lib libs: copy ONLY the ldd closure of the installer tools (not the whole
# 336MB /usr/lib/amd64 which is mostly gstreamer/db/etc cruft). The full /lib
# tree above already carries the /lib/64 half of the closure; here we add the
# /usr/lib half. Compute the closure with ldd, copy each referenced .so (follow
# symlinks so the real file lands + recreate the soname link).
log "copying ldd closure of installer tools from /usr/lib"
# NOTE: sshd + the console-auth binaries are in this closure too. Their
# DIRECT /usr/lib deps (libcrypto.so.3, libicu*.so.78, libxml2.so.16, libldap,
# libsasl, libidmap, ...) are ldd-visible and get copied here for BOTH ABIs.
# The dlopen'd runtime pieces (passwdutil.so.1, the NSS/NSPR mps tree) are NOT
# ldd-visible and are force-copied in a dedicated block further down.
CLOSURE_TOOLS="/sbin/zpool /sbin/zfs /usr/sbin/format /usr/sbin/fmthard
  /usr/sbin/sshd /usr/bin/ssh-keygen /usr/bin/login /usr/bin/su
  /usr/libexec/sshd-session /usr/libexec/sshd-auth
  /usr/libexec/ssh-keysign /usr/libexec/sftp-server
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
  usr/bin/vim usr/bin/ex usr/bin/view usr/bin/nano
  usr/has/bin/vi
  usr/bin/man usr/bin/mandoc usr/bin/col usr/bin/nroff
  usr/bin/curl usr/bin/wget
  usr/sbin/ping usr/sbin/traceroute
  usr/has/bin/file etc/magic
  usr/bin/env usr/bin/test usr/bin/true usr/bin/false usr/bin/sh usr/bin/pfexec
  usr/bin/su usr/bin/login usr/bin/newtask
  usr/bin/digest usr/bin/openssl usr/bin/od usr/bin/xargs usr/bin/mkfile
  usr/bin/gzip
  usr/bin/mdb usr/bin/adb usr/bin/truss usr/bin/pstack usr/bin/pargs
  usr/bin/pmap usr/bin/pfiles usr/bin/pgrep usr/bin/ptree usr/bin/gcore
  usr/bin/prstat usr/bin/snoop
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
  usr/sbin/in.routed usr/bin/netstat
  usr/bin/login usr/bin/i86/ksh93 usr/bin/pgrep usr/bin/pkill usr/bin/logger
  usr/sbin/hostconfig usr/sbin/sysconfig usr/lib/saf/ttymon usr/lib/saf/sac
  usr/lib/utmpd usr/lib/pfexecd usr/lib/rad/rad
  usr/sbin/pmadm usr/sbin/sacadm usr/bin/coreadm usr/lib/utmpd
  usr/sbin/sshd usr/bin/ssh-keygen usr/bin/ssh-keysign usr/lib/ssh/ssh-keysign
  usr/lib/ssh/sftp-server usr/lib/ssh/sshd
  usr/libexec/sshd-session usr/libexec/sshd-auth usr/libexec/ssh-keysign
  usr/libexec/ssh-pkcs11-helper usr/libexec/ssh-sk-helper usr/libexec/sftp-server
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
# MAN PAGES: the minimal install should ship `man` + pages for the staged tools
# (NixOS parity — a base install has working man). /usr/share/man is ~82MB raw
# but the ramdisk is right-sized + gzipped at the end (~4x), so it costs ~20MB
# on media and lands in BOTH the ISO live-root AND the installed BE (the BE is
# copied from the live-root). man(1) here uses mandoc (staged above), no nroff
# pipeline needed. Include the man tree + man config if present.
for mp in usr/share/man etc/man.conf usr/share/man/man.cf usr/share/mandoc; do
  [ -e "$SRC/$mp" ] && echo "$mp" >> /tmp/solnix-tools.list
done
# Copy the curated list in ONE archive. NOTE: the earlier `xargs tar -cf -`
# approach was BROKEN on illumos: illumos xargs honors a small -s command-size
# cap and SPLITS a long list into multiple `tar -cf -` invocations, each
# emitting a separate archive stream concatenated on stdout; `tar -xf -` reads
# only the FIRST stream and discards the rest -> entries in later batches (e.g.
# usr/libexec/sshd-auth) silently vanished, and WHICH ones dropped depended on
# where xargs split (intermittent). cpio -o reads the whole path list from
# stdin in a SINGLE archive (preserves hardlinks), so nothing is dropped.
( cd "$SRC" && cpio -o -H ustar < /tmp/solnix-tools.list 2>/dev/null ) \
  | ( cd "$RDROOT" && cpio -idm -H ustar 2>/dev/null ) \
  || echo "WARN: tool copy had errors" >&2

# --- 2.24 nix runtime into the live ramdisk (so nix works in the installer
# shell: nix profile install by-name from cache.solnix.io, solnix-install). The
# relocatable /nix-tools224 (bootstrap tarball) + its CA bundle. ~185MB — sized
# into RD_MB. The full toolset closure is NOT baked (that is the installed
# system's job, fetched from cache); the live media stays minimal.
if [ -d /nix-tools224 ]; then
  log "staging /nix-tools224 into live ramdisk"
  ( cd / && tar -cpf - nix-tools224 ) | ( cd "$RDROOT" && tar -xpf - ) 2>/dev/null \
    || echo "WARN: nix-tools224 stage had errors" >&2
  [ -f "$RDROOT/nix-tools224/ca-bundle.crt" ] || cp /etc/certs/ca-certificates.crt "$RDROOT/nix-tools224/ca-bundle.crt" 2>/dev/null || true
fi
# native ping (task requirement: curl + native ping present).
[ -e "$RDROOT/usr/sbin/ping" ] || { [ -x /usr/sbin/ping ] && cp /usr/sbin/ping "$RDROOT/usr/sbin/ping" && chmod 4555 "$RDROOT/usr/sbin/ping" && chown root:bin "$RDROOT/usr/sbin/ping" 2>/dev/null; }

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

# EDITORS: solnix's default vi is nvi (github.com/lichray/nvi2) — a small, C++,
# wide-char nvi with NO vim dependency. It's staged as usr/bin/nvi (from the nvi
# package); /usr/bin/{vi,ex,view} link to nvi. This replaces the old vi->vim
# symlink (which dangled whenever vim was absent).
#   NOTE: nvi requires real BSD DB 1.85 (the db1 package) to actually EDIT — the
#   db5-compat layer is not a drop-in (its 1-based RECNO rejects nvi's record-0
#   append). db1 has landed and nvi is rebuilt against it; the nvi package's
#   postInstall runs an edit smoke test and, on success, drops bin/nvi-edits-ok.
#   This gate keys on that marker: nvi becomes the default vi/ex/view only when
#   the marker is present (a WORKING nvi); otherwise vi/ex/view fall back to the
#   native /usr/has/bin/vi.
# So: if a WORKING nvi is present, point vi/ex/view at it; else the native vi. nano
# is a real bin. (vim, if staged, remains available as `vim` but is NOT what vi is.)
if [ -e "$RDROOT/usr/bin/nvi" ] && [ -e "$RDROOT/usr/bin/nvi-edits-ok" ]; then
  for _e in vi ex view; do rm -f "$RDROOT/usr/bin/$_e"; ln -s nvi "$RDROOT/usr/bin/$_e" 2>/dev/null || true; done
elif [ -e "$RDROOT/usr/has/bin/vi" ]; then
  for _e in vi ex view; do rm -f "$RDROOT/usr/bin/$_e"; ln -s ../has/bin/vi "$RDROOT/usr/bin/$_e" 2>/dev/null || true; done
fi
# `file` ships as /usr/bin/file -> ../has/bin/file (AST file(1) + /etc/magic db).
# The curated copy now stages usr/has/bin/file + etc/magic; ensure the link
# resolves (recreate it if the target came through but the link didn't).
if [ -e "$RDROOT/usr/has/bin/file" ] && [ ! -e "$RDROOT/usr/bin/file" ]; then
  rm -f "$RDROOT/usr/bin/file"; ln -s ../has/bin/file "$RDROOT/usr/bin/file" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 2b. AUTH RUNTIME dlopen closure (sshd PAM + console login/su).
#
# WHY this is separate from the ldd closure above: PAM loads its service
# modules and the password backend by dlopen() at RUNTIME, so ldd of
# sshd/login/su does NOT list them. Without them the console login(1)/su path
# dies with `passwdutil.so.1: open failed` and `pam_authtok_get.so.1:
# relocation error`, and network/ssh:default goes to maintenance (exit-95).
# COPY_DIRS already grabs usr/lib/security (the pam_*.so.1 modules, both ABIs)
# and the whole /lib tree (libpam.so.1 lives at /lib/libpam.so.1). What is
# still missing is:
#   - /usr/lib/passwdutil.so.1  (pam_unix_* dlopens it; 32-bit + amd64)
#   - the NSS/NSPR mps tree (libsasl -> libldap -> dlopen NSS)
#   - a handful of 32-bit /usr/lib deps of the 32-bit login/su/passwdutil path
#     (libidmap, libsmbios, libldap.5, libsasl, libsldap) -- the CLOSURE loop
#     above copies the amd64 half but the 32-bit login path needs the base ABI.
# Note: login(1)/su(1)/passwdutil.so.1 are 32-bit ELF, so they load the
# 32-bit (base) /usr/lib/*.so and 32-bit /usr/lib/security modules; sshd is
# 64-bit and uses the amd64 variants. We copy BOTH ABIs where they exist.
log "force-copying PAM/auth dlopen closure (passwdutil, NSS mps, 32-bit auth libs)"
_copy_lib() {   # $1 = path under /usr/lib (relative to SRC); copies file+recreates dest dir
  _s="$SRC${1}"; _rel=${1#/}
  # /usr/lib/64 is a symlink to amd64 in our tree; normalize dest like the
  # ldd-closure loop does so mkdir doesn't collide with the symlink.
  _dr=$(echo "$_rel" | sed 's,^usr/lib/64/,usr/lib/amd64/,')
  [ -e "$_s" ] || return 0
  mkdir -p "$RDROOT/$(dirname "$_dr")"
  cp -p "$_s" "$RDROOT/$_dr" 2>/dev/null || true
}
for _l in \
  /usr/lib/passwdutil.so.1 /usr/lib/amd64/passwdutil.so.1 \
  /usr/lib/libidmap.so.1 /usr/lib/libsmbios.so.1 \
  /usr/lib/libldap.so.5 /usr/lib/libsasl.so.1 /usr/lib/libsldap.so.1 \
  /usr/lib/64/libcrypto.so.3 /usr/lib/64/libidmap.so.1 \
  /usr/lib/64/libsmbios.so.1 \
  /usr/lib/64/libcrypt.so.1 /usr/lib/64/libgss.so.1 \
  /usr/lib/64/gss/mech_krb5.so.1 /usr/lib/64/libkrb5.so.1 \
  /usr/lib/64/libk5crypto.so.3 /usr/lib/64/libkrb5support.so.1 \
  /usr/lib/64/libcom_err.so.3; do
  _copy_lib "$_l"
done
# NSS/NSPR (mps) tree -- dlopen'd by libsasl/libldap; copy both ABIs whole
# (~7MB, but auth silently fails without it). Real files + soname symlinks.
if [ -d "$SRC/usr/lib/mps" ]; then
  mkdir -p "$RDROOT/usr/lib/mps"
  ( cd "$SRC/usr/lib" && tar -cf - mps ) | ( cd "$RDROOT/usr/lib" && tar -xf - ) 2>/dev/null \
    || echo "WARN: copy /usr/lib/mps had errors" >&2
fi
# pam.conf + nsswitch already come via COPY_DIRS etc; sanity-check they landed.
[ -s "$RDROOT/etc/pam.conf" ] || echo "WARN: /etc/pam.conf missing in live root (console auth needs it)" >&2

# NOTE: gburd + sshd host-key baking is done LATER (section 3c'), AFTER the
# passwd/shadow/group copy below re-copies those files from the build host --
# otherwise that copy clobbers gburd's passwd/shadow lines.

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
# We ship the FULL driver-config set so the live kernel can attach the widest
# range of hardware: name_to_major (268), driver_aliases (1339 PCI-ID->driver
# mappings) + minor_perm etc. Combined with the complete kernel/drv trees
# (COPY_DIRS: platform/i86pc/kernel + kernel + usr/kernel = ~252 drivers), the
# installer boots on essentially any host illumos-gate supports (NVMe, AHCI,
# LSI mpt/mpt_sas, VMware pvscsi/vmxnet3s, virtio, ENA, igb/ixgbe/e1000g, bge,
# rge, nge, sdhost, ...).
mkdir -p "$RDROOT/etc/security"
for f in name_to_major name_to_sysnum driver_aliases driver_classes minor_perm \
         system path_to_inst vfstab nsswitch.conf passwd shadow group \
         hosts netconfig; do
  [ -e "/etc/$f" ] && cp "/etc/$f" "$RDROOT/etc/$f" 2>/dev/null || true
done

# 3c'. OPTIONAL personal-overlay user + sshd host keys. IDENTITY-FREE by default:
#      a PUBLIC image bakes NO personal user/key/password (matching NixOS's
#      installer). Only when PERSONAL_OVERLAY=1 (a maintainer's own test build)
#      is a personal admin user baked — from PERSONAL_USER/PERSONAL_HASH/PERSONAL_KEY
#      env (never hardcoded here). MUST run AFTER the passwd/shadow/group copy.
if [ "${PERSONAL_OVERLAY:-0}" = 1 ]; then
  _PU="${PERSONAL_USER:?PERSONAL_OVERLAY=1 requires PERSONAL_USER}"
  _PU_HASH="${PERSONAL_HASH:-NP}"
  _PU_KEY="${PERSONAL_KEY:-}"
  log "baking personal user '$_PU' (uid 1000, Primary Administrator) -> installed BE"
  grep -q '^staff:' "$RDROOT/etc/group" 2>/dev/null || echo 'staff::10:' >> "$RDROOT/etc/group"
  grep -q "^$_PU:" "$RDROOT/etc/passwd" 2>/dev/null || \
    echo "$_PU:x:1000:10:$_PU:/export/home/$_PU:/usr/bin/ksh93" >> "$RDROOT/etc/passwd"
  if ! grep -q "^$_PU:" "$RDROOT/etc/shadow" 2>/dev/null; then
    echo "$_PU:${_PU_HASH}:6445::::::" >> "$RDROOT/etc/shadow"
  fi
  # RBAC: Primary Administrator profile so `pfexec` -> uid=0.
  touch "$RDROOT/etc/user_attr"
  grep -q "^$_PU:" "$RDROOT/etc/user_attr" 2>/dev/null || \
    echo "$_PU::::type=normal;profiles=Primary Administrator" >> "$RDROOT/etc/user_attr"
  # home + authorized_keys (key login in addition to the password), if a key given.
  mkdir -p "$RDROOT/export/home/$_PU/.ssh"
  [ -n "$_PU_KEY" ] && echo "$_PU_KEY" > "$RDROOT/export/home/$_PU/.ssh/authorized_keys"
  chmod 0700 "$RDROOT/export/home/$_PU/.ssh"
  [ -f "$RDROOT/export/home/$_PU/.ssh/authorized_keys" ] && chmod 0600 "$RDROOT/export/home/$_PU/.ssh/authorized_keys"
  chown -R 1000:10 "$RDROOT/export/home/$_PU" 2>/dev/null || true
  # root key (personal build only), if provided
  [ -n "$_PU_KEY" ] && { mkdir -p "$RDROOT/root/.ssh"; echo "$_PU_KEY" > "$RDROOT/root/.ssh/authorized_keys"; chmod 0700 "$RDROOT/root/.ssh"; chmod 0600 "$RDROOT/root/.ssh/authorized_keys"; }
else
  log "identity-free image (no personal user baked; installer/first-boot creates the operator)"
fi
chmod 0400 "$RDROOT/etc/shadow"
# sshd host keys + config: the AMI must accept SSH on first boot. /etc/ssh
# (incl sshd_config) arrives via COPY_DIRS etc; pre-generate host keys so
# SELF-INSTALL copies them onto the AMI (network/ssh also runs `ssh-keygen -A`
# at first boot as a fallback). Force PasswordAuthentication + PubkeyAuth on.
mkdir -p "$RDROOT/etc/ssh"
# sshd privilege-separation chroot dir: the sshd privsep user's home is
# /var/empty; sshd refuses to start (SMF network/ssh -> maintenance, exit 95)
# if it is absent or not root-owned 0755. The COPY_DIRS etc grab does NOT
# include /var, so create it explicitly.
mkdir -p "$RDROOT/var/empty"
chown 0:3 "$RDROOT/var/empty" 2>/dev/null || true   # root:sys
chmod 0755 "$RDROOT/var/empty"
# Other /var runtime dirs the stripped ramdisk drops but daemons expect at
# start: ttymon's /var/saf/zsmon (else "cannot create log file .../zsmon/log"),
# cron spool, svc log dir. Cheap to create; keeps svcs -x clean.
mkdir -p "$RDROOT/var/saf/zsmon" "$RDROOT/var/spool/cron/crontabs" \
         "$RDROOT/var/svc/log" "$RDROOT/var/log" "$RDROOT/var/adm" \
         "$RDROOT/var/cron" 2>/dev/null || true
# Default nodename so the installed host is not "unknown". COPY_DIRS etc
# brings the build host's /etc/nodename ("unknown"), so overwrite it. A first
# boot on EC2 can still rename; this just gives a sane default hostname.
echo solnix > "$RDROOT/etc/nodename"
if [ ! -s "$RDROOT/etc/ssh/ssh_host_rsa_key" ]; then
  log "pre-generating sshd host keys into live root"
  for _t in rsa ecdsa ed25519; do
    _kf="$RDROOT/etc/ssh/ssh_host_${_t}_key"
    [ -s "$_kf" ] || ssh-keygen -q -t "$_t" -N '' -f "$_kf" </dev/null 2>/dev/null || true
  done
fi
if [ -f "$RDROOT/etc/ssh/sshd_config" ]; then
  grep -q '^PubkeyAuthentication' "$RDROOT/etc/ssh/sshd_config" || echo 'PubkeyAuthentication yes' >> "$RDROOT/etc/ssh/sshd_config"
  grep -q '^PasswordAuthentication' "$RDROOT/etc/ssh/sshd_config" || echo 'PasswordAuthentication yes' >> "$RDROOT/etc/ssh/sshd_config"
fi
# WIDEST-HARDWARE BOOT: /etc/path_to_inst binds specific driver INSTANCE numbers
# to the BUILD HOST's exact PCI/device topology. Shipping the host's copy makes
# the live kernel try to honor a foreign device tree -> on different hardware
# (physical or a different hypervisor) instances misbind / devices don't attach.
# Install media must ship an EMPTY path_to_inst so the kernel REBUILDS instance
# assignments for whatever hardware it actually boots on (standard illumos
# install-media behavior). devfsadm at live-boot then populates /dev fresh.
: > "$RDROOT/etc/path_to_inst"
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

# 3d'. loader boot files INSIDE the ramdisk /boot (pmbr, gptzfsboot, loader64.efi).
#      solnix-install needs them at INSTALL time from the copied root: mkfs_pcfs
#      unconditionally copies a boot sector from /boot/pmbr when it FATs the ESP
#      slice (absent -> `/boot/pmbr: No such file or directory` and no FAT is
#      written); installboot writes /boot/pmbr + /boot/gptzfsboot to the target
#      disk; and step 10 copies /boot/loader64.efi to the ESP. The curated
#      ramdisk /boot only had solaris/bootenv.rc, so all three were missing.
#      They are tiny (pmbr 512B, gptzfsboot ~140K, loader64.efi ~640K).
for f in pmbr gptzfsboot loader64.efi; do
  [ -e "/boot/$f" ] && cp "/boot/$f" "$RDROOT/boot/$f" 2>/dev/null || echo "WARN: /boot/$f absent (install ESP/loader steps need it)" >&2
done

# 3d''. The forth menu tree + canonical loader.rc + defaults/loader.conf INSIDE
#       the ramdisk /boot. ROOT CAUSE of the installed-disk 'can't load kernel'
#       -> 'no bootable kernel' -> 'start not found': the SELF-INSTALL copies
#       the ramdisk root (/) into the BE, and solnix-install copies the BE's
#       /boot/loader.rc + /boot/forth FROM that copied root. The curated ramdisk
#       /boot carried ONLY solaris/ + the loader binaries -- NO forth/, NO
#       loader.rc -- so solnix-install fell back to a `boot`-only loader.rc that
#       never runs `initialize` (the word that reads loader.conf), leaving
#       $kernel unset -> the loader tries to load a module literally named
#       'kernel' and fails. They live on the build host at /boot (the ISO tree
#       is built from them, line 6a) and are tiny (forth/ ~210K, loader.rc 497B).
#       Stage them so the installed BE gets the real initialize->read-conf chain.
for b in forth loader.rc; do
  [ -e "$SRC/boot/$b" ] || { echo "WARN: $SRC/boot/$b absent (installed BE loader.rc chain needs it)" >&2; continue; }
  ( cd "$SRC" && tar -cf - "boot/$b" ) | ( cd "$RDROOT" && tar -xf - ) 2>/dev/null \
    || echo "WARN: staging boot/$b into ramdisk had errors" >&2
done
[ -d "$SRC/boot/defaults" ] && { ( cd "$SRC" && tar -cf - boot/defaults ) | ( cd "$RDROOT" && tar -xf - ) 2>/dev/null || true; }

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

# 4-DECL. DECLARATIVE-Nix installed system (CS=<current-system store path>).
#   When CS is set, bake the current-system closure into the live ramdisk
#   /nix/store + wire /run-current-system -> CS + the default profile + nix.conf.
#   solnix-install (run from the live env) then finds a real toplevel with an
#   activate/ + sw/, so it takes the DECLARATIVE install path (NOT SELF-INSTALL):
#   the INSTALLED disk gets sw (userland+nix) + /etc/nix/nix.conf pointing at
#   cache.solnix.io, i.e. a nix-operational build-host baseline. The closure is
#   small (16 paths, ~250MB on UFS) so the ramdisk stays within RD_MB.
#   CLOSURE_LIST (one store path/line) is authoritative if given; else the CS's
#   own closure is walked on the build host via nix-store -qR.
CS="${CS:-}"
if [ -n "$CS" ]; then
  [ -d "$CS" ] || die "CS=$CS not a directory (current-system store path)"
  [ -e "$CS/sw" ] || die "$CS has no sw/ (not a solnix current-system)"
  log "DECLARATIVE: baking current-system closure into live /nix/store ($CS)"
  mkdir -p "$RDROOT/nix/store" "$RDROOT/nix/var/nix/profiles"
  _clist="${CLOSURE_LIST:-}"
  if [ -z "$_clist" ] || [ ! -s "$_clist" ]; then
    _clist=/tmp/solnix-cs-closure.list
    if command -v nix-store >/dev/null 2>&1; then
      nix-store -qR "$CS" | sort -u > "$_clist"
    else
      echo "WARN: no nix-store on PATH + no CLOSURE_LIST; copying CS dir only (closure may be incomplete)" >&2
      echo "$CS" > "$_clist"
    fi
  fi
  _ncs=0
  while read -r _p; do
    [ -n "$_p" ] || continue
    [ -e "$_p" ] || { echo "WARN: closure path missing on host: $_p" >&2; continue; }
    ( cd / && tar -cf - "${_p#/}" ) | ( cd "$RDROOT" && tar -xf - ) 2>/dev/null && _ncs=$((_ncs+1)) \
      || echo "WARN: copy $_p into ramdisk had errors" >&2
  done < "$_clist"
  log "DECLARATIVE: copied $_ncs store paths into live /nix/store"
  # wire the toplevel so solnix-install's default-toplevel lookup resolves it
  # (it reads /run-current-system) and takes the non-SELF-INSTALL path.
  rm -f "$RDROOT/run-current-system" "$RDROOT/run/current-system" 2>/dev/null || true
  ln -s "$CS" "$RDROOT/run-current-system"
  mkdir -p "$RDROOT/run"; ln -s "$CS" "$RDROOT/run/current-system" 2>/dev/null || true
  rm -f "$RDROOT/nix/var/nix/profiles/default"
  ln -s "$CS/sw" "$RDROOT/nix/var/nix/profiles/default"
  # nix.conf for the LIVE env too (so nix works in the installer shell); the
  # INSTALLED system gets its own copy from $CS/etc/nix/nix.conf via solnix-install.
  mkdir -p "$RDROOT/etc/nix"
  if [ -f "$CS/etc/nix/nix.conf" ]; then
    cp -L "$CS/etc/nix/nix.conf" "$RDROOT/etc/nix/nix.conf" 2>/dev/null \
      || cp "$CS/etc/nix/nix.conf" "$RDROOT/etc/nix/nix.conf" 2>/dev/null || true
  fi
  # FULL-CLOSURE store DB dump (NOT just the toplevel): --load-db needs every
  # referenced path registered or first boot fails 'path <dep> is not valid'.
  # solnix-install re-dumps this for the installed BE; the live copy lets the
  # live env register the closure too.
  if command -v nix-store >/dev/null 2>&1; then
    nix-store --dump-db $(nix-store -qR "$CS") > "$RDROOT/nix/.solnix-registration" 2>/dev/null \
      || nix-store --dump-db "$CS" > "$RDROOT/nix/.solnix-registration" 2>/dev/null || true
  fi
  # maintainer directive: managed coreadm policy + no cores in the live ramdisk.
  if [ -f "$(dirname "$0")/lib-core-scrub.sh" ]; then
    . "$(dirname "$0")/lib-core-scrub.sh"; scrub_cores "$RDROOT" || true
  else
    mkdir -p "$RDROOT/var/cores"; chmod 1777 "$RDROOT/var/cores" 2>/dev/null || true
    cat > "$RDROOT/etc/coreadm.conf" <<'CADM'
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
    find "$RDROOT" \( -name 'core' -o -name 'core.[0-9]*' \) -type f -delete 2>/dev/null || true
  fi
fi

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

# 4b'. CAP ZFS ARC in the ramdisk /etc/system. ROOT CAUSE of the AUTO-INSTALL
# failure at the target-BE boot_archive step: bootadm's create_ramdisk runs
# `digest -a sha1` over the ~450MB target CPIO; on the RAM-backed live root the
# ZFS ARC (uncapped by default) grows against the newly-created rpool + the
# resident live root and the kernel OOM-kills `digest` ("create_hash line 377
# Killed") -> truncated boot_archive -> SOLNIX_AUTOINSTALL_RESULT: FAIL rc=1.
# This is deterministic + RAM-tuning-immune (fails at 10/12/14G) precisely
# because ARC expands to consume whatever RAM you add. Cap ARC to 512MB so the
# hashing step always has headroom; the live install never needs a big ARC.
# (Append, don't clobber, any /etc/system copied by COPY_DIRS.)
touch "$RDROOT/etc/system"
if ! grep -q 'zfs_arc_max' "$RDROOT/etc/system" 2>/dev/null; then
  printf '\n* solnix live-install: cap ZFS ARC so bootadm digest is not OOM-killed\nset zfs:zfs_arc_max = 0x20000000\n' >> "$RDROOT/etc/system"
fi

# 4b''. TRUE ROOT CAUSE of the boot_archive FAIL: bootadm's create_ramdisk runs
# `digest -a sha1` over the target CPIO. `digest` uses the PKCS#11 framework,
# whose pkcs11.conf enables the pkcs11_tpm.so provider -- but libtspi.so.1 (its
# TrouSerS dependency) is NOT on the media, so ld.so hits a fatal relocation
# error and the process dies with SIGKILL ("create_hash line 377 Killed").
# That misreads as an OOM but is a missing-library relocation abort, which is
# why it was RAM-tuning-immune. Disable the TPM provider so `digest` falls back
# to the softtoken/SW SHA1 path and the hash (and boot_archive) build cleanly.
PKCS="$RDROOT/etc/crypto/pkcs11.conf"
if [ -f "$PKCS" ]; then
  sed -i 's,^\(/usr/lib/security/\$ISA/pkcs11_tpm.so.*\)$,# solnix: disabled (libtspi.so.1 absent -> digest SIGKILL) \1,' "$PKCS"
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
  <!-- minimal cloud AMI: disable services whose method binaries/deps are not in
       the curated ramdisk and that we do not need. Leaving them enabled sends
       them to maintenance (svcs -x noise) but does not block boot. sshd +
       basic networking are what matter. -->
  <service name="network/shares/group" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="network/shares/reparsed" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="network/inetd" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="system/cron" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="system/system-log" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="system/dumpadm" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="system/picl" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="application/desktop-cache/input-method-cache" version="1" type="service"><instance name="default" enabled="false"/></service>
  <service name="network/routing/route" version="1" type="service"><instance name="default" enabled="false"/></service>
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
PATH=/nix-tools224/bin:/usr/sbin:/usr/bin:/sbin:/usr/gnu/bin:/usr/ccs/bin
export PATH TERM=vt100 TMPDIR=/tmp
LD_LIBRARY_PATH=/nix-tools224/runtime-lib:/nix-tools224/lib:/nix-tools224/lib/amd64
export LD_LIBRARY_PATH
NIX_CONF_DIR=/etc/nix; export NIX_CONF_DIR
NIX_PATH=nixpkgs=/run/current-system/solnix-flake; export NIX_PATH
cat /etc/solnix-banner 2>/dev/null
exec /usr/bin/ksh93 2>/dev/null || exec /sbin/sh
SHELLEOF
chmod 0555 "$RDROOT/etc/solnix-live-shell"
# LIVE nix.conf (5HAV, s3-origin, flakes) so nix works in the installer shell
# even when no full CS is baked (minimal ISO). solnix-install re-copies the
# INSTALLED system's nix.conf from the toplevel it lays down.
mkdir -p "$RDROOT/etc/nix"
if [ ! -f "$RDROOT/etc/nix/nix.conf" ]; then
  cat > "$RDROOT/etc/nix/nix.conf" <<'NIXCONF'
substituters = https://s3.solnix.io/solnix-cache https://cache.solnix.io
trusted-public-keys = cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=
experimental-features = nix-command flakes
ssl-cert-file = /nix-tools224/ca-bundle.crt
sandbox = false
build-users-group =
max-jobs = auto
NIXCONF
fi
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
              network/shares/group:default network/shares/reparsed:default \
              network/inetd:default system/cron:default system/system-log:default \
              system/dumpadm:default system/picl:default network/routing/route:default \
              application/desktop-cache/input-method-cache:default \
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

  # Host system/X11 libs the desktop binaries NEED but the /nix/store closure
  # does NOT provide: their SONAMEs (e.g. libXau.so.6, libXfixes.so.1,
  # libxshmfence.so.1, libdbus-1.so.3 ...) resolve to the OI HOST's /usr/lib/64,
  # not /nix/store, so the '/nix/store/' closure filter drops them -> live root
  # lacks them -> 'ld.so.1: Xvfb: fatal: libXfixes.so.1: open failed' -> the
  # live desktop never starts. Stage each SONAME from the host into the live
  # /usr/lib/64 (which is a symlink -> amd64). We deref (cp -L) into a real file
  # named after the SONAME so it works regardless of whether the host entry is a
  # same-dir symlink or points off to /lib/amd64. List derived by walking the
  # NEEDED closure of Xvfb/Xorg + the xfce/slim binaries against the store
  # closure (scripts note: closure-miss host libs). Small (~2MB total).
  #   libXau/libXdmcp  X11 transport (Xvfb/Xorg)
  #   libXfixes/libXRes/libX11.so.4  X11 ABI variants xfwm4/panel link
  #   libxshmfence     Xvfb DRI3 fence
  #   libdbus-1/libuuid  session bus (xfce4-session, at-spi)
  #   libxml2/libintl/libfribidi/libthai  gtk/pango text stack
  #   libcups/libexif  thunar/print + image metadata
  #   libbrotlidec/libbz2/liblzo2/libcrypt/libncurses/libtermcap/libsec  misc deps
  #   libbrotlidec  needs libbrotlicommon.so.1 (_kBrotliContextLookupTable);
  #   libharfbuzz   needs libgraphite2.so.3 (gr_make_face_with_ops);
  #   libthai       needs libdatrie.so.1 (trie_new_from_file);
  #   libxml2       needs libicuuc.so.78 -> libicudata.so.78 (gtk XML path) -- transitive
  #     deps of staged host libs, themselves not directly NEEDED by any binary
  #     so the earlier walk missed them; ld.so.1 fails at reloc time otherwise.
  #   dbus-daemon   needs libexpat.so.1 (XML_ParserCreate_MM) + libsmbios/libidmap;
  #     all live under /usr/lib/64 which is a SYMLINK -> amd64, so COPY_DIRS only
  #     archived the symlink, not the target files. cp -L stages real files here.
  _hostlibs="libXau.so.6 libXdmcp.so.6 libXfixes.so.1 libXRes.so.1 libX11.so.4
    libxshmfence.so.1 libdbus-1.so.3 libuuid.so.1 libxml2.so.16 libintl.so.1
    libfribidi.so.0 libthai.so.0 libcups.so.2 libexif.so.12 libbrotlidec.so.1
    libbz2.so.1 liblzo2.so.2 libcrypt.so.1 libncurses.so.5 libtermcap.so.1
    libsec.so.1
    libharfbuzz.so.0 libfontconfig.so.1 libXft.so.2 libSM.so.6 libXrender.so.1
    libbrotlicommon.so.1 libgraphite2.so.3 libdatrie.so.1 libicuuc.so.78
    libicudata.so.78
    libexpat.so.1 libsmbios.so.1 libidmap.so.1"
  # usr/lib/64 is a symlink -> amd64 on illumos; mkdir -p on an existing symlink
  # errors under set -e, so only mkdir when nothing is there, else write through.
  [ -e "$RDROOT/usr/lib/64" ] || mkdir -p "$RDROOT/usr/lib/64"
  _staged=""
  for _so in $_hostlibs; do
    _src=""
    for _d in /usr/lib/64 /lib/64; do [ -e "$_d/$_so" ] && { _src="$_d/$_so"; break; }; done
    [ -n "$_src" ] || { echo "WARN: host lib not found: $_so" >&2; continue; }
    # GNU cp -L (via $GCP): illumos /usr/bin/cp rejects -L on a single file
    # (exit 2, usage error) -- only GNU cp derefs a single symlink. The host
    # SONAMEs are symlinks (libXau.so.6 -> libXau.so.6.0.0), so -L follows the
    # chain and lands a real file at the SONAME name (ld.so.1 opens by SONAME).
    ${GCP:-/usr/gnu/bin/cp} -L "$_src" "$RDROOT/usr/lib/64/$_so" 2>/dev/null && _staged="$_staged $_so" \
      || echo "WARN: staging $_so had errors" >&2
  done
  log "GRAPHICAL: staged X11 transport libs ($_staged) into /usr/lib/64"

  # D-BUS runtime (session bus). xfce4-session hard-requires a running session
  # bus; the OI host ships dbus-daemon/dbus-run-session/dbus-send/dbus-uuidgen
  # (all link only core-OS libs already in the live root) but NOT dbus-launch.
  # Stage the host binaries into the live root, then (since dbus-launch is
  # missing) drive the session with dbus-run-session AND drop a tiny dbus-launch
  # shim (some tools shell out to it) that execs dbus-daemon --fork.
  # iceauth: xfce4-session shells out to /usr/bin/iceauth to populate the ICE
  # authority file + start the ICE listener; without it the session manager
  # never exports SESSION_MANAGER and every client warns 'SESSION_MANAGER
  # environment variable not defined'. The host iceauth links only core-OS libs
  # (same as the dbus bins), so stage it the same cp -L way.
  _dbus_bins="dbus-daemon dbus-run-session dbus-send dbus-uuidgen iceauth"
  _dbstaged=""
  mkdir -p "$RDROOT/usr/bin"
  for _b in $_dbus_bins; do
    _src=""
    for _d in /usr/bin /usr/sbin /bin; do [ -x "$_d/$_b" ] && { _src="$_d/$_b"; break; }; done
    [ -n "$_src" ] || { echo "WARN: host dbus binary not found: $_b" >&2; continue; }
    ${GCP:-/usr/gnu/bin/cp} -L "$_src" "$RDROOT/usr/bin/$_b" 2>/dev/null \
      && { chmod 0555 "$RDROOT/usr/bin/$_b"; _dbstaged="$_dbstaged $_b"; } \
      || echo "WARN: staging dbus binary $_b had errors" >&2
  done
  # dbus-launch shim: the host lacks it and xfce4-session shells out to it; a
  # 3-line wrapper around dbus-daemon --fork --print-address gives the same
  # DBUS_SESSION_BUS_ADDRESS + PID output callers parse. dbus-run-session is the
  # primary path (see launcher); this shim covers any stray dbus-launch call.
  cat > "$RDROOT/usr/bin/dbus-launch" <<'DBLEOF'
#!/bin/sh
# minimal dbus-launch replacement (host lacks the real one). Start a session
# bus via dbus-daemon and print the address (+ optional PID) as dbus-launch does.
_out=$(/usr/bin/dbus-daemon --session --fork --print-address=1 --print-pid=2 2>/dev/null 3>&1)
_addr=$(echo "$_out" | sed -n '1p'); _pid=$(echo "$_out" | sed -n '2p')
[ -n "$_addr" ] || { echo "dbus-launch: failed to start dbus-daemon" >&2; exit 1; }
echo "DBUS_SESSION_BUS_ADDRESS='$_addr';"
echo "export DBUS_SESSION_BUS_ADDRESS;"
echo "DBUS_SESSION_BUS_PID=${_pid};"
DBLEOF
  chmod 0555 "$RDROOT/usr/bin/dbus-launch"
  log "GRAPHICAL: staged dbus binaries ($_dbstaged) + dbus-launch shim"

  # /etc/machine-id: dbus refuses to spawn a bus without it ('Cannot spawn a
  # message bus without a machine-id'). Seed a random 128-bit id at bake time
  # and point /var/lib/dbus/machine-id at it (both paths dbus checks).
  if [ -x "$RDROOT/usr/bin/dbus-uuidgen" ]; then
    "$RDROOT/usr/bin/dbus-uuidgen" > "$RDROOT/etc/machine-id" 2>/dev/null || :
  fi
  # fallback / belt+braces: if dbus-uuidgen produced nothing, use urandom.
  [ -s "$RDROOT/etc/machine-id" ] || \
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "$RDROOT/etc/machine-id"
  mkdir -p "$RDROOT/var/lib/dbus"
  rm -f "$RDROOT/var/lib/dbus/machine-id" 2>/dev/null
  ln -s /etc/machine-id "$RDROOT/var/lib/dbus/machine-id" 2>/dev/null || \
    cp "$RDROOT/etc/machine-id" "$RDROOT/var/lib/dbus/machine-id" 2>/dev/null || :
  log "GRAPHICAL: seeded /etc/machine-id ($(cat "$RDROOT/etc/machine-id" 2>/dev/null))"

  # dbus config data: dbus-daemon reads /usr/share/dbus-1/session.conf (which
  # includes /etc/dbus-1/session.d etc.) at startup; without it the bus won't
  # spawn ('Failed to open .../session.conf'). Stage both dirs from the host.
  for _dd in usr/share/dbus-1 etc/dbus-1; do
    if [ -d "/$_dd" ]; then
      mkdir -p "$RDROOT/$(dirname "$_dd")"
      ( cd / && tar -cf - "$_dd" ) | ( cd "$RDROOT" && tar -xf - ) 2>/dev/null \
        && log "GRAPHICAL: staged dbus config /$_dd" \
        || echo "WARN: staging /$_dd had errors" >&2
    else
      echo "WARN: host dbus config dir /$_dd absent" >&2
    fi
  done

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

  # Full store lib search path. On this illumos cross-build many desktop
  # binaries do NOT list their own package's /lib in their ELF RUNPATH (the
  # cross toolchain omits $ORIGIN/../lib), so libs that ARE staged in the
  # closure -- e.g. libxfce4panel-2.0.so.4 lives in xfce4-panel/lib -- are
  # still unfindable by ld.so.1 via RUNPATH alone. Build one LD_LIBRARY_PATH_64
  # covering EVERY staged store /lib (+ /lib/amd64) so ld.so.1 resolves every
  # closure lib by SONAME regardless of each binary's RUNPATH. This is the
  # source fix for the recurring 'libXXX: open failed' whack-a-mole: the
  # complete closure is on disk AND on the search path.
  # Guard against FOREIGN-ISA store libs on the 64-bit search path: a stray
  # aarch64 zlib etc. would claim the SONAME and yield 'libz.so relocation
  # error'. Put a /lib dir on LD_LIBRARY_PATH_64 unless it has a 64-bit non-x86-64
  # .so (a 32-bit x86 sibling is harmless; ld.so.1 skips the wrong ELF class).
  # (Closure gen also filters these; belt+braces.)
  _is_x86_libdir() {
    for _so in "$1"/*.so*; do
      [ -e "$_so" ] || continue
      _fi=$(file "$_so" 2>/dev/null)
      case "$_fi" in *'ELF 64-bit'*) ;; *) continue;; esac
      echo "$_fi" | grep -qE 'x86-64|AMD64|Intel' || return 1
    done
    return 0
  }
  GFX_LIBPATH="/usr/lib/64:/lib/64:/usr/gcc/14/lib/amd64"
  for _libd in $RDROOT/nix/store/*/lib; do
    [ -d "$_libd" ] || continue
    case "$_libd" in *-debug/lib) continue;; esac
    _is_x86_libdir "$_libd" || { log "GRAPHICAL: skip wrong-arch libdir $(_rel "$_libd")"; continue; }
    GFX_LIBPATH="$GFX_LIBPATH:$(_rel "$_libd")"
    [ -d "$_libd/amd64" ] && _is_x86_libdir "$_libd/amd64" && GFX_LIBPATH="$GFX_LIBPATH:$(_rel "$_libd/amd64")"
  done
  log "GRAPHICAL: LD_LIBRARY_PATH_64 spans $(echo "$GFX_LIBPATH" | tr ':' '\n' | grep -c .) dirs"

  # ~/.xinitrc -- the pd1d Xfce body (xfconfd -> xfwm4/panel/xfsettingsd/xterm ->
  # exec xfce4-session). Driven by the live-session launcher below.
  cat > "$RDROOT/home/solnix/.xinitrc" <<XINITEOF
#!/bin/sh
# solnix live .xinitrc -- Xfce 4.18 session (software render).
export PATH="$XFWM4/bin:$PANEL/bin:$SESSION/bin:$XFCONF/bin:$SETTINGS/bin:$THUNAR/bin:$XTERM/bin:$XKBCOMP/bin:/usr/bin:/usr/sbin:/sbin"
# full store lib search path (many desktop bins omit their own /lib from
# RUNPATH; su - reset the env so set it here too). See GFX_LIBPATH build note.
export LD_LIBRARY_PATH_64="$GFX_LIBPATH"
export HOME=/home/solnix XDG_CONFIG_HOME=/tmp/solnix-xdg XDG_CACHE_HOME=/tmp/solnix-cache XDG_RUNTIME_DIR=/tmp/solnix-run
export XDG_DATA_HOME=/tmp/solnix-data
mkdir -p "\$XDG_CONFIG_HOME" "\$XDG_CACHE_HOME" "\$XDG_RUNTIME_DIR" "\$XDG_DATA_HOME/.local/share" 2>/dev/null
chmod 700 "\$XDG_RUNTIME_DIR" 2>/dev/null
# Disable the AT-SPI accessibility bus: its org.a11y.Bus service (at-spi2) is not
# in the closure, so every GTK client's spawn attempt fails and -- with the
# broken C locale returning NULL D-Bus error strings -- trips a fatal GLib
# 'Bail out!' assertion that tears the whole session down. GTK runs fine without
# a11y once we tell it not to look.
export NO_AT_BRIDGE=1 GTK_A11Y=none QT_ACCESSIBILITY=0 GTK_MODULES=
# HOME (/home/solnix) is on the READ-ONLY ramdisk, so xfce4-session cannot write
# ~/.ICEauthority -> the ICE session manager never starts -> every client fails
# 'connect to the session manager' and xfconfd/panel/wm4 lose their bus names and
# exit. Point ICE + X auth + HOME-ish dirs at the tmpfs XDG_RUNTIME_DIR so the
# session manager can come up.
export ICEAUTHORITY="\$XDG_RUNTIME_DIR/ICEauthority"
export XAUTHORITY="\$XDG_RUNTIME_DIR/Xauthority"
touch "\$ICEAUTHORITY" "\$XAUTHORITY" 2>/dev/null; chmod 600 "\$ICEAUTHORITY" "\$XAUTHORITY" 2>/dev/null
# Force a UTF-8-safe C locale + filename encoding: Xlib/GLib have no locale data
# here ('locale set to C', 'UTF-8 -> \"\" conversion not supported'), which was
# producing NULL D-Bus error messages. Pin the charset so GLib stops choking.
export LANG=C LC_ALL=C G_FILENAME_ENCODING=UTF-8 CHARSET=UTF-8
export XKB_CONFIG_ROOT="$XKBCFG/share/X11/xkb"
# DISPLAY must be set for every X client; su - can strip it, so default it here.
: "\${DISPLAY:=:0}"; export DISPLAY
# xfce4-session IS the session manager AND the launcher of the desktop. It must
# be the SOLE thing started: it opens the ICE listener, exports SESSION_MANAGER,
# THEN launches its 'Failsafe' session (xfwm4 + xfsettingsd + xfce4-panel +
# xfdesktop + Thunar) as session-managed children that inherit SESSION_MANAGER.
# The old .xinitrc backgrounded those clients BEFORE exec'ing xfce4-session, so
# they raced the session manager and every one hit 'SESSION_MANAGER environment
# variable not defined'. To find its Failsafe session xfce4-session needs
# XDG_CONFIG_DIRS to include its own etc/xdg (holds xfce4-session.xml) and needs
# xfconfd on the bus. Start xfconfd (a D-Bus service, no SM needed), point
# XDG_CONFIG_DIRS at the session config, then exec the session manager alone.
export XDG_CONFIG_DIRS="$SESSION/etc/xdg:$PANEL/etc/xdg:$SETTINGS/etc/xdg:$XFWM4/etc/xdg:/etc/xdg"
"$XFCONF/lib/xfce4/xfconf/xfconfd" &
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
# libXau/libXdmcp (X11 transport) are staged into /usr/lib/64 + /lib/64 (they
# resolved to the OI host, not /nix/store, so the closure filter dropped them);
# ensure ld.so finds them for Xvfb/Xorg -- AND every staged store /lib so libs
# whose package /lib is not in the binary RUNPATH (e.g. libxfce4panel) resolve.
LD_LIBRARY_PATH_64=$GFX_LIBPATH; export LD_LIBRARY_PATH_64
_disp=:0
# Register socket families (esp. AF_UNIX -> /dev/ticotsord) so dbus-daemon can
# open its session-bus unix socket. The minimal live root doesn't run the
# network/socket-config SMF service, so soconfig must be invoked here; without
# it dbus fails 'Failed to open socket: Address family not supported'.
if [ -d /etc/sock2path.d ]; then
  /sbin/soconfig -d /etc/sock2path.d 2>/dev/null || echo "[solnix] soconfig -d failed"
fi
# belt+braces: explicitly register AF_UNIX (family 1) transports in case the
# dir load skipped them.
/sbin/soconfig 1 2 0 /dev/ticotsord 2>/dev/null || true
/sbin/soconfig 1 6 0 /dev/ticotsord 2>/dev/null || true
/sbin/soconfig 1 1 0 /dev/ticlts 2>/dev/null || true
# start the software framebuffer X server (Xvfb) detached.
$XORGSRV/bin/Xvfb \$_disp -screen 0 1280x800x24 -ac -nolisten tcp >/tmp/solnix-xvfb.log 2>&1 &
_xpid=\$!
sleep 8
if [ ! -S /tmp/.X11-unix/X0 ]; then echo "[solnix] Xvfb failed to start (see /tmp/solnix-xvfb.log)"; fi
# per-user XDG_RUNTIME_DIR (dbus/xfce want one it can create sockets in).
mkdir -p /tmp/xdg-solnix && chown solnix /tmp/xdg-solnix 2>/dev/null; chmod 700 /tmp/xdg-solnix 2>/dev/null
# The ICE library (xfce4-session's session manager) hard-wires its listener
# socket under /tmp/.ICE-unix and refuses to create the dir as a non-root euid
# ('_IceTransmkdir: euid != 0, /tmp/.ICE-unix will not be created' ->
# '_IceTransMakeAllCOTSServerListeners: failed to open listener' -> the session
# manager never exports SESSION_MANAGER -> every client warns). Pre-create it
# (and .X11-unix) as root, world-writable+sticky (mode 1777) like /tmp normally
# has, so ICE can bind its listener and SESSION_MANAGER comes up.
mkdir -p /tmp/.ICE-unix /tmp/.X11-unix 2>/dev/null; chmod 1777 /tmp/.ICE-unix /tmp/.X11-unix 2>/dev/null
# run the Xfce session AS the live user against that display (auto-login, no pw).
# DISPLAY/XDG_RUNTIME_DIR are hard-exported via env (su - resets the environment)
# and the session is started under dbus-run-session (the modern dbus-launch
# replacement -- host lacks dbus-launch) so the session bus is up for xfconfd.
su - solnix -c "env DISPLAY=\$_disp HOME=/home/solnix XDG_RUNTIME_DIR=/tmp/xdg-solnix /usr/bin/dbus-run-session -- /bin/sh /home/solnix/.xinitrc" >/tmp/solnix-x.log 2>&1 &
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
  # honor AUTOINSTALL_DISK marker (same block as the minimal method) BEFORE the
  # desktop, so the automated install test completes headless. If no marker,
  # fall through to the live desktop.
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
  echo "[solnix] starting live Xfce desktop (Xvfb software framebuffer)..."
  /usr/sbin/solnix-live-desktop 2>&1 || echo "[solnix] desktop launcher returned non-zero"
  # give xfce4-session time to spawn its children before snapshotting (the
  # launcher's own Xvfb wait already elapsed; the session bus + xfwm4/panel come
  # up a few seconds after su). Snapshot late so the ps below is meaningful.
  sleep 25
  echo "[solnix] Xvfb log:";  tail -20 /tmp/solnix-xvfb.log 2>/dev/null
  echo "[solnix] SESSION-LOG-BEGIN"; tail -60 /tmp/solnix-x.log 2>/dev/null; echo "[solnix] SESSION-LOG-END"
  echo "[solnix] X socket:"; ls -la /tmp/.X11-unix 2>/dev/null
  echo "[solnix] X clients running?"; ps -ef 2>/dev/null | grep -E 'Xvfb|xfce|xterm|xfwm4|xfdesktop|dbus' | grep -v grep
  # PERSISTENCE PROOF: snapshot AGAIN ~60s later. If xfce4-session (the session
  # manager) + xfwm4 + xfce4-panel are still all present in this second ps, the
  # live session held (didn't tear down after coming up).
  sleep 60
  echo "[solnix] SESSION-STILL-UP-CHECK (t+85s):"
  ps -ef 2>/dev/null | grep -E 'xfce4-session|xfwm4|xfce4-panel|xfsettingsd|Xvfb' | grep -v grep
  if ps -ef 2>/dev/null | grep -v grep | grep -q 'xfce4-sess'; then
    echo "[solnix] SESSION-VERDICT: xfce4-session STILL RUNNING (session stayed up)"
  else
    echo "[solnix] SESSION-VERDICT: xfce4-session GONE (session exited)"
  fi
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
# CRITICAL: the 4f offline pre-import (svccfg/svc.configd against the ramdisk's
# repository.db) RE-CREATES /etc/svc/volatile/{init.state,init-next.state,
# svc_nonpersist.db,repository-boot-*,...} as a side effect of running configd
# at build time. The line-134 purge (right after COPY_DIRS) is undone by 4f. So
# purge AGAIN here, AFTER 4f + BEFORE gzip, so the shipped boot_archive has an
# EMPTY /etc/svc/volatile (a runtime tmpfs) -> fresh PID1 init doesn't read a
# stale init.state -> no SIGKILL restart loop. (This is the real fix; the early
# purge alone was insufficient because pre-import repopulates it.)
rm -rf "$RDROOT"/etc/svc/volatile/* "$RDROOT"/etc/svc/volatile/.[!.]* 2>/dev/null || true
# maintainer directive: FINAL core scrub right before gzip (the 4f pre-import can
# crash a helper + leave a core). Delete any stray core; the coreadm policy was
# already written in the DECLARATIVE block (or here if no CS).
find "$RDROOT" \( -name 'core' -o -name 'core.[0-9]*' \) -type f 2>/dev/null | while read -r _c; do
  file "$_c" 2>/dev/null | grep -qi 'core file' && rm -f "$_c" && echo "  scrubbed core: ${_c#$RDROOT}" >&2 || true
done
[ -f "$RDROOT/etc/coreadm.conf" ] || { mkdir -p "$RDROOT/var/cores"; chmod 1777 "$RDROOT/var/cores" 2>/dev/null; printf 'COREADM_GLOB_PATTERN=/var/cores/core.%%f.%%p.%%t\nCOREADM_GLOB_ENABLED=yes\nCOREADM_PROC_ENABLED=no\n' > "$RDROOT/etc/coreadm.conf"; }
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
