# aa64f: the SError on c6g.metal is the ena LLQ write through a cacheable mapping

Track aa64f, 2026-10-24. Base: aa64e boot 2 (committed 2a0025a), rebuilt on build host i-0ede6e691aa1c2362
(us-west-2) with the aa64e boot-2 shas reproduced first (progress.txt 13:18Z).

## Boot 1: SError unmasked in the kernel (c6g.metal i-0bf013978b5455c34, 20:51Z-21:38Z, 3 cycles)

Changes (patchers in `patches/`, one concern each):
- b1-01: `mp_startup()` clears I|A, as the boot CPU already does (`startup.c enable_irq()` clears all of DAIF).
- b1-02: unmask A after the frame is saved: on EL0 sync/IRQ entry by widening the existing
  `DAIFClr #DEBUG` immediate (0 new instructions, so the 32-insn IRQ vector slot doesn't grow); on EL1 sync/IRQ entry
  only if the interrupted SPSR had A=0.
- b1-03: `DAIFSet I|A` before every ELR/SPSR restore in exceptions.S; re-unmask A where a return path calls C.
- b1-04: per-CPU live DAIF and SPSR at `trap()` entry; one `[AA64F-DAIF]` line per 15 s heartbeat.
- b1-05: `[AA64F-MAP]` for every non-strict rootnex mapping, with the attribute byte the MMU actually uses (AT S1E1R,
  PAR_EL1.ATTR); `[AA64F-LLQ]` markers before the first LLQ store and after a `dsb sy` that follows it.
- b1-06: `[AA64F-KSERR]` for every kernel T_SERROR, including the `on_trap` and `t_lofault` branches that would
  otherwise recover silently.

Shas (boot_archive == proto, /build/verify-f1.log 9/9): unix 672a107b, ena 95b25581, rootnex 20e823e9; genunix 7509512b,
wc 9e32d09d, nvme 883c8941, gicv3_its 2e3e8b13, ecam c3b33e42, pcierc 50095ddb are unchanged from aa64e boot 2.

### Result (consoles/m1-c1.txt): the prediction held

```
[AA64F-MAP] ena0 pa 0x1802f000000 size 0x1000000 hat 0x400 par 0xff0001802f000b80 attr 0xff mair 0x844bbff0400
[AA64F-LLQ] first write cpu23 dst ffff8031c8e32000 n 16
[AA64F-KSERR] cpu23 esr 0xbe000411 elr 0xfffffffffa89e3c0 ena_llq_write_to_dev+0xa8 far 0x7fffef14d7e8
              spsr 0x60000049 lr ena_submit_tx comm dhcpagent -> die
```

- **Kernel PC:** `ena_llq_write_to_dev+0xa8` (ena_tx.o 0x838). That is the first instruction after the copy loop
  (0x7f8-0x808: 16 × `str x1, [x2], #8` to the LLQ BAR) and after the observer's CAS. The SError was taken there,
  before the `dsb sy` and before "first write done" was printed.
- **Device:** ena0 LLQ BAR (BAR 2, pa 0x1802f000000, 16 MiB), mapped by ena with `DDI_STORECACHING_OK_ACC`.
  rootnex turns that into `HAT_STORECACHING_OK`, `hati_mkpte` into `PTE_ATTR_NORMEM`, and that selects MAIR slot 2 =
  **0xff, Normal Inner/Outer Write-Back cacheable**. The PAR_EL1 measurement confirms it: attr 0xff.
- ESR 0xbe000411 (EC 0x2f, IDS=0, AET=0 uncontainable, DFSC 0x11 = asynchronous SError) is the same as aa64e's EL0 panics,
  and the same comm (dhcpagent). x17 in the dump still holds 0x7fffef1801c4 (EL0 entry loads ELR into x17), which is
  aa64e's "user PC", the return point of the syscall. aa64e's EL0 panics were this same kernel store, deferred to the eret.
- spsr M = EL2h is the kernel's own mode (VHE, `boot-el 2`), not a hypervisor.
- **Rate:** 1 of 1 cycles that transmitted. Cycle 1 attached ena0 before root mount, so network/physical plumbed it and
  dhcpagent's first DHCPDISCOVER was the first LLQ write, which SErrored. Cycle 2 was the expected boot-archive
  self-reboot. Cycle 3 reached login with sshd running, but never transmitted (see "ena0 INITIALIZED").
- The box stayed at the panic for 10+ min (no SBSA watchdog), then reset.

### DAIF samples (all 3 cycles)

The heartbeat CPU always reads `daif 0x240` (D|F set, I and A clear). The per-CPU last-`trap()` live DAIF nibbles are 3
(F|I) or b (D|F|I), and the SPSR nibbles are 0 or 1 (F). Not one of ~3500 nibbles has bit 2 (A) set, so A is clear in the
kernel and at EL0 on every sampled CPU. Before b1-01..03, A was masked in every exception handler on every CPU
(HW sets PSTATE.A on entry), which is why the SError surfaced only at the next eret to EL0.

## Boot 2: the fix

b2-01 (rootnex.c, both `rootnex_map_regspec` and `rootnex_map_handle`): `DDI_STORECACHING_OK_ACC` -> `HAT_MERGING_OK`
-> `PTE_ATTR_NORMEM_UC` = MAIR slot 4 = **0x44, Normal Non-Cacheable**. That is the attribute Linux uses for the same
BAR (`ioremap_wc`, MT_NORMAL_NC), so write-combining is kept and LLQ stays on. It is fixed in rootnex, not in ena,
because no device register may be mapped cacheable on arm64, whatever the driver asked for. The hat and RAM mappings are
untouched. rootnex 0aadb917; everything else == boot 1 (observers kept).

The image also carries `aa64f-diag.sh`. It is aa64e-diag with a different late-plumb STUB: `ipadm enable-if -t ena0`, with
`ifconfig plumb` as a fallback, because ena0 is already in the persistent ipadm.conf, so `create-if` cannot work. The
STUB never ran in boot 2: ena0 was plumbed by network/physical itself.

### Result: c6g.metal i-0283c74200f882805 (22:02Z-22:49Z, 2 cycles) and a fresh launch i-00637cf64c9ad59f0

- `[AA64F-MAP] ena0 ... hat 0x200 par 0x44...b00 attr 0x44`: the LLQ BAR is now Normal-NC, measured by the MMU.
- `[AA64F-LLQ] first write cpu21 ...` is followed by `first write done` (after `dsb sy`), and 0 KSERR / 0 panic over
  all 4 transmitting cycles (m2 c1+c2, m3 c1+c2). Boot 1's only transmitting cycle SErrored on that first write.
- Load: 200 MiB pulled box -> floki over ssh, `tx_packets 147333 tx_bytes 219860539` through the LLQ path, no SError.
- ena0 `st 3 link 1` (STARTED, LINK_STATE_UP), aenq `link_change 1`, `dladm show-link`: up 25000 full, DHCP
  `ena0/dhcp ok 172.31.38.12/20`, gateway answers ping, hostname from DHCP `ip-172-31-38-12`.
- **sshd reached.** `ssh root@<public ip>` with the launch key (keypair solnix-baked, installed by aa64-ec2-key from
  IMDS): `SunOS ip-172-31-38-12 5.11 arm64-gate-0-g6cd2521c armv8 aarch64`, `svc:/network/ssh:default online`.
  Uptime 32 min at teardown.
- Fresh hands-off launch of the same AMI (i-00637cf64c9ad59f0): ssh as root worked about 19 min after launch (on the 2nd
  cycle, after the expected boot-archive self-reboot). ena0/dhcp 172.31.41.93/20, and the IMDS instance id is recorded in
  /root/.ssh/.aa64-iid.
- `scripts/ami-registry-check.sh`: REGISTRY_FETCH_FAIL rc=127, `nix: not found`. This is expected: the image is a bare
  illumos-gate aarch64 system with no nix. It is a bootable base, not a solnix system.

## Why ena0 stayed INITIALIZED (aa64e's open question)

`st 1` = ENA_STATE_INITIALIZED without STARTED. STARTED is set only by `ena_m_start` (mc_start), which runs when IP
opens the link. `link 0` = LINK_STATE_UNKNOWN: no AENQ link-change was handled (kstat aenq:link_change 0). In every
started cycle it is 1. So "INITIALIZED, link 0" means nothing opened ena0. Two separate causes:

1. **aa64e boot 2, and every cycle where it was plumbed: the SError.** Plumbing ena0 starts it (st 3), dhcpagent
   sends DHCPDISCOVER, the first LLQ write SErrors, and the box panics. Boot 1 cycle 1 shows exactly this
   (`st 3 link 0`, then the KSERR).
2. **aa64f boot 1 cycle 3 (out/m1-c9.txt): ena0 was never plumbed in that cycle.** The diag shows `ipadm show-if` with
   only lo0, `ena0/dhcp disabled`, `dladm` state unknown, aenq link_change 0. The aa64e STUB `ipadm create-if ena0`
   failed ("Operation failed"; probably because ena0 is already in the persistent ipadm.conf, not verified). In boot 2,
   network/physical's `ipadm enable-if -t ena0` blocked until the late attach finished (method start 22:17:08,
   exit 22:19:02) and plumbed it, in both cycles. I did not determine why the same method did not plumb ena0 in m1
   cycle 3 (attach at ~122 s after the 6 GiB Rx allocation, the same as m2 cycle 2, which did plumb). It did not
   recur in 2 of 2 boot-2 login cycles. UNKNOWN; the 6 GiB Rx sizing (rxqs 32 × 16384 descs × 12 KiB, only after
   MP start) is still the reason attach takes ~100 s.

