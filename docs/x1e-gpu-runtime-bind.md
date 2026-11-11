# GPU drivers on the X1E: runtime load test and staged attach

The installer image carries the Intel iGPU driver and the NVIDIA open modules (`hardware.graphics.onMedia`,
modules/config/graphics-gpu.nix):

| module | hardware | PCI id | on the media |
|---|---|---|---|
| `i915` (OpenBSD inteldrm port, `pkgs.solnix.i915-driver`) | Iris Xe (Alder Lake-P) | `pciex8086,46a6` | module, major, `minor_perm i915:* 0666` |
| `nvidia` (+ `nvidia_modeset`, `nvidia_i2c`), 615.71.09 | RTX 3080 Ti (GA103) | `pciex10de,2420` | modules, majors, minor_perm; **no GSP firmware** |

**None of them has a `driver_aliases` line**, so nothing attaches at boot: the panel stays on `vgatext` (the
firmware framebuffer console) and the dGPU stays unbound and powered off. None of them has ever attached on
this hardware. The image does not carry NVIDIA's GSP firmware. It is unfree, and without it the GPU does not
initialise. An nvidia attach therefore needs an image built with `hardware.graphics.nvidia.acceptFirmwareLicense
= true`.

The i915 module is built with `-mno-mmx -mno-sse` like every illumos kernel module. Its build fails unless the
only SIMD instructions are OpenBSD's `movntdqa` copies (`i915_memcpy_from_wc`,
`i915_unaligned_memcpy_from_wc`, `drm_memcpy_from_wc`) and each of them lies between `fpu_kernel_enter` and
`fpu_kernel_exit` (src/drm-port/i915/simd-gate.sh). The earlier modules 229d0e54 and 614a0cba were built
without those flags and must not be loaded (src/drm-port/i915/STAGED-ATTACH-PLAN.md). Check the hash of the
module you load against the boot sheet:

    digest -a sha256 /kernel/drv/amd64/i915

## A. Live media: load and unload only (no attach)

`modload` runs the module's `_init`, which sets up soft state, starts the compat layer's task queues and
registers the driver. Because no device is bound, `attach` never runs: no PCI access, no BAR mapping, no
console change. The test exercises the symbol binding against this kernel and the module's init and fini
code. It does not reach the inteldrm or FPU paths (`fpu_kernel_enter` runs only from the WC memcpy, which
only a modeset uses).

    modinfo | grep -w i915                     # nothing: not loaded
    grep -w i915 /etc/name_to_major            # i915 <major>
    grep -w i915 /etc/driver_aliases           # nothing: not bound
    modload /kernel/drv/amd64/i915; echo rc=$?
    modinfo | grep -w i915                     # <id> ... i915 (i915 (OpenBSD inteldrm))
    dmesg | tail -5                            # no "multiply defined" / "undefined symbol"
    modunload -i <id>; echo rc=$?
    modinfo | grep -w i915                     # nothing
    prtconf -D | grep -c 'driver name: i915'   # 0

Repeat the cycle at least 8 times (`while` loop; the image has no `seq`) and report each rc. A bursty failure
looks like a pass in a sample of one.

Do **not** run `modload` on `nvidia_modeset` before `nvidia`'s resource manager has initialised. Do not load
any nvidia module on this media at all: without GSP firmware the only thing `modload nvidia` can show is the
symbol binding, and the load already happens at `_init`. If that one check is wanted:
`modload /kernel/drv/amd64/nvidia`, `modinfo | grep -w nvidia`, `modunload -i <id>`. Never `nvidia_modeset`.

## B. Stage 1 on an installed system: i915 bound at boot, text console only

This is stage 1 of src/drm-port/i915/STAGED-ATTACH-PLAN.md. Its preconditions all apply: the operator is at
the machine, the deadman and a dump device are armed and verified, and one change is made per boot. Install
from the media first (`solnix-install`). Then, on the installed system:

1. Arm the deadman and the dump in the configuration, and check them on a known-good generation (no i915)
   before anything else. The deadman is off by default; `set snooping=1` turns it on (uts/common/os/clock.c
   `deadman_init`). The dump device comes from `solnix.dumpadm` (modules/config/dumpadm.nix):

       environment.generatedEtc."system.d/solnix-deadman" = "set snooping=1\n";
       solnix.dumpadm = { enable = true; device = "/dev/zvol/dsk/rpool/dump"; };

   `solnix-rebuild boot`, reboot into it, then:

       echo deadman_enabled/D | mdb -k          # 1
       dumpadm                                  # the dump device and savecore dir are set
       savecore -L                              # a live dump lands in the savecore dir

   This generation is the known-good BE for steps 2-3.

2. Build the experimental generation into a **boot-once** BE. In the system configuration set
   `hardware.graphics.i915.attachAtBoot = true;` (it renders `driver_aliases i915 "pciex8086,46a6"` and lays
   the module), then:

       solnix-rebuild boot                       # creates the next solnix-<N> BE and activates it
       beadm activate solnix-<N-1>               # make the known-good BE the default again
       beadm activate -t solnix-<N>              # the new BE for ONE boot only
       beadm list                                # N-1 has R (default), N has T (temporary)
       digest -a sha256 /<mount of solnix-N>/kernel/drv/amd64/i915   # equals the boot sheet

   Before arming, confirm no service would open `/dev/dri/card0` (no X server, compositor or greeter is
   enabled). An open would trigger the inteldrm modeset, which is stage 2.

3. Reboot and read the console (the table in STAGED-ATTACH-PLAN.md "Stage 1"):
   - pass: `i915<N>: ... console on gfxp_fb; OpenBSD inteldrm attach on first open`, the panel keeps live,
     scrolling text, no `inteldrm` message, ssh answers;
   - fail: preserve the dump (`savecore`), photograph the panel, stop. Do not retry with a change.

## C. Back out

- Live media: `modunload -i <id>`, or reboot (the media's ramdisk forgets everything).
- Installed, stage B: a plain reboot boots the default BE again, because `beadm activate -t` lasts one boot.
  If the machine hangs before userland, power-cycle it. The boot-once activation is spent, so the default BE
  boots. At the loader menu you can also pick the known-good BE by hand. Then
  `beadm destroy solnix-<N>` and set `attachAtBoot` back to false.
- Never back out with an ssh script, cron or a timer. None of them runs if the hang comes before userland.

## D. nvidia bound at boot (boot-once BE only)

`hardware.graphics.nvidia = { attachAtBoot = true; acceptFirmwareLicense = true; }` (modules/config/graphics-gpu.nix)
binds `nvidia` to `pciex10de,2420` and changes what tzmon does, so read all of this first.

- tzmon's boot-time dGPU power-off (scripts/patches/0005) acts on any dGPU that has no driver attached when tzmon
  attaches, even one bound by alias, so the option opts tzmon out (`solnix-dgpu-off=0` in tzmon.conf), unless
  `nvidia.rtd3` is on (section E: nvidia then attaches to the GPU tzmon cut). From then on the GPU is powered.
  Unmanaged it went 53 -> 94 C in ten minutes and the EC cut power.
- `site/solnix-nvidia-guard` starts with single-user. It reads the EC's dGPU sensor (GPUT, kstat
  `dgputemp:0:ec:gput_C`, from the `dgputemp` module) every 3 s and reboots at `nvidia.maxTempC` (80) or when the
  sensor cannot be read. Test it without rebooting: `DRYRUN=1 SENSOR=tmp0_C MAXT=40 LOG=/tmp/g.log sh <guard>`
  logs `would reboot` at the first sample.
- nvidia.conf sets `NVreg_GpuInitOnProbe=0`. The PCI attach maps the BARs and makes /dev/nvidia0, but it does not
  boot the GSP. `site/solnix-nvidia` (after the guard and system/dumpadm) opens /dev/nvidia0, which runs
  RmInitAdapter and boots the GSP after the dump device is armed. It then holds the device open and logs to
  /var/log/solnix-nvidia.log. The GSP firmware is in usr/kernel/firmware, outside the boot_archive.
- Use it only in a `beadm activate -t` BE. The guard's reboot then lands in a BE where tzmon powers the GPU off.
  Without `nvidia.rtd3` (section E) nothing powers an idle GPU down. That is why this is not a default.

## E. Runtime D3cold (hardware.graphics.nvidia.rtd3, boot-once BE only)

