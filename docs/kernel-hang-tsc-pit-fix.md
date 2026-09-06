# solnix cold-boot 10/10: the pre-userland kernel hang ROOT-CAUSED + FIXED (15/15)

> **⚠️ STALE CLOUD IDENTIFIERS.** Every AWS instance/AMI/snapshot id below belongs to a
> CLOSED account (chiuso / mala / lala) and no longer resolves. The findings, root causes
> and recipes here remain valid — only the ids are dead. Current substrate ids live in the
> gitignored `.infra/`; the rebuild paths are `docs/base-ami-rebuild-runbook.md` (x86_64,
> from the public OI cloudimage) and `docs/aarch64-buildhost-runbook.md` (the aarch64 gate
> host). See `docs/durability-account-loss.md` for why this keeps happening and the rules
> that limit the damage.

## Result
NEW CANONICAL AMI **ami-08028a88f6e53ff49** (solnix-kh-pitfix-zfs) = **15/15** unattended
cold launches on m5.4xlarge (measured, clean first-pass: PASS=15 DHCP-stuck=0 HANG=0).
The residual pre-userland kernel hang (bucket-B) is eliminated. This is a genuine
root-cause fix, not a workaround.

## The exact hang point (named, no debugger — printf-bisection via prom_debug)
Function: `tsc_calibrate()` -> `tsc_pit_also()` -> `tsc_calibrate_pit()` in
`usr/src/uts/i86pc/os/timestamp.c` + `tscc_pit.c` (the legacy i8254 PIT calibration,
ultimately the hand-rolled asm `freq_tsc_pit` in `uts/i86pc/ml/locore.S`).

Evidence (get-console-output ring, no kmdb needed):
- The illumos startup path is already densely instrumented with `PRM_POINT`/`PRM_DEBUG`
  that print via `prom_printf` when the boot property `prom_debug` is set
  (`uts/i86pc/sys/prom_debug.h`). Setting `boot-args="-B prom_debug=1"` streams every
  marker to the EC2 console ring -- zero custom-kernel build required.
- On a HUNG boot (1/15) the LAST console lines were:
    startup.c: startup_tsc() starting...
    timestamp.c: Calibrating the TSC...
    timestamp.c: 'tsccpp[i]->tscc_source' is 'VMware'   <-- last line, then SILENCE
  A GOOD boot continues: startup.c 'tsc_freq' is 0x950... -> startup_end() starting...
- Between the "VMware" line and the next marker, `tsc_calibrate()`:
  (1) `tsc_calibrate_vmware()` returns the freq from the hypervisor CPUID leaf
      0x40000010 (pure CPUID, fast, cannot hang);
  (2) prints "?TSC calibrated using VMware" (a `?` cmn_err -> log only, not console);
  (3) calls **`tsc_pit_also()`**, which runs the legacy PIT calibration
      (`pit_sanity_check()` then `freq_tsc_pit()`) purely for diagnostics / legacy
      APIC-timing back-compat, EVEN THOUGH the TSC freq is already known.

## Why it hangs on 16-vCPU Nitro (intermittent ~7-11%/boot)
The AWS Nitro hypervisor's emulated i8254 PIT is unreliable on cold boot. `tsc_pit_also()`
unconditionally touches the PIT (`outb`/`inb` on PITCTL_PORT/PITCTR0_PORT + the
`freq_tsc_pit` correlation loop). On the boots where the emulated PIT is in a bad state,
that port I/O / calibration loop stalls -> the boot wedges in `startup_tsc()` BEFORE
device probe (`configure()`), so EC2 marks the instance "impaired (reachability failed)"
and no userland shim can help (it never runs). This is the SAME PIT-on-Nitro
unreliability the prior work saw as "tsc_calibration=PIT PANICS on Nitro" -- forcing PIT
panics; the residual is the intermittent HANG when the diagnostic `tsc_pit_also()` PIT
path is taken after a successful VMware calibration.

