# iwm (Intel AC 9560) attach plan for dixi: exact procedure, prerequisites, back-out

Status of this document: PLANNED. Nothing here has been run beyond the load test in section 0. Every step that
changes dixi is marked; nothing in this plan is to be run until the maintainer approves the dump device AND the
alias/attach step, in that order.

## 0. Already measured (REAL, 2026-10-09, dixi solnix-2 BE, kernel solnix-ac45d71fc2b0)

- Module: dixi:/var/tmp/streamD2/solnix/src/wifi-port/iwm/iwm (rebuild with
  `IWM_DIXI_DIR=/var/tmp/streamD2/solnix/src IWM_DIXI_OUT=/var/tmp/streamD2 src/wifi-port/iwm/build-dixi.sh` from floki).
  Gates: 118 undefined, 0 unresolved vs running unix+genunix+misc/mac, 0 kernel-name collisions vs all of /dev/ksyms.
- Final module: sha1 aaced5c6e562b3765360a3a740349176a3405e99, 442704 B, 127 undefined / 0 unresolved / 0 collisions.
- Load with no major: 17/17 `modload` ENXIO (two builds) + "mod_installdrv: no major number for iwm", no panic (after the cb_str
  fix in iwm_gld.c; the unfixed module would NULL-deref in dld_fini_ops).
- With a major and NO alias (`add_drv -n iwm` + `drvconfig -b -i iwm -m 362`): 13/13 load/modinfo/modunload cycles clean
  (9 on build fbc5f4e3, 4 on the final build aaced5c6 that carries the WLDP bridge):
  modinfo "iwm (Intel AC 7260-9560 (OpenBSD iwm)", devnames flags DN_LEAF_DRIVER,DN_NETWORK_DRIVER,DN_GLDV3_DRIVER,
  one n80211_systq thread while loaded and 0 after unload; the a370 node stayed "driver not attached"; prtconf -D showed no iwm.
- Backed out with `rem_drv iwm` + removing the /reconfigure add_drv created; /etc/{name_to_major,driver_aliases,minor_perm,
  driver_classes}, /etc/security/{device_policy,extra_privs}, /etc/path_to_inst all byte-identical (cmp) to
  dixi:/var/tmp/streamD2/etc-before/.

## 1. Prerequisite: a crash dump device (needs maintainer approval; NOT done)

The first attach runs OpenBSD code against real hardware (firmware upload, DMA rings, MSI/INTx). A panic without a
dump device loses the only evidence. Commands (from /tmp/streamD-dump-request.md):

    pfexec zfs create -V 4G rpool/dump
    pfexec dumpadm -d /dev/zvol/dsk/rpool/dump -s /var/crash/dixi -y
    pfexec dumpadm            # expect: Dump device: /dev/zvol/dsk/rpool/dump (dedicated)

`dumpadm -e` estimated 3.13 GB for kernel pages on 64 GB RAM, so 4 GB fits. NixOS equivalent: none needed on Linux
(kdump is opt-in); on illumos a dump zvol is what the installer creates by default, so this is the illumos default,
not a solnix invention.

## 2. Firmware placement (PLANNED; needs root on the BE)

firmware_open("iwm", "iwm-9000-46") resolves "firmware/iwm/iwm-9000-46" ONLY through the kernel module path
(firmload.c: kobj_open_path(path, use_path=1)); dixi's module path (mdb `*default_path/s`) is
"/system/boot/kernel /platform/i86pc/kernel /kernel /usr/kernel". So the blob must be under one of those, e.g.:

    pfexec mkdir -p /kernel/firmware/iwm
    pfexec cp /nix/store/k8nx230y4p2n0cbfib5hp48585ry7bba-iwm-firmware-20241017/kernel/firmware/iwm/iwm-9000-46 \
        /kernel/firmware/iwm/iwm-9000-46
    digest -a sha256 /kernel/firmware/iwm/iwm-9000-46
    # expect 9a0c5d938646942f9798e6212579c25771e4bb44301cd409b82abe361ca2c3e0 (1519568 bytes)

