# ena-runtime-mtu.patch

Makes the ena `MAC_PROP_MTU` link property runtime-settable and exposes its
range, so the MTU is no longer effectively permanent. Follow-on to
`ena-default-mtu-1500.patch` (the boot-safe 1500 default) and the second half
of the lesson in `docs/design-mtu-policy.md`.

## What it changes

`usr/src/uts/common/io/ena/ena_gld.c`
- `ena_m_setprop` handled `MAC_PROP_MTU` instead of returning `ENOTSUP`:
  validates the request against `[ETHERMIN, ena_max_mtu]`, and updates
  `ena_mtu` + the derived Rx/Tx buffer sizes (`ena_update_buf_sizes`) +
  `mac_maxsdu_update`.
- `ena_m_propinfo` reports `MAC_PROP_MTU` as `RW` with range
  `ETHERMIN..ena_max_mtu`, so `dladm show-linkprop -p mtu ena0` shows the
  possible range (before, `POSSIBLE` was just the current value).

`usr/src/uts/common/io/ena/ena.c`
- `ena_update_buf_sizes` is made non-static (declared `extern` in `ena.h`) so
  the mac callback can recompute the buffer sizes on an MTU change.
- The attach-time MTU is read from an `ena.conf` `mtu` property, clamped to
  `[ETHERMIN, ena_max_mtu]`, defaulting to the boot-safe `min(ena_max_mtu,
  ETHERMTU)` (1500). Nothing changes unless the property is set, so cold-boot
  DHCP reliability is unchanged; a per-instance target MTU is applied at a
  clean attach.

## Why setprop applies the change only while the link is stopped (EBUSY when up)

The ENA IO queues (and their Rx/Tx DMA buffers, sized from the MTU) are
(re)allocated when MAC starts the rings. The only in-driver primitive that
reprograms the device and reallocates the rings live is `ena_reset()` — an
**error-recovery** path (illumos 16391 "ena driver could support reset").
Driving `ena_reset()` under an active data path races in-flight Tx/Rx against
the ring teardown and makes the device latch its fatal-error bit (status
`0x21`); the watchdog then loops resetting forever and the instance is wedged.
This was reproduced repeatedly on EC2 m5.large (synchronous reset, reset with a
Tx re-check, and reset after `ifconfig down` all wedged).

So while the data path is running, `ena_m_setprop` returns `EBUSY` (as i40e/igb
do). The change is applied when the link is stopped — i.e. at the next attach,
driven by the `ena.conf mtu` property. This never wedges the link and never
regresses the boot-safe 1500 default.

## Measured on EC2 (m5.large, patched module)

- `dladm show-linkprop -p mtu ena0` `POSSIBLE` = `60-9216` (was `1500`).
- `dladm set-linkprop -t -p mtu=9001 ena0` while UP → `link busy` (EBUSY),
  exit 1, **no wedge**, box reachable, MTU unchanged (was `ENOTSUP` on the
  shipped driver).
- Cold DHCP at 1500: 5/5 stop/start cold boots (boot reliability preserved).

## Driver-level caveat: jumbo receive on Nitro

Independently of how the MTU is raised, a real **jumbo frame receive** at MTU
9001 latches the ENA device fatal-error bit on the tested Nitro backends
(`ena_rx_sgl_max_sz = 1` → a single ~12KB contiguous Rx buffer per descriptor).
DHCP (small frames) completes even at 9001, but the first ~8 KB receive wedges
the NIC. This is a driver limitation beyond MTU policy; on the current ena the
correct evidence-based outcome is to stay at 1500 (which the `solnix-mtu`
service does). The patch + service enable jumbo automatically on any
NIC/driver that supports a verified live resize.

## Applying

Apply on top of `ena-default-mtu-1500.patch` (it layers on the 1500 default),
before the proto build:

    cd <illumos-gate>
    patch -p1 < pkgs/illumos/patches/ena-default-mtu-1500.patch
    patch -p1 < pkgs/illumos/patches/ena-runtime-mtu.patch
    # build just the module (see ena-default-mtu-1500.README.md):
    MACH=i386 /opt/onbld/bin/bldenv env/i386-native
    cd $SRC/uts/intel/ena && dmake def
