# x86 and the stale boot archive (aa64rb, 2026-10-29)

Evidence: /scratch/solnix/aa64rb/progress.txt (16:58Z-18:13Z), x86{a,b,c,d}-*.txt. The AMI was dpimg3 fix
(kiwi ami-097535d16544556cb, the same image as solnix-ami ami-0807209e1e89b3963), on m6i.large in us-west-2a.

## Same latent state as aarch64
- After the first boot, the boot archive's etc/path_to_inst is the image's EMPTY file. The installer's cloud-image
  step does `: > path_to_inst`. Meanwhile the disk copy holds 26 lines written by devfsadm, `bootadm update-archive -vn`
  reports "changed /etc/path_to_inst", and boot-archive-update did nothing. That makes 4/4 instances (x86a-d).
- The cause is the same: /reconfigure is gone by the time boot-archive-update runs, so only the shutdown-time bootadm syncs.

## No symptom on EC2, for two measured reasons
1. **An EC2 API reboot of x86 is a clean shutdown.** reboot-instances is an ACPI power button. The console prints
   "poweroff: initiated", "updating .../boot_archive", "syncing file systems". Boot 2 then has archive == disk.
   1/1 (x86a). On aarch64 the console prints no shutdown output: the port ignores the event, and EC2 hard-resets.
2. **A hard reset survives.** After `uadmin 1 1` (no shutdown bootadm), boot 2 printed "/etc/path_to_inst empty or
   not found / rebuilding device instance data", yet ena0 came up, `svcs -x` was empty, and ssh answered. 3/3 (x86b, x86c, x86d).

Not measured: why x86's instance rebuild keeps ena0 and aarch64's loses it. The empty file gives PTI_NOT_FOUND
on x86; the bootstrap magic gives PTI_REBUILD on aarch64.

## Decision
- modules/ is NOT changed: there is no x86 symptom to fix. The aarch64 fix is site/aa64-archive-sync
  (/scratch/solnix/aa64rb/aa64rb-archive-sync.diff).
- Residual 1: any x86 hard reset before the first clean shutdown (a panic, a host failure, `stop --force`) costs one
  instance-data rebuild. Nothing breaks.
- Residual 2: the stock boot-archive-update can fail silently and still exit 0 ("cpio: etc/path_to_inst: cannot be
  archived - inode too big for -Hodc format / boot-archive creation FAILED"). It raced devfsadm's inst_sync rewrite on
  x86b boot 2. A later bootadm run fixed it. The aarch64 method retries for this reason.
- If x86 ever needs it, the same method plus manifest would be a module service: after device/local and
  boot-archive-update, before network/ssh. NixOS has no equivalent, since it has no boot archive.
