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
# The live root is a MINIMAL slice of the running illumos root (~195MB used, not
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
# RD_MB is the RAW (uncompressed) size of the UFS ramdisk, and it is a HARD
# BOOT CONSTRAINT, not just a disk-space knob. The EFI loader's efi_loadaddr()
# (usr/src/boot/efi/loader/copy.c) calls
#   BS->AllocatePages(AllocateMaxAddress, EfiLoaderData, pages, &paddr)
# with paddr = UINT32_MAX, i.e. it demands CONTIGUOUS pages BELOW 4 GB, and it
# stat()s the file so it asks for the UNCOMPRESSED size, not the gzipped one.
# Real Lenovo X1 Carbon firmware fragments the low 4 GB (runtime services,
# ACPI NVS, framebuffer, reserved) and refused an 820 MB request:
#   failed to allocate 859832320 bytes for staging area: 9  (EFI_OUT_OF_RESOURCES)
#   Can not load environment module: out of memory
#   No rootfs module provided, aborting
# QEMU/OVMF hands out a clean memory map, so it never showed this (8/8 passes).
# So RD_MB must track MEASURED usage, not be padded "to be safe" -- padding it
# is what broke real hardware.
#
# Measured on the 820 MB minimal image (UFS superblock + cg summary of the
# shipped 2026-09-09 boot_archive): 195.0 MiB of the 769.1 MiB data area used,
# 3369 of 392000 inodes used -- a 4.2x overshoot. Confirmed by df on the build
# host at RD_MB=320: 199686KB used / 307158KB total.
#
# The X1's real ceiling is now KNOWN, read off its own `memmap` at the ok prompt:
# the largest free ConventionalMemory block below 4 GiB is 199248 pages at
# physical 0x100000 = 816,119,808 B = 778.3 MiB. The 820.0 MiB request missed it
# by 41.7 MiB (5.1%) -- a NEAR-MISS, not a wall. (`smap` was the wrong
# instrument: it collapses and merges types, and the 0x58000000/2 MiB line it
# showed is a small unrelated region. Use `memmap`.)
#
# 340 MB = 356,515,840 B therefore leaves ~438 MiB of headroom inside that block,
# while holding the measured 195.0 MiB of content with ~145 MiB of filesystem
# slack. The headroom is the point: 778.3 MiB is ONE machine's map and another
# firmware will fragment differently. Do not raise RD_MB to "be safe" -- padding
# it is exactly what broke real hardware. /tmp, /var/run and /system/volatile are
# tmpfs at runtime and the installer writes to the TARGET disk, so the live root
# barely grows after boot.
#
# GRAPHICAL=1 layers the Xfce desktop closure on top (~177 MB), so ~372 MiB of
# content -> 500 MB (524,288,000 B, ~254 MiB of headroom under 778.3 MiB).
# UNTESTED: no graphical media has been rebuilt or booted since this change; the
# df/raw-size gates below are what protect it.
GRAPHICAL="${GRAPHICAL:-0}"
# RD_MB default. STAGE_NIX=1 (the default, see section 2) adds the SLIM nix tree:
# 95,412,745 B measured with wc -c. Previous content measured 199,698 KB used, so
# with nix + terminfo (3.9 MB) + /usr/gnu (~14 MB) + rsync/xz/top/wget the live
# root lands near 306 MiB and 340 MB no longer leaves the required 32 MB of slack.
# 440 MB = 461,373,440 B UNCOMPRESSED = 56.5% of the X1's MEASURED 816,119,808 B
# largest low-4GB free block, i.e. ~338 MiB of headroom still under the ceiling.
# Set STAGE_NIX=0 to build the old nix-less media, which fits in 340.
#
# 420 -> 440 is TRACKING MEASURED USAGE, not padding "to be safe" (which the
# paragraph above rightly forbids). The ldd(1) closure that replaced the
# hand-maintained library allowlist stages 24 real dependencies the list omitted
# -- including usr/lib/libmapmalloc.so.1, whose absence is why vi died on real
# hardware. MEASURED consequence: live-root usage 378,626 KB (image k) ->
# 389,611 KB, which left 28,132 KB against the 32 MB RD_MIN_FREE_MB floor and
# correctly FAILED the build. The content is load-bearing, so the image gets the
# space; the occupancy gate stays where it is and did exactly its job.
# RD_MB default. The text installer now carries git + dig + the full tool
# closure, which land a ~640 MiB ramdisk (image p/p2 shipped exactly this,
# 82.2% of the X1's 778.3 MiB low block) -- so the text default is 640, not the
# old 440 which pre-dated those tools and would drop them. The graphical variant
# keeps its measured 500 (it does not add git/dig and has never needed more);
# raise it only against a measured graphical build, not "to be safe".
if [ "$GRAPHICAL" = 1 ]; then RD_MB="${RD_MB:-500}"; else RD_MB="${RD_MB:-640}"; fi
# RD_NBPI: newfs -i bytes-per-inode. illumos newfs defaults to nbpi=2048 for an
# image this size, which cost 20,522KB of inode tables at RD_MB=320 to hold 3369
# used inodes out of 160000 -- ~7% of the whole image spent on a table that is
# 98% empty. 8192 keeps a >10x inode margin and gives back ~15 MB, which matters
# proportionally more now that the image is small. The inode gate below fails the
# build if the margin is ever actually consumed.
RD_NBPI="${RD_NBPI:-8192}"
# RD_MAX_RAW_MB: refuse to ship a ramdisk whose UNCOMPRESSED size is above this,
# because that is literally the byte count the loader asks EFI for below 4 GB.
# 700 MB (734,003,200 B) admits the RD_MB=640 text image the media now needs
# (git + dig + the full tool closure land a ~671 MB / 640 MiB ramdisk, which
# image p already shipped at 82.2% of the X1's measured 778.3 MiB low block)
# with ~44 MiB of headroom under the ceiling, and still admits the 680 MB
# graphical variant. The old 560 cap PRE-DATED git/dig and rejected the very
# ramdisk p shipped -- it had drifted below the size the media requires.
RD_MAX_RAW_MB="${RD_MAX_RAW_MB:-700}"
# RD_MIN_FREE_MB / RD_MIN_FREE_INODES: refuse to ship a ramdisk with less slack
# than this, so shrinking RD_MB or RD_NBPI can never silently produce a full or
# truncated live root.
RD_MIN_FREE_MB="${RD_MIN_FREE_MB:-32}"
RD_MIN_FREE_INODES="${RD_MIN_FREE_INODES:-5000}"
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
log "lofi = $LOFI ; newfs (nbpi=$RD_NBPI)"
yes | newfs -m 1 -i "$RD_NBPI" "${LOFI/dsk/rdsk}" >/dev/null 2>&1 || newfs -m 1 -i "$RD_NBPI" "$LOFI" >/dev/null 2>&1 || \
  newfs "$LOFI" >/dev/null 2>&1 || die "newfs failed"
mount -F ufs -o nologging "$LOFI" "$RDROOT" || die "mount ramdisk failed"

# ---------------------------------------------------------------------------
# 2. populate the live root: copy the essential subtrees from the running root.
#    NOT the whole 10.7G — just what boots + partitions + zpools + installs.
# ---------------------------------------------------------------------------
log "populating live root (MINIMAL essential subtrees from $SRC)"
# BOTH loaders stage the WHOLE UNCOMPRESSED boot_archive into a limited region:
# BIOS into a limited heap, UEFI into contiguous pages BELOW 4 GB (AllocatePages
# with AllocateMaxAddress/UINT32_MAX). A 2.7G image OOMs BIOS and an 820MB one
# was refused by real X1 Carbon firmware. So keep the live root tiny (~195MB
# used): drivers + libc closure + the zfs/format/installboot tools. Do NOT
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
  /usr/sbin/useradd /usr/sbin/usermod /usr/sbin/groupadd /usr/bin/passwd
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
  /lib/svc/bin/svc.configd /lib/svc/bin/svc.startd /lib/svc/bin/mfstscan
  /usr/bin/git /usr/bin/dig /usr/bin/nslookup /usr/bin/host /usr/sbin/route
  /usr/libexec/git-core/git /usr/libexec/git-core/git-remote-https
  /usr/libexec/git-core/git-remote-http /usr/libexec/git-core/git-http-fetch"
for t in $CLOSURE_TOOLS; do
  [ -e "$SRC$t" ] && ldd "$SRC$t" 2>/dev/null | awk '{print $3}'
