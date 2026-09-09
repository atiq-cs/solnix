# Install-media plan: what the maintainer gets, and when

Two target machines were requested: a **Lenovo X1 Carbon ThinkPad (x86_64)** and the
**Milk-V Jupiter (SpaceMiT K1, RISC-V)**. Both to run multi-user solnix + the COSMIC
desktop, host PostgreSQL development, and serve as PG build-farm animals.

These two are **not** at comparable readiness, and saying so up front is the point.

## x86_64 (X1 Carbon) -- ACHIEVABLE, in flight

| requirement | state |
|---|---|
| multi-user solnix | **PROVEN** -- a fresh EC2 instance boots off installer-written media, root login, `nix` runs (`docs/install-media-first-real-install.md`) |
| bootable USB image | **IN FLIGHT** -- `make-iso-usb.sh` exists but has never been run; agent producing + QEMU/OVMF-proving `.iso` + `.img` |
| COSMIC desktop | **IN FLIGHT** -- derivations exist and the ~860-crate graph compiles; `cmakeMinimal` just unblocked; no binary yet |
| PG dev + build-farm animal | **WORKS on dixi** ("All stages succeeded"); agent converting `bene-provision-dixi.sh` into a declarative edition |

Gap that cannot be closed by software work alone: **no solnix image has ever booted on
non-EC2 hardware.** The X1 will be first-of-kind for UEFI-on-real-firmware, NVMe, Intel
wifi, trackpad and Xe graphics. Wifi and GPU are expected NOT to work initially. QEMU
under OVMF is the closest available proxy and is what the media is being tested against.

## RISC-V (Milk-V Jupiter) -- NOT ACHIEVABLE YET, and not close

An installer image is **months** away. This is measured, not estimated:

| requirement | blocking state |
|---|---|
| write an installed system to disk | `rootfs.c` is an **in-memory READ-ONLY** filesystem -- its own comment says "no write/create/unlink" |
| ZFS boot environment | none exists; solnix installs into a ZFS BE |
| run COSMIC | `elf.c` accepts **static `ET_EXEC` only** -- no `ld.so.1`, no `dlopen`; COSMIC is ~860 crates of dynamic Rust |
| PG build farm | needs a POSIX userland, a socket layer and packages; the registry has **ZERO** riscv64 derivations |
| networking | no socket layer; `vionef.c` sends one hand-built ARP frame |
| hardware | **not one instruction has ever executed on the board** |

What the board CAN do now: the **"it prints"** checkpoint -- flash `unix-k1.Image` +
`k1.dtb` to a microSD, `booti` from the U-Boot prompt, and read a kernel banner on the
serial console. `docs/milkv-jupiter-bringup-runbook.md` is the procedure, and it needs a
USB-to-UART adapter first. That is the gate every later RISC-V milestone waits behind,
and four defects that would each have prevented it were fixed only yesterday.

Promising a RISC-V installer now would repeat a habit this repo has already had to
retract three times in one session: a real result summarised one step too confidently,
with the summary outliving the caveat.
