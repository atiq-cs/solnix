# i915 (UHD 630, 8086:3e9b) load plan for dixi: prerequisites, steps, back-out, console handover

Status: **HOLD: reported boot loop; failing phase UNKNOWN.** This document retains
historical build evidence; it is not authorization to load, bind or reboot.
See [the runtime audit](../../../docs/x1-gpu-runtime-audit.md) and
[console source reconciliation](CONSOLE-HANDOVER.md).

**Operator record (not independent loader evidence):** the maintainer supplied a
transcript saying c3, SHA-1 prefix `1dacd9ae` (full artifact hash
`1dacd9aede76774823f33953c8bbbff488f74311`), was copied into `solnix-4`, then rebooted
around **2026-10-11 03:23:42 UTC**. The user reported a boot loop; the orchestrator
issued no explicit DRM open. This neither proves what the loader loaded nor
excludes another process opening card0/renderD128.

The read-only audit found one saved iwm attach panic, not a matching i915 dump.
DDI attach/text-console initialization and deferred inteldrm modeset are separate;
which failed is unknown. Alias persistence explains repeated attempts, not the
original fault. No evidence establishes `bootadm -R` archive corruption.

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

At the E4 checkpoint these kernel paths had not been exercised. That historical
statement is not evidence of what ran during the later reported boot loop.
`ddi_regs_map_setup`, MSI, device-tree walking, `hat_devload`, contig_alloc and
OpenBSD attach still lack validation from a matching runtime record here.

## 0b. The cdev and console (historical E5 build; runtime not validated)

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
  `i915_il_open`, gobjdump). This intends to retain the GOP console until the first
  DRM open; it does not prove that DDI attach, text `VIS_DEVINIT`, or drawing succeeds.
  While a DRM master exists the code requests KD_GRAPHICS; on release it requests
  `drm_client_dev_restore` then KD_TEXT. After modesetting, gfxp may repaint a GOP
  buffer that is no longer scanned out. Neither a black panel nor a callback/log
  establishes kernel liveness or SSH availability.
  The separate c3 handover implementation is absent from repository source and
  unreviewed: same-mode tem callbacks need not repaint, do not replace polled-I/O
  pointers in the cached tem source, and the recovered workspace code logs success
  even without a callback (its exact correspondence to the c3 binary is unproven).
  See CONSOLE-HANDOVER.md; section 4(b) is not closed.
- **Minors (F3):** kind(7:0) | instance(15:8) | clone(31:16); `minor()` for OpenBSD code is `getminor`
  (obsd_kern.h). Test: 524,280 opens -> 524,280 distinct drm_file keys; with the SVR3 `x & 0xff`: 8.
- **ioctl (F4):** Linux _IOC decoded, OpenBSD's re-encoded (i915_drmioc.h); 152/152 OpenBSD uapi ioctls match
  OpenBSD's own encoding, all 21 R1a ioctls present, none has an argument >= 256 bytes; reading the Linux bits as BSD
  fails 90 checks. 8/8 runs.
- **devmap (F6/F7):** the MAP_DUMB offset is looked up as OpenBSD's i915_gem_mmap does; only WC offsets (Gen9 dumb)
  are served: `pin_map(I915_MAP_WC)` -> `gfxp_umem_cookie_init` (KMEM_NON_PAGEABLE) -> `gfxp_devmap_umem_setup`
  with DDI_MERGING_OK_ACC (write-combining); unpinned on the last devmap_unmap. Other mmap types: ENOTSUP (R2).
- `selwakeup` now calls `pollwakeup` on the drm_file's pollhead (was a no-op).
  This wires the intended wakeup path; event delivery still needs runtime proof.

## 1. Dump evidence and recovery prerequisites (HOLD)

The audit read `/etc/dumpadm.conf`: device `/dev/zvol/dsk/rpool/dump`, save directory
`/var/crash/dixi`, kernel content, enabled saves and compression. The older claim
that no dump device was configured is stale. No device was probed or changed.
`vmdump.0` and `{unix,vmcore}.0` represent the same Oct 10 iwm attach panic
(UUID `c5e7bb76-9c12-4afa-b27d-b4f8126a5999`); `bounds` is 1.

Configuration is not proof that dumping worked during the i915 attempt. A hard
hang may produce no dump. SSH requires a functioning kernel/network; at/cron
cannot recover a pre-userspace hang. Independent early capture and a physically
present operator with a known-good boot selection are prerequisites for any
separately approved retry. No recovery or dump-setup commands are authorized here.

## 2. Firmware (PLANNED; not needed for the first load)

CFL display needs no firmware for a modeset. DMC (`i915/kbl_dmc_ver1_04.bin`) only enables display C-states, and
GuC/HuC are off by default before Gen12 (`gt/uc/intel_uc.c`). `loadfirmware` resolves through firmware(9F) under
`drm/` in the module path; a missing DMC blob makes inteldrm log it and continue without DC states.

## 3. No-alias load stage (historical proposal, NOT authorized)

