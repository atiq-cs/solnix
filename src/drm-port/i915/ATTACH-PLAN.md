# i915 (UHD 630, 8086:3e9b) load plan for dixi: prerequisites, steps, back-out, console handover

Status: PLANNED. Nothing here has been run. Nothing is to be run until the maintainer approves the dump device (step 1),
then the no-alias load (step 3), then the alias (step 5), each separately. Same shape as
`src/wifi-port/iwm/ATTACH-PLAN.md`, which was carried out for iwm up to its step 3.

## Prerequisite before loading alongside iwm: symbol scoping (REAL, done)

i915 and iwm both carry an OpenBSD-kernel-API compat layer and used to export the SAME global names (tsleep,
wakeup, bus_dmamap_*, timeout_*, task_*, pci_conf_read, loadfirmware, systq, ...). krtld binds a loading module's
non-local symbols to any existing definition (uts/common/krtld/kobj.c do_symbols), so whichever of the two loaded
second had its compat references cross-wired into the first module's copies. Measured on dixi: pre-fix i915
exported 4643 globals; its intersection with pre-fix iwm's 871 globals, minus the module interface, was 33
(the bus_dma*/timeout_*/task_*/pci_*/tsleep/loadfirmware/config_mountroot/systq set -- the 33 that resolved into
loaded iwm in stream G).

Fix: a linker mapfile at the `ld -r` step (src/drm-port/i915/i915.mapfile, applied by build-module.sh with
-Breduce) scopes every symbol local except the kernel-loader interface i915 defines -- _init, _fini, _info and
_depends_on (char _depends_on[] = "misc/gfx_private", which krtld reads by name). The equivalent lands in iwm
(src/wifi-port/iwm/iwm.mapfile, which has no _depends_on). After the fix i915 exports exactly
_init/_fini/_info/_depends_on, iwm exactly _init/_fini/_info, and their exported-global intersection minus the
interface is 0; the 33 compat collisions are 0 (post-fix module 4,810,080 B vs pre-fix 5,535,936 B, the local
symbols dropped from the symtab). build-module.sh fails the build if i915 ever exports a non-interface global
again (scripts/check-compat-local.sh is the standalone gate; its negative control is that the pre-fix module
fails). BOTH modules must be symbol-scoped before either is loaded while the other is resident.

## 0. What exists (REAL, 2026-10-09, dixi BE solnix-3, kernel solnix-ac45d71fc2b0)

- Module: dixi:/home/gburd/streamE4/mod3/i915, ELF64 ET_REL AMD64, 5,523,936 bytes (text 3,236,200, data 2,152,
  bss 8,144), sha1 53a1b23f559ad6e10ee68ad0e0b20c01acfdf738 (a clean rebuild of the final tree; mod2, d7aa74d2..., is
  the same size and gate result from before the compat objects were rebuilt; the hash changes with any rebuild). It is `ld -r` of the 391 OpenBSD drm + inteldrm + ttm
  objects (OpenBSD 37a498de, unmodified, `-D__HAVE_ACPI -DNACPI=1`), the compat objects
  `obsd-compat/obsd_{kern,time,bus,vm,glue}.o`, `i915/i915_illumos.o` and `i915/i915_pciid.o`.
  Build: `i915/link-gap.sh` then `OBJS_FROM=<lg dir> i915/build-module.sh OBSD PORT OUT FILES` (on dixi, under
  /home/gburd: /var/tmp is in the BE and did not survive the solnix-3 switch).
- Gates (`build-module.sh`): 178 undefined symbols, **0 not exported by the running unix + genunix**; **0 globals that
  collide with the 27,540 global symbols of /dev/ksyms** (kernel + every loaded module; `_init/_fini/_info` exempt).
  Negative controls (`build-module-negctl.sh`): an added call to a missing function and an added `ddi_get_lbolt`
  definition each fail the gate by name. The first collision run found a real one: the loaded `ufs` module exports a
  global `free()`, and krtld would have bound every drm `free()` to it (now `obsd_free`, `obsd_prelude.h`).
- Undefined vs "defined nowhere" (`link-gap.sh`): 114 → 0. The R2, console and ACPI rows are **stubs that fail**
  (ENOTSUP/NULL), listed in `obsd-compat/obsd_glue.c`, not implementations.
