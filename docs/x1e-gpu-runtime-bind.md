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

## Not done here

- Stage 2 (one explicit open of card0, the OpenBSD inteldrm modeset). It is the first time the FPU glue
  (`kernel_fpu_begin` with `KFPU_NO_STATE` under `kpreempt_disable`), BAR mapping, MSI and GEM run.
- An nvidia attach. It needs an image with the GSP firmware, and the order is `nvidia` before `nvidia_modeset`
  (src/drm-port/nvidia-oss).