(The deadman `snooping=1` could NOT catch this: `deadman_init` runs from `init_tbl[]` in
main.c AFTER `startup()` returns, and `start_other_cpus` is later still -- the deadman
cyclic is not armed during the primary `startup_end`/`startup_tsc` window. A deadman test
did reproduce the hang but produced no panic stack, which itself PROVED the hang is in the
primary startup window, not the AP path.)

## The minimal fix (a tunable -- no kernel rebuild to ship)
`/etc/system.d/solnix-nitro-pit`:
    set pit_is_broken = 1

`pit_is_broken` is a non-static global (`tscc_pit.c:51`). Setting it makes:
  - `tsc_calibrate_pit()` return B_FALSE on its first line (before any PIT I/O) -- so
    `tsc_pit_also()` becomes a no-op -> the hang path is never entered;
  - `apic_calibrate_pit()` return 0 -> the APIC calibrates off the TSC instead
    (`apic_calibrate_use_pit = 0` by default, so no panic).
This is exactly the escape hatch `tscc_pit.c` documents: "we still allow pit_is_broken to
be set in /etc/system to inform the system to avoid attempting to use the PIT at all."
The TSC freq still comes from the VMware/hypervisor CPUID leaf; nothing real is lost.

`/etc/system` is read by `mod_read_system_file()` inside `kmem_init()` (called from
`startup_kmem()`), which runs BEFORE `startup_tsc()` -- so the tunable is in effect in
time to gate the PIT path.

## Proof the fix works (measured on the fleet)
- Fixed instances: `pit_is_broken=1` AND **`pit_tsc_hz=0`** (the PIT calibration NEVER
  ran). Baseline instances: `pit_tsc_hz=81760812` (PIT ran).
- A/B (simultaneous, same env, N=15 each):
    baseline ami-0f5ab5fac82d7cd1f (30 boots total across two batches): 2 genuine
      bucket-B kernel hangs (~6.7%); one stayed impaired/no-SSH (un-recovered hang).
    fixed ami-08028a88f6e53ff49: 0 genuine kernel hangs.
- Confirmation cold-launch, N=15 on m5.4xlarge: **PASS(ssh)=15, DHCP-stuck=0, HANG=0**.

## Baking note (why the first fixed AMIs regressed DHCP -- avoided)
Baking the fix by stop-instance -> snapshot -> register (booted-instance reimage) POISONS
DHCP (the documented "boot-but-no-lease AMI"): clones don't re-run the shim's DHCP
recovery, so 0/15 leased even though 15/15 booted past the hang. The correct method (used
for the canonical AMI) is the OpenZFS **single-import + clean-export** offline edit:
  1. Ubuntu 24.04 helper, `zfsutils-linux` (OpenZFS 2.3.4 kmod) imports the baseline pool
     `spool` RW at an altroot (single import).
  2. Add `/etc/system.d/solnix-nitro-pit` to the ZFS root; rebuild the boot_archive
     OFFLINE as raw odc cpio (extract -> add the one fragment -> repack, same order,
     re-gzip -9); update `archive_cache` for consistency.
  3. `zpool export` (clean), snapshot the volume, `register-image` (uefi, ena, x86_64).
The kernel reads `/etc/system` from the boot_archive ramdisk at boot, so the fragment MUST
be inside the boot_archive (`loader.conf` has `hash_load="NO"`, so the .hash is not
verified). The offline rebuild was surgical: 1353 -> 1354 entries (exactly the one added
fragment), no ipadm.conf/runtime state captured -> DHCP behavior identical to baseline.

## Files
- Fix fragment: docs/solnix-nitro-pit.system.d  (install as /etc/system.d/solnix-nitro-pit)
- New canonical AMI: ami-08028a88f6e53ff49 (region us-east-2)

## Deliverable summary
- Hang: `tsc_pit_also()` -> legacy i8254 PIT calibration in `startup_tsc()`, wedged by the
  unreliable Nitro emulated PIT on 16-vCPU cold boot (before device probe).
- Fix: `set pit_is_broken = 1` in /etc/system.d (tunable; no kernel rebuild).
- Measured: 15/15 unattended cold launches on m5.4xlarge (ami-08028a88f6e53ff49).
