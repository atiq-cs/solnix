#!/sbin/sh
# aa64-archive-sync: bring the boot archive in line with /etc after device configuration.
# On a fresh launch the archive still carries the image's bootstrap /etc/path_to_inst: devfsadm writes the
# real one on the reconfigure boot, but boot-archive-update only acts on /reconfigure (already removed by
# rcS) or the safefile flag (set before devfsadm ran). Only the shutdown-time bootadm would sync it, and an
# EC2 API reboot is a hard reset that skips it. The next boot then reads the bootstrap path_to_inst from the
# archive and network/physical fails with DL_BADPPA (aa64rb, 2026-10-29). Runs every boot; a no-op in sync.
. /lib/svc/share/smf_include.sh
smf_is_globalzone || exit $SMF_EXIT_OK
smf_root_is_ramdisk && exit $SMF_EXIT_OK
# Retried: an inst_sync rewriting path_to_inst during the cpio makes create_ramdisk fail ("inode too big
# for -Hodc format"; seen on x86 boot-archive-update, aa64rb x86b) while the stock method exits 0.
i=0
while [ $i -lt 6 ]; do
	if /sbin/bootadm update-archive -vn >/dev/null 2>&1; then
		echo "boot archive in sync after $i updates"
		/sbin/sync
		exit $SMF_EXIT_OK
	fi
	/sbin/bootadm update-archive -vn 2>&1 | grep -v '^cannot find'
	/sbin/bootadm update-archive
	i=$((i + 1))
	sleep 5
done
echo "boot archive still out of sync after $i updates"
exit $SMF_EXIT_ERR_FATAL
