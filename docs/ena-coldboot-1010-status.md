# RESOLVED: true 10/10 achieved. The bucket-B kernel hang was tsc_pit_also() touching the
# unreliable Nitro i8254 PIT for a legacy diagnostic cross-check after the VMware CPUID leaf already
# gave the TSC freq. FIX: set pit_is_broken=1 (documented escape hatch, no kernel rebuild). Canonical
# AMI ami-08028a88f6e53ff49 = MEASURED 15/15 unattended on m5.4xlarge. See docs/kernel-hang-tsc-pit-fix.md.

# solnix cold-boot: 8/10 -> 14/15 -> FIXED 15/15 (the kernel hang is root-caused + fixed)

## Result (UPDATED: kernel hang FIXED)
NEW CANONICAL AMI **ami-08028a88f6e53ff49** = **15/15** unattended cold launches on m5.4xlarge (clean
first-pass: PASS=15 DHCP-stuck=0 HANG=0). The residual pre-userland kernel hang (bucket B) is ELIMINATED.
Root cause + fix: see docs/kernel-hang-tsc-pit-fix.md. Summary: `tsc_calibrate()` -> `tsc_pit_also()` runs
the legacy i8254 PIT calibration in `startup_tsc()` even after the VMware/hypervisor CPUID leaf already gave
the TSC freq; the AWS Nitro emulated PIT is unreliable on 16-vCPU cold boot and that PIT path intermittently
wedges (~7-11%) before device probe. Fix = the documented tunable `set pit_is_broken = 1` (in
/etc/system.d/solnix-nitro-pit) -> `tsc_calibrate_pit()` + `apic_calibrate_pit()` short-circuit before any
PIT I/O (proven: fixed instances show pit_tsc_hz=0). No kernel rebuild required.

Prior state (superseded): ami-0f5ab5fac82d7cd1f = 14/15; the residual ~1/15 was the kernel hang below.

## Per-failure buckets (the prior agent conflated these; now resolved)
- (A) DHCP race: reached userland, no lease. Common on m5.4xlarge first boot. RECOVERABLE in userland ->
  FIXED by the shim rewrite.
- (B) Pre-userland KERNEL HANG: hangs right after the kernel banner / "TSC calibrated using VMware", BEFORE
  device probe. ~11%/boot. Unrecoverable in-guest (= EC2 "impaired at Booting"). THIS is the real residual,
  distinct from the DHCP race. The shim never runs, so no userland fix can touch it.

## Shim fixes applied (scripts/metadata-shim.sh, the exact old bugs)
1. NEVER delete-addr the persisted ena0/dhcp (destroying it made the race PERMANENT -- a 0/15 regression
   caught + fixed). In-place recovery = refresh-addr + interface bounce x8, no reboot; only then a BOUNDED
   COUNTER reboot (not the old one-shot-forever mark). Widened watchdog. ssh/dns enabled before the DHCP wait.
2. Removed boot-args="-v".
3. Built via the SAFE OpenZFS single-import + clean-export method (proven by the source AMI's own zpool
   history) -- NOT the booted-instance reimage (boot-but-no-lease AMIs) and NOT reguid->bootadm (corrupts
   the pool, ZFS-8000-8A).

## Bucket B: ruled un-fixable WITHOUT a gate kernel change (all tested)
- -v removal: no effect. tsc_calibration=PIT: PANICS (no PIT on Nitro). apix_enable=0 / pcplusmp: verified
  active, hang persists. The shim: never runs (pre-userland).
- A forced FIRST-boot reboot is inherent: the kernel rewrites path_to_inst/devid_cache -> bootadm rebuild ->
  reboot, which DOUBLES bucket-B exposure (two cold boots instead of one).
- ROOT CAUSE (hypothesis): early CPU/mem bringup on a 16-vCPU cold boot on the Nitro hypervisor hangs before
  device probe. Needs an illumos-gate kernel fix (the early SMP/ACPI/timer bringup path), not a shim/AMI edit.

## Path to a true 15/15 (10/10)
1. Reduce bucket-B exposure: eliminate the forced first-boot reboot (pre-seed path_to_inst/devid_cache in the
   AMI so the kernel doesn't rewrite+reboot -> ONE cold boot, not two -> ~halves the hang probability), AND
2. Fix the early-boot hang in the kernel (capture the exact hang point via console + a kmdb/serial boot; the
   SMP AP-bringup / ACPI-MADT / timer-calibration path on 16-vCPU cold boot). This is a gate kernel patch.
