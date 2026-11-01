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

## Result (2026-10-27)

- **Stage 1 passed** on BE solnix-8 (after 91fe7f0 created the /dev/dri links: devlink.tab
  `type=ddi_display:drm<TAB>dri/\M0`). i915 attached; `/dev/dri/card0` and `renderD128` exist and nothing
  holds them open. ssh, both links and `svcs -x` are unaffected.
- **Stage 2, first try (solnix-8), panicked.** `#gp` in `obsd_enum_walk <- pci_find_device <-
  intel_pch_detect`: pci_find_device used inteldrm's uninitialised `pa` as a template. The deadman and
  dump worked: the machine came back on the default BE, and vmdump.0 and the mdb output are banked at
  `~/solnix-bank/lixi-gpu-stage2-20261027/`. Fixed in 25c3c18.
- **Stage 2 passed** on solnix-10 (25c3c18). `open(/dev/dri/card0)` ran the inteldrm attach:
  `inteldrm0: msi, ALDERLAKE_P, gen 12`, `inteldrm0: 3840x2400, 32bpp`. DRM_IOCTL_VERSION returned
  i915 1.6.0.
- **Default since 2026-10-27:** solnix-11 (nix-config c14ab1c: i915 bound at boot, i915 firmware). The
  same open shows no DMC/GuC errors.
- **Who may open /dev/dri:** the stock /etc/logindevperm gives `/dev/dri/*` 0600 to the console user,
  and login/logout move it (illumos's seat model; NixOS does the same with logind ACLs). A compositor
  started from a console login owns card0. Outside a console session, card0 is root-only.