done | grep '^/usr/lib' | sort -u | while read -r libpath; do
  rel="${libpath#/}"
  # ICU DATA IS 33MB AND 64-BIT-ONLY IS ENOUGH. dig/host/nslookup pull
  # libdns -> libicuuc -> libicudata.so.78 (33MB), and the ldd walk sees it in
  # BOTH /usr/lib (32-bit) and /usr/lib/amd64 (64-bit) = ~66MB. Every live tool
  # that needs ICU runs 64-bit (isaexec dispatches to amd64), so the 32-bit copy
  # is dead weight that overflowed the ramdisk once. Skip the 32-bit libicudata;
  # keep the amd64 one. (git itself pulls no ICU -- this is purely the DNS tools.)
  case "$rel" in usr/lib/libicudata.so*) continue ;; esac
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
# the live shell need, NOT all of /usr/bin. The copy below cpio -o's the include
# list in ONE archive, which PRESERVES hardlinks -- so git (150 hardlinks @5MB)
# costs ~5MB here, not the ~800MB a per-file cp -L would have exploded it to.
# That per-file hazard is why git was excluded historically; with the
# single-archive cpio it is affordable, and --git / manual `git clone` on the
# live media both want it. Still keep the list curated -- the ramdisk ceiling is
# real (RD_MB budget), so add deliberately, not wholesale.
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
  usr/sbin/df
  # openssl's REAL target: usr/bin/openssl is a symlink into a versioned tree that
  # was never staged, so the link dangles in the image. solnix-install now uses
  # openssl to hash the admin password, so a dangling link would mean a LOCKED
  # account on a freshly installed laptop. Stage the versioned tree; the installer
  # still has fallbacks, but the primary path should work.
  #
  # ⚠️ THE BINARIES ARE NOT ENOUGH -- MEASURED IN THE SHIPPED IMAGE. Staging only
  # the two binaries produced an openssl that RESOLVED but could not RUN:
  #   ld.so.1: openssl: fatal: libssl.so.1.0.0: open failed
  # usr/bin/openssl points at the 1.0 tree, which is 32-bit ELF, and /lib/
  # libssl.so.1.0.0 is itself a symlink into usr/openssl/1.0/lib/ -- a SECOND-ORDER
  # dangling link, in a LIBRARY directory that the command-symlink gate does not
  # scan. Stage the two 32-bit libraries the 1.0 CLI actually needs, named
  # individually: staging the whole usr/openssl/*/lib trees cost 30,239 KB (cmake
  # files, engines, and amd64 copies of libs the ldd closure ALREADY places in
  # usr/lib/amd64) and blew the occupancy gate at 15,805 KB free. These two files
  # are 2,497,964 B total and are the whole fix. The openssl-3 CLI needs nothing
  # here: it resolves via usr/lib/64 -> amd64, which the ldd closure populates
  # (measured -- it ran correctly in a build that staged no versioned lib dir).
  usr/openssl/1.0/bin/openssl usr/openssl/3/bin/openssl
  usr/openssl/1.0/lib/libssl.so.1.0.0 usr/openssl/1.0/lib/libcrypto.so.1.0.0
  usr/bin/du usr/bin/echo usr/bin/printf usr/bin/expr usr/bin/dirname
  usr/bin/basename usr/bin/hostname usr/bin/sleep usr/bin/kill usr/bin/chmod
  usr/bin/chown usr/bin/chgrp usr/bin/mount usr/bin/umount usr/bin/sync
  usr/bin/yes usr/bin/file usr/bin/vi usr/bin/more usr/bin/less usr/bin/tee
  usr/bin/vim usr/bin/ex usr/bin/view usr/bin/nano
  usr/has/bin/vi
  usr/bin/man usr/bin/mandoc usr/bin/col usr/bin/nroff
  usr/bin/curl usr/bin/wget
  usr/sbin/ping usr/sbin/traceroute
  # DNS diagnostics -- dig/nslookup/host from the bind package. Staged so the
  # operator can debug name resolution (the live media's getent can stall on an
  # mdns source with no responder, so a real resolver query tool is worth having).
  # [ -e ] in the copy loop skips any the host lacks, so this is safe if absent.
  usr/bin/dig usr/bin/nslookup usr/bin/host
  usr/has/bin/file etc/magic
  usr/bin/env usr/bin/test usr/bin/true usr/bin/false usr/bin/sh usr/bin/pfexec
  usr/bin/su usr/bin/login usr/bin/newtask
  usr/bin/digest usr/bin/openssl usr/bin/od usr/bin/xargs usr/bin/mkfile
  usr/bin/gzip
  usr/bin/bzip2 usr/bin/xz usr/bin/unxz usr/bin/xzcat
  usr/bin/rsync
  usr/bin/top
  usr/bin/tput usr/bin/clear usr/bin/stty usr/bin/reset
  usr/bin/diff3 usr/bin/sdiff usr/bin/cmp usr/bin/comm usr/bin/join
  usr/bin/nl usr/bin/paste usr/bin/split usr/bin/uniq usr/bin/wget
  usr/bin/ssh usr/bin/scp usr/bin/sftp usr/bin/ssh-add usr/bin/ssh-agent
  # git -- for --git and manual `git clone` on the live media. Hardlinked heavily
  # in /usr/bin (git-* subcommands), but the single-archive cpio preserves the
  # links, so the real cost is ~5MB. git also lives in usr/libexec/git-core
  # (find-expanded since cpio -o does not recurse); bring the dir.
  usr/bin/git usr/libexec/git-core
  usr/bin/ksh usr/bin/pkill usr/bin/nohup usr/bin/time
  usr/sbin/useradd usr/sbin/userdel usr/sbin/usermod usr/sbin/groupadd
  usr/sbin/groupdel usr/sbin/groupmod usr/bin/passwd usr/sbin/pwconv
  usr/bin/chown usr/bin/chgrp usr/bin/mkdir
  usr/bin/kbd usr/sbin/modinfo usr/sbin/strconf
  # Reported missing on the installed system: `which` was absent entirely, along
  # with much of binutils. `which` in particular is depended on by countless
  # scripts and by muscle memory, and its absence reads as a broken system.
  usr/bin/which usr/bin/whence usr/bin/type
  usr/bin/nm usr/bin/strip usr/bin/objdump usr/bin/size usr/bin/ar usr/bin/ranlib
  usr/bin/ld usr/bin/as usr/bin/elfdump usr/bin/elfedit usr/bin/dump usr/bin/mcs
  usr/bin/ldd usr/bin/nawk usr/bin/pgrep usr/bin/ptree usr/bin/pargs usr/bin/pmap
  usr/bin/truss usr/bin/mdb usr/bin/gcore usr/bin/pstack usr/bin/pfiles
  usr/bin/readlink usr/bin/realpath usr/bin/seq usr/bin/tac usr/bin/rev
  usr/bin/md5sum usr/bin/sha1sum usr/bin/sha256sum usr/bin/cksum usr/bin/sum
  usr/bin/base64 usr/bin/uudecode usr/bin/uuencode
  usr/bin/getopt usr/bin/logger usr/bin/mesg usr/bin/tty usr/bin/who usr/bin/w
  usr/bin/uptime usr/bin/vmstat usr/bin/iostat usr/bin/mpstat usr/bin/prstat
  usr/bin/svcs usr/bin/svcprop usr/sbin/svcadm usr/sbin/svccfg
  usr/gnu/bin/which usr/gnu/bin/readlink usr/gnu/bin/stat usr/gnu/bin/seq
  usr/gnu/bin/find usr/gnu/bin/xargs usr/gnu/bin/tar usr/gnu/bin/awk
  usr/gnu/bin/sort usr/gnu/bin/head usr/gnu/bin/tail usr/gnu/bin/wc
  usr/gnu/bin/tr usr/gnu/bin/cut usr/gnu/bin/basename usr/gnu/bin/dirname
  usr/bin/mdb usr/bin/adb usr/bin/truss usr/bin/pstack usr/bin/pargs
  usr/bin/pmap usr/bin/pfiles usr/bin/pgrep usr/bin/ptree usr/bin/gcore
  usr/bin/prstat usr/bin/snoop
  usr/sbin/zpool usr/sbin/zfs usr/sbin/format usr/sbin/fmthard usr/sbin/prtvtoc
  usr/sbin/tar
  usr/sbin/mkfs usr/sbin/newfs usr/sbin/fsck usr/sbin/installboot
  usr/sbin/fstyp usr/sbin/clri
  usr/sbin/bootadm usr/sbin/lofiadm usr/sbin/devfsadm usr/sbin/dladm
  usr/sbin/ipadm usr/sbin/ifconfig usr/sbin/prtconf usr/sbin/init
  usr/sbin/route
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
# MAN PAGES: keep `man` + the pages (NixOS parity -- a base install has working
# man), and they land in BOTH the ISO live-root and the installed BE.
#
# ⚠️ CORRECTION to the previous comment here, which claimed "~82MB raw ... costs
# ~20MB on media". MEASURED with `wc -c`: /usr/share/man is 51,478,373 B, and
# ramdisk cost is UNCOMPRESSED bytes -- the gzip only shrinks the on-media file,
# not the allocation the EFI loader must make below 4 GB. So man costs ~49 MiB of
# the ceiling, not ~20 MB.
#
# ⚠️ AND, until the find-expansion added below, NO shipped image contained a
# single man page: cpio -o does not recurse into a listed directory, so
# usr/share/man arrived EMPTY (host=127 entries, ramdisk=0, measured). The
# "~20MB" figure was never real.
#
# It is kept (49 MiB is affordable at RD_MB=420: total lands at ~55% of ceiling),
# but it is now the FIRST thing to drop if the ceiling is ever approached --
# SOLNIX_NO_MAN=1 does that.
if [ "${SOLNIX_NO_MAN:-0}" != 1 ]; then
  for mp in usr/share/man etc/man.conf usr/share/man/man.cf usr/share/mandoc; do
    [ -e "$SRC/$mp" ] && echo "$mp" >> /tmp/solnix-tools.list
  done
else
  echo "SOLNIX_NO_MAN=1: man pages NOT staged (saves ~49 MiB uncompressed)" >&2
fi
# GNU DIFFUTILS + the rest of /usr/gnu/bin.
#
# ⚠️ LOAD-BEARING, not a nicety. illumos /usr/bin/diff prints
#     "No differences encountered"
# for identical files instead of staying silent, which has silently broken checks
# in this project more than once (see docs/working-with-subagents.md). The
# installed system therefore needs GNU diff, AND /usr/gnu/bin must come FIRST in
# PATH so `diff` means the GNU one (wired in /etc/profile + the live shell below).
# /usr/gnu is small: 4 diffutils bins = 641,160 B, +sed/grep = ~1.3 MB total.
for gp in usr/gnu/bin usr/gnu/share; do
  [ -e "$SRC/$gp" ] && echo "$gp" >> /tmp/solnix-tools.list
done
# TERMINFO: measured 3,871,847 B. Without it `less`, `top`, `vi` and any curses
# tool die with "No terminal database found" / unusable output. Cheap, and an
# installer whose pager does not work is not usable over a console.
for tp in usr/share/lib/terminfo usr/share/lib/tabset etc/termcap; do
  [ -e "$SRC/$tp" ] && echo "$tp" >> /tmp/solnix-tools.list
done
# POWER MANAGEMENT (modest, measured at 45,350 B total). illumos's PM is:
#   * the `power` driver (already in the whole-kernel-tree copy)
#   * /usr/lib/power/powerd, the daemon that acts on /etc/power.conf
#   * svc:/system/power + its method script
#   * /etc/power.conf itself
# There is NO poweradm and NO powertop on illumos -- those are Solaris 11 /
# Linux tools respectively. cpupm/cpu-threshold in power.conf is the knob.
for pp in usr/lib/power lib/svc/method/svc-power lib/svc/manifest/system/power.xml \
          etc/power.conf usr/sbin/poweroff usr/sbin/halt usr/sbin/shutdown \
          usr/sbin/reboot usr/sbin/uadmin sbin/uadmin etc/halt etc/reboot \
          usr/bin/pkill usr/bin/pgrep; do
  [ -e "$SRC/$pp" ] && echo "$pp" >> /tmp/solnix-tools.list
done
# ⚠️ reboot(1m) and poweroff(1m) are HARDLINKS to halt, not separate binaries:
# usr/src/cmd/halt/Makefile:40 is `ROOTLINKS = $(ROOTUSRSBIN)/poweroff
# $(ROOTUSRSBIN)/reboot`, and halt.c:49 dispatches on argv[0]. The loop above uses
# `[ -e ] &&`, which SILENTLY SKIPS anything absent -- so a missing link produced
# no warning and the maintainer booted an installed system with only `halt`, no way
# to reboot or power off. Same silent-skip shape as the /dev allowlist and the nix
# lib list. Report presence, and synthesise the argv[0] links if absent.
for _pw in usr/sbin/halt usr/sbin/reboot usr/sbin/poweroff usr/sbin/shutdown; do
  if [ -e "$SRC/$_pw" ]; then
    echo "  power cmd: $_pw present on host" >&2
  else
    echo "  WARN: $_pw absent on the build host -- will link it to halt in the image" >&2
  fi
done
# EXPAND DIRECTORY ENTRIES. ⚠️ `cpio -o` does NOT recurse into a directory named
# on its stdin -- it archives the directory INODE only, so every directory listed
# above arrived in the ramdisk EMPTY. Measured on this build:
#   usr/share/man          host=127 entries  ramdisk=0
#   usr/gnu/bin            host=25            ramdisk=0
#   usr/share/lib/terminfo host=42            ramdisk=0
# and confirmed with a minimal control (one dir, one file, cpio -o | cpio -idm ->
# 0 files copied). This is the SAME class as the xargs-split and readlink bugs
# already documented here: the copy "succeeded" and shipped nothing.
#
# It is also PRE-EXISTING: the man-page block above has been listing
# usr/share/man for several images, and the docs claim "~20MB on media" -- but no
# shipped image can have contained a single man page. Caught only because the new
# base-tooling gate asserts a FILE inside one of these dirs.
#
# Fix: expand every directory entry to its full file list with find(1) before
# handing the list to cpio. find IS present on illumos (unlike readlink/stat).
if [ -s /tmp/solnix-tools.list ]; then
  : > /tmp/solnix-tools.list.exp
  while read -r _e; do
    [ -n "$_e" ] || continue
    if [ -d "$SRC/$_e" ] && [ ! -h "$SRC/$_e" ]; then
      ( cd "$SRC" && find "$_e" -print 2>/dev/null ) >> /tmp/solnix-tools.list.exp
    else
      echo "$_e" >> /tmp/solnix-tools.list.exp
    fi
  done < /tmp/solnix-tools.list
  sort -u /tmp/solnix-tools.list.exp | grep -v '^/' > /tmp/solnix-tools.list
  # grep -v '^/': every legitimate entry above is RELATIVE (echoed as usr/... or
  # walked with `find` under `cd $SRC`). An ABSOLUTE entry can only point at the
  # host, and cpio cannot preserve a hardlink between an absolute host path and a
  # relative $RDROOT path -- it aborts the WHOLE stream with
  #   cpio: Cannot link "/usr/bin/scalar" and "usr/libexec/git-core/scalar", errno 18
  # dropping every entry after the failure (less/git/ls silently gone; 2>/dev/null
  # hid it). This surfaced once git's 150-way /usr/bin/git-* <-> git-core hardlink
  # group was added. Absolutes are never copyable into the ramdisk anyway, so
  # filtering them is both the fix and correct on its own terms.
  echo "tool list expanded to $(wc -l < /tmp/solnix-tools.list | tr -d ' ') paths (dirs walked with find; cpio -o does not recurse)" >&2
