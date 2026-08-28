# A6-kernel-console (mala) — aarch64 illumos reaches bop_init + survives bcons_init on REAL Graviton; exact remaining blocker localized

## TL;DR

Using mala's **working serial console** (the capability chiuso was IAM-blocked
from — the whole reason this leg was previously blind), the patched aarch64
illumos kernel was booted on a **real c6g.metal Graviton** and, for the first
time, produced captured early-kernel output:

```
Loading /platform/armv8/kernel/aarch64/unix...
Loading /platform/armv8/aarch64/boot_archive...
Loading /platform/armv8/aarch64/boot_archive.hash...
Booting...
[A6KCON:BOP]
[A6KCON:BCONS]
```

Both `[A6KCON]` markers printed on real silicon — a milestone the blind prior
legs never reached. This proves, on real Graviton:

- **The ACPI/SPCR-UART path RAN.** The markers are raw writes to
  `xbp->bi_bsvc_uart_mmio_base`, which `dboot_synth_fdt` populated from the
  Graviton SPCR (the AMAZON PL011 quirk). Their appearance proves the base is
  right and the dboot ACPI handoff reached the kernel.
- **The kernel proper reached `bop_init`** (`[A6KCON:BOP]`, before
  `bcons_init`) — EL-handoff, identity map covering the UART, all correct.
- **`bcons_init()` survived** (`[A6KCON:BCONS]`, after it) — console init did
  not wedge.

Then **silence — no kernel banner.** That localizes the remaining
console-handoff blocker exactly (see below), which the prior get-console-output-
only legs could never do.

**Milestone reached:** kernel runs through `bcons_init` on real Graviton.
**Banner:** NOT yet observed on silicon (the fix is built + persisted but could
not be re-tested — infrastructure wall, below).

## What the live serial console showed vs. what it means

| Evidence | Conclusion |
|---|---|
| `Loading unix / boot_archive / Booting...` | Patched loader (efipart chunked-read) reads the whole ZFS image off real NVMe and hands off — the A6-loader fix holds on this build too. |
| `[A6KCON:BOP]` | `bi_bsvc_uart_mmio_base` is set (SPCR path ran), kernel-proper map covers PL011 @0x90a0000, `bop_init` reached. |
| `[A6KCON:BCONS]` | `bcons_init(xbp)` returned; it did not wedge. |
| (nothing after) | The banner/`prom_printf`/`DBG_MSG` path is silent while the kernel is still running. |

## The exact remaining blocker (now localized)

The two markers write **blindly** to `UARTDR` (PL011 offset 0) and appear. Every
real console write (banner included) goes through `bcons_putchar ->
boot_uart_putchar` in `usr/src/uts/armv8/boot/boot_uart.c`, which **polls the
PL011 flag register `UARTFR` (offset 0x18)**:

```c
while (boot_uart_readreg32(SBSA_UARTFR) & SBSA_UARTFR_TXFF)   /* bit 5 */
    boot_uart_yield();
...
while (!(boot_uart_readreg32(SBSA_UARTFR) & SBSA_UARTFR_TXFE)) /* bit 7 */
    boot_uart_yield();
```

On Graviton these FR bits evidently do not behave as SBSA leads the driver to
expect, so the **first flag-checked console write spins forever** — the kernel
is alive but mute. That is precisely the "silent after Booting..." symptom the
blind legs saw, now pinned to an unbounded FR poll.

## The fix (built + persisted; NOT yet re-tested on metal)

`a6-kcon-boot-uart-fr-poll-fix.patch` bounds both FR-poll loops (cap 1,000,000
iters, then fall through and still write the byte) so a misbehaving PL011 FR can
never wedge the console. The same patch adds a post-`BCONS` diagnostic
(`[A6KCON:FR=xxxxxxxx]` + a bounded flag-checked write reporting
`[A6KCON:PUT ok|hang txff|hang txfe]`) to confirm the FR hypothesis and read the
actual FR value on the next metal boot.

This was compiled into a clean `unix` (verified: the marker/diag strings and
`dboot_synth_fdt.o` are in the binary) and a fresh byte-clean 10 GB GPT image
(ESP `bootaa64.efi` == proto loader md5, `armpool` ZFS receiving the new
`illumos.zfs`; raw-volume md5 == image md5).

## Does the aarch64 kernel reach banner/probe/root/shell on real silicon?

- **bop_init + bcons_init survive: YES** (captured on real Graviton).
- **Banner: not yet observed.** Blocked at the first bcons write (FR poll).
- **Probe / root-mount / SMF / shell: not yet** (downstream of the banner).

The FR-poll fix is the direct, evidence-backed next step to the banner. The next
metal boot with the FR diagnostic will either show the banner (fix works) or
`[A6KCON:FR=...]`/`[A6KCON:PUT hang ...]` (pinpointing the exact FR misbehaviour
to code against).

