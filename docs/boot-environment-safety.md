# Boot-environment safety: never need a physical reboot to recover a bad BE

## The incident (2026-10-11)

An i915 driver alias was set on the *permanent-default* BE (solnix-4) and the box
rebooted. i915 bound display@2 at boot, faulted during attach/modeset, and the
machine reset before login -- a boot loop. Because the bad BE was the permanent
default, every reset re-entered it. Recovery required the maintainer to
physically select the previous BE (solnix-3) at the loader menu.

That must never be necessary again. The illumos loader has the mechanism to
avoid it; we were not using it.

## The rule

**A risky boot-time change (a new driver alias, a kernel/driver swap, a new
toplevel that touches early boot) is NEVER applied to the permanent-default BE.
It is applied to a NEW or NON-DEFAULT BE and tried with boot-once.**

Boot-once = `beadm activate -t <BE>`:
- `-t` sets the BE to boot on the **next boot only**; the permanent default
  (`zpool get bootfs rpool`) is unchanged.
- `beadm list` shows the boot-once BE as **`T`** and the permanent default as
  **`NR`** (or `N` + a separate `R`).
- If the boot-once BE boots and is healthy, promote it: `beadm activate <BE>`
  (now `NR`).
- If it loops/faults, the automatic reset lands back on the permanent default
  **with no keyboard** -- the loader does not re-try a boot-once BE after a
  reset.
- To cancel a pending boot-once: `beadm activate -T <BE>` ("Temporary
  activation removed").

Verified on dixi 2026-10-11: `activate -t solnix-4` -> solnix-4 `T`, solnix-3
stays `NR` (`rpool bootfs` still solnix-3); `activate -T solnix-4` clears it.

## Honest limit

The illumos loader provides **boot-once (try once -> auto-fall-back)**, not a
built-in **"fail N times then fall back"** counter. The N-strikes counter
(`zfs_bootonce` attempt counting) is a FreeBSD-loader feature illumos's loader
does not implement. Boot-once is sufficient for the hazard we hit (a boot-time
driver fault), because one failed boot auto-reverts. If a true 3-strikes policy
is wanted for flaky-but-not-always-failing boots, it must be built in userland:
an SMF "boot-succeeded" sentinel service that, late in a healthy boot, promotes
the boot-once BE to permanent; absent the sentinel (because boot failed), the
next reset auto-reverts. A single failed boot already reverts, so the sentinel
only adds value for intermittent failures -- deferred until needed.

## Driver-bringup checklist (the attach discipline, updated)

1. Build the driver change into a NEW BE (or a known non-default one), never the
   current default.
2. Arm the dump device (`dumpadm`), keep an ssh session open on the WIRED link
   (independent of the driver under test).
3. `beadm activate -t <newBE>`; confirm `beadm list` shows it `T` and the
   good BE still the permanent default.
4. Reboot. If it comes up healthy over ssh, verify, then `beadm activate <newBE>`
   to promote. If it loops, it auto-reverts -- no physical access needed.
5. For a driver that binds at boot via an alias (i915, iwm): the alias is the
   hazardous step. Put it only in the boot-once BE. To disarm a BE that has a
   bad alias: `beadm mount <BE> /mnt`, remove the alias from
   `/mnt/etc/driver_aliases`, `rm /mnt/kernel/drv/amd64/<drv>` and the
   `archive_cache` copy, `bootadm update-archive -R /mnt`, `beadm unmount <BE>`.
