# solnix GPU parity on AMD V520 (g4ad) — Stage 1 FIXED, Stage 2 bound (PSP wall)

## RESOLVED (latest session)

### STAGE 1 — ILP32-on-AMD SIGKILL loop: FIXED. solnix userland + SSH up on the g4ad.
The fault was NOT a kernel bug and NOT KPTI/MCA. The base `/lib/libc.so.1` was
built as the SYSENTER libc variant: it tags hwcap `AV_386_SEP` (0x8) as required
AND emits the `sysenter` instruction for syscalls. The illumos amd64 kernel
removes `X86FSET_SEP` on all AMD (uts/intel/os/cpuid.c: AMD has no sysenter in
long mode), which also drops the 32-bit userland hwcap `AV_386_SEP`. So on AMD
`ld.so.1` rejects libc (fatal → SIGKILL/9); if you strip the hwcap tag, libc
loads but `sysenter` then #UD-faults (SIGILL/4). Either way every 32-bit process
dies → init(8) restart loop. Upstream illumos ships the BASE libc as the
int/`syscall` variant, which is why upstream 32-bit works on AMD.

Fix (userland, no kernel change): swap the base libc to the int/syscall variant
solnix already builds:

    cp /usr/lib/libc/libc_hwcap3.so.1 /lib/libc.so.1

(`libc_hwcap3.so.1`: 0 sysenter, `int $0x91` + `syscall`, hwcap 0x861 = no SEP).
The amd64 kernel supports both on AMD: `sys_syscall_int` (int $0x91) always, and
`MSR_AMD_CSTAR = sys_syscall32` for the 32-bit `syscall` insn (X86FSET_ASYSC).
Result: `milestone/multi-user`, `multi-user-server`, `network/ssh` all online;
root SSH works. First solnix userland on AMD. Permanent fix: make the solnix
libc package install the int/syscall build as the base `/lib/libc.so.1`.

### STAGE 2 — amdgpu V520 bind: BOUND; stops at the PSP secure-OS hardware gate.
Built `src/drm-port` drm+amdgpu+KFD (`gmake kfd` → `drm-full`) natively on the
g4ad and bound it to the real V520 (pci1002,7362 = Navi12). Load/bind fixes
(now in the repo source): use `gmake` (illumos `make` lacks `$(wildcard)`),
`char _depends_on[]="misc/virtio"`, `-mcmodel=kernel -mno-red-zone`, wire
`amdgpu_transport_attach` into `drm_attach`, and fix `AMDGPU_RNUM` (illumos
numbers regs over PRESENT BARs → VRAM=1, doorbell=2, MMIO=3, not bar+1).
Staged `navi12_*.bin` (linux-firmware) in `/kernel/firmware/amdgpu`.

Bring-up reached, no panic: drm0 bound at `/pci@0,0/pci1002,a34@1e`; minor nodes
card0/renderD128/kfd; TTM up (VRAM 256MB BAR0 aperture, GTT 512MB); GMC/GART
512MB; GFX+SDMA+IH rings; IP blocks up; 8 firmware blobs loaded. WALL:
`amdgpu_psp_wait_sos` times out on `PSP_C2PMSG_SOS_STATUS` (C2PMSG_64) —
"PSP sOS not running". The PSP secure-OS bring-up (load navi12_sos.bin via the
PSP bootloader mailbox = psp_v11_0_bootloader_load_sysdrv, phase C3-amdgpu-d)
is not implemented, so sOS never runs → no fw auth → no GFX/SDMA power-up → no
render path. (Also: VRAM BAR is only 256MB; resizable-BAR not enabled.)

### STAGE 3 — measure: NOT RUN. GPU bound + software floor + firmware up, but not
powered (no PSP sOS → RADV cannot enumerate). No number fabricated.
Linux V520 baseline remains pp 1995 / tg 283 tok/s. Next: implement C3-amdgpu-d
PSP sOS load → fw auth → GFX/SDMA power-up → /dev/dri → RADV NAVI12 → benchmark.

---

## Prior-session root-cause notes (kept for the trace)

Instance i-037b2e911e4d08f4d, g4ad.2xlarge, AMD EPYC 7R32 (family 23 / model 49 = Zen 2 "Rome"),
8 vCPU @ 2800 MHz, AMD Radeon Pro V520 (Navi 12). AMI ami-0223f9a80bfaf2735 (BIOS-boot + cu_flags=0).