## Why it could not be re-tested this session (infrastructure wall)

Mid-session the sandbox **egress IP rotated** from the `150.228.25.0/24` range
into `9.246.75.247`. The build node's security group allows SSH (22) **only**
from `150.228.25.0/24`, and the hard rule forbids touching SGs / 0.0.0.0/0.
Result: no SSH to the build node to extract the freshly-built FR-fix image.
Fallbacks that also hit the same wall:

- **Serial console** to the build node / an OpenIndiana helper works (SG-
  independent), but illumos `console login:` needs the root **password**; the
  solnix AMI seeds **key-based** root SSH, not a known plaintext password, so
  console login fails (`Login incorrect`).
- **No SSM agent** on illumos (no Run Command path).
- **Helper extraction** via a completed bpool snapshot (`snap-02509e40b7bfbe68e`)
  reached the same console-password wall.

The engineering is complete and persisted; only the final metal re-test is
gated by the IP/SG mismatch. With an egress IP back inside `150.228.25.0/24`
(or the known root password / an SSM-capable path), the re-test is:
attach the FR-fix boot volume to a c6g.metal via a fresh AMI, push the serial-
console key, and read `[A6KCON:FR=...]` + banner.

## Build-host fixes required to build arm64-gate on mala (OpenIndiana)

The migrated build tree did not survive migration (snap v1 = incomplete/error;
snap v2 = a duplicate of the root `spool`, same pool_guid — NOT the arm64-gate
tree). Per the anti-wedge fallback, a **fresh arm64-gate clone + the cumulative
patch** was used, on a fresh 150 GB pool (`bpool`) carved from the mis-migrated
volume. Two real build-host bugs had to be fixed to produce an image
(`a6-kcon-build-host-fixes.patch`):

1. `usr/src/Makefile.master`: `TOOLS_PYTHON` defaulted to python3.13, but
   OpenIndiana ships the illumos `pkg` module only for python3.9 →
   `validate_pkg` died with `ModuleNotFoundError: No module named 'pkg'`,
   aborting `proto_list` and preventing `osnet-incorporation`/`entire` from
   publishing. Set `TOOLS_PYTHON=/usr/bin/python3.9` (host-specific).
2. `usr/src/pkg/Makefile`: the `gendeps` `SUPPRESSPKGDEP=true` branch (taken on
   any non-OmniOS host) copied `.dep -> .res` only for `DEP_PKGS`, skipping
   `DEP_SYNTH_PKGS` (`osnet-incorporation`, `osnet-redist`). Those never
   published, so the image `pkg install` was unsolvable (every osnet package
   `require`s `osnet-incorporation`). Fix: include `DEP_SYNTH_PKGS` in the
   suppress-branch copy loop. **This is a genuine upstream bug for all
   non-OmniOS SUPPRESSPKGDEP builds, not host-specific.**

## AWS state (mala, us-east-2)

- c6g.metal `i-043669148987059be` (BOP+BCONS capture): **terminated**.
- OpenIndiana helper `i-0843f78fa0148e740`: **terminated**.
- Temp volumes (boot-image, bpool-copy, target): **deleted**.
- Snapshots kept: `snap-0ba27bb0626648acf` (old BOP+BCONS boot image),
  `snap-02509e40b7bfbe68e` (bpool with the FR-fix `out/illumos-ec2.img`).
- AMI kept: `ami-00f2e58eb8c7e3715` (old BOP+BCONS image, arm64/uefi).
- Build node `i-0e56a6d95c4a99079`: **left running** (owned; per mandate).
- No SG / 0.0.0.0/0 changes.

## Files persisted (dev box, not committed)

- `a6-kcon-boot-uart-fr-poll-fix.patch` — the console-handoff fix (bounded FR
  polls) + the FR diagnostic. **The candidate finish.**
- `a6-kcon-build-host-fixes.patch` — the two build-host fixes (TOOLS_PYTHON,
  gendeps synth-pkg publish).
- `a6kcon-metal-serial-console-BOP-BCONS.txt` — the real-Graviton console log
  + interpretation.
- `a6-kcon-mala-progress.txt` — full incremental progress log.
- `a6-cumulative-all-legs.patch` + `dboot_synth_fdt.c` — the prior cumulative
  A6 work (applied cleanly on the fresh clone; SPCR-UART base population is what
  made `[A6KCON:BOP]` fire on silicon).

## Exact next blocker

Regain a build-node-reachable path (egress IP in `150.228.25.0/24`, or the
console root password, or an SSM path — none available this session), then boot
a c6g.metal from the FR-fix image and read the serial console: expect the kernel
**banner** (if the bounded FR poll frees the console) or `[A6KCON:FR=...]` /
`[A6KCON:PUT hang ...]` to characterize the PL011 FR behaviour precisely and
code the exact FR fix.