## What remains

- Boot-archive self-reboot on first boot (expected; costs one cycle, about 10 min, before sshd).
- svcs -x: rpc/bind in maintenance, hal offline (no dbus), intrd maintenance. These do not block sshd.
- ena Rx sizing of 6 GiB (MTU 9216 × 32 queues × 16384) when attached after MP start.
- No SBSA watchdog: a panic sits until the platform resets the box (10+ min).
- The image has no nix (registry check fails), so it is not yet a solnix AMI.

## Artifacts

- Patches (uncommitted): /home/gburd/ws/solnix/src/aarch64-arm64-gate-patches/serror-20261024/
- Bank: /home/gburd/solnix-bank/ami/aarch64-6cd2521c1e-serror-20261024/ (SHA256SUMS read back 60/60;
  aa64f-b1 gz 2f18f852 raw 883b9032; aa64f-b2 gz ce8fdad5 raw ab2c0d82, raw == EBS readback).
- AMI kept: ami-058f141e996b929f9 (aa64f-20261024-b2r, private, us-west-2, snap-05d4711742dfbee21).

## AMI owner steps (ami-058f141e996b929f9)

1. Launch c6g.metal (it is the only type tested) in us-west-2 with a keypair, a public IP, and an SG that allows 22 from
   your /24 only.
