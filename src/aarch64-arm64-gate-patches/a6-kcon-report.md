# A6-kernel-console — aarch64 kernel console on real Graviton after `Booting...`

## TL;DR

The aarch64 kernel was silent on real c6g.metal after the loader's `Booting...`
because the kernel's **early boot UART** (`bi_bsvc_uart_mmio_base`) was **0**.

**Root cause is NOT the synth-FDT serial node** (that already emits from the real
SPCR, from the A6-hw work). It is that Graviton describes its console UART **only
in the static ACPI SPCR table**, and *mis-declares* it, so:

- the loader's ACPI-namespace UART walk finds no device
  (`WARNING: acpiuart: no compatible MMIO UARTs` — on every metal boot), and
- the kernel's early `boot_uart` base stays 0 -> `boot_uart_putchar()` no-op ->
  total silence.

**Fix (kernel-side, self-contained in `dboot_synth_fdt.c`):** when the loader did
not hand us a UART (`bi_bsvc_uart_mmio_base == 0`), drive the early UART from the
SPCR directly, with an AWS OEM quirk workaround.

**Milestone reached (proven, console evidence):** a raw diagnostic write to the
SPCR UART base `0x90a0000` from dboot (`[A6KCON:SPCR-UART]`) **appeared on the EC2
serial console after `Booting...`** — the **first illumos kernel-stage output on
real Graviton silicon**. This proves (a) the ACPI path runs, (b) the SPCR base +
AMAZON quirk are correct, (c) `0x90a0000` is the UART the EC2 console captures.

**Full SunOS banner: not yet reached.** After the fix (without the wedging
`bcons_init` re-entry, and with the console-flooding debug loader swapped for the
quiet shipping loader), the kernel still produced no output after `Booting...`.
The next blocker is isolated to the **kernel-proper (MMU-on) path to the boot
UART** — a two-marker diagnostic build is prepared to pinpoint it (see "Handoff").

The chiuso account (build node + all test infra) was wound down before that
diagnostic metal boot could complete. All source/diffs/evidence are persisted to
the dev box; the work resumes on the `mala` account (same arm64-gate snapshot, a
WORKING SendSerialConsoleSSHPublicKey serial console — which removes the 64 KiB
console-ring limitation).

## Is the synth-FDT serial node the QEMU constant or the real SPCR?

**The real SPCR** — already, from A6-hw. `synth_scan_spcr()` reads
`ACPI_TABLE_SPCR` via the XSDT and emits the serial node from
`spcr->SerialPort.Address`, not a QEMU `0x9000000` constant. That was never the
cause of the banner silence: the kernel banner is emitted *earlier* than the FDT
serial node is consulted, through a **different** mechanism — the early boot UART
(`bi_bsvc_uart_mmio_base`).

## The actual chain (why silent)

1. Kernel banner + all early kernel output -> `bcons_putchar` -> `boot_uart_putchar`
   (`uts/armv8/boot/boot_uart.c`) -> writes to `boot_uart_mmio_base`.
2. `boot_uart_mmio_base` = `xbp->bi_bsvc_uart_mmio_base` (`boot_uart_init`), set by
   dboot in `dboot_conf.c` from the loader property `bcons.uart.mmio_base`
   (default `EARLY_UART_PA == 0`).
3. The loader sets `bcons.uart.mmio_base` only when its ACPI UART discovery
   (`usr/src/boot/efi/libacpiuart/acpiuart.c`) finds a namespace UART device that
   matches the SPCR, requiring `_HID` ARMH0011/etc + valid `_CRS`, **and** SPCR
   `BitWidth==32 && AccessWidth==3 && InterfaceType∈{PL011,SBSA}`.
