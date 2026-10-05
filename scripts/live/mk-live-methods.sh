#!/bin/sh
# Build the live-root SMF method overrides from the world's stock methods.
# $1 = world store path, $2 = out dir. Each patch is anchored on stock text and
# FAILS if the anchor moved (a silently-unpatched method wedges the live boot).
set -eu
W=$1; O=$2; mkdir -p "$O"
# fs-root: the kernel mounts /ramdisk:a read-only and the stock mountpoint-only
# remount fails on a ramdisk; remount rw via the explicit device right after
# fs_include.sh (measured: `mount -F ufs -o remount,rw /devices/ramdisk:a /` works).
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
  END { if (!d) exit 3 }
' "$W/lib/svc/method/fs-root" > "$O/fs-root"
# fs-usr: skip its root remount when / has no vfstab entry (the ramdisk case).
awk '
  /readvfstab \/ < \$vfstab/ && !o {
    print
    print "\t# solnix: guard root remount -- skip when no / vfstab entry (ramdisk"
    print "\t# root, already remounted rw by fs-root via the explicit device)."
    print "\tif [ -z \"$mountp\" ]; then :; else"
    o=1; next
  }
  /mountfs -m \$mountp \$fstype \$mntopts -/ && o && !c { print; print "\tfi   # close solnix guard"; c=1; next }
  { print }
  END { if (!o || !c) exit 3 }
' "$W/lib/svc/method/fs-usr" > "$O/fs-usr"
# svc-dlmgmtd: dlmgmtd's door dir lives on the (empty-at-boot) volatile tmpfs.
awk '
  /^\/sbin\/dlmgmtd/ && !d {
    print "# solnix: dlmgmt door dir (tmpfs /etc/svc/volatile is empty at boot)"
    print "mkdir -p /etc/svc/volatile/dladm 2>/dev/null"
    print "/usr/bin/chown dladm:netadm /etc/svc/volatile/dladm 2>/dev/null || true"
    print; d=1; next
  }
  { print }
  END { if (!d) exit 3 }
' "$W/lib/svc/method/svc-dlmgmtd" > "$O/svc-dlmgmtd"
# manifest-import: early-manifest-import can exit non-zero on the read-only live
# root even though the repository is fully pre-imported at image build; never let
# it drop the installer into maintenance.
cat > "$O/manifest-import" <<EOF
#!/sbin/sh
"$W/lib/svc/method/manifest-import" "\$@"; _rc=\$?
case "\$SMF_FMRI" in *early-manifest-import*) exit 0;; *) exit \${_rc:-0};; esac
EOF
chmod 0555 "$O"/*
