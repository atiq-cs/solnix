# ena-default-mtu-1500.patch

Fixes the EC2 Nitro cold-launch DHCP wedge on solnix AMIs.

## Symptom
Fresh cold launch: `ena0` link up but no lease. dhcpagent never binds
(`ena0 ... 0.0.0.0`, no dhcp_bound), console shows `Hostname: unknown`,
IMDS unreachable. Reboots only recover it probabilistically (~29%).

## Root cause (measured, not assumed)
The AMI already ships the modern multi-file gate ena (with the 16373
"occasionally hangs"/reset and 17939 Nitro v5/v6 LLQ fixes) — it is NOT the
2021 monolithic OI ena. The residual wedge is not a data-path death:

On a wedged cold boot (captured via a console-dumping metadata shim):
- `ena0` link UP 1000/full; AENQ healthy (`keep_alive` counting, `link_change 1`)
- TX works: `txq_0 packets` = the DHCP DISCOVERs sent
- `dhcpagent`: `State=SELECTING Sent=11 Recv=0` — zero DHCP replies received
- `mac:brdcstrcv 0`; `snoop` in promiscuous mode sees nothing on the wire

The interface transmits but never *receives* the broadcast DHCP OFFER. The
driver defaulted `ena_mtu = ena_max_mtu` (jumbo, 9216) at attach, and
`ena_m_setprop` returns `ENOTSUP` so the MTU cannot be lowered at runtime (the
shim's `ifconfig ena0 mtu 1400` calls silently fail). On several Nitro
backends a queue programmed with jumbo-sized Rx buffers does not reliably
deliver small broadcast frames on cold boot, so DHCP never completes.

## Fix
Default the interface MTU to standard 1500 (`ETHERMTU`) instead of the device
maximum, clamped so it never exceeds `ena_max_mtu`. This matches FreeBSD's
`if_ena` (`ifp->if_mtu = ETHERMTU`). Larger MTUs remain reachable via
`ena_max_mtu`.

## Result
Fresh cold-launch DHCP+SSH success, no manual steps:

| type      | pass |
|-----------|------|
| m5.large  | 20/20 (two rounds) |
| t3.large  | 5/5  |
| c5.large  | 5/5  |
| **total** | **30/30** |

vs 0/10 on the previous best AMI (ami-01dbb2a6a5e56cee6).

## Applying
The gate proto is built externally (see pkgs/illumos/gate.nix). Apply this
patch to `usr/src/uts/common/io/ena/ena.c` in the illumos-gate tree before the
proto build; the resulting `kernel/drv/amd64/ena` carries the fix. Build just
the module natively:

    cd <illumos-gate>
    MACH=i386 /opt/onbld/bin/bldenv env/i386-native
    cd $SRC/uts/intel/ena && dmake def
    # link with the proto ld (ctfmerge against genunix is optional):
    #   ld -ztype=kmod -N misc/mac -z defs -M .../{ddi,mac,kernel}.mapfile \
    #      -M debug64/dtrace.mapfile -o debug64/ena debug64/*.o