4. **Graviton's DSDT has NO UART device** (`a6hw-graviton-DSDT.bin`: only
   PCIe/GPIO/GED/clock). Its **SPCR is mis-declared** (`a6hw-graviton-SPCR.bin`,
   dumped from a live c6g.medium):
   `InterfaceType=0x00` ("16550"), `BitWidth=8`, `AccessWidth=1`,
   `Address=0x90a0000`, GSIV=37, OEM=`AMAZON` — but the device is physically an
   ARM PL011 (Linux: `ACPI: SPCR: console: uart,mmio,0x90a0000,115200`, "AMBA
   PL011 UART driver", `ttyAMA0`).
5. So the loader rejects it (`no compatible MMIO UARTs`), the kernel's early UART
   base stays 0 -> silent. (`init_physmem()` also only maps the UART when base!=0.)

## The SPCR-UART fix

`usr/src/uts/armv8/dboot/dboot_synth_fdt.c` — full file + `a6-kcon-spcr-uart.patch`
(diff vs the A6-hw file) + `a6-kcon-spcr-uart-gate.patch` (gate-relative):

- `synth_scan_spcr()` records the raw SPCR `InterfaceType`, and applies the
  **AWS Graviton quirk**: if OEM-ID is `AMAZON` and InterfaceType is not already a
  PL011/SBSA code, force it to `0x03` (ARM PL011). Gated on the AMAZON OEM-ID
  exactly like the existing virtio-mmio gate.
- In `dboot_synth_fdt()`, when `bi->bi_bsvc_uart_mmio_base == 0` and the SPCR gives
  a PL011/SBSA UART, set `bi_bsvc_uart_mmio_base = spcr base` and
  `bi_bsvc_uart_type = iface` (XBI_BSVC_UART_* share SPCR/DBG2 numbering:
  PL011=0x03, SBSA2X=0x0d, SBSA=0x0e). The kernel proper's own `bcons_init(bi)`
  (`fakebop.c::bop_init`) then picks up the base; because it is now non-zero,
  `diag` is set to `CONS_TTY` and the banner routes to the SPCR UART.

Confirmed: the arm64 loader is built **without `LOADER_FDT_SUPPORT`**, so
`bi_fdt == 0` always -> the kernel **always** takes the ACPI path
(`dboot_configure_acpi -> dboot_synth_fdt`) on Graviton, so this fix always runs.

WEDGE FOUND + REMOVED: do **not** call `bcons_init(bi)` from inside
`dboot_synth_fdt` (mid-`dboot_configure`). Re-entering it there (re-running the
framebuffer/keyboard init) wedges the boot before the kernel is entered (metal
test showed the raw marker, then nothing). The shipped fix sets only the `bi`
fields and lets the kernel proper's own `bcons_init` do the routing.

## Metal test results (console evidence)

| Build | Loader | Result on real c6g.metal |
|-------|--------|--------------------------|
| fix v1 (with `bcons_init` re-entry) | debug | wedged; only `[A6KCON:SPCR-UART]` raw marker, then silence — proved 0x90a0000 reaches EC2 console (`a6kcon-metal-console-marker.txt`) |
| fix v2 (fields only, no re-entry) | debug | loader spam floods 64 KiB console ring; no banner (`a6kcon-metal-console-final.txt`) |
| fix v2 | quiet (shipping) loader | clean console: full illumos loader menu + `Booting...`, **then nothing** (`a6kcon-metal-console-quiet.txt`) — kernel genuinely silent after handoff |

The quiet-loader run is decisive: the console is only ~12 KiB and *not* flooded,
so any kernel output would show. The kernel produces none after `Booting...`.

## Exact next blocker

The silence is now isolated to the **kernel-proper (MMU-on) path to the boot
UART**. dboot writes `0x90a0000` fine with the MMU off (the marker proved it).
The kernel proper (`fakebop.c::bop_init -> bcons_init(xbp) -> boot_uart_putchar`)
writes it with the MMU on, using the physical address as a pointer, relying on the
identity map dboot established at `exitto` (comment in `kboot_mmu.c`: "We rely on
being identity mapped"). The remaining question is whether the kernel-proper
identity map covers `0x90a0000` (a low device address) — under QEMU the boot UART
`0x9000000` is reachable, so the mechanism exists; if Graviton's `0x90a0000` is
not in that early map, the first kernel-proper UART write faults -> silent hang.

## Handoff to `mala` (diagnostic build prepared)

A two-marker diagnostic is ready (built + staged on chiuso before it died; the
diff is persisted): `a6kcon-fakebop-diag.patch` adds raw writes to the SPCR UART
at two points in `fakebop.c::bop_init`:
- `[A6KCON:BOP]` at bop_init entry (MMU on, before bcons_init) — tests the
  kernel-proper identity map / that bop_init is reached.
- `[A6KCON:BCONS]` right after `bcons_init(xbp)` — tests that bcons_init survives.

Interpretation on the next metal boot (on `mala`, with the working serial console):
- **Neither marker** -> kernel faults before/at bop_init, or the kernel-proper
  identity map does NOT cover `0x90a0000` (fix: map the boot-UART page in the
  kernel's early identity map / dboot handoff).
- **`[A6KCON:BOP]` only** -> `bcons_init(xbp)` faults in the kernel proper (fix
  there).
- **Both markers, no banner** -> bcons routing (`console`/`diag`) issue past
  bcons_init (fix routing).

Resume steps on `mala` (profile mala, acct 724081032357; same arm64-gate snapshot):
1. Apply `a6-kcon-spcr-uart-gate.patch` (the real fix) to
   `usr/src/uts/armv8/dboot/dboot_synth_fdt.c` — this is the permanent fix.
2. For diagnosis, also apply `a6kcon-fakebop-diag.patch` (remove before shipping).
3. Rebuild unix (`bldenv -T aarch64 ../env/aarch64`; `dmake` + `dmake install` in
   `usr/src/uts/armv8/unix`), stage into the image (unix into ZFS + boot_archive,
   rewrite `boot_archive.hash`), keep the **quiet shipping loader** on the ESP.
4. Boot c6g.metal (us-east-2 had capacity in 2b/2c, not always 2a) via the working
   serial console; read the markers per the table above; fix the identified stage.
5. Once the banner shows: device probe -> root on NVMe -> SMF -> shell (the A6-hw
   kernel path is proven under QEMU; on real HW with a live console it should
   progress).

## Files (dev box, persisted; not committed)

- `dboot_synth_fdt.c` — full patched file (the fix)
- `a6-kcon-spcr-uart.patch`, `a6-kcon-spcr-uart-gate.patch` — the fix diff
- `a6kcon-fakebop-diag.patch` — the two-marker diagnostic (diagnosis only)
- `fakebop.c.orig`, `fakebop.c.a6kcon-diag` — fakebop before/after the diagnostic
- `a6hw-graviton-SPCR.bin` — real Graviton SPCR (80 B: iface 0x00, 0x90a0000, AMAZON)
- `a6kcon-metal-console-marker.txt` — the milestone (`[A6KCON:SPCR-UART]` after Booting)
- `a6kcon-metal-console-quiet.txt` — quiet-loader boot (kernel silent after Booting)
- `a6kcon-metal-console-final.txt` — debug-loader boot (spam-flooded)

## AWS

- SPCR/DSDT probe c6g.medium `i-08009f6c65fee0140`: terminated.
- Image-build helpers (t4g.small) x5: terminated.
- c6g.metal tests `i-010c37cb4236d595b`, `i-00958f9f09434306e`,
  `i-09b5b19d772469d0f`: terminated.
- Build node `i-0d24c0ec7a9a0e109` and all chiuso infra: account wound down.
- Verified image transfer throughout (gz md5 == source; raw-volume md5 == source
  `dd`) — no ZFS corruption in any test.
- No SG / 0.0.0.0/0 changes.