## STAGE 1 — init(8) SIGKILL loop: ROOT CAUSE ISOLATED (not yet fixed)

### Observability was the first wall
- Serial-console SSH is BLOCKED: IAM denies ec2-instance-connect:SendSerialConsoleSSHPublicKey and
  SendSSHPublicKey for user chiuso (account-level enable-serial-console-access succeeded, but the key-push
  API is denied). No interactive console / kmdb.
- get-console-output floods: the init loop emits ~936 identical "WARNING: init(8) exited on fatal signal 9:
  restarting automatically" lines in <6 s, saturating the 64 KB console ring before AWS snapshots it, so the
  kernel banner and any fault are overwritten. Caught the boot window only by rapid (3-6 s) polling right
  after reboot and keeping every distinct buffer.

### Kernel-source trace (illumos-gate)
- The message is emitted by the KERNEL: uts/common/os/exit.c restart_init() -> exit_reason(CLD_KILLED, 9).
  The kernel re-execs PID 1 (/sbin/init) each time it dies. "restarting automatically" (not "system reboot
  required") => exec_init SUCCEEDS every iteration; init RUNS then dies by SIGKILL (SKILLED flag).
- /sbin/init is a 32-bit i386 ELF (interp /lib/ld.so.1). start_init_common() also forces DATAMODEL_ILP32.

### The decisive experiment (diagnostic-init probes, via offline boot_archive/ZFS edits)
Replaced /sbin/init with shell-script diagnostics that print a unique marker to /dev/console and loop:
- 32-bit interpreter (#!/sbin/sh -> 32-bit ksh93): SIGKILLed, loop persists, NO marker.
- 64-bit interpreter (#!/usr/bin/ksh93 -> 64-bit ksh93): *** "SOLNIX-DIAG64: 64bit userland ALIVE" + TICK 0
  PRINTED ***. Loop HALTED; full kernel banner became visible.

CONCLUSION: **64-bit (LP64) userland runs fine on the g4ad AMD Zen2. Every 32-bit (ILP32) process is
force-SIGKILLed.** illumos userland is ~90% 32-bit here (init, svc.startd, sulogin, syseventd, most of
/sbin and /usr/sbin are 32-bit i386 ELF; counts: sbin 36/38 32-bit, usr/sbin 182/245, lib/svc/bin 6/7).
So a 64-bit-only init is NOT a workaround — startd and the rest still die. This needs a KERNEL fix.

### Fault character (what it is / is NOT)
- With set tudebug=1 tudebugfpe=1 tudebugsse=1 tudebugbpt=1, the ONLY trap dump ever printed is a benign,
  on_trap()-caught kernel #gp in pid=0: rdmsr(0xC0010055 = MSR_AMD_INT_PENDING_CMP_HALT, the C1E-disable
  probe in post_startup_cpu_fixups()) — the g4ad hypervisor rejects that AMD MSR (same class as the earlier
  cu_flags/MSR-0xc0010000 fix), but it is wrapped in on_trap so the system continues (root mounts, devices
  probe). It is NOT the init killer.
- There is NO user-mode trap dump for the dying 32-bit init in any capture (no SIGSEGV/SIGILL/SIGFPE via
  trap()). => the 32-bit process death is a SILENT in-kernel force-kill during process/LWP setup or the
  return-to-user path for compat mode, BEFORE the process executes a faulting user instruction. Most likely
  the ILP32 lwp_load/setregs segment-selector setup or the 32-bit sysret/return-to-user trampoline on this
  AMD+hypervisor combination.

### Tunables tried (in the boot_archive /etc/system, the ramdisk illumos actually reads), all NEGATIVE:
- set xsave_force_disable = 1  (force legacy FXSAVE, mask XSAVE/AVX/F16C/FMA) — loop persists.
- set use_mp = 0               (single-CPU; rules out AP-featureset-mismatch — boot shows "Not in MP mode"
                                and the "cpuN feature mismatch" warnings, but the loop persists) — negative.
- (cu_flags = 0 and exclude pcbe.AuthenticAMD were already baked; they fixed the earlier PMC #gp panic.)

### Verdict for Stage 1
NOT fixed. Root cause narrowed to: **the illumos 32-bit (ILP32 compat-mode) process bring-up / return-to-user
path faults on AMD Zen2 under the g4ad hypervisor, silently SIGKILLing every 32-bit process; 64-bit userland
is unaffected.** Pinning the exact faulting instruction requires kmdb (an early kernel breakpoint on the
return-to-user / lwp_rtt / sysret32 path), which is blocked by the IAM/serial-console restrictions on this
account. The next concrete step is a kmdb-equipped boot (needs serial-console SSH IAM perms) or a small
targeted kernel patch/instrumentation in the ILP32 setregs/sysret path, rebuilt into the boot_archive.

## STAGE 2 — amdgpu V520 bind: NOT REACHED (gated by Stage 1 — no userland, no add_drv/update_drv).

## STAGE 3 — measurement: NOT RUN. No /dev/dri, no solnix V520 tok/s. Nothing fabricated.
Linux V520 baseline stands: GGML_VULKAN TinyLlama-1.1B-Q4 = 1995 pp / 283 tg tok/s.

## Net
This session turned the opaque "init SIGKILL-loops 936x" blocker into a precise, reproducible
characterization: 64-bit solnix userland runs on the AMD g4ad; 32-bit userland is force-killed by a
silent in-kernel fault in the ILP32 bring-up/return-to-user path (not a user trap, not XSAVE, not SMP).
That is the first real solnix-on-AMD-userland data point and the exact seam the fix must target.

## UPDATE -- Stage 1 FIXED + Stage 2 amdgpu BOUND (PSP wall named)

### STAGE 1 -- ILP32-on-AMD: FIXED (a libc packaging bug, NOT a kernel bug)
The 32-bit SIGKILL loop on AMD (g4ad Zen2) was NOT KPTI (setprop kpti 0 negative), NOT MCA
(cmi_no_init=1 negative), NOT a kernel bug. ROOT CAUSE: solnix shipped the BASE 32-bit /lib/libc.so.1 as
the SYSENTER variant -- it tags CA_SUNW_HW_1 requiring AV_386_SEP (0x8) + emits `sysenter` for syscalls.
The illumos amd64 kernel deliberately removes X86FSET_SEP on ALL AMD (cpuid.c: AMD has no sysenter in long
mode), which drops the 32-bit hwcap AV_386_SEP. So on AMD: ld.so.1 rejects the SEP-requiring libc -> the
process dies (SIGKILL/9, the 936x init loop); strip the tag and `sysenter` in compat-mode #UDs -> SIGILL/4.
Every 32-bit process dies. FIX (one line, userland): `cp /usr/lib/libc/libc_hwcap3.so.1 /lib/libc.so.1` --
the int/syscall variant solnix already builds (0 sysenter, int $0x91 + syscall, hwcap 0x861, no SEP; the
amd64 kernel supports both on AMD via sys_syscall_int + MSR_AMD_CSTAR/sys_syscall32). -> multi-user +
network/ssh online; ROOT SSH WORKS. FIRST solnix userland on AMD. Fixes solnix on AMD hardware BROADLY.
PERMANENT FIX: the solnix libc package must install the int/syscall build as the base /lib/libc.so.1 (as
upstream illumos does) + keep the sysenter build only as an Intel-selected hwcap variant. See
pkgs/illumos/patches/libc-amd-int-syscall-base.README.md.

### STAGE 2 -- amdgpu V520 BIND: BOUND to the real GPU; wall = PSP secure-OS load
Built src/drm-port drm+amdgpu+KFD natively on the g4ad + BOUND to the real V520 (drm0, CHIP_NAVI12, no
panic). 5 real load/bind bugs fixed: use gmake (illumos make lacks $(wildcard)); _depends_on misc/virtio;
-mcmodel=kernel; wire amdgpu_transport_attach into drm_attach; and the BAR->rnumber map (illumos numbers
regs over PRESENT BARs: VRAM=1, doorbell=2, MMIO=3 -- not bar+1). Staged the navi12 firmware Linux uses.
Software floor ran: TTM -> GMC/GART -> GFX/SDMA/IH rings -> 8 firmware blobs loaded, then STOPS at
amdgpu_psp_wait_sos timing out on PSP_C2PMSG_SOS_STATUS ("PSP sOS not running"). The PSP secure-OS
bootloader load (navi12_sos.bin, phase C3-amdgpu-d) is not implemented -> no fw-auth -> no GFX power-up ->
no render path -> RADV can't enumerate. STAGE 3 measurement NOT RUN (no fabricated number; Linux V520 stays
1995/283). NEXT: implement the PSP sOS bootloader load sequence (C3-amdgpu-d) -> GFX power-up -> /dev/dri ->
RADV -> the first solnix V520 benchmark.

## UPDATE -- GPU measurement attempt: the CIRCULAR blocker (no number, nothing fabricated)
The AMD libc fix is PROVEN + reproducible on the real g4ad: every boot reaches the console login prompt,
full device probe, SMF online -- the 32-bit init SIGKILL-loop is dead. BUT SSH was never reached, so the
amdgpu bind (STAGE 2) was not attempted. Linux V520 stays 1995 pp / 283 tg.

THE CIRCULAR BLOCKER (precisely named): the libc-AMD fix requires a root-filesystem edit (cp
libc_hwcap3.so.1 -> /lib/libc.so.1). The only OFFLINE way to edit the root is `zpool import` -- but a
ZFS-import-edited AMI POISONS DHCP (docs/ena-rx-coldboot-fix.md root-cause #1, the dominant unrecoverable
one: import-edited = 0/10). The repo's SAFE in-place edit method needs SSH -- which needs the libc fix. The
boot_archive carries only kernel/drivers (no libc), so it can't break the circle. Tested the dual-addrobj +
clean-export fixes too -- still 0 DHCP, exactly matching the doc. Also: the V520 (pci1002,*) never appeared
in the console device tree (only pci1d0f NVMe) -- BIOS/enum gap vs console-ring truncation is undetermined
without prtconf -D (needs SSH).

THE UNBLOCK (the ONLY path avoiding the circle, and it's build-side not hardware): make the solnix libc
PACKAGE install the int/syscall build as the BASE /lib/libc.so.1 (as UPSTREAM illumos does -- see
pkgs/illumos/patches/libc-amd-int-syscall-base.README.md "Permanent fix"). Then a g4ad AMI built by the
IN-PLACE method (never zpool-import) ships libc-correct AND DHCP-intact in ONE image -> SSH works -> prtconf
1002 (is the V520 enumerated?) -> amdgpu bind + the PSP sOS bootloader-load test (8c2ec60) -> the bench.
Kept AMIs for next session: ami-0cb7254da736f1df1 (libc+ena), ami-0de76c0bb198c735f (libc-only) + snapshots.

## UPDATE -- CIRCLE BROKEN: g4ad boots to SSH, amdgpu BOUND to the real V520, walls at the PSP MP0 register window

The build-side unblock worked. A g4ad AMI baked via the fixed `oi-preseed-be.sh`
(in-place on the mounted BE: AMD-safe libc + single-addrobj DHCP, NO zpool
reguid -> no DHCP poison) boots to root SSH. The first solnix V520 amdgpu bind on
real hardware followed. No number fabricated; Linux V520 stays 1995 pp / 283 tg.

### STAGE 0 -- fresh fixed AMI baked + VERIFIED: ami-0531979c70a921d71
Built from the g4ad-v4 base BE (BIOS boot-block + cu_flags=0 already baked), on
an Ubuntu ZFS helper: `zpool import -N -R /mnt` (no reguid) -> mount BE -> fixed
`oi-preseed-be.sh` -> clean export -> snapshot -> `register-image
--boot-mode legacy-bios`. VERIFIED on the mounted BE before snapshot:
- base `/lib/libc.so.1` swapped to the int/syscall variant (`libc_hwcap3.so.1`,
  md5 b3bde24b): **0 sysenter, 352 int-$0x91/syscall** (the AMD-safe libc).
- `ipadm.conf` single `ena0/dhcp` (stale `ena0/v4` stripped).
- BIOS MBR bootcode present (pmbr jmp eb3c90) + `cu_flags=0` in `/etc/system`.
- **+ the NIC bind fix (new): ena `pci1d0f,*` driver_aliases.** g4ad enumerates
  the ENA NIC as `pci1d0f,ec20` (legacy-PCI compatible name), but the stock
  aliases were only `pciex1d0f,*` -> the device enumerated but ena never bound
  -> no NIC -> no DHCP. Added the `pci1d0f,*` aliases (now in `oi-preseed-be.sh`).

### STAGE 1 -- g4ad boots to ROOT SSH (the circle is broken)
Cold-launch of ami-0531979c70a921d71 on g4ad.2xlarge reached root SSH. Every
boot reaches `console login:` with SMF online (the libc AMD fix is solid -- no
init SIGKILL-loop). With the ena `pci1d0f,*` alias, `ena0` binds
(`pci1d0f,ec20`), DHCP gets a lease (172.31.x), sshd is reachable. First solnix
userland-over-SSH on the AMD/V520 g4ad. (Cold `run-instances` is the reliable
path; warm reboot can drop the lease -- matches ena-rx-coldboot-fix.md.)

### STAGE 2 -- amdgpu V520: ENUMERATED + BOUND; walls at the MP0 PSP register window
`prtconf -D` shows the V520 fully enumerated: `pci1002,a34@1e`, compatible incl
`pci1002,7362` (Navi12) + `pciexclass,038000`. Built `src/drm-port` natively
(`gmake kfd` -> `drm-full`, 131 syms resolve), staged the 15 `navi12_*.bin`
(linux-firmware) in `/kernel/firmware/amdgpu`, `add_drv` bound amdgpu to
`pci1002,7362` -> `/dev/dri/card0` + `renderD128` + `/dev/kfd` created; amdgpu0
attaches, no panic. Bring-up: TTM -> GMC/GART -> GFX/SDMA/IH rings -> **9
firmware blobs loaded + validated** (incl `navi12_sos.bin` ver 0x180764).

Two bugs, one fixed, one root-caused (the exact wall):
- **FIXED: the sOS-not-found false negative.** `psp.c` scanned
  `uc->fw[0..fw_count)` for the SOS blob, but the ucode set is stored BY
  `fw_id` index and `AMDGPU_UCODE_ID_SOS`=12 > `fw_count`=9 -> the scan missed
  it -> "no sOS firmware (navi12_sos.bin) loaded". Fixed to index
  `uc->fw[AMDGPU_UCODE_ID_SOS]` directly. sOS is now found; the PSP bootloader
  path runs.
- **THE WALL (root-caused, not fixed): the MP0/PSP C2PMSG registers are outside
  the mapped BAR.** The PSP bootloader-ready poll on C2PMSG_35 reads **0x0**
  forever. Live diagnostic on the real card:
  `SOC15_REG_OFFSET(MP0,0,C2PMSG_64)` = word **0x3b26540** = byte **0xec99500
  (~247 MB)**, but the MMIO register BAR (BAR5) is only **0x80000 (512 KB)** ->
  **out of range** -> the direct `ddi_get32` reads 0x0. The in-range GC probe
  (GRBM_STATUS) reads **0xffffffff** (GC block unpowered). BAR map verified
  correct (BAR0 VRAM 256 MB, BAR2 doorbell 2 MB, BAR5 MMIO 512 KB -> rnumber
  1/2/3 = `AMDGPU_RNUM`). Root cause: **on Navi12 the MP0 SMN block (the PSP
  C2PMSG mailbox) is NOT directly BAR-mapped -- it must be reached via the SMN
  index/data indirect register window.** The port's direct-BAR-only
  `psp_rreg/_wreg` cannot address it, so the PSP handshake never starts.

### STAGE 3 -- measure: NOT RUN. amdgpu is bound + firmware up, but the PSP sOS
cannot start (MP0 registers unreachable) -> no GFX power-up -> no /dev/dri
render path -> RADV cannot enumerate. No number fabricated. Linux V520 baseline
stays 1995 pp / 283 tg.

### NEXT (the single concrete step)
Implement SMN index/data indirect register access for the MP0 block in the
illumos amdgpu port (Linux routes `mmMP0_SMN_C2PMSG_*` through the SMN window,
not the BAR). With that, `psp_rreg(C2PMSG_35)` reaches the live PSP -> the sOS
bootloader handshake (the code is in place, `amdgpu_psp_bootloader_load_sos`) ->
sOS RUNNING (C2PMSG_64) -> fw authenticate -> GFX/SDMA power-up -> /dev/dri ->
RADV NAVI12 -> the first solnix V520 GGML_VULKAN number vs 1995/283.
Baked AMI kept: **ami-0531979c70a921d71** (boots to SSH, amdgpu-ready).