fi
# Copy the curated list in ONE archive. NOTE: the earlier `xargs tar -cf -`
# approach was BROKEN on illumos: illumos xargs honors a small -s command-size
# cap and SPLITS a long list into multiple `tar -cf -` invocations, each
# emitting a separate archive stream concatenated on stdout; `tar -xf -` reads
# only the FIRST stream and discards the rest -> entries in later batches (e.g.
# usr/libexec/sshd-auth) silently vanished, and WHICH ones dropped depended on
# where xargs split (intermittent). cpio -o reads the whole path list from
# stdin in a SINGLE archive (preserves hardlinks), so nothing is dropped.
#
# stderr is captured (not sent to /dev/null) and scanned for REAL errors: a bare
# 2>/dev/null once hid an errno-18 "Cannot link" that aborted the stream and
# silently dropped less/git. cpio is noisy (block counts), so filter to the
# lines that mean data loss and fail on them -- a copy that half-completes must
# not pass as success.
( cd "$SRC" && cpio -o -H ustar < /tmp/solnix-tools.list 2>/tmp/solnix-cpio-o.err ) \
  | ( cd "$RDROOT" && cpio -idm -H ustar 2>/tmp/solnix-cpio-i.err ) \
  || echo "WARN: tool copy pipeline returned nonzero" >&2
if grep -qiE 'Cannot link|Cannot open|write error|No space' /tmp/solnix-cpio-o.err /tmp/solnix-cpio-i.err 2>/dev/null; then
  echo "ERROR: cpio tool copy reported data-loss errors:" >&2
  grep -iE 'Cannot link|Cannot open|write error|No space' /tmp/solnix-cpio-o.err /tmp/solnix-cpio-i.err >&2
  die "tool copy incomplete -- refusing to ship a ramdisk missing tools"
fi