2. Wait about 20 min: the first cycle does the boot-archive self-reboot. Read progress with
   `aws ec2 get-console-output --latest` and look for `console login:`.
3. `ssh root@<ip>` with the launch key. The key comes from IMDS (site/aa64-ec2-key), the password is empty, and the
   console login is root.
4. Not yet present: nix, a solnix toplevel, dump device, SBSA watchdog. The account expires 2026-10-30, and the AMI goes
   with it. The durable copy is the banked raw image (restore: gunzip, dd to a 10 GiB EBS volume, snapshot,
   `register-image --architecture arm64 --virtualization-type hvm --boot-mode uefi --ena-support`).

## Which patches are fixes and which are diagnostics (orchestrator, 2026-10-24)

The maintainer asked that diagnostic code not stay in the kernel. For the aarch64 base going forward:

| patch | kind | keep? |
|---|---|---|
| b2-01-storecaching-nc.py (rootnex: DDI_STORECACHING_OK_ACC -> Normal-NC, MAIR 0x44) | **the fix** | yes |
| b1-01-mp-startup-daif.py (secondaries clear DAIF.A at mp_startup, as the boot CPU does) | correctness | yes: an SError must reach the kernel where it happens |
| b1-02-entry-unmask-a.py, b1-03-eret-mask-a.py (A unmasked after the frame is saved, masked before eret) | correctness | yes, for the same reason; this is how the SError was attributed |
| b1-04-daif-samples.py (per-CPU DAIF at trap entry, heartbeat line) | diagnostic | no |
| b1-05-mapping-attr-print.py (print the attribute of non-strict maps, LLQ first-write marker) | diagnostic | no |
| b1-06-kernel-serror-print.py (print every kernel SError before die/lofault) | diagnostic | keep only the part that names an SError in the panic message; drop the per-event console print |
| aa64e observers (direct UART writes after consconfig, heartbeat; postmount-20261023/) | diagnostic / workaround | no, once the console output path after consconfig is fixed (the real fix, still open) |

The next aarch64 track builds the base as b1-01 + b1-02 + b1-03 + b2-01 (plus aa64-overlay's cp fix), drops the
observers, and fixes the console output path so a release image has a working console without them.