The original proposal used E4 `/home/gburd/streamE4/mod3/i915` to test relocation,
then driver registration without a device alias to test compat init/fini, followed
by scoped load/unload trials. It did not test DDI attach or deferred modeset.
That old module must not substitute for a reconciled candidate.

The audit found `mod_installdrv: no major number for i915` warnings at Oct 10
18:47:14 and 18:47:53 in `/var/adm/messages`. These messages do not prove that
`_init` was never reached: the reviewed `_init` calls `mod_install` after compat
initialization. The previous categorical claim to the contrary is withdrawn.

Do not repeat trials until candidate/kernel identity, capture and independent
recovery have been reviewed. Stop at the first new failure rather than chaining
changes; eventual repeatability results must report clustering, not just totals.

## 4. Console paths (source reading, not a boot diagnosis)

Historical measurement (`docs/x1-gpu-route.md` section 1): vgatext instance 0 owned
display@2, major 351, `/dev/fb` and `/dev/vt00`. GOP framebuffer physical address
`0x40_00000000` is BAR2/GMADR offset 0. This is not a fresh binding observation.

**illumos:** vgatext hosts gfxp. In the reviewed source `gfxp_bm_attach` installs
callbacks; bitmap console initialization maps `fb_info.paddr` with write-combining
and tem obtains polled-I/O pointers through `VIS_DEVINIT`. The console stream and
`ddi-no-autodetach` prevent treating a live alias change as a safe console handoff.
KD_GRAPHICS/KD_TEXT manage drawing; they do not establish GPU scanout ownership.

**Repository i915:** `i915_il_attach` does PCI setup, gfxp attach and text/card/render
minor creation. Text open/ioctl routes to gfxp. Only a card/render open calls
`i915_il_drm_attach` and OpenBSD inteldrm/probe/modeset. DDI completion is not proof
of text-console initialization, and binding is not proof of deferred modesetting.
The earlier description of DDI attach immediately running inteldrm was for the
superseded E4 code, not this implementation.

**4(b), fbdev handover remains OPEN:** recovered console workspace code adds draw
routines, `i915_glue_fbinfo` and `i915_cons_modeset_done`, but none is in repository
implementation at audited HEAD. In cached `tem.c`, unchanged geometry/depth makes
`tems_modechange_callback` return without repainting; it does not replace
`ts_fb_polledio`. The recovered driver sets its switched flag/logs success even
with no callback. These facts invalidate the claimed proof of handover, but do
not locate the historical boot fault. Match the exact kernel source before
choosing a repair; do not merge the review-only reconciliation diff wholesale.

## 5. Binding and first DRM open (separate future approvals)

A persistent alias can select the experimental driver on subsequent boots even
when a live console owner could not detach. That explains repeated exposure,
not the first crash. Retire the former “alias = attach = modeset” expected sequence.

The next runtime plan, if approved, must separate:

1. Driver initialization, DDI attach and text `VIS_DEVINIT`, with independently
   controlled/observed absence of automatic DRM openers.
2. A single explicit card/render open, then inteldrm return and console handover.

The cdev is wired in the repository; the old “open always returns ENXIO until
wired” statement is stale. Successful open/modeset/scanout remains unvalidated.
A success line alone proves none of the latter properties.

Follow the NixOS generation-selection model for recovery, but first verify a
known-good selectable environment without the experimental binding. Do not assume
historical `solnix-3`, an SSH cleanup, or a timer is a working back-out. No alias,
BE, reboot or live-load command is authorized by this document. See the audit's
bounded plan before drafting a new operator procedure.

## 6. Known gaps (source findings, not historical fault attribution)

- cdev: open/close/read/ioctl/chpoll/devmap are wired (section 0b), but no matching runtime evidence validates them.
  Known ceilings: a failed `devmap_device` after `i915_il_devmap` leaks the pin and its cookie (bounded by failed mmap
  calls); KDSETMODE switches only on open/close/SET_MASTER/DROP_MASTER, not on the master's process dying without a
  close (the close does run on exit, so this is the same path).
- bus_dma is a stub (ENOTSUP): any GEM object that needs `drm_dmamem_alloc` (phys objects, cursor on old gens) fails.
  CFL cursor and fbdev use stolen/shmem objects (uao + GGTT through BAR0), which are implemented.
- `pci_find_device` walks the whole illumos tree (MAP); `intr_barrier` is a disable/enable pair (MAP).
- uao objects are wired at creation (no swap): a 4K fbdev buffer is 33 MB of locked kernel memory.
- No suspend/resume (DDI_SUSPEND refused), no detach (OpenBSD has none either).
- PRIME/hybrid: the module links **OpenBSD DRM, not C1**. `obsd_glue.c` has
  `fdalloc = ENOTSUP`, `fd_getfile/fnew = NULL`; OpenBSD dma-buf attach is a stub,
  and foreign i915 GEM import falls through the non-`notyet` path to `panic`.
  Do not enable fds alone and call this working hybrid support. Separate C1
  PRIME's same-device table is not an OpenBSD cross-driver bridge.