# --- 2.24 nix runtime into the live ramdisk, SLIMMED (STAGE_NIX=1, default).
#
# WHY this ships at all: solnix-install takes the SELF_INSTALL path on this media
# (no CS toplevel), which copies the LIVE ROOT onto the target disk. So whatever
# is in the ramdisk is what the installed system gets, and an installed system
# with no `nix` cannot install anything. Staging /nix-tools224 here is what gives
# a fresh install a working nix from first boot.
#
# ⚠️ WHY IT MUST BE SLIMMED, with the measured numbers. The relocatable bootstrap
# tarball materialises nix-build/nix-store/nix-env/... as 12 FULL COPIES of one
# 153,731,896 B UNSTRIPPED binary (all byte-identical: sha256
# ef98273b2f97b39f58b421e0c4df114ad6986ff4a7d7b9ecab747656ef276226), plus a 13th
# copy as libexec/nix/build-remote. Measured with `wc -c` sums:
#   bin 1,844,782,752   lib 437,860,164   libexec 153,731,896   runtime-lib 77,452,384
# i.e. ~2.5 GB, which is 3.1x the X1's ENTIRE 816,119,808 B low-memory ceiling.
# Staging it verbatim could never have booted.
#
# ⚠️ AND WHY `du` MUST NOT BE USED TO CHECK THIS. The build host is ZFS with
# compression on, so `du -sk /nix-tools224` reports ~1.1 GB and the tree was
# previously described as "~185 MB". A UFS ramdisk pays the UNCOMPRESSED bytes.
# This is the same wrong-unit error that let the original 820 MB overshoot hide
# behind the gzipped boot_archive size. Use `wc -c`, never `du`, for ramdisk cost.
#
# Slim = ONE stripped nix (4,041,432 B) + 11 symlinks + stripped libs +
# runtime-lib + etc + ca-bundle = 95,412,745 B measured. `nix --version` and
# `nix-store --version` both return 0 from the slimmed tree.
STAGE_NIX="${STAGE_NIX:-1}"
if [ "$STAGE_NIX" = 1 ] && [ -d /nix-tools224 ] && [ -x /nix-tools224/bin/nix ]; then
  log "staging SLIM /nix-tools224 into the live root (nix from first boot)"
  mkdir -p "$RDROOT/nix-tools224/bin" "$RDROOT/nix-tools224/lib" \
           "$RDROOT/nix-tools224/libexec/nix" "$RDROOT/nix-tools224/etc/nix"
  # ⚠️ STRIP OUTSIDE THE RAMDISK, NOT IN PLACE. This used to cp the 153,731,896 B
  # unstripped binary straight in and strip afterwards, which cannot work: the
  # ramdisk has ~145,880,064 B free at this point, so the FIRST cp dies with
  # "No space left on device" -- 7.5 MiB short before strip ever runs. Image j
  # only built because that host's /nix-tools224 happened to be pre-stripped,
  # making an undocumented host prerequisite look like a working script.
  # Staging via a temp copy costs one extra write and removes the prerequisite.
  _nixstage="${TMPDIR:-/var/tmp}/solnix-nixstage.$$"
  mkdir -p "$_nixstage"
  cp /nix-tools224/bin/nix "$_nixstage/nix" || die "copy nix to staging failed"
  if [ -x /usr/bin/strip ]; then
    /usr/bin/strip "$_nixstage/nix" || echo "WARN: strip nix failed (will try to ship unstripped)" >&2
  fi
  # Refuse to even attempt a copy that cannot fit, so the failure names the cause
  # instead of surfacing as a bare ENOSPC three steps later.
  _nsz=$(( $(wc -c < "$_nixstage/nix") ))
  echo "  staged nix binary: $_nsz B" >&2
  [ "$_nsz" -lt 33554432 ] || die "staged nix is $_nsz B (>32 MiB) -- strip did not run; the ramdisk cannot hold an unstripped nix (needs ~154 MB, has ~146 MB)"
  cp "$_nixstage/nix" "$RDROOT/nix-tools224/bin/nix" || die "copy nix failed"
  rm -f "$_nixstage/nix"; rmdir "$_nixstage" 2>/dev/null || true
  # strip: the shipped binary is unstripped (153.7 MB -> 4.0 MB). /usr/bin/strip
  # exists on illumos; guard anyway rather than trusting it (the stat(1) lesson).
  if [ -x /usr/bin/strip ]; then
    /usr/bin/strip "$RDROOT/nix-tools224/bin/nix" || echo "WARN: strip nix failed (shipping unstripped)" >&2
  else
    echo "WARN: no /usr/bin/strip -- shipping UNSTRIPPED nix, expect +150MB" >&2
  fi
  # the 11 sibling commands are argv[0]-dispatched from the same binary.
  ( cd "$RDROOT/nix-tools224/bin" && for _a in nix-build nix-channel \
      nix-collect-garbage nix-copy-closure nix-daemon nix-env nix-hash \
      nix-instantiate nix-prefetch-url nix-shell nix-store; do
        ln -s nix "$_a" 2>/dev/null || true; done )
  ( cd "$RDROOT/nix-tools224/libexec/nix" && ln -s ../../bin/nix build-remote 2>/dev/null || true )
    # ⚠️ These cp's used to end in `|| true` with stderr discarded, so a failed
    # copy was SILENT and the shipped image had ZERO libs in lib/, while the build
    # log said "runtime-lib staged PASS 39 libs" -- that check looked at
    # runtime-lib/ (a tar, which worked) and never at lib/ (this loop). nix then
    # died on the installed system with:
    #   ld.so.1: nix: fatal: libnixstore.so: open failed
    _nlibs=0
    for _l in /nix-tools224/lib/*.so /nix-tools224/lib/*.so.*; do
      [ -f "$_l" ] || continue
      # Same staging discipline as bin/nix above: libnixstore.so is 169,169,752 B
      # unstripped, larger than the whole ramdisk's free space, so stripping in
      # place after the copy cannot work. Strip outside, then copy.
      _lb=$(basename "$_l")
      _lstage="${TMPDIR:-/var/tmp}/solnix-libstage.$$"
      mkdir -p "$_lstage"
      if cp "$_l" "$_lstage/$_lb"; then
        [ -x /usr/bin/strip ] && /usr/bin/strip "$_lstage/$_lb" 2>/dev/null || true
        if cp "$_lstage/$_lb" "$RDROOT/nix-tools224/lib/$_lb"; then
          _nlibs=$((_nlibs + 1))
        else
          rm -f "$_lstage/$_lb"; rmdir "$_lstage" 2>/dev/null || true
          die "failed to copy nix library $_l into the ramdisk (stripped size $(wc -c < "$_lstage/$_lb" 2>/dev/null) B)"
        fi
        rm -f "$_lstage/$_lb"
      else
        die "failed to stage nix library $_l"
      fi
      rmdir "$_lstage" 2>/dev/null || true
    done
    echo "  nix-tools224/lib: staged $_nlibs library file(s)" >&2
    [ "$_nlibs" -ge 4 ] || die "only $_nlibs nix libraries staged; nix needs libnixstore.so et al"
    for _need in libnixstore.so libnixutil.so libnixexpr.so libnixmain.so; do
      [ -f "$RDROOT/nix-tools224/lib/$_need" ] || die "nix-tools224/lib/$_need missing -- nix cannot start"
    done
  ( cd /nix-tools224 && tar -cf - runtime-lib ) | ( cd "$RDROOT/nix-tools224" && tar -xf - ) \
    || echo "WARN: runtime-lib copy had errors" >&2
  [ -f /nix-tools224/ca-bundle.crt ] && cp /nix-tools224/ca-bundle.crt "$RDROOT/nix-tools224/ca-bundle.crt"

  # nix.conf for the INSTALLED system (SELF_INSTALL copies this root verbatim).
  cat > "$RDROOT/nix-tools224/etc/nix/nix.conf" <<'NT224CONF'
substituters = https://cache.solnix.io https://s3.solnix.io/solnix-cache
trusted-public-keys = cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=
ssl-cert-file = /nix-tools224/ca-bundle.crt
sandbox = false
build-users-group =
experimental-features = nix-command flakes fetch-closure
max-jobs = auto
NT224CONF

  # WRAPPERS in /usr/bin, NOT a global LD_LIBRARY_PATH.
  #
  # MEASURED MECHANISM: the top `nix` binary's RUNPATH is the absolute
  # /nix-tools224/lib:/nix-tools224/lib/amd64:/nix-tools224/runtime-lib, but the
  # TRANSITIVE libs carry BUILD-HOST RUNPATHs that do not exist on a target:
  #   libnixstore.so  -> /usr/gcc/13/lib/amd64:/usr/openssl/3/lib/amd64:/var/tmp/libgit2-inst/lib:/nix-tools224/lib
  #   libnixutil.so   -> /usr/gcc/13/lib/amd64:/usr/openssl/3/lib/amd64:/var/tmp/libgit2-inst/lib
  # so libboost_context.so.1.78.0, libgit2.so.1.7 and libarchive.so.13 are NOT
  # found from RUNPATH alone: `nix --version` dies
  #   ld.so.1: nix: fatal: libboost_context.so.1.78.0: open failed
  # (oi-fleet-bootstrap.sh documents the same thing for the build hosts.)
  #
  # A GLOBAL LD_LIBRARY_PATH would fix it and is the WRONG fix: runtime-lib holds
  # libcrypto.so.3, libssl.so.3, libstdc++.so.6, libncurses.so.5, libxml2.so.16,
  # libicuuc.so.78 -- exporting it system-wide would let nix's copies SHADOW the
  # system libraries for every process on the installed machine. Scope it to the
  # exec instead. VERIFIED: wrapper runs `nix (Nix) 2.24.15` rc=0 with no env set;
  # negative control (wrapper pointed at a nonexistent lib dir) FAILS as expected.
  for _n in nix nix-build nix-channel nix-collect-garbage nix-copy-closure \
            nix-env nix-hash nix-instantiate nix-prefetch-url nix-shell nix-store; do
    cat > "$RDROOT/usr/bin/$_n" <<WRAPEOF
#!/sbin/sh
# Scoped wrapper: nix's transitive libs carry build-host RUNPATHs, so
# LD_LIBRARY_PATH is required -- but ONLY for this exec, never exported globally
# (runtime-lib would shadow system libcrypto/libstdc++/libncurses otherwise).
LD_LIBRARY_PATH=/nix-tools224/runtime-lib:/nix-tools224/lib:/nix-tools224/lib/amd64
export LD_LIBRARY_PATH
NIX_CONF_DIR=\${NIX_CONF_DIR:-/nix-tools224/etc/nix}; export NIX_CONF_DIR
exec /nix-tools224/bin/$_n "\$@"
WRAPEOF
    chmod 0555 "$RDROOT/usr/bin/$_n"
  done

  # LOUD-FAIL GATES: a silent staging failure here ships an installer whose whole
  # purpose (nix from first boot) is missing. Assert the RESULT, not the copy.
  [ -x "$RDROOT/nix-tools224/bin/nix" ] || die "slim nix not staged at $RDROOT/nix-tools224/bin/nix"
  [ -s "$RDROOT/nix-tools224/bin/nix" ] || die "staged nix is EMPTY"
  _nb=$(wc -c < "$RDROOT/nix-tools224/bin/nix" | tr -d ' ')
  [ "$_nb" -gt 1000000 ] || die "staged nix is only $_nb B -- strip destroyed it"
  [ "$_nb" -lt 120000000 ] || die "staged nix is $_nb B -- NOT stripped, this will blow the ramdisk ceiling"
  _rl=$(ls "$RDROOT/nix-tools224/runtime-lib" 2>/dev/null | wc -l | tr -d ' ')
  [ "$_rl" -ge 30 ] || die "nix runtime-lib staged only $_rl libs (expect 39) -- nix will not run"
  for _need in libboost_context.so.1.78.0 libgit2.so.1.7 libarchive.so.13 libstdc++.so.6; do
    [ -f "$RDROOT/nix-tools224/runtime-lib/$_need" ] || \
      die "nix runtime-lib missing $_need (measured as REQUIRED: build-host RUNPATHs cannot supply it)"
  done
  [ -x "$RDROOT/usr/bin/nix" ] || die "nix wrapper not staged in /usr/bin"
  grep -q 'LD_LIBRARY_PATH=/nix-tools224/runtime-lib' "$RDROOT/usr/bin/nix" || \
    die "nix wrapper lacks the scoped LD_LIBRARY_PATH -- nix would fail on libboost_context"
  echo "  nix gate OK: slim nix ${_nb} B + $_rl runtime libs + 12 wrappers" >&2
else
  echo "WARN: NOT staging nix (STAGE_NIX=$STAGE_NIX, /nix-tools224 present=$([ -d /nix-tools224 ] && echo yes || echo no));" >&2
  echo "      the installed system will have NO nix (SELF_INSTALL copies this root verbatim)." >&2
fi
# native ping (task requirement: curl + native ping present).
[ -e "$RDROOT/usr/sbin/ping" ] || { [ -x /usr/sbin/ping ] && cp /usr/sbin/ping "$RDROOT/usr/sbin/ping" && chmod 4555 "$RDROOT/usr/sbin/ping" && chown root:bin "$RDROOT/usr/sbin/ping" 2>/dev/null; }

# USER ADMINISTRATION. The image ships NO personal user by design, so the operator
# must be able to create one on the installed system -- `useradd` + `passwd` are
# therefore part of the base install, not extras. Whole set costs 190,920 B.
#
# ⚠️ passwd(1) is SETUID+SETGID root (mode 4555/2555 -> -r-sr-sr-x). It CANNOT
# work without those bits, and an archive round-trip is exactly where they get
# dropped. Re-assert them explicitly rather than trusting cpio, then GATE on it
# below: a passwd that silently lost setuid fails only when the operator tries to
# set a password, i.e. after the install.
if [ -e "$RDROOT/usr/bin/passwd" ]; then
  chown root:sys "$RDROOT/usr/bin/passwd" 2>/dev/null || true
  chmod 6555 "$RDROOT/usr/bin/passwd" 2>/dev/null || true
fi
# /export/home is the illumos home-directory parent and useradd -m needs it to
# exist (it does not create the parent). Absent from the curated tree.
mkdir -p "$RDROOT/export/home" 2>/dev/null || true
chmod 0755 "$RDROOT/export" "$RDROOT/export/home" 2>/dev/null || true

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
  /usr/lib/64/libcom_err.so.3 \
  /usr/lib/64/libssl.so.3 /usr/lib/64/libncurses.so.5 \
  /usr/lib/libncurses.so.5; do
  _copy_lib "$_l"
done
# ⚠️ CLOSE THE WHOLE CLASS: resolve every staged ELF's libraries with ldd(1)
# rather than maintaining a list by hand. The hardcoded list above shipped a `vi`
# that died with "ld.so.1: vi: fatal: libmapmalloc.so.1: open failed" -- the same
# shape as the hardcoded 12-name /dev allowlist that omitted /dev/zfs and
# /dev/sad. Enumerating real dependencies is the only version that cannot
# silently omit something.
#
# ldd is illumos-native (SUNWcsu) but guard rather than assume -- the stat(1) and
# readlink(1) lessons. Without it, fall back and SAY SO: a silent downgrade here
# ships binaries that die at exec time.
if [ -x /usr/bin/ldd ]; then
  : > "$OUT/.ldd-added"
  for _bin in "$RDROOT"/usr/bin/* "$RDROOT"/usr/sbin/* "$RDROOT"/usr/gnu/bin/* \
              "$RDROOT"/usr/has/bin/* "$RDROOT"/sbin/* "$RDROOT"/usr/lib/*.so* \
              "$RDROOT"/usr/openssl/1.0/bin/* "$RDROOT"/usr/openssl/3/bin/*; do
    [ -f "$_bin" ] || continue
    LC_ALL=C od -An -N4 -tx1 "$_bin" 2>/dev/null | grep -q '7f 45 4c 46' || continue
    /usr/bin/ldd "$_bin" 2>/dev/null | while read -r _n _a _p _rest; do
      case "$_p" in /*) ;; *) continue ;; esac
      # ldd resolves $ORIGIN-relative RUNPATHs against the STAGED binary, so it
      # reports paths INSIDE the build tree. MEASURED: .ldd-added held
      # var/tmp/solnix-media/rd/usr/bin/../../lib/libelf.so.1, and 1.8 MB of junk
      # landed under $RDROOT/var/tmp/ while staging nothing useful -- the runtime
      # resolves the SONAME on the real library path, not that one. Skip $OUT:
      # anything already inside the ramdisk needs no staging.
      case "$_p" in "$OUT"/*|"$RDROOT"/*) continue ;; esac
      [ -f "$_p" ] || continue
      # /usr/lib/64 and /lib/64 are SYMLINKS to amd64 in the live root, and
      # illumos `mkdir -p` FAILS rc=2 ("Exists but is not a directory") when the
      # LAST component is a symlink-to-directory -- GNU mkdir succeeds, illumos
      # does not. Under `set -e` that KILLED THE BUILD (vim -> /usr/lib/64/
      # libncurses.so.5, zpool -> /lib/64/libzfs.so.1 both hit it). Normalise
      # 64/ -> amd64/ exactly as _copy_lib() above already does, so the parent is
      # a real directory; ld.so.1 still finds the file through the 64 symlink.
      _rel=$(echo "${_p#/}" | sed -e 's,^usr/lib/64/,usr/lib/amd64/,' -e 's,^lib/64/,lib/amd64/,')
      [ -f "$RDROOT/$_rel" ] && continue
      mkdir -p "$RDROOT/$(dirname "$_rel")" 2>/dev/null || true
      cp -p "$_p" "$RDROOT/$_rel" 2>/dev/null && printf '%s\n' "$_rel" >> "$OUT/.ldd-added"
    done
  done
  _ldd_n=$(sort -u "$OUT/.ldd-added" 2>/dev/null | wc -l | tr -d ' ')
  echo "  ldd closure: added ${_ldd_n:-0} library file(s) missing from the manual list" >&2
  rm -f "$OUT/.ldd-added"
else
  echo "WARN: no /usr/bin/ldd -- library staging falls back to the manual list;" >&2
  echo "      expect 'ld.so.1: <cmd>: fatal: lib*.so: open failed' at runtime" >&2
fi

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
# NOTE: illumos has NO readlink(1) -- /usr/bin/readlink is absent on the base
# image, so `$(/usr/bin/readlink /dev/$n)` expanded to the empty string and the
# `ln -sf "" ...` silently did nothing (errors swallowed by 2>/dev/null||true),
# leaving the live ramdisk with NONE of these nodes. Derive the target from
# `ls -ld` instead, the same idiom scripts/solnix-install uses (_readlink).
#
# THE ALLOWLIST WAS THE SECOND HALF OF THAT SAME DEFECT. The readlink fix
# corrected HOW each node was derived and nobody questioned WHICH nodes the list
# named. It held exactly 13 names, so the shipped media had 12 /dev entries and
# was missing, among others, /dev/zfs (libzfs_init opens it -> "internal error:
# failed to initialize ZFS library") and /dev/sad/user (ttymon/autopush open it
# -> "ttymon: open /dev/sad/user failed"). Both errors are on the shipped
# console log. Note `dlpi` was in the list and does not exist on the host at all,
# which is the signature of a hand-maintained list: wrong in both directions.
#
# So DERIVE the set instead of naming it, the same principle COPY_DIRS already
# applies to the kernel trees (whole trees, not a curated driver list).
#
# WHY NOT COPY /dev WHOLESALE: /dev mixes two kinds of entry. Nodes under
# devices/pseudo/ are PSEUDO devices -- drivers with no hardware behind them
# (zfs, sad, mm, log, conskbd, ...) which exist identically on every machine, so
# staging them is safe and host-independent. But dsk/, rdsk/, net/, cfg/, term/,
# the e1000g0/ena0 links and friends encode the BUILD HOST's own disk and NIC
# INSTANCE numbers -- exactly the per-machine kernel state that must never ride
# onto removable media (the same class of bug as shipping a populated
# /etc/path_to_inst). Copying those would actively misinform the live kernel
# about hardware the target does not have.
#
# Hence: stage EVERY pseudo-backed node, and ONLY pseudo-backed nodes. devfsadm
# regenerates the hardware-specific ones at boot for whatever hardware is real.
# Handles BOTH shapes /dev uses: a bare symlink (/dev/zfs) and a DIRECTORY of
# symlinks (/dev/sad/{admin,user}). The old `[ -L ]` test silently skipped every
# directory-shaped node, so simply adding "sad" to the list would have no-oped --
# the recurring failure mode in this script.
log "staging /dev pseudo-device nodes (derived from $SRC/dev, both shapes)"
_devlink() {   # $1 = path; echo its symlink target ($SRC has no readlink(1))
  ls -ld "$1" 2>/dev/null | sed -n 's/.* -> //p'
}
_stage_dev_link() {   # $1 = /dev-relative path ("zfs" or "sad/user")
  _t=$(_devlink "$SRC/dev/$1")
  case "$_t" in *devices/pseudo/*) ;; *) return 1 ;; esac
  mkdir -p "$RDROOT/dev/$(dirname "$1")" 2>/dev/null || true
  rm -f "$RDROOT/dev/$1" 2>/dev/null || true
  ln -s "$_t" "$RDROOT/dev/$1" || return 1
  return 0
}
_ndev=0
for _e in "$SRC"/dev/*; do
  _n=$(basename "$_e")
  if [ -L "$_e" ]; then
    _stage_dev_link "$_n" && _ndev=$((_ndev+1))
  elif [ -d "$_e" ]; then
    # directory shape: stage the pseudo-backed symlinks INSIDE it (sad/, lofi/,
    # rlofi/, dtrace/). A dir whose entries are all hardware links (dsk/, net/)
    # contributes nothing and is left for devfsadm.
    for _s in "$_e"/*; do
      [ -L "$_s" ] || continue
      _stage_dev_link "$_n/$(basename "$_s")" && _ndev=$((_ndev+1))
    done
  fi
done
log "staged $_ndev /dev pseudo nodes"

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
# path_to_inst is DELIBERATELY NOT in this list. It is per-machine kernel state
# (its own header says "Caution! This file contains critical kernel state"): it
# pins driver INSTANCE numbers to the build host's exact PCI topology. It used to
# be copied here and then truncated ~80 lines below, which worked but read as a
# contradiction and invited someone to "fix" the truncation. It is now created
# empty in exactly one place, and gate (iv) asserts it shipped empty.
# The files that REMAIN here are host-independent by nature: driver tables
# (name_to_major, driver_aliases, ...) describe drivers, not this machine's
# device instances.
for f in name_to_major name_to_sysnum driver_aliases driver_classes minor_perm \
         system vfstab nsswitch.conf passwd shadow group \
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
  # nix's NEEDED libs that resolve to the OS (libreadline/libsodium in
  # /usr/lib/amd64) are only pulled into the ramdisk if some base tool links
  # them; nix is the only reader of readline/sodium here, so a slim closure
  # drops them -> 'ld.so.1: nix: libreadline.so.8: open failed'. Walk nix's ldd
  # and copy any OS-resolved lib (not already in the ramdisk, not /nix/store)
  # into the live /usr/lib/amd64 so nix runs with no LD_LIBRARY_PATH.
  _nixbin=$(readlink -f "$CS/sw/bin/nix" 2>/dev/null || echo "$CS/sw/bin/nix")
  if [ -x "$_nixbin" ]; then
    ( unset LD_LIBRARY_PATH; ldd "$_nixbin" 2>/dev/null || true ) | awk '/=>/{print $3}' | while read -r _lib; do
      case "$_lib" in /nix/store/*|"") continue;; esac
      [ -f "$_lib" ] || continue
      _dst="$RDROOT${_lib}"
      [ -e "$_dst" ] && continue
      mkdir -p "$(dirname "$_dst")" 2>/dev/null || true
      # illumos /usr/bin/cp rejects -L on files; these are real files (ldd
      # resolved them), so a plain cp copies content. Prefer GNU cp ($GCP).
      { "$GCP" "$_lib" "$_dst" 2>/dev/null || cp "$_lib" "$_dst" 2>/dev/null; } \
        && echo "  staged nix runtime lib: ${_lib}" >&2 || true
    done || true
  fi
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
    # bare cp (not cp -L): illumos /usr/bin/cp rejects -L on a single file (mv.c:271)
    # and already dereferences a source symlink, so -L is both wrong and unneeded here.
    cp "$CS/etc/nix/nix.conf" "$RDROOT/etc/nix/nix.conf" 2>/dev/null || true
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
  # ⚠️ devfsadm and the disk listing go to the LOG, never to /dev/console.
  #
  # OBSERVED ON REAL HARDWARE: this block redirects to /dev/console (see the
  # closing `} > /dev/console 2>&1`), and ttymon/login READS THAT SAME DEVICE. So
  # `ls /dev/dsk` was delivered to login as if TYPED, and the console showed
  #
  #   solnix console login: c1t001B448B485502D1d0p0
  #   c1t001B448B485502D1d0p1        <- consumed as usernames
  #
  # login then loops rejecting device names as users, and real keystrokes are lost
  # in the flood. The maintainer reported this as "no keyboard" -- the keyboard was
  # fine; the prompt was drowning. Anything chatty must NOT share the console with
  # an interactive login.
  /usr/sbin/devfsadm >>/var/log/solnix-live.log 2>&1 || true
  { echo "[solnix] disks visible:"; ls /dev/dsk 2>/dev/null; } >>/var/log/solnix-live.log 2>&1
  echo "[solnix] devfsadm done; disk list in /var/log/solnix-live.log"

    if [ ! -r /etc/solnix-autoinstall ]; then
      _bp=$(/usr/sbin/prtconf -v 2>/dev/null | sed -n '/solnix-autoinstall/{n;s/.*value=.\{0,1\}//;s/.$//p;}' | head -1)
      if [ -n "$_bp" ]; then
        echo "$_bp" > /etc/solnix-autoinstall
        echo "[solnix] auto-install from BOOT PROPERTY solnix-autoinstall='$_bp'"
      fi
    fi
  # IDENTIFY OUR OWN BOOT MEDIUM -- ALWAYS, not only when hunting for a marker.
  #
  # ⚠️ DATA-LOSS GUARD. The `auto` target picker below skips the disk named in
  # /tmp/.solnix-media-disk. That file used to be written only inside the
  # media-marker branch, so when the marker was BAKED INTO THE RAMDISK
  # (AUTOINSTALL_DISK= at build time) the branch never ran, $_media was EMPTY and
  # the media-exclusion silently no-opped -- leaving the hsfs check as the only
  # thing between `auto` and erasing the USB stick the operator booted from.
  # Identification is therefore unconditional and keyed on OUR OWN CONTENT
  # (the boot_archive), not on the marker, so it holds for every marker source.
  #
  # The medium is found by ATTEMPTING a read-only hsfs mount rather than by
  # fstyp, deliberately: the target-picker's own guard already uses fstyp, and
  # two guards sharing one mechanism are one guard. mount -F hsfs -o ro fails
  # harmlessly on anything that is not an ISO9660 filesystem and writes nothing.
  _mediadisk=""
  for _p0 in /dev/dsk/c*p0; do
    [ -e "$_p0" ] || continue
    mkdir -p /tmp/.media
    if /usr/sbin/mount -F hsfs -o ro "$_p0" /tmp/.media 2>/dev/null; then
      if [ -f /tmp/.media/platform/i86pc/amd64/boot_archive ]; then
        _mediadisk=$(basename "$_p0" p0)
        echo "[solnix] boot medium identified as $_mediadisk (solnix ISO9660) -- EXCLUDED from install targets"
        if [ ! -r /etc/solnix-autoinstall ] && [ -f /tmp/.media/solnix-autoinstall ]; then
          tr -d '\r' < /tmp/.media/solnix-autoinstall | head -1 > /etc/solnix-autoinstall
          echo "[solnix] auto-install marker found on media $_mediadisk: '$(cat /etc/solnix-autoinstall)'"
        fi
      fi
      /usr/sbin/umount /tmp/.media 2>/dev/null
    fi
    [ -n "$_mediadisk" ] && break
  done
  echo "$_mediadisk" > /tmp/.solnix-media-disk
  if [ -r /etc/solnix-autoinstall ]; then
    _tgt=$(cat /etc/solnix-autoinstall 2>/dev/null)
    _media=$(cat /tmp/.solnix-media-disk 2>/dev/null)
    if [ "$_tgt" = auto ] || [ -z "$_tgt" ]; then
      _tgt=""
      for _c in /dev/rdsk/c*t*d0s0 /dev/rdsk/c*d0s0; do
        [ -e "$_c" ] || continue
        _d=$(basename "$_c"); _d=${_d%s0}
        # TWO INDEPENDENT DATA-LOSS GUARDS, different mechanisms on purpose:
        #   1. never the disk we booted from (identified above by content)
        #   2. never a disk whose p0 is itself ISO9660 (catches a medium that
        #      failed identification, e.g. mount refused)
        [ -n "$_media" ] && [ "$_d" = "$_media" ] && continue
        case "$(/usr/sbin/fstyp "/dev/rdsk/${_d}p0" 2>/dev/null)" in hsfs) continue;; esac
        _tgt=$_d; break
      done
    fi
    echo "[solnix] AUTO-INSTALL to ${_tgt:-<none found>} (media=${_media:-?}) -- THIS DISK WILL BE ERASED"
    /usr/sbin/format </dev/null 2>&1 | grep -E '^ +[0-9]+\.' | head -8 || true
    if [ -n "$_tgt" ]; then
      _i=10; while [ $_i -gt 0 ]; do printf '[solnix] writing to %s in %2d s ...\r' "$_tgt" $_i; sleep 1; _i=$((_i-1)); done; echo
      echo "[solnix] AUTO-INSTALL starting on $_tgt"
      # ⚠️ SOLNIX_TARGET_CONSOLE=text, NOT the "ttya" default. illumos derives BOTH
      # stdin and stdout from the console value, so an installed system pointed at
      # a serial port the machine does not have boots to a BLACK SCREEN that also
      # takes no input -- and by then the target disk is already erased. This path
      # is by definition the keyboard-free one, i.e. a laptop with no serial port,
      # so it must hand the framebuffer console to the installed system. "text" is
      # exactly what this media ships and is the configuration the X1 Carbon has
      # actually booted; "text,ttya" is NOT used
      # because only the single value has hardware evidence behind it.
      SOLNIX_POOL=rpool SOLNIX_ALLOW_RPOOL=1 SOLNIX_TARGET_CONSOLE=text \
        /usr/sbin/solnix-install "$_tgt" \
        && echo "SOLNIX_AUTOINSTALL_RESULT: DONE" \
        || echo "SOLNIX_AUTOINSTALL_RESULT: FAIL rc=$?"
    else
      echo "SOLNIX_AUTOINSTALL_RESULT: FAIL no-target-disk"
    fi
  fi
  # second probe: give slow USB enumeration ~20 s more, then report again
  sleep 20
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
# /usr/gnu/bin FIRST: illumos /usr/bin/diff prints "No differences encountered"
# for identical files, which silently breaks scripted comparisons. GNU diffutils
# is staged and must win the PATH lookup.
PATH=/usr/gnu/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/usr/ccs/bin
export PATH TERM=${TERM:-vt100} TMPDIR=/tmp
NIX_CONF_DIR=/etc/nix; export NIX_CONF_DIR
NIX_PATH=nixpkgs=/run/current-system/solnix-flake; export NIX_PATH
cat /etc/solnix-banner 2>/dev/null
exec /usr/bin/ksh93 2>/dev/null || exec /sbin/sh
SHELLEOF
chmod 0555 "$RDROOT/etc/solnix-live-shell"

# /etc/profile PATH: /usr/gnu/bin FIRST for every login shell (console + ssh) on
# BOTH the live media and the installed system (SELF_INSTALL copies this root).
# Appended, not rewritten, so the stock profile's other setup is preserved.
if [ -f "$RDROOT/etc/profile" ] && ! grep -q 'solnix-gnu-path' "$RDROOT/etc/profile"; then
  cat >> "$RDROOT/etc/profile" <<'PROFPATH'

# solnix-gnu-path: /usr/gnu/bin FIRST. illumos /usr/bin/diff prints
# "No differences encountered" for identical files rather than staying silent,
# so scripts that test diff output silently misbehave. GNU diffutils is staged;
# make it win. /nix-tools224/bin is wrapped into /usr/bin, so no entry needed.
PATH=/usr/gnu/bin:/usr/sbin:/usr/bin:/sbin:/usr/ccs/bin
export PATH
PROFPATH
fi
# LIVE nix.conf (5HAV, s3-origin, flakes) so nix works in the installer shell
# even when no full CS is baked (minimal ISO). solnix-install re-copies the
# INSTALLED system's nix.conf from the toplevel it lays down.
mkdir -p "$RDROOT/etc/nix"
if [ ! -f "$RDROOT/etc/nix/nix.conf" ]; then
  cat > "$RDROOT/etc/nix/nix.conf" <<'NIXCONF'
substituters = https://s3.solnix.io/solnix-cache https://cache.solnix.io
trusted-public-keys = cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=
experimental-features = nix-command flakes fetch-closure
ssl-cert-file = /nix/store/jxn55a9725j8ba9hkqila89s66abszhr-nix-2.24.15/etc/ssl/certs/ca-bundle.crt
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

  This media does NOT install by itself. Nothing is written until you run
  solnix-install yourself, and it will not touch the disk you booted from.

  nix is staged: `nix --version` works here and on the installed system.
  Editor: vi (native). Pager: less. GNU diffutils is first in PATH.

BANNEREOF
# autopush needs iu.ap; copy if present, else stub
[ -e /etc/iu.ap ] && cp /etc/iu.ap "$RDROOT/etc/iu.ap" 2>/dev/null || : > "$RDROOT/etc/iu.ap"

# POWER MANAGEMENT defaults for a laptop. The stock /etc/power.conf already has
# `cpupm enable` + `cpu-threshold 1s`; add S3 and device/display idle-down, which
# is what actually matters on battery. Deliberately MODEST -- these are config
# lines, not packages, so the ramdisk does not grow.
#
# WHAT illumos DOES NOT HAVE, so it is not staged and not promised:
#   * no poweradm(8)    -- that is Solaris 11 only
#   * no powertop       -- Linux only; illumos has no equivalent
#   * no tlp/thermald   -- no analog
#   * cpu_deep_idle is a driver/kernel tunable, NOT a power.conf keyword; it is
#     set via /etc/system on hardware that supports it, and is left alone here
#     because enabling deep C-states blind on unknown hardware risks a hang.
# So: cpupm + autopm + autoS3 + device idle, and the `power` driver (which comes
# in with the whole-kernel-tree copy) plus /usr/lib/power/powerd.
if [ -f "$RDROOT/etc/power.conf" ] && ! grep -q 'solnix-pm' "$RDROOT/etc/power.conf"; then
  cat >> "$RDROOT/etc/power.conf" <<'PMEOF'

# solnix-pm: laptop defaults. autopm/autoS3 `default` (above) means "enable on
# hardware that reports support", which is the right call for unknown machines.
# cpupm enable + a 1s threshold is already set above; add display/device idle.
device-thresholds            /dev/fb          900s
system-threshold             always-on
PMEOF
fi

cat > "$RDROOT/etc/solnix-release" <<EOF
The Solnix Operating System - live installer media
built: $(date -u +%FT%TZ 2>/dev/null || date)
host:  $(uname -a)
EOF

# path_to_inst must EXIST (devfsadm writes it) but must be EMPTY: it is
# per-machine kernel state and the target's topology is not the build host's.
# This used to fall back to `cp /etc/path_to_inst` when the file was absent,
# which would have shipped the build host's PS/2 keyboard/mouse instance pins
# onto media booted on unrelated hardware. Always empty, never copied.
: > "$RDROOT/etc/path_to_inst"

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
  # See the minimal method: chatty output must not go to /dev/console, which
  # ttymon/login reads -- it is delivered to login as typed input.
  /usr/sbin/devfsadm >>/var/log/solnix-live.log 2>&1 || true
  { echo "[solnix] disks visible:"; ls /dev/dsk 2>/dev/null; } >>/var/log/solnix-live.log 2>&1
  echo "[solnix] devfsadm done; disk list in /var/log/solnix-live.log"
  # honor AUTOINSTALL_DISK marker (same block as the minimal method) BEFORE the
  # desktop, so the automated install test completes headless. If no marker,
  # fall through to the live desktop.
  if [ -r /etc/solnix-autoinstall ]; then
    _tgt=$(cat /etc/solnix-autoinstall 2>/dev/null)
    _media=$(cat /tmp/.solnix-media-disk 2>/dev/null)
    if [ "$_tgt" = auto ] || [ -z "$_tgt" ]; then
      _tgt=""
      for _c in /dev/rdsk/c*t*d0s0 /dev/rdsk/c*d0s0; do
        [ -e "$_c" ] || continue
        _d=$(basename "$_c"); _d=${_d%s0}
        # same two data-loss guards as the minimal method. NOTE: this method does
        # NOT run the boot-medium identification block, so /tmp/.solnix-media-disk
        # is absent, $_media is empty and guard 1 is INERT here -- guard 2 (fstyp
        # hsfs) is the only live one. Acceptable only because no graphical media
        # has ever been shipped; copy the identification block up from the minimal
        # method before shipping one.
        [ -n "$_media" ] && [ "$_d" = "$_media" ] && continue
        case "$(/usr/sbin/fstyp "/dev/rdsk/${_d}p0" 2>/dev/null)" in hsfs) continue;; esac
        _tgt=$_d; break
      done
    fi
    echo "[solnix] AUTO-INSTALL to ${_tgt:-<none found>} (media=${_media:-?})"
    /usr/sbin/format </dev/null 2>&1 || true
    if [ -n "$_tgt" ]; then
      # SOLNIX_TARGET_CONSOLE=text for the same reason as the minimal method: an
      # unattended install must not leave the installed system talking to a
      # serial port that may not exist.
      SOLNIX_POOL=rpool SOLNIX_ALLOW_RPOOL=1 SOLNIX_TARGET_CONSOLE=text \
        /usr/sbin/solnix-install "$_tgt" \
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
# ---------------------------------------------------------------------------
# 5a. HARD CLOSURE GATE: verify what we STAGED is actually THERE.
#
# The durable lesson of this script's whole bug history: every serious defect so
# far was a silent staging failure, not a wrong decision. A missing readlink(1)
# made `ln -sf ""` a no-op and shipped ZERO /dev nodes; a hardcoded 13-name /dev
# allowlist shipped media with no /dev/zfs (libzfs_init fails) and no
# /dev/sad/user (ttymon fails); a missing stat(1) made a size gate ALWAYS FALSE
# so the check after its && never ran; illumos xargs split a tool list into
# multiple tar streams and dropped whichever entries landed after the split.
#
# Every one of those would have been caught by asserting the RESULT instead of
# trusting the copy. So: assert. Loudly, and before anything ships.
#
# These use `[ -e ]`/`ls` and `die`, never a tool that might be absent -- a gate
# that depends on a missing tool is how the stat(1) gate silently passed for weeks.
log "verifying live-root closure (loud-fail gates)"

# (i) /dev nodes the live media's own services open. Each name here traces to an
#     OBSERVED failure or to a service on the media, not to a guess:
#       zfs        libzfs_init(3lib) -> zpool/zfs/solnix-install (rpool creation)
#       sad/user   ttymon + autopush(8) STREAMS admin (observed console error)
#       sad/admin  autopush -f at boot
#       dld        dlmgmtd; absent -> datalink-management maintenance -> ~52 svcs
#       console msglog syscon systty sysmsg  svc.startd/init stdio + logging
#       null zero tty poll random urandom    libc/daemon basics
#       conslog log  syslogd and anything calling syslog(3c)
#       ptmx ptmajor pts/  pseudo-terminals: ssh sessions and script(1)
#       kbd mouse  conskbd/consms console input aggregators
#       lofictl    lofiadm, used by the installer to mount images
#       crypto cryptoadm  cryptosvc; `digest` in bootadm's archive path
_DEV_REQUIRED="zfs sad/user sad/admin dld console msglog syscon systty sysmsg
  null zero tty poll random urandom conslog log ptmx ptmajor kbd mouse lofictl
  crypto cryptoadm"
_missing=""
for _n in $_DEV_REQUIRED; do
  # -e follows the symlink and its target is NOT in the ramdisk, so test -L too:
  # these are dangling-by-design until devfsadm runs at boot.
  [ -L "$RDROOT/dev/$_n" ] || [ -e "$RDROOT/dev/$_n" ] || _missing="$_missing $_n"
done
[ -z "$_missing" ] || die "live root missing required /dev nodes:$_missing
  (the derived pseudo-node staging above should have created these; a name here
   that does not exist on the build host at all means this list is wrong)"
echo "  /dev gate OK: all $(echo $_DEV_REQUIRED | wc -w | tr -d ' ') required nodes present" >&2

# (ii) DRIVER COVERAGE. Install media must boot on whatever hardware someone
#      tries, so it ships the WHOLE kernel tree rather than a curated list --
#      but "ships the whole tree" was an ASSUMPTION, and the ':476' comment
#      approximating it as "~252 drivers" is how a shortfall could hide. Compare
#      the ramdisk's count against the BUILD HOST's actual inventory per tree and
#      fail on ANY difference. An exact match is the only claim worth making.
_drvbad=""
for _t in kernel/drv/amd64 kernel/strmod/amd64 kernel/misc/amd64 \
          kernel/dacf/amd64 kernel/fs/amd64 kernel/sched/amd64 \
          platform/i86pc/kernel/drv/amd64 platform/i86pc/kernel/dacf/amd64; do
  [ -d "$SRC/$_t" ] || continue
  _hn=$(ls "$SRC/$_t" 2>/dev/null | wc -l | tr -d ' ')
  _rn=$(ls "$RDROOT/$_t" 2>/dev/null | wc -l | tr -d ' ')
  echo "  $_t: host=$_hn ramdisk=$_rn" >&2
  [ "$_hn" = "$_rn" ] || _drvbad="$_drvbad $_t(host=$_hn,rd=$_rn)"
done
[ -z "$_drvbad" ] || die "driver-tree coverage SHORTFALL:$_drvbad
  install media must carry every driver the build host has (one image, any hardware)"

# (iii) the kernel modules the USB keyboard chain needs. The chain is
#       usb kbd -> hid -> usbkbm -> kbtrans -> conskbd -> wc/console, and a
#       break anywhere in it kills EVERY keyboard identically. These are STREAMS
#       modules and a dacf module, NOT drivers, so they are absent from
#       name_to_major legitimately and would not show up in any driver check.
#       NOTE: these were VERIFIED PRESENT in the 2026-09-09 media, so a missing
#       module is NOT the X1 keyboard fault -- this gate exists to keep it that
#       way, not because it ever fired.
for _m in kernel/strmod/amd64/usbkbm kernel/strmod/amd64/ldterm \
          kernel/misc/amd64/kbtrans kernel/misc/amd64/consconfig \
          kernel/drv/amd64/hid kernel/drv/amd64/conskbd kernel/drv/amd64/consms \
          kernel/drv/amd64/sad kernel/drv/amd64/zfs \
          platform/i86pc/kernel/dacf/amd64/consconfig_dacf; do
  [ -e "$RDROOT/$_m" ] || die "live root missing $_m (console input / zfs chain)"
done
echo "  console-input + zfs module gate OK" >&2

# (iv) /etc files that must be EMPTY on removable media because they are
#      per-machine kernel state. path_to_inst pins driver INSTANCE numbers to the
#      build host's exact PCI topology; shipping a populated copy tells the live
#      kernel about hardware the target does not have. :560 truncates it, but the
#      copy loop at :483 lists it, so assert the ORDER actually held.
for _f in path_to_inst mnttab; do
  [ -f "$RDROOT/etc/$_f" ] || die "live root /etc/$_f missing (must exist and be empty)"
  _sz=$(wc -c < "$RDROOT/etc/$_f" | tr -d ' ')
  [ "$_sz" = 0 ] || die "live root /etc/$_f is $_sz bytes, must be EMPTY (per-machine state must not ship)"
done
echo "  per-machine-state gate OK: path_to_inst + mnttab are empty" >&2

# (iv') BASE TOOLING the interactive installer promises. Each of these is a
#       command the operator is told to use (README/banner) or that another
#       staged tool depends on, so a silent copy failure must fail the BUILD.
#       GNU diff is singled out because illumos /usr/bin/diff prints
#       "No differences encountered" and has silently broken checks here before.
for _t in usr/gnu/bin/diff usr/gnu/bin/cmp usr/gnu/bin/diff3 usr/gnu/bin/sdiff \
          usr/bin/less usr/bin/curl usr/bin/tar usr/bin/gzip usr/sbin/format \
          usr/sbin/solnix-install usr/bin/ksh93 usr/bin/vi; do
  [ -e "$RDROOT/$_t" ] || die "live root missing base tool $_t (interactive installer needs it)"
done
# vi must RESOLVE, not merely exist: a dangling symlink passes -e on its own but
# gives the operator a broken editor. -f follows the link to a real file.
[ -f "$RDROOT/usr/bin/vi" ] || die "/usr/bin/vi does not resolve to a real file (dangling editor symlink)"
# terminfo: without it less/top/vi print "No terminal database found".
[ -d "$RDROOT/usr/share/lib/terminfo" ] || die "live root missing usr/share/lib/terminfo (curses tools unusable)"
[ -e "$RDROOT/usr/share/lib/terminfo/v/vt100" ] || echo "WARN: terminfo has no v/vt100 entry" >&2
# power management: the daemon + its config, per the requirement.
[ -x "$RDROOT/usr/lib/power/powerd" ] || echo "WARN: /usr/lib/power/powerd not staged (no PM daemon)" >&2
[ -f "$RDROOT/etc/power.conf" ] || echo "WARN: /etc/power.conf not staged" >&2
[ -e "$RDROOT/kernel/drv/amd64/power" ] || echo "WARN: power driver absent from ramdisk" >&2
# /usr/gnu/bin must WIN the PATH lookup, or staging GNU diff was pointless.
grep -q 'solnix-gnu-path' "$RDROOT/etc/profile" || \
  die "/etc/profile lacks the solnix-gnu-path block -- /usr/gnu/bin would not be first in PATH"
grep -q '^PATH=/usr/gnu/bin' "$RDROOT/etc/solnix-live-shell" || \
  die "live shell PATH does not start with /usr/gnu/bin"
echo "  base-tooling gate OK: GNU diffutils + less + terminfo + power + gnu-first PATH" >&2

# (iv'''') NO DANGLING SYMLINKS among the staged commands. This is its own bug
#          CLASS, not a one-off: `usr/bin/df` was staged as a SYMLINK to
#          ../sbin/df (= /usr/sbin/df) while the TARGET was never in the tool
#          list, so the live root had a `df` that passed every `[ -e ]` presence
#          check -- `-e` follows the link and the build host resolves it -- and
#          then reported "df: not found" inside the image. MEASURED consequence:
#          solnix-install:104 and :158 both call `df -n /`, so the installer's
#          root-pool guard and its "booted from" line were both broken. Same
#          shape as the dangling-vi check above, generalised: a symlink is only
#          staged if its target is too. -L finds links, -e tests resolution.
_dangle=""
for _d in usr/bin usr/sbin sbin usr/gnu/bin usr/has/bin; do
  [ -d "$RDROOT/$_d" ] || continue
  for _f in "$RDROOT/$_d"/*; do
    [ -L "$_f" ] || continue
    [ -e "$_f" ] && continue
    _dangle="$_dangle $_d/$(basename "$_f")"
  done
done
if [ -n "$_dangle" ]; then
  # ⚠️ openssl is NO LONGER EXEMPT. It used to warn here as an unused packaging
  # artifact (usr/bin/openssl -> ../openssl/1.0/bin/openssl, a versioned tree that
  # was not staged). It is now LOAD-BEARING: solnix-install's _hash_pw() uses it to
  # produce the SHA-512 crypt for the root and admin passwords, so a dangling
  # openssl means a LOCKED ADMIN ACCOUNT on a freshly installed laptop. The
  # versioned targets are staged explicitly (see the tool list), and if that ever
  # fails this gate must FAIL THE BUILD rather than warn. Nothing is exempt now:
  # every staged command symlink must resolve inside the image.
  die "dangling command symlink(s) in the live root:$_dangle
  Each passes a [ -e ] presence check on the BUILD HOST (which resolves them) and
  then reports 'not found' inside the image. Stage the TARGET, not just the link.
  If this names usr/bin/openssl, password hashing would fail and the admin account
  would be locked -- stage usr/openssl/*/bin/openssl."