/kernel and /kernel/firmware are dr-xr-xr-x root (measured); pfexec mkdir/cp works on the BE's own zfs
(rpool/ROOT/solnix-2, not read-only). This is mutable BE state (see section 6). Back-out: `pfexec rm
/kernel/firmware/iwm/iwm-9000-46 && pfexec rmdir /kernel/firmware/iwm`.

If the blob is missing, attach fails cleanly: iwm_preinit -> iwm_read_firmware returns the error, OpenBSD prints
"could not read firmware iwm-9000-46 (error 2)" and iwm_il_attach's "!iwm: firmware/NVM preinit failed" goes to
the log, then the fail_hw path frees rings and interrupts. (Code path REAL; not run.)

## 3. Driver registration (PLANNED)

Plain `add_drv` refuses here: the module is not in the module path (add_drv.c:304 module_not_found), and
/kernel/drv is read-only for files the BE did not ship. Two ways in:

A. (preferred for the first attach; no files in /kernel/drv)
    pfexec add_drv -n iwm                     # name_to_major only (measured: 'iwm 362'), creates /reconfigure
    pfexec rm /reconfigure                    # add_drv -n creates it; it is absent on dixi
    pfexec /usr/sbin/drvconfig -b -i iwm -m <major from /etc/name_to_major>   # kernel binding, no alias
    pfexec modload /var/tmp/streamD2/solnix/src/wifi-port/iwm/iwm             # installs dev_ops (MOD_NOAUTOUNLOAD)
  Attach of a bound node then finds the driver installed (modsubr.c:106 CB_DRV_INSTALLED) and does NOT need
  /kernel/drv/amd64/iwm.

B. (persistent, after A works) copy the module to /kernel/drv/amd64/iwm and use plain add_drv; better done
  declaratively (section 6).

## 4. The alias = the attach (PLANNED; the step that needs explicit approval)

    pfexec update_drv -a -i '"pciex8086,a370"' iwm

Why "pciex8086,a370" and not "pci8086,a370": the node is PCIe and its compatible list (prtconf -v, measured) starts
'pciex8086,a370.8086.30.10' 'pciex8086,a370.8086.30' 'pciex8086,a370.10' 'pciex8086,a370' ... 'pci8086,a370' ...;
illumos binds the FIRST compatible entry that has an alias, and iwn's aliases are all "pciex8086,..." (measured).
Either alias would match; pciex8086,a370 matches the convention. `update_drv -a` writes /etc/driver_aliases,
calls MODADDMAJBIND with the alias (rebinds the node), then `devfsadm -i iwm` (load_driver), which attaches.
NOTE: the node name 'pci8086,30' was derived from the subsystem ids; the a370 alias still matches because binding
goes through 'compatible', not the node name.

What the maintainer will see if it works (PLANNED expectations, from the code):
- dmesg: "iwm0: hw rev 0x<rev>, fw ver <ver>, address <MAC>" (OpenBSD iwm_preinit printf, if_iwm.c:11672).
- `dladm show-phys` -> iwm0, MEDIA "WiFi", STATE "down" (mac_link_update DOWN at register).
- `modinfo | grep iwm` -> the module; `prtconf -D | grep iwm` -> "pci8086,30, instance #0 (driver name: iwm)".
- `dladm scan-wifi iwm0` -> (bridge in section 5) WL_SCAN brings the interface up (mac_start -> iwm_init:
  firmware upload, then ieee80211_begin_scan) and waits up to ~2.4 s, then lists ESSIDs. First run may list nothing
  if the OpenBSD scan needs longer than the wait; repeat once.

What failure looks like:
- "iwm0: could not read firmware iwm-9000-46" -> section 2 not done.
- "iwm: firmware/NVM preinit failed" -> firmware load or NVM read failed; attach returns DDI_FAILURE; driver stays
  installed but unattached; back out with section 7.
- "iwm0: interrupt priority above LOCK_LEVEL" (iwm_bus.c:508 refuses a hilevel interrupt) -> attach refuses.
- panic -> with section 1 done, savecore writes /var/crash/dixi/vmdump.N on reboot; the default BE boots without the
  alias only if the /etc edits are on the BE (they are; see back-out). Without section 1: no evidence.

