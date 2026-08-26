# solnix GPU V520 — the MP0 PSP wall, re-diagnosed to the true blocker

Mandate: implement Navi12 MP0 SMN indirect register access to get past the PSP
sOS handshake on the real V520 (g4ad), toward RADV + the first solnix GPU
number. No fabricated numbers. Linux V520 baseline stays 1995 pp / 283 tg.

## Verdict (one line)
The "MP0 needs SMN indirect access" wall was a **misdiagnosis** caused by a
wrong `MP0_C2PMSG_BASE` constant. The MP0 PSP mailbox is in-BAR and correctly
addressable directly. The true, now-measured wall is one layer deeper: on the
g4ad V520 **under Nitro the GPU register fabric is unpowered / unclocked (reads
0xffffffff) because the SOC has not been POSTed** (no vBIOS/ATOM + SMU power
sequence). No sOS RUNNING, no GFX, no /dev/dri render, RADV cannot enumerate.
Nothing fabricated.

## What I implemented (the SMN window + the corrections)
1. **SMN index/data window** (`psp.c` `smn_rreg`/`smn_wreg`): write the SMN
   byte address (SOC15 word << 2) to `mmPCIE_INDEX2` (in-BAR word 0x0e),
   readback flush, read/write `mmPCIE_DATA2` (word 0x0f). Crib: nbio_v2_3
   get_pcie_index/data_offset + amdgpu_device_indirect_rreg/_wreg. This is the
   correct, working plumbing for any out-of-BAR SMN register; it is retained as
   a fallback + diagnostic cross-check.
2. **The real bug: wrong C2PMSG base.** The port had
   `MP0_C2PMSG_BASE = 0x03b10500`. Real Navi12 (mp_11_0):
   `mmMP0_SMN_C2PMSG_N = word (0x40 + N)`, BASE_IDX 0. With MP0 seg0 base
   0x16000 the SOC15 word for C2PMSG_64 is **0x16080** (byte 0x58200) —
   **inside** the 512 KB BAR. The bad base pushed it to word 0x3b26540 (byte
   ~247 MB, off-BAR), which is what made a direct read return 0x0 and *looked*
   like it required the SMN window. Corrected the base to 0x40; `psp_rreg/wreg`
   use the direct in-BAR path.
3. **`psp_wait_reg` 0xffffffff guard.** An all-ones read is an unpowered/no-
   responder read, not a live status. Without the guard, `0xffffffff & bit31 ==
   bit31` spuriously "passed" the bootloader-ready and sOS-running checks (I
   observed exactly this false pass before adding the guard). The guard rejects
   all-ones so a dead read can never fake success.
4. **PCI mem/bus-master enable** (`amdgpu.c` `amdgpu_map_bars`): illumos, unlike
   Linux `pci_enable_device`/`pci_set_master`, leaves this to the driver. Added
   `PCI_COMM_MAE|PCI_COMM_ME` in the command register before mapping BARs.
   (Measured cmd=0xc7 afterward: IO+MEM+BusMaster all enabled — not the blocker,
   but correct hygiene the port was missing.)

## The measurements on the real V520 (g4ad.2xlarge, ami-0531979c70a921d71)
Driver builds clean on illumos (gcc 14.3.0, `drm-full`, 132 syms, zero-phantom),
`add_drv` binds `pci1002,a34@1e` → `/dev/fbs/card0` + `renderD128` + `/dev/kfd`.
Full bring-up runs on a clean-boot attach:

- attach `1002:7362 rev c3 (CHIP_NAVI12)`
- TTM VRAM 256 MB (BAR0) + GTT 512 MB; GMC/GART 512 MB; GFX/SDMA/IH rings
- 8 firmware blobs loaded incl `navi12_sos.bin ver 0x180764` (fetched from
  linux-firmware; the test AMI had none staged — now under
  `/kernel/firmware/amdgpu`)
- **PSP register probe (clean boot):**
  - `PCI cmd=0xc7` — IO+MEM+BusMaster enabled
  - `BAR0/VRAM[0]=0x0` — framebuffer BAR decodes as zeroed memory
  - `BAR5/MMIO`: `mmPCIE_INDEX2` written 0xdeadbeef, **read back 0xffffffff**
  - `C2PMSG_35/64/115 = 0xffffffff` via **both** direct-BAR (word 0x16063 =
    byte 0x5818c, in-BAR) **and** the SMN window (smn addr 0x5818c)
- Result: `PSP bootloader not ready (C2PMSG_35=0xffffffff; register fabric
  unpowered — GPU not POSTed)`; hw_init stops at the hardware gate; software
  floor intact.

Interpretation: a register that is correctly addressed, in-BAR, and behind an
enabled memory-decode window, yet reads 0xffffffff for *every* block including
the most basic NBIO register, means the GPU's internal register fabric is not
clocked. VRAM decodes (0x0, zeroed) but the register SOC is in reset. The V520
exposes **no option ROM / vBIOS to the guest**, and the port has **no ATOM
POST** path.

## Answers to the report questions
- **SMN index/data window implemented?** Yes — `mmPCIE_INDEX2`/`mmPCIE_DATA2`
  (words 0x0e/0x0f, in-BAR), SMN addr = SOC15 word << 2. Verified writes reach
  the index reg; retained as fallback + cross-check.
- **Does psp_rreg read sane MP0 values now?** No — but for a *different, deeper*
  reason than the mandate assumed. The addressing is now correct (in-BAR, both
  paths agree); the reads are 0xffffffff because the register fabric is
  unpowered, not because of SMN routing. The original SMN-wall diagnosis was a
  wrong-base artifact.
- **PSP sOS RUNNING?** No (register fabric unpowered).
- **GFX up? /dev/dri render? RADV enumerates?** No / no / no.
- **GGML_VULKAN pp/tg vs 1995/283?** Not reached. No number fabricated.
- **The exact new blocker:** GPU has not been POSTed — the SOC register blocks
  are unclocked/in-reset on this Nitro V520. Next step is a vBIOS/ATOM POST +
  SMU power-on sequence (`amdgpu_atombios` / `amdgpu_device_asic_init`), which
  Linux runs before the PSP handshake and which clocks the register fabric.
  This is GPU power-up, not SMN/register plumbing.

## Files changed (persisted to repo; no git commit — orchestrator commits)
- `src/drm-port/amdgpu/psp.c`:
  - `MP0_C2PMSG_BASE` corrected 0x03b10500 → 0x40 (mp_11_0 mmMP0_SMN_C2PMSG_N).
  - `smn_rreg`/`smn_wreg` SMN index/data window (mmPCIE_INDEX2/DATA2) added;
    kept as fallback + diagnostic.
  - `psp_rreg`/`psp_wreg` use the corrected direct-BAR path.
  - `psp_wait_reg` rejects 0xffffffff (dead-read) as a spurious ready.
  - A permanent register-fabric diagnostic (PCI cmd, VRAM[0], NBIO scratch,
    C2PMSG both ways) + corrected wall comments naming the true blocker.
- `src/drm-port/amdgpu/amdgpu.c`: `amdgpu_map_bars` enables PCI MEM + bus-master
  (PCI_COMM_MAE|ME) before mapping BARs.

## Provenance / no fabrication
Firmware versions and register values are the live reads from the g4ad
(navi12_sos.bin ver 0x180764; C2PMSG all-ones; cmd 0xc7; VRAM 0x0). The Linux
V520 baseline (1995/283) is untouched and unmet — no solnix GPU number was
produced because the GPU never powered up.