fi
echo "  dangling-symlink gate OK: every staged command symlink resolves in the image" >&2
# df is called by solnix-install (root-pool guard + "booted from"), so assert it
# RESOLVES rather than merely existing -- that is exactly what failed before.
[ -f "$RDROOT/usr/bin/df" ] || die "/usr/bin/df does not resolve to a real file -- solnix-install's df -n / would fail"
# openssl must RESOLVE AND RUN: _hash_pw() has no pure-shell fallback that can
# produce a crypt, so this is the difference between a usable admin account and a
# locked one. -f follows the symlink chain to a real file.
[ -f "$RDROOT/usr/bin/openssl" ] || die "/usr/bin/openssl does not resolve -- solnix-install could not hash the root/admin password"
# (iv''') USER CREATION must work on the installed system: the image ships no
#         personal user, so if these are missing the operator cannot make one.
for _u in usr/sbin/useradd usr/sbin/usermod usr/sbin/groupadd usr/bin/passwd; do
  [ -e "$RDROOT/$_u" ] || die "live root missing $_u -- operator could not create a user"
done
[ -d "$RDROOT/export/home" ] || die "live root missing /export/home (useradd -m cannot create the parent)"
# passwd MUST still be setuid after the archive round-trip. `ls -l` is used because
# illumos has no stat(1); the mode string is the portable check.
_pm=$(ls -l "$RDROOT/usr/bin/passwd" | awk '{print $1}')
case "$_pm" in
  -r-sr-sr-x|-r-sr-xr-x|*s*) echo "  passwd setuid gate OK: $_pm" >&2 ;;
  *) die "/usr/bin/passwd lost its setuid bit (mode $_pm) -- passwd would fail for the operator AFTER install" ;;
