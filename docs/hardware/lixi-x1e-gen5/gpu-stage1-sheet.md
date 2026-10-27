# lixi: GPU stage 1 (i915 bound at boot, text console only) -- the operator sheet

Prepared 2026-10-27. Run this at the machine only. Nothing on lixi is activated yet.

| what | where |
|---|---|
| default BE | `solnix-7` (plain lixi, the deadman armed: `deadman_enabled = 1`, dump on `rpool/dump`) |
| stage-1 toplevel | `/nix/store/97zs3gwjm846qyzy40k2cxqisibdfszr-solnix-system-lixi` (nix-config `2e87689`, `solnixConfigurations.lixi-gpu1`). Already in lixi's store, verified |
| i915 module in it | sha256 `e284943d8017533f…`, aliases `pciex8086,46a6` (Iris Xe) and `pciex8086,3e9b` |
| what it changes | only the i915 binding. Nothing opens `/dev/dri/card0`, so no modeset runs: the COSMIC module is off and there is no display service |

## Before (over ssh is fine)

    beadm list                                   # solnix-7 NR
    echo deadman_enabled/D | pfexec mdb -k       # 1
    pfexec dumpadm | head -3                     # dedicated /dev/zvol/dsk/rpool/dump

## Arm the boot-once BE (over ssh is fine)

    L=/nix/store/97zs3gwjm846qyzy40k2cxqisibdfszr-solnix-system-lixi
    pfexec $L/bin/switch-to-configuration boot   # creates solnix-8 and makes it the default
    pfexec beadm activate solnix-7               # put the known-good BE back as the default
    pfexec beadm activate -t solnix-8            # solnix-8 for ONE boot only
    beadm list                                   # solnix-7 R, solnix-8 T

## Boot it, at the machine

    pfexec reboot

Watch the panel, and photograph it if anything looks wrong.

- **pass:** the boot text keeps scrolling on the panel, a login prompt appears, wifi joins, and ssh to
  192.168.1.192 works. Then:

      prtconf -D | grep -i i915                  # driver name: i915 on the Iris Xe node
      modinfo | grep -w i915
      pfexec dmesg | grep -iE 'i915|inteldrm|drm' | tail -20
      ls -l /dev/dri/                            # card0 / renderD128 exist, nothing has them open

- **fail (black panel, hang, panic):**
  - Within about 50 s the deadman should panic it and write a dump. If not, hold the power button.
  - The boot-once BE is spent, so the next boot is solnix-7.
  - Then `pfexec savecore -v` and photograph the panic screen. Send me the photo plus
    `ls -la /var/crash/lixi/`.

## Back out

A plain reboot boots solnix-7 again. To drop the stage-1 BE afterwards: `pfexec beadm destroy solnix-8`.

## Next, only after a pass

**Stage 2** is the first explicit open of card0, the inteldrm modeset. It's another boot-once BE plus one test
program. After that, cosmic-comp (solnix 0f051d2, built) can take the panel.