- Userland tests (`obsd-compat`: `gmake test`): sleep queue 8/8, BAR parse on dixi's real iGPU properties 4/4, vm
  registry + uao 14/14; 8 runs each, 24/24 PASS; 4 negative controls each FAIL. `i915`: `gmake test` PASS + neg ctl FAILS.

What has NOT run anywhere: any kernel code path of this module. `ddi_regs_map_setup` offsets, MSI allocation, the
device-tree walk, `hat_devload` attributes, contig_alloc and the OpenBSD attach itself are unexecuted.

## 0b. The cdev and the console (REAL build, dixi generation after solnix-3; nothing run)

Module dixi:/home/gburd/streamE5/full/i915, clean rebuild of all 391 drm objects (`-D__HAVE_ACPI -DNACPI=1`):
5,536,008 bytes (text 3,241,816), sha1 d2a541ecc9e97db7e41a5512e20756a813ed60ac. Gates: 202 undefined, **0 not
exported by unix + genunix + misc/gfx_private** (the module's `_depends_on`, as vgatext's), **0 collisions** with the
25,267 globals of /dev/ksyms. Both negative controls fail by name.

- **F2 fixed:** `rasops_init` (obsd_glue.c) sets `ri_font` to a metrics-only 8x16 font, so the attachhook's
  `ri->ri_font->fontwidth` no longer dereferences NULL. Control: the E4 module's rasops_init is `mov $0x30,%eax; ret`;
  the new one stores `ri_font` (+0x20).
- **Attach order (F1):** DDI attach does `gfxp_fb_attach` and creates `text-0` (DDI_NT_DISPLAY) before `card0` and
  `renderD128` (DDI_NT_DISPLAY_DRM), so tem's "first minor" is the gfxp console, as on vgatext. The OpenBSD
  inteldrm attach (the modeset) runs from the first open of card0/renderD128 (`inteldrm_ca` is referenced only from
  `i915_il_open`, gobjdump). So **binding i915 instead of vgatext keeps the same console**, which answers 4(b):
  no new console code, the vgatext one, **until the first drm open**. While a DRM master exists, text-0 goes
  KD_GRAPHICS; when it goes, `drm_client_dev_restore` then KD_TEXT repaints from gfxp_bitmap's shadow copy.
  OPEN RISK (not verified): gfxp draws into the GOP buffer at `fb_info.paddr` (GMADR offset 0). After the OpenBSD
  modeset that buffer is still on screen only if `intel_fbdev` inherits the BIOS plane's stolen-memory object
  (intel_plane_initial.c) and `drm_client_dev_restore` puts that framebuffer back. If it allocates a new one
  instead, KD_TEXT repaints memory nobody scans out: the console is invisible but alive, and ssh still works.
  The first load must check this, and must have a dump device ready.
- **Minors (F3):** kind(7:0) | instance(15:8) | clone(31:16); `minor()` for OpenBSD code is `getminor`
  (obsd_kern.h). Test: 524,280 opens -> 524,280 distinct drm_file keys; with the SVR3 `x & 0xff`: 8.
- **ioctl (F4):** Linux _IOC decoded, OpenBSD's re-encoded (i915_drmioc.h); 152/152 OpenBSD uapi ioctls match
  OpenBSD's own encoding, all 21 R1a ioctls present, none has an argument >= 256 bytes; reading the Linux bits as BSD
  fails 90 checks. 8/8 runs.
- **devmap (F6/F7):** the MAP_DUMB offset is looked up as OpenBSD's i915_gem_mmap does; only WC offsets (Gen9 dumb)
  are served: `pin_map(I915_MAP_WC)` -> `gfxp_umem_cookie_init` (KMEM_NON_PAGEABLE) -> `gfxp_devmap_umem_setup`
  with DDI_MERGING_OK_ACC (write-combining); unpinned on the last devmap_unmap. Other mmap types: ENOTSUP (R2).
- `selwakeup` is now `pollwakeup` on the drm_file's pollhead (was a no-op), so poll(2) on a vblank/flip event wakes.

## 1. Prerequisite: a crash dump device (needs maintainer approval; NOT done)

Same as iwm section 1, and the same request (/tmp/streamD-dump-request.md):

    pfexec zfs create -V 4G rpool/dump
    pfexec dumpadm -d /dev/zvol/dsk/rpool/dump -s /var/crash/dixi -y
    pfexec dumpadm            # expect: Dump device: /dev/zvol/dsk/rpool/dump (dedicated)