`hardware.graphics.nvidia.rtd3 = true` (with `attachAtBoot`) makes the nvidia module power the dGPU off when no
client has it open, and on again at the next open. It is NVIDIA's coarse runtime power management
(`NVreg_DynamicPowerManagement=1`). RM decides when, and src/drm-port/nvidia-oss/patches/0002 is the illumos
executor RM's hooks were stubbed without.

- Off: 10 s after the last close, PCI D3hot, then the root port's `_PR3` power resource `_OFF`. On the X1E that is
  SSDT14 `PEG1.PXP._OFF` -> `POFF`: link to L2/L3, reset asserted, power GPIO off, the same thing tzmon does at boot.
  The GPU's HDMI audio function (01:00.1) is offlined at attach, before audiohd takes it, and stays offline.
- On: the next open of /dev/nvidia0 runs `_ON` and waits for the link (Data Link Layer Link Active) and for config
  reads. It restores config space, and RM initialises the GPU as on the first open.
- Read it from `kstat -p nvidia:0:rtd3` (off, offs, ons), `kstat -p dgputemp:0:ec:psta` (PEG1.PSTA: 1 = power
  GPIO on and reset released) and `pr3_sta`, and from the `rtd3:` lines in /var/adm/messages.
- The guard accepts a missing GPUT reading only while psta and pr3_sta are both 0 (off). After an off -> on edge
  it allows 10 unreadable samples (30 s). Anything else unreadable still reboots.
- site/solnix-nvidia opens the GPU once (RM + GSP up, temperature read) and releases it. It then logs the rtd3
  kstat, GPUT and psta every 60 s.
- Gate (per-boot test, nothing persistent): off within ~15 s of the last close (psta 0, `rtd3: idle 10 s: off`).
  `nvidia-probe` reopens it (`rtd3: on`, RM init, temperature). Negative control: `nvidia-probe -w 60` holds it on
  for the 60 s. 8 open/close cycles, with kernel heap per cycle.
- The boot (src/drm-port/nvidia-oss/patches/0003): with `rtd3` tzmon KEEPS its boot-time power-off (no
  `solnix-dgpu-off=0`), so the GPU is cut about 2 s after the kernel banner, as in a BE without nvidia. Measured
  2026-11-11 (BE 48, tzmon opted out): the guard's first sample, 5 s after the banner, read 80 C and it rebooted.
  The window before the banner (POST, the loader) is firmware: the GPU is powered there in every BE, which is why
  an NVIDIA BE still boots only from a cold dGPU.
- tzmon offlines the GPU's functions, and devfsadm never attaches an offline node. `site/solnix-nvidia` (after the
  guard is sampling) opens `/devices/pseudo/nvidia@0:nvidia-poweron` (root only). That open is the cold attach:
  `_ON`, wait for Data Link Layer Link Active and the vendor id, then restore what a fundamental reset cleared,
  with decode off: the Resizable BAR sizes (BAR1 is 16 GB on this GPU), the BAR bases from `assigned-addresses`,
  Max_Payload_Size from the root port. It verifies them from config space (ids against the node, every BAR's base
  and size by the sizing probe, each Resizable BAR control's size). A mismatch puts the GPU back in D3hot and
  `_OFF` and fails the open, so RM never starts on a mis-sized BAR. Otherwise it onlines the node, and nvidia
  attaches. The RTD3 resume runs the same restore and check after `pci_restore_config_regs`, whose register order
  writes the BARs before the Resizable BAR control.
- The guard runs with `EXPECT_OFF=1`: its first sample must see the GPU off (no reading, psta 0, pr3_sta 0).
  Anything powered then, readable or not, means tzmon did not cut it, and it reboots.
- Not done: the fine mode (GC6/GCOFF with the framebuffer kept, `=2`), which needs RM's runtime suspend/resume
  callbacks and the NVIDIA GC6 `_DSM`. Also not done: putting the audio function back online.

## Not done here

- Stage 2 (one explicit open of card0, the OpenBSD inteldrm modeset). It is the first time the FPU glue
  (`kernel_fpu_begin` with `KFPU_NO_STATE` under `kpreempt_disable`), BAR mapping, MSI and GEM run.
- `nvidia_modeset` / `nvidia_i2c` attach (load them only after /dev/nvidiactl exists), and display on the dGPU.
