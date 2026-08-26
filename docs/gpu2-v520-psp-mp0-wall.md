# solnix GPU on AMD V520 (g4ad) — the honest result

Mandate: first real solnix GPU number on the AMD V520, now that the build-level
circular blocker is fixed. No fabricated numbers. Linux V520 = 1995 pp / 283 tg.

## Verdict
The circle is BROKEN. A g4ad AMI baked via the fixed offline flow boots to root
SSH; the amdgpu driver BINDS to the real V520 and loads firmware; it walls at a
precisely-named point: **the PSP MP0 C2PMSG mailbox registers are outside the
512 KB MMIO BAR and need SMN indirect access the port doesn't yet implement.**
No tok/s produced — the GPU never powers up. Nothing fabricated; Linux V520
stays 1995/283.

## STAGE 0 — fixed g4ad AMI baked + VERIFIED: `ami-0531979c70a921d71`
Built IN-PLACE (the safe path, no DHCP poison): Ubuntu ZFS helper `zpool import
-N -R /mnt` (NO reguid) → mount the g4ad-v4 base BE (BIOS boot-block + cu_flags=0
already baked) → run the fixed `scripts/oi-preseed-be.sh` → clean export →
snapshot → `register-image --boot-mode legacy-bios`.
VERIFIED on the mounted BE before snapshot:
- base `/lib/libc.so.1` = the int/syscall variant `libc_hwcap3.so.1` (md5
  b3bde24b): **0 sysenter, 352 int-$0x91/syscall** — the AMD-safe libc. (The
  stock base was the sysenter variant: 193 sysenter, "uses ... SEP".)
- `ipadm.conf` single `ena0/dhcp` (stale `ena0/v4` stripped).
- BIOS MBR bootcode present (pmbr jmp `eb3c90`) + `cu_flags=0` in `/etc/system`.
- **NEW NIC fix:** ena `pci1d0f,*` driver_aliases (see STAGE 1).

## STAGE 1 — g4ad boots to ROOT SSH: **the circle is broken**
Cold-launch of the AMI on g4ad.2xlarge reaches root SSH. Every boot hits
`console login:` with SMF online — the libc AMD fix is solid, no init
SIGKILL-loop. The extra fix that got SSH: g4ad enumerates the ENA NIC as
`pci1d0f,ec20` (legacy-PCI compatible name), but the stock aliases were only
`pciex1d0f,*`, so the device enumerated yet ena never bound → no NIC → no DHCP.
Adding `pci1d0f,*` aliases (now in `oi-preseed-be.sh`) makes `ena0` bind →
DHCP lease (172.31.x) → sshd reachable. First solnix userland-over-SSH on the
AMD/V520 g4ad. Cold `run-instances` is the reliable path (warm reboot can drop
the lease — matches ena-rx-coldboot-fix.md).

## STAGE 2 — amdgpu V520: ENUMERATED + BOUND; walls at the MP0 PSP register window
- **V520 enumerated:** `prtconf -D` → `pci1002,a34@1e`, compatible incl
  `pci1002,7362` (Navi12) + `pciexclass,038000` (display).
- **Built + bound:** `gmake kfd` → `drm-full` (131 syms resolve), staged 15
  `navi12_*.bin` (linux-firmware) in `/kernel/firmware/amdgpu`, `add_drv`
  bound amdgpu to `pci1002,7362` → `/dev/dri/card0` + `renderD128` + `/dev/kfd`
  created; amdgpu0 attaches, no panic.
- **Bring-up ran:** TTM (VRAM 256 MB BAR0, GTT 512 MB) → GMC/GART 512 MB →
  GFX/SDMA/IH rings → **9 navi12 firmware blobs loaded + validated** (incl
  `navi12_sos.bin` ver 0x180764) → kfd bound.
- **BUG FIXED (sОS lookup):** `psp.c` scanned `uc->fw[0..fw_count)` for SOS, but
  blobs are stored BY `fw_id` index and `AMDGPU_UCODE_ID_SOS`=12 > `fw_count`=9,
  so the scan missed it → false "no sOS firmware loaded". Fixed to index
  `uc->fw[AMDGPU_UCODE_ID_SOS]` directly. sOS now found; the PSP path runs.
- **THE PSP TEST / THE WALL:** does the sOS come RUNNING (C2PMSG_64)? **No — and
  the exact reason is measured.** `amdgpu_psp_bootloader_load_sos` polls
  C2PMSG_35 (bootloader-ready) and reads **0x0** forever. Live diagnostic on the
  real card: `SOC15_REG_OFFSET(MP0,0,C2PMSG_64)` = word **0x3b26540** = byte
  **0xec99500 (~247 MB)**, but the MMIO register BAR (BAR5) is only **0x80000
  (512 KB)** → the offset is **out of range** → the direct `ddi_get32` reads
  0x0. The in-range GC probe (GRBM_STATUS) reads **0xffffffff** (GC block
  unpowered). BAR map verified correct (assigned-addresses: BAR0 VRAM 256 MB,
  BAR2 doorbell 2 MB, BAR5 MMIO 512 KB → illumos rnumber 1/2/3 = `AMDGPU_RNUM`;
  the MMIO handle IS mapped). **Root cause: on Navi12 the MP0 SMN block (the PSP
  C2PMSG mailbox) is NOT directly BAR-mapped — it must be reached through the
  SMN index/data indirect register window.** The port's direct-BAR-only
  `psp_rreg/_wreg` cannot address it, so the PSP handshake never starts.

## STAGE 3 — measure: NOT RUN
amdgpu is bound + firmware up, but the PSP sOS cannot start (MP0 registers
unreachable) → no GFX power-up → no /dev/dri render → RADV cannot enumerate.
No number fabricated. Linux V520 baseline stays **1995 pp / 283 tg**.

## NEXT (single concrete step)
Implement SMN index/data indirect register access for the MP0 block in the
illumos amdgpu port (Linux routes `mmMP0_SMN_C2PMSG_*` through the SMN window,
not the BAR). Then `psp_rreg(C2PMSG_35)` reaches the live PSP → the sOS
bootloader handshake (code already in place) → sOS RUNNING → fw authenticate →
GFX/SDMA power-up → /dev/dri → RADV NAVI12 → the first solnix V520 number.

## Durable artifacts (persisted, no git commit — orchestrator commits)
- AMI **ami-0531979c70a921d71** (solnix-g4ad-gpu2-v2): boots g4ad to SSH,
  amdgpu-ready. Snapshot snap-03f035ba31d91b353.
- `scripts/oi-preseed-be.sh`: + ena `pci1d0f,*` aliases (the g4ad NIC bind fix).
- `src/drm-port/amdgpu/psp.c`: sOS-lookup fix (index by fw_id) + the MP0
  SMN-indirect wall documented in-code.
- `src/drm-port/STATUS.md`, `docs/GPU-BENCH-SOLNIX.md`: updated with the result.

## Code changes this session (files, no git commit)
1. `scripts/oi-preseed-be.sh` — section 3c: add ena `pci1d0f,*` driver_aliases.
2. `src/drm-port/amdgpu/psp.c` — `amdgpu_psp_bootloader_load_sos`: index the
   sOS blob by `AMDGPU_UCODE_ID_SOS` (was a broken `[0,fw_count)` scan); add the
   measured MP0-BAR-window wall as a code comment + a diagnostic warning string.
3. `src/drm-port/STATUS.md`, `docs/GPU-BENCH-SOLNIX.md` — session results.