## 5. What attach needs from the GLDv3 side (state of the code)

- BUILT (written this run, compiles and links on dixi, never executed): mc_ioctl / mc_getprop / mc_setprop /
  mc_propinfo WLDP bridge in src/wifi-port/iwm/iwm_gld.c with the OpenBSD-side half in iwm_attach.c (iwm_il_*;
  per-property table in src/wifi-port/iwm/STATUS.md), mc_tx 802.11->Ethernet conversion before if_snd, RX
  Ethernet->802.11 FROMDS+LLC before mac_rx, mac_pdata_update of the BSSID before link up.
- BUILT since 4d7064ee (never executed): loadfirmware -> firmware_open("iwm", name), giant dropped around the IO.
- GATED: WPA/WPA2 (wpad door + MAC_PROP_WL_KEY/WPA/SETOPTIE/MLME): ENOTSUP. Open networks and scan only for the first
  attach.
- detach refused once attached (iwm_attach.c NOTE): after a successful attach, modunload returns EBUSY; back-out of a
  live attach is `update_drv -d` + reboot (section 7).

## 6. Declarative form (what a module must emit so this survives a new generation)

These /etc and /kernel edits are mutable state on the CURRENT BE (solnix-2); `solnix-rebuild switch` builds a new BE
from the store and they vanish. NixOS's equivalent is hardware.firmware + boot.extraModulePackages + udev aliases
from modinfo; on illumos the driver database is files, so a module `hardware.wirelessIwm` (rename/extend of
modules/config/wireless-iwx.nix) must emit, at BE build time (install-be.sh copies pkgs.solnix.drivers' four files
into etc/, modules/system/activation/install-be.sh:221):

- name_to_major: `iwm <N>` with N not used by the gate's list (dixi's next free was 362, measured);
- driver_aliases: `iwm "pciex8086,a370"` (plus the other iwm_devices ids when supported);
- minor_perm: `iwm:* 0666 root sys` and `clone:iwm 0666 root sys` (the gate gives iwn exactly these; measured
  in pkgs/illumos/data/drivers/minor_perm:93-94);
- the module at kernel/drv/amd64/iwm and the firmware at kernel/firmware/iwm/iwm-9000-46 inside the kernel tree
  the BE copies (install-be.sh _ktree; bootadm then puts the module in the boot archive);
- no driver_classes / device_policy entries (iwn has none; measured).
Today pkgs.solnix.drivers is a fixed builtins.path of pkgs/illumos/data/drivers, so this needs either an overlay of
that derivation (append lines) or a drivers.extra option merged by install-be.sh. Not written in this run (PLANNED).

## 6b. First-attach test sequence (after sections 1-4; open network only)

    dladm show-phys                          # iwm0 WiFi down
    pfexec dladm scan-wifi iwm0              # first execution of iwm_init + scan; up to ~10 s
    pfexec dladm connect-wifi -e <open-ssid> iwm0
    dladm show-wifi iwm0
Stop at the first failure and capture `echo ::msgbuf | pfexec mdb -k | tail -40`. WPA networks are refused up front
(CAPABILITY reports no WPA), by design for this stage.

## 7. Back-out

Before any attach (state after section 3A):
    pfexec modunload -i $(modinfo | awk '$6=="iwm"{print $1}')
    pfexec rem_drv iwm
    [ -e /reconfigure ] && pfexec rm /reconfigure
    for f in name_to_major driver_aliases minor_perm driver_classes; do cmp /var/tmp/streamD2/etc-before/$f /etc/$f; done

After an alias (section 4), attach failed or succeeded:
    pfexec update_drv -d -i '"pciex8086,a370"' iwm      # removes the alias, unbinds an unattached node
    pfexec rem_drv iwm                                    # if attached, rem_drv reports the module busy (detach refused)
    -> if attached: reboot; the boot reads the edited /etc files (alias gone), so iwm never loads.
Then the same cmp against etc-before, and remove /kernel/firmware/iwm (section 2).

Hard rule from the brief: never touch e1000g0 (the only working link), never change the boot environment.