The i915 attach writes GPU registers (forcewake, GGTT PTEs, display PLLs) on the device that carries the console.
A hang or panic there takes the screen with it, so a dump is the only evidence that survives. Also have an ssh
session open from floki before every step below: once the display is lost, ssh is the only console.

## 2. Firmware (PLANNED; not needed for the first load)

CFL display needs no firmware for a modeset. DMC (`i915/kbl_dmc_ver1_04.bin`) only enables display C-states, and
GuC/HuC are off by default before Gen12 (`gt/uc/intel_uc.c`). `loadfirmware` resolves through firmware(9F) under
`drm/` in the module path; a missing DMC blob makes inteldrm log it and continue without DC states.

## 3. Load with no major binding (PLANNED; needs approval after step 1)

    pfexec modload /home/gburd/streamE4/mod3/i915      # expect ENXIO "no major number for i915", as iwm did
    modinfo | grep i915                                # expect nothing left loaded

This exercises only krtld's relocation of a 5.5 MB module against the running kernel (the gate above, done for real).
`_init` is not reached without a major. Then, as iwm step 3A, **with no alias**:

    pfexec add_drv -n i915 && pfexec rm /reconfigure   # name_to_major only; no alias, nothing binds
    pfexec /usr/sbin/drvconfig -b -i i915 -m <major>
    pfexec modload /home/gburd/streamE4/mod3/i915      # runs _init: obsd_compat_init (taskq, jiffies periodic,
    modinfo | grep i915                                #   vm registry, SMBIOS strings), mod_install
    pfexec modunload -i <id>                           # runs _fini: mod_remove + obsd_compat_fini

Repeat >= 8 times (judge by rate, report clustering). Expected: 8/8 load + unload, no panic, the display@2 node
still bound to vgatext (`prtconf -D`), `modinfo` shows `i915 (OpenBSD inteldrm, Gen9)` while loaded. This tests the
compat layer's init/fini, which is real code (ddi_periodic, taskq_create, avl, tsd), but not the attach.

Back-out: `pfexec rem_drv i915`; compare /etc/{name_to_major,driver_aliases,minor_perm,driver_classes},
/etc/security/{device_policy,extra_privs} and /etc/path_to_inst against copies taken before step 3 (`cmp`).

## 4. The console question, answered from the source (REAL reading; not tested)

Today: `vgatext` instance 0 owns display@2 (major 351, `/dev/fb`, `/dev/vt00`), and its console is `gfxp_bitmap`
drawing into the GOP framebuffer at `fb_info.paddr = 0x40_00000000`. That address is BAR2 (GMADR) of this
very device, at aperture offset 0 (x1-gpu-route.md section 1, measured).

**illumos side.** `vgatext` -> `gfxp_fb_attach` -> `gfxp_bm_attach` maps `fb_info.paddr` with
`gfxp_map_kernel_space(..., GFXP_MEMORY_WRITECOMBINED)` and hands tem the polled-I/O callbacks
(`bitmap_polled_display/copy/cursor`). The device node carries `ddi-no-autodetach=1` (prtconf, measured), and
`vgatext_detach(DDI_DETACH)` -> `gfxp_bm_detach` unmaps the framebuffer, but tem keeps the console stream open, so
the node is never detached while it is the console. There is no handover protocol: illumos has no equivalent of
Linux's `aperture_remove_conflicting_devices` or OpenBSD's `efifb_detach`. `KDSETMODE KD_GRAPHICS` (the X/DRM-master
path, `bitmap_kdsetmode`) is the only supported way to stop tem drawing: it stops tem's blits into the framebuffer
and gives it back on `KD_TEXT`.

**OpenBSD side.** `inteldrm_attach` checks `efifb_is_primary(pa)`, marks itself primary and console, and calls
`efifb_detach()` (efifb stops drawing, its mapping stays valid). Then `inteldrm_attachhook` -> `i915_driver_probe`
does the modeset, `intel_fbdev` allocates a new framebuffer object in stolen memory, the display plane is pointed at
it, and `rasops_init` + `wsdisplay_cnattach` move the kernel console onto that new buffer. The GOP framebuffer is not
reused once the first modeset has run (`i915_driver.c:513` `aperture_remove_conflicting_pci_devices`; the BIOS's
initial plane config is read back by `intel_initial_plane_config` only to inherit the boot mode).