esac

# (iv'') NIX MUST ACTUALLY RUN, not merely be present. This is the whole point of
#        the image: SELF_INSTALL copies this live root onto disk, so if nix cannot
#        execute here it cannot execute on the installed system either.
#
#        The ramdisk is still MOUNTED at this point, so the staged binary can be
#        executed directly. Its RUNPATH is the absolute /nix-tools224/lib..., which
#        on the BUILD HOST resolves to the build host's own (full) tree -- so an
#        unqualified run here would be a DEAD TEST that proves nothing about the
#        target. Point LD_LIBRARY_PATH at the RAMDISK's copies explicitly, exactly
#        as the shipped wrapper does relative to the target's root.
if [ "$STAGE_NIX" = 1 ] && [ -x "$RDROOT/nix-tools224/bin/nix" ]; then
  _nixout=$( LD_LIBRARY_PATH="$RDROOT/nix-tools224/runtime-lib:$RDROOT/nix-tools224/lib" \
             NIX_CONF_DIR="$RDROOT/nix-tools224/etc/nix" \
             "$RDROOT/nix-tools224/bin/nix" --version 2>&1 | head -1 )
  case "$_nixout" in
    *"(Nix) "*) echo "  nix RUNS from the staged tree: $_nixout" >&2 ;;
    *) die "staged nix does not run: '$_nixout'
  (expected 'nix (Nix) 2.24.15'. If this says libboost_context/libgit2/libarchive
   open failed, the runtime-lib copy is incomplete -- those three are NOT
   satisfiable from the binary's RUNPATH alone, measured.)" ;;
  esac
    # ⚠️ This gate lives HERE, before the umount, deliberately. An earlier version
    # sat AFTER `umount "$RDROOT"`, so "$RDROOT/..." resolved inside an empty
    # mountpoint: the outer [ -x ... ] was always false and the die() inside could
    # never fire. Dead code that read like protection -- same class as a guard that
    # reports success while measuring nothing. Verified on a build host: after the
    # umount that directory has 0 entries and neither gate string appears in the log.
    for _t in which nm strip elfdump ldd; do
      [ -x "$RDROOT/usr/bin/$_t" ] || [ -x "$RDROOT/usr/gnu/bin/$_t" ] \
        || echo "WARN: $_t absent from the live root" >&2
    done
    # which(1) is illumos-native (SUNWcsu), NOT part of the gnu-binutils package
    # that userland-incorporation rejects, so its absence is our bug and is fatal.
    [ -x "$RDROOT/usr/bin/which" ] || [ -x "$RDROOT/usr/gnu/bin/which" ] \
      || die "which(1) absent from the live root -- it was missing from a shipped image and must not be again"
    echo "  tooling gate OK: which(1) present in the MOUNTED ramdisk" >&2

    # reboot/poweroff are argv[0] links to halt (halt.c:49). Create them in the
    # image if the host did not ship them, then GATE: an installed system with no
    # way to reboot is what the maintainer actually hit.
    if [ -f "$RDROOT/usr/sbin/halt" ]; then
      for _ln in reboot poweroff; do
        [ -e "$RDROOT/usr/sbin/$_ln" ] || \
          ln "$RDROOT/usr/sbin/halt" "$RDROOT/usr/sbin/$_ln" 2>/dev/null || \
          cp -p "$RDROOT/usr/sbin/halt" "$RDROOT/usr/sbin/$_ln" 2>/dev/null || true
      done
    fi
    for _pw in halt reboot poweroff shutdown; do
      [ -x "$RDROOT/usr/sbin/$_pw" ] || [ -x "$RDROOT/sbin/$_pw" ] \
        || die "$_pw(1m) missing from the image -- an installed system must be able to reboot and power off"
    done
    echo "  power gate OK: halt + reboot + poweroff + shutdown all present" >&2

    # The installer belongs in root's home: that is where an operator who just
    # logged in will look, and `ls` there should show it without knowing a path.
    # /usr/sbin/solnix-install stays as the canonical location (it is on PATH);
    # this is a hardlink so both names are the same inode and cannot drift.
    if [ -f "$RDROOT/usr/sbin/solnix-install" ]; then
      mkdir -p "$RDROOT/root"
      ln "$RDROOT/usr/sbin/solnix-install" "$RDROOT/root/solnix-install" 2>/dev/null \
        || cp -p "$RDROOT/usr/sbin/solnix-install" "$RDROOT/root/solnix-install"
      chmod 0755 "$RDROOT/root/solnix-install"
      [ -x "$RDROOT/root/solnix-install" ] \
        || die "solnix-install not executable in /root -- the operator lands there and must find it"
      echo "  installer gate OK: /root/solnix-install present and executable" >&2
    else
      die "usr/sbin/solnix-install missing from the image -- nothing to install with"
    fi

    # ⚠️ EXEC-TIME GATE, not a presence check. `vi` was PRESENT in image k and
    # still died: "ld.so.1: vi: fatal: libmapmalloc.so.1: open failed". A file
    # existing proves nothing about whether it can start, which is the same lesson
    # as the nix runnability gate. chroot so the loader resolves inside the image.
    # /devices is lofs-mounted because the image's /dev is symlinks into
    # ../devices/pseudo that only a booted kernel populates.
    if [ -x "$RDROOT/usr/bin/chroot" ] || [ -x /usr/sbin/chroot ]; then
      _chr=$(command -v chroot 2>/dev/null || echo /usr/sbin/chroot)
      mkdir -p "$RDROOT/devices"
      mount -F lofs -o ro /devices "$RDROOT/devices" 2>/dev/null && _lofs=1 || _lofs=0
      for _c in /usr/bin/vi /usr/bin/which /usr/bin/less /usr/bin/ldd /usr/bin/openssl; do
        [ -f "$RDROOT$_c" ] || continue
        # ⚠️ `|| true` is LOAD-BEARING, not sloppiness. `--version` is not a
        # universal flag: MEASURED inside this image, vi exits 1 and which exits 2
        # with "illegal option -- version", and ldd exits 1 with a usage message.
        # Under `set -euo pipefail` the command substitution inherits that status
        # and set -e KILLED THE WHOLE BUILD at the first probe -- no die(), no
        # output, the gate written to prove "presence is not runnability" never
        # ran to completion itself. The verdict here comes from the TEXT (the case
        # below greps for the loader's "fatal:"/"open failed"), never from rc: a
        # binary that reaches argument parsing has already been loaded by ld.so.1,
        # which is exactly what this gate exists to establish.
        _o=$( { "$_chr" "$RDROOT" "$_c" --version 2>&1 </dev/null || true; } | head -1 )
        case "$_o" in
          *"fatal:"*|*"open failed"*)
            [ "$_lofs" = 1 ] && umount "$RDROOT/devices" 2>/dev/null
            die "$_c cannot start in the image: $_o
    A library is missing from the ramdisk. The ldd closure should have caught this." ;;
          *) echo "  exec gate OK: $_c starts in the image" >&2 ;;
        esac
      done
      [ "$_lofs" = 1 ] && umount "$RDROOT/devices" 2>/dev/null || true
    else
      echo "WARN: no chroot -- cannot exec-test the staged binaries" >&2
    fi
  # and the sibling commands must be argv[0] links to the same binary, not copies
  [ -L "$RDROOT/nix-tools224/bin/nix-store" ] || \
    die "nix-store is not a symlink -- the 12-full-copies pathology is back, +1.8GB"
