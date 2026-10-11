# i915 console handover: recovered candidate, not validated runtime

Status: **UNREVIEWED external implementation; boot-failure phase UNKNOWN.**
See [the runtime audit](../../../docs/x1-gpu-runtime-audit.md) for crash evidence,
source provenance, and the bounded diagnostic plan. This does **not** close
ATTACH-PLAN section 4(b) or authorize another attach.

## Candidate and operator record

The earlier build record names `dixi:/home/gburd/gpu-console/c3/i915`, ELF64 ET_REL
AMD64, 4,815,280 bytes, SHA-1 `1dacd9aede76774823f33953c8bbbff488f74311`.
The read-only audit confirmed that file's hash. Earlier build gates reported zero
unresolved symbols/collisions and four globals (`_init/_fini/_info/_depends_on`,
with `_depends_on = misc/gfx_private`). These are link checks, not runtime proof.
A later c4 artifact has the same size but SHA-1
`ceff98ca49faf86eb8825c4f3ae237220bcd64da`.

**Operator record, supplied by the maintainer:** candidate c3 (hash prefix
`1dacd9ae`) was copied into `solnix-4`, followed by a reboot around
**2026-10-11 03:23:42 UTC**. The user reported a boot loop. The orchestrator issued
no explicit DRM open. This is not independent proof of what the loader loaded,
or proof that no other process opened card0/renderD128.

The audit found only the old iwm attach panic in `/var/crash/dixi`; the compressed
and decompressed `.0` files represent the same crash. No matching saved i915 dump
was found there. The earlier “nothing has run” claim is withdrawn; which paths
ran during the reported attempt remains unknown.

## Source is missing from the repository implementation

At audited HEAD `739f67c59c98621c5d8bd6032573fa6d54917666`, repository
`i915_illumos.c` has 679 lines and uses gfxp for the text console; it has no
`i915_cons_modeset_done`. Repository `i915_drmglue.c` has no `i915_glue_fbinfo`.

The recovered workspace `dixi:/home/gburd/gpu-console/port/i915/` contains the
1,119-line console version and its glue/header additions. It is preserved in
`/tmp/streamGPU-resume.WIP/dixi-console-source-complete.tar`. A workspace snapshot
is not a reproducible source manifest for c3 or proof of the failed boot binary.
The [source-reconciliation diff](../../../docs/x1-gpu-console-reconciliation.diff)
is review-only; it has **not** been merged into the driver.

## Separate phases (source reading, not observed boot sequence)

1. **DDI attach:** PCI identification, `gfxp_fb_attach`, then `text-0` before
   card/render minors. No OpenBSD inteldrm attach occurs here. In the reviewed
   illumos source, `gfxp_bm_attach` installs callbacks; subsequent text-console
   `VIS_DEVINIT` performs bitmap initialization/mapping. A DDI return alone does
   not prove tem initialized or displayed text.
2. **First card/render open:** both repository and recovered versions call
   `i915_il_drm_attach` here, under `il_lock`, then OpenBSD inteldrm/probe/modeset.
   Opening text-0 alone routes to gfxp and does not trigger that path.
3. **Proposed fbdev handover, recovered version only:** `i915_glue_fbinfo` reads
   `drm_i915_private->ro`; `i915_cons_modeset_done` selects the buffer and supplies
   visual_io callbacks through the captured `modechg_cb`. After `ic_switched`,
   normal console ioctls use i915's draw routines. Runtime correctness is unproven.

The DDI message `console on gfxp_fb; OpenBSD inteldrm attach on first open` marks
code progress, not successful text initialization. The later message
`console on fbdev framebuffer ...` does not prove repaint, polled-console
replacement, scanout or kernel liveness. Missing messages cannot locate a fault
that occurred before persistent logging. A black panel alone does not distinguish
bad scanout from a hung kernel.

## Callback limitations and review blockers (REAL source findings)

- Recovered `i915_cons_modeset_done` sets `ic_switched = 1` and prints success
  even when `ic_modechg_cb == NULL`. The earlier claim that a missing callback
  leaves the console state unchanged was wrong.
- In `/tmp/streamE5-illumos/tem.c`, `tems_modechange_callback` compares only
  geometry/depth and returns immediately when they match. Passing a new buffer
  with the same 3840x2160/32bpp mode therefore does not force a repaint. The same
  limitation applies to using that callback for KD_TEXT restoration.
- That cached tem source assigns `ts_fb_polledio` during initial `VIS_DEVINIT`,
  not in the modechange callback. Supplying a new `polledio` pointer to the latter
  does not replace panic/kmdb console callbacks. Match this source to the exact
  target kernel before selecting a handover mechanism.
- The recovered VIS_DEVINIT interception captures callback pointers before
  gfxp's kernel-only check; review the FKIOCTL trust boundary before reuse.
- The recovered code supports 16/24/32bpp, but copy/cursor paths read framebuffer
  memory. “Never reads back” was false; neither safety nor speed was validated
  by this audit. `rasops_init` remains a metrics-only stub, not a tem handover.
- `test/test_console.c` duplicates draw arithmetic against RAM. It does not test
  the production draw routines, DDI attach, callback lifetime or tem integration.

These are source-review findings, **not a diagnosis of the reported boot loop**.
Handover code runs only after deferred DRM attachment in the reviewed candidate.

## Recovery and next step

Do not rely on SSH `dmesg` as an independent console or on at/cron for a
pre-userspace hang. EC2 `get-console-output` is not a laptop console facility.
A dump configuration cannot guarantee a dump from a hard hang. A persistent
alias can cause retries but does not explain the original fault; there is no
established `bootadm -R` archive-corruption diagnosis.

Before any separately approved runtime test, require exact candidate/kernel
provenance, independent early-output capture if available, a physically present
operator and a known-good boot selection without the experimental binding.
Neither an SSH cleanup nor a named historical BE is a guaranteed back-out.
First reconcile and review the source, then use the small test-first proposal
in the runtime audit. No loads, alias/BE changes or reboots are authorized here.