**What happens on dixi if i915 binds display@2 as written (i915_illumos.c):**
1. The node is bound to i915 *instead of* vgatext (one driver per node). For that, vgatext must detach first,
   which the console prevents (ddi-no-autodetach + tem). **So `update_drv -a -i '"pciex8086,3e9b"' i915` alone will
   not take the device**: the alias is written, the rebind fails while vgatext holds it, and it takes effect at the
   next boot, when i915 attaches first and vgatext never does.
2. At that next boot, with i915 bound: the early boot console is the kernel's boot framebuffer console on
   `fb_info`, but no vgatext attaches to hand tem a display, so **what consconfig does then is NOT verified here**
   (consconfig_dacf.c was not read in this run; the expectation is that tem gets no framebuffer and the console stays
   on the boot console or serial). i915's own attach
   runs the OpenBSD modeset and then its console attach fails by design (`rasops_init` STUB in `obsd_glue.c`).
   Expected screen: the GOP image freezes, then goes black or shows i915's fbdev buffer after the first modeset. The
   kernel console is then **ssh/serial only**.
3. Nothing in this module draws a console. That is deliberate for R1a: the next design step is either
   (a) keep vgatext as the console owner and attach i915 as a *second* driver on the same function, which illumos does
   not support; or (b) give i915 a `vis_devinit`/polled-I/O console of its own on its fbdev buffer, the way
   `gfxp_bitmap` provides one (illumos `sys/visual_io.h`), so tem moves to i915 at attach. (b) is the illumos-native
   answer and the equivalent of OpenBSD's `wsdisplay_cnattach`. It is PLANNED and is the console handover work item.

(Section 0b supersedes (b) for the boot console: i915 hosts the vgatext console itself. The open risk there is
what the screen shows after the first modeset.)

**Therefore the order is:** step 3 (load, no alias) → write the (b) console handover → step 5 (alias) at a reboot,
with ssh open, a dump device, and the BE to roll back to (`beadm activate solnix-3`). Not before (b): without it, a
successful i915 attach is indistinguishable from a hang on the laptop's own screen.

## 5. The alias = the attach (PLANNED; the step that needs explicit approval, after 1, 3 and 4(b))

    pfexec update_drv -a -i '"pciex8086,3e9b"' i915     # compatible[3] of display@2 (prtconf, measured):
                                                        #   pciex8086,3e9b.17aa.2267.0, .17aa.2267, .0, pciex8086,3e9b, ...
    pfexec reboot                                       # vgatext cannot detach from the console node (4.1)

Expected, once 4(b) exists: `i915%d: coffeelake gen9 gt2, OpenBSD inteldrm attach`, then OpenBSD's own
`inteldrm0: msi, COFFEELAKE, gen 9` line, then `drm0` attach messages, `/dev/dri/card0` present (open returns ENXIO
until drmopen is wired), and the console on i915's fbdev.

Back-out (from ssh, or the bootloader's BE menu): `pfexec update_drv -d -i '"pciex8086,3e9b"' i915`,
`pfexec rem_drv i915`, reboot; or `beadm activate solnix-3` and reboot, which also drops /etc changes. NixOS
equivalent: the driver would be a declarative `boot.kernelModules`/driver entry in the generation, so a rollback is
selecting the previous generation; solnix should do the same once this works (iwm ATTACH-PLAN section 6).

## 6. Known gaps that a first attach will hit (PLANNED, from the code)

- cdev (written, never run): open/close/read/ioctl/chpoll/devmap are wired (section 0b), but no path of it has executed.
  Known ceilings: a failed `devmap_device` after `i915_il_devmap` leaks the pin and its cookie (bounded by failed mmap
  calls); KDSETMODE switches only on open/close/SET_MASTER/DROP_MASTER, not on the master's process dying without a
  close (the close does run on exit, so this is the same path).
- bus_dma is a stub (ENOTSUP): any GEM object that needs `drm_dmamem_alloc` (phys objects, cursor on old gens) fails.
  CFL cursor and fbdev use stolen/shmem objects (uao + GGTT through BAR0), which are implemented.
- `pci_find_device` walks the whole illumos tree (MAP); `intr_barrier` is a disable/enable pair (MAP).
- uao objects are wired at creation (no swap): a 4K fbdev buffer is 33 MB of locked kernel memory.
- No suspend/resume (DDI_SUSPEND refused), no detach (OpenBSD has none either).