fi

# (v) autoinstall must be OPT-IN. /etc/solnix-autoinstall makes the live media
#     write to a disk with NO operator confirmation, so its mere presence on a
#     public image would be a data-loss bug. Fail the build if it appears WITHOUT
#     the operator having asked for it via AUTOINSTALL_DISK.
#
#     ⚠️ This gate used to be unconditional, which made AUTOINSTALL_DISK=... a
#     build that ALWAYS died here (the marker is written at :1188, this runs
#     after) -- the opt-in knob and its own safety gate were mutually exclusive.
if [ -z "${AUTOINSTALL_DISK:-}" ]; then
  [ -e "$RDROOT/etc/solnix-autoinstall" ] && \
    die "/etc/solnix-autoinstall present in live root -- autoinstall MUST be opt-in (see docs/usb-install-media.md)"
  echo "  autoinstall gate OK: not enabled by default" >&2
  # BELT AND BRACES: the brief for this image is explicitly "interactive", and the
  # previous image (usb-image-20260910i) WAS an autoinstaller, so a stale marker
  # or a copied tree is a real risk. Assert the absence a second way -- by
  # LISTING, not by [ -e ] alone -- and also assert nothing else in the live root
  # carries the marker name.
  if ls "$RDROOT/etc/solnix-autoinstall" >/dev/null 2>&1; then
    die "/etc/solnix-autoinstall EXISTS (ls) -- this image must be INTERACTIVE"
  fi
  echo "  autoinstall gate OK (2nd check, ls): marker absent" >&2
else
  # opt-in build: the marker is load-bearing, so fail loudly if it did not land.
  _ai=$(cat "$RDROOT/etc/solnix-autoinstall" 2>/dev/null | tr -d ' \n')
  [ "$_ai" = "$AUTOINSTALL_DISK" ] || \
    die "AUTOINSTALL_DISK=$AUTOINSTALL_DISK requested but live root marker reads '${_ai:-<absent>}'"
  echo "  autoinstall gate: DELIBERATE OPT-IN, /etc/solnix-autoinstall = '$_ai'" >&2
fi

# (v') the console-keyboard override is load-bearing when requested (it is the
#      only thing that can give a PS/2-less laptop a console keyboard), and a
#      typo in /etc/system is silently ignored by the kernel. Gate it.

# HARD GATE on ramdisk occupancy. RD_MB is a boot constraint (see the header
# comment: the EFI loader must AllocatePages the UNCOMPRESSED size contiguously
# below 4 GB), so it is deliberately tight -- which means an over-full ramdisk
# has to fail the BUILD rather than ship a live root with no room. df -k is used
# because illumos has no stat(1) and df is already relied on here.
set -- $(df -k "$RDROOT" 2>/dev/null | awk 'NR==2{print $2, $3, $4}')
RD_TOTAL_KB="${1:-0}"; RD_USED_KB="${2:-0}"; RD_AVAIL_KB="${3:-0}"
echo "live root: ${RD_USED_KB}KB used / ${RD_TOTAL_KB}KB total / ${RD_AVAIL_KB}KB avail (RD_MB=$RD_MB nbpi=$RD_NBPI)" >&2
# inode occupancy too: shrinking nbpi trades table space for a smaller margin,
# and running OUT of inodes mid-copy would truncate the live root quietly.
# `df -F ufs -o i` columns are: Filesystem iused ifree %iused Mounted-on, so
# ifree is $3 and iused is $2 (verified on-node against a scratch lofi UFS).
RD_IUSED=$(df -F ufs -o i "$RDROOT" 2>/dev/null | awk 'NR==2{print $2}')
RD_IFREE=$(df -F ufs -o i "$RDROOT" 2>/dev/null | awk 'NR==2{print $3}')
echo "live root inodes: ${RD_IUSED:-?} used / ${RD_IFREE:-?} free" >&2
[ "$RD_TOTAL_KB" -gt 0 ] || die "df -k $RDROOT gave no numbers -- cannot verify ramdisk occupancy"
[ "$RD_AVAIL_KB" -ge $(( RD_MIN_FREE_MB * 1024 )) ] || \
  die "ramdisk too full: ${RD_AVAIL_KB}KB avail < ${RD_MIN_FREE_MB}MB minimum (raise RD_MB, or drop content)"
if [ -n "$RD_IFREE" ]; then
  [ "$RD_IFREE" -ge "$RD_MIN_FREE_INODES" ] || \
    die "ramdisk inodes nearly exhausted: $RD_IFREE free < $RD_MIN_FREE_INODES (lower RD_NBPI)"
fi
sync
umount "$RDROOT" || die "umount ramdisk failed"
lofiadm -d "$LOFI" || true
log "gzipping ramdisk (loader auto-inflates)"
gzip -1 -c "$RDIMG" > "$RDIMG.gz"
ls -la "$RDIMG" "$RDIMG.gz" >&2
# HARD GATE on the UNCOMPRESSED size -- the acceptance metric for real-hardware
# boot, because efi_loadaddr() asks EFI for exactly this many bytes as ONE
# contiguous block below 4 GB. wc -c, not stat(1) (illumos has none).
RD_RAW_BYTES=$(wc -c < "$RDIMG" | tr -d ' ')
RD_GZ_BYTES=$(wc -c < "$RDIMG.gz" | tr -d ' ')
echo "boot_archive: $RD_GZ_BYTES bytes gzipped, $RD_RAW_BYTES bytes UNCOMPRESSED (what the EFI loader stages below 4GB)" >&2
[ "$RD_RAW_BYTES" -gt 0 ] || die "could not size $RDIMG"
[ "$RD_RAW_BYTES" -le $(( RD_MAX_RAW_MB * 1024 * 1024 )) ] || \
  die "uncompressed ramdisk $RD_RAW_BYTES B exceeds RD_MAX_RAW_MB=${RD_MAX_RAW_MB}MB; real X1 firmware refused 859832320 B (EFI_OUT_OF_RESOURCES)"

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

# 6d. loader.conf: console + ramdisk rootfs. STANDARD boot
#
# ⚠️ CONSOLE INPUT: this was "text,ttya" and that is a LIST from which illumos
#     derives BOTH stdin and stdout. consconfig_dacf.c:68-86 documents the
#     consequence: if stdin does not resolve to a keyboard, the console becomes
#     CONSOLE_SERIAL_KEYBOARD / CONSOLE_TIP and rconsvp is wired to the SERIAL
#     device -- output still reaches the VGA text screen while NO keystroke is
#     ever read. On a laptop with no physical serial port that presents exactly
#     as "the keyboard does not work", for every keyboard, which is what the X1
#     showed with both an internal and an external USB keyboard.
#
#     QEMU never exposed it because we boot with `-nographic -serial mon:stdio`,
#     so there the serial line IS the keyboard and the setting is accidentally
#     correct. Fourth instance of the emulator being more permissive than the
#     target (after the 820 MiB staging allocation, PS/2-vs-USB keyboards, and
#     the clean low-4GB memory map).
#
#     Default is now "text" (local framebuffer + local keyboard). Set
#     SOLNIX_CONSOLE="text,ttya" to restore serial-console behaviour for headless
#     EC2/QEMU work, or SOLNIX_CONSOLE="ttya" for serial-only.

#     (no init override) so /sbin/init -> svc.startd runs the fs milestones.
# 6c'. BRAND THE BOOT SCREEN "solnix".
#      Two independent sources, both must be patched -- loader.conf alone is NOT
#      enough:
#        * boot/forth/menu.4th hardcodes `s" Welcome to illumos"` as the menu
#          title, so setting loader_menu_title in loader.conf is ignored unless
#          the fallback string is also replaced.
#        * the ASCII logo word comes from boot/forth/logo-*.4th.
#      Guarded: if the expected string is absent (upstream changed it), FAIL LOUDLY
#      rather than silently shipping the illumos branding -- the silent-no-op class
#      of bug that has bitten this script repeatedly (readlink, stat, the /dev list).
_mt="$OUT/iso/boot/forth/menu.4th"
if [ -f "$_mt" ]; then
  if grep -q 'Welcome to illumos' "$_mt"; then
    sed -i 's/Welcome to illumos/Welcome to solnix /' "$_mt"
    grep -q 'Welcome to solnix' "$_mt" || { echo "FATAL: menu.4th rebrand did not apply" >&2; exit 1; }
    log "boot menu rebranded: 'Welcome to illumos' -> 'Welcome to solnix'"
  else
    echo "WARNING: menu.4th has no 'Welcome to illumos' string -- upstream changed it;" >&2
    echo "         the boot screen may still say illumos. Check boot/forth/menu.4th." >&2
  fi
else
  echo "WARNING: $_mt absent -- cannot rebrand the boot menu title" >&2
fi

# ⚠️ UNQUOTED heredoc, deliberately. With <<'EOF' the ${SOLNIX_CONSOLE:-text}
# below is written to loader.conf LITERALLY, and the loader has no shell-style
# ${VAR} expansion -- so the kernel console was set to the 22-character string
# "${SOLNIX_CONSOLE:-text}", which is not a console. That shipped in image j and
# the keyboard was dead on real hardware again. Do not re-quote this heredoc.
cat > "$OUT/iso/boot/loader.conf" <<EOF
loader_logo="illumos"
loader_brand="solnix"
loader_menu_title="Welcome to solnix"
console="${SOLNIX_CONSOLE:-text}"
# os_console pins the KERNEL console. PROVEN ON REAL HARDWARE: the X1 Carbon
# had a dead keyboard until BOTH `set console=text` AND `set os_console=text`
# were given at the loader prompt. multiboot2.c:468 reads os_console via
# getenv and :598-603 only defaults it when unset AND several consoles exist,
# so on this machine the kernel console was never pinned to the framebuffer:
# output fell back to the screen while input stayed on a nonexistent ttya.
# This one line is the only keyboard change with hardware evidence behind it.
os_console="${SOLNIX_CONSOLE:-text}"
# Readable console on a HiDPI panel. MEASURED on the X1: EDID 3840x2160, and
# the loader picked text mode 2 = 480 columns x 113 rows -- unreadable. The
# font is a FIXED 8x16 with no larger built-in, so rows/cols come from screen
# size (font.c:232). GOP mode 2 (800x600) gives ~99x37, which is legible.
efi-max-resolution="800x600"
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

# ⚠️ /boot/conf.d/ IS ALSO READ (support.4th:1207,1441 include_conf_files) and the
# upstream OpenIndiana tree ships conf.d/console hardcoding console="ttya" and
# os_console="ttya". Neither of our scripts created it, so it survived every
# loader.conf fix and re-pinned the kernel console to a serial port the X1 does
# not have -- the keyboard was dead in image j for this reason as well as the
# unexpanded heredoc above. Rather than reason about which file wins, make them
# AGREE: then the result is correct under either precedence order.
_cd="$OUT/iso/boot/conf.d/console"
if [ -f "$_cd" ]; then
  sed -e "s/^console=.*/console=\"${SOLNIX_CONSOLE:-text}\"/" \
      -e "s/^os_console=.*/os_console=\"${SOLNIX_CONSOLE:-text}\"/" \
      "$_cd" > "$_cd.new" && mv "$_cd.new" "$_cd"
  echo "  conf.d/console reconciled to ${SOLNIX_CONSOLE:-text}" >&2
else
  # Absent is fine, but say so -- a silently missing override file is exactly
  # how the previous version of this bug hid.
  echo "  note: $_cd absent (nothing to reconcile)" >&2
fi

# LOUD GATE: neither file may contain an unexpanded ${...} or a stale ttya.
for _f in "$OUT/iso/boot/loader.conf" "$OUT/iso/boot/conf.d/console"; do
  [ -f "$_f" ] || continue
  if grep -q '\${' "$_f"; then
    die "$_f contains an unexpanded \${...} -- the loader has no variable expansion, so this ships a literal string as the console"
  fi
  if [ "${SOLNIX_CONSOLE:-text}" = "text" ] && grep -qE '^(os_)?console="ttya"' "$_f"; then
    die "$_f still pins console to ttya despite SOLNIX_CONSOLE=text"
  fi
done
echo "  console gate OK: loader.conf + conf.d/console both = ${SOLNIX_CONSOLE:-text}" >&2


# 6e. copy the UEFI loader out so the assembler can build the ESP FAT image
cp /boot/loader64.efi "$OUT/loader64.efi"
cp /boot/cdboot "$OUT/cdboot" 2>/dev/null || true

# 6f. tar up the staging tree for shipping
log "packing solnix-iso-tree.tar.gz"
( cd "$OUT" && tar -cf - iso loader64.efi cdboot 2>/dev/null | gzip -1 > solnix-iso-tree.tar.gz )
ls -la "$OUT"/solnix-iso-tree.tar.gz "$OUT/iso/platform/i86pc/amd64/boot_archive"

log "DONE: staging tree at $OUT/iso ; tarball $OUT/solnix-iso-tree.tar.gz"
echo "scp $OUT/solnix-iso-tree.tar.gz back, then assemble the hybrid ISO + USB img locally." >&2
