# i915 console handover: the design decision, with mechanism-level evidence

Scope: design (and, where a correct one exists, build) a SAFE illumos-native console
handover for i915 on the X1 (Comet Lake iGPU, `pciex8086,3e9b`, Gen9). This supersedes
the recovered `i915_cons_modeset_done`/`modechg_cb` path that
`CONSOLE-RECONCILIATION-DECISION.md` flagged as both a kernel-RCE and ineffective.

Pinned illumos reference: `/tmp/streamE5-illumos/` (tem.c sha256
`3d925906b4534635795c16f5a96c0fd9080ae6709c6fb6084a7bbad614d301fa`, plus gfxp_fb.c,
gfxp_bitmap.c, consconfig_dacf.c, wscons.c, visual_io.h). Pinned OpenBSD reference:
`/tmp/streamE5-obsd/obsd-drm` (rev `37a498de2f7aa77a9e30afd65012af6434819316`).

## Decision

**illumos has NO supported live console handover. Console binding is boot-time only, and
is one-shot.** There is no supported mechanism for a driver to take tem's console (text
*or* panic/kmdb polled) away from the framebuffer tem bound at boot. The recovered
`modechg_cb` design did not just do it unsafely — it aimed at a handover illumos does not
implement.

Consequence for i915 on the X1: **the console stays on `gfxp_fb` (the firmware GOP
framebuffer) exactly as the repo source already does.** No console code is folded. A
corrected *boot-time* i915 console is possible in principle but is **structurally blocked
on this hardware** (see §4) by a second, independent fact: inteldrm's own framebuffer
(`ri_bits`) does not exist until the deferred modeset, which runs *after* boot-time
VIS_DEVINIT.

This is a VALUABLE negative result. It converts a 440-line "handover" that cannot work
into one sentence the next bring-up can rely on, and it tells `STAGED-ATTACH-PLAN.md`'s
stage-2 black-panel caveat *why* it is correct rather than merely cautious.

## 1. How illumos legitimately owns the tem console (the supported path)

Traced end to end in the pinned source:

1. **Boot picks exactly one framebuffer.** `consconfig_dacf.c` reads `sp->cons_fb_path`
   (from firmware `output-device` / the boot framebuffer), holds the dip with
   `e_ddi_hold_devi_by_dev`, and checks the driver's `tem-support` property
   (`consconfig_tem_supported`, L504) *without opening it* — "some video cards … could
   hang or crash if opened too early during boot."
2. **One `WC_OPEN_FB`.** `consconfig` sends `wc` (the workstation-console STREAMS mux)
   `WC_OPEN_FB` with the fb path (`consconfig_dacf.c` L938). `wc`'s handler
   (`wscons.c` L928) is `secpolicy_console`-gated and calls `tem_info_init` **once**.
3. **One VIS_DEVINIT, kernel-only.** `tem_info_init` (tem.c L420, comment *"only called
   once during boot"*) opens the fb via `ldi` and issues a single
   `ldi_ioctl(VIS_DEVINIT, …, FWRITE|FKIOCTL)` (L466). The framebuffer driver fills in
   `vis_devinit`: geometry, depth, `color_map`, mode, and crucially
   `polledio` — its panic/kmdb draw routines. tem stores
   `tems.ts_fb_polledio = temargs.polledio` (L484) and keeps `tems.ts_hdl` (the ldi
   handle) for all later `VIS_CONSDISPLAY/COPY/CURSOR/CLEAR` (the `tems_*_layered`
   helpers, all `FKIOCTL`).
4. **gfxp enforces kernel-only.** `gfxp_fb.c do_gfx_ioctl` (L354):
   `case VIS_DEVINIT: if (!(mode & FKIOCTL)) { "kernel only"; return ENXIO; }`. A userland
   open of the text minor cannot initialise the console or hand in a `polledio`/`modechg_cb`
   pointer. `VIS_CONSDISPLAY/COPY/CURSOR` take `ddi_copyin`'d request structs but the
   framebuffer pointer is the driver's own `softc->console->fb.fb` (set from `fb_info.paddr`
   in `bitmap_setup_fb`), never a userland pointer.

That is the whole ownership contract. The console framebuffer, the text-draw path, and the
panic/kmdb polled path are all bound in that single boot-time VIS_DEVINIT.

## 2. Why there is no supported LIVE handover (the three locks)

Each of these is a hard, independent block, confirmed in the pinned tree:

- **The one-shot guard.** `tem_info_init` begins `if (tems.ts_initialized) { return 0; }`
  (tem.c L431). `tems.ts_initialized` is set to 1 exactly once (L520) and is **never
  cleared anywhere in the tree** (`grep ts_initialized` → three sites: two reads, one set).
  A second `WC_OPEN_FB` therefore returns success having done nothing — no new VIS_DEVINIT,
  no new `ts_fb_polledio`, no rebind.

- **No unbind.** `WC_CLOSE_FB` (wscons.c L1005) is a documented stub: *"There's nothing
  that can call this, so it's not really implemented."* There is no path to release the
  framebuffer tem bound at boot.

- **The polled pointer and the repaint are reachable only through VIS_DEVINIT.**
  `ts_fb_polledio` is assigned only at tem.c L484. The modechange path
  (`tems_modechange_callback`, L~660) never touches it, and begins
  `diff = tems_check_videomode(devinit); if (diff == 0) return;` (L~670). A handover at the
  **same** geometry/depth (the common 3840×2160/32bpp case) gives `diff == 0`, so tem
  returns immediately: no repaint, no pointer move. `tem_register_modechg_cb` registers an
  *upper-layer consumer* callback (wscons' `wc_modechg_cb`) that fires only on a
  **dimension** change and only after tem has already reinitialised its own buffers; it is
  not a driver-takeover hook.

This is precisely the two defects `CONSOLE-RECONCILIATION-DECISION.md` named — the RCE
(capturing `modechg_cb`/`modechg_arg` from a non-FKIOCTL ioctl) and the ineffectiveness
(same-mode `modechg_cb` moves nothing) — and the mechanism root of both is the same: the
only interface that sets the console up is the one-shot, kernel-only VIS_DEVINIT, and the
recovered code tried to substitute the modechange callback for it.

## 3. Why the OpenBSD / FreeBSD / XNU model does not map

- **OpenBSD** `inteldrm` takes the console at attach via
  `wsdisplay_cnattach(&inteldrm_stdscreen, ri->ri_active, …)` (i915_driver.c L2500). This
  works because OpenBSD's `wsdisplay` is designed around the *driver's own* `rasops_info`
  (`ri_bits`): the console abstraction follows whichever driver calls `wsdisplay_cnattach`.
  **illumos has no `wsdisplay`.** The port stubs `wsdisplay_cnattach` to a no-op
  (`obsd-compat/obsd_glue.c` L392) and `rasops_init` to a metrics-only stub, because the
  illumos console is `tem` + `visual_io` + `gfxp`, not rasops/wsdisplay. Importing the
  wsdisplay model would mean building a console subsystem illumos does not have.
- **FreeBSD** `vt(4)` and **XNU** `IOFramebuffer` likewise have a console layer that a KMS
  driver registers *into* at runtime (`vt_allocate` / `IOFramebuffer::doSetup`). illumos
  `tem` has no runtime register-a-new-backend entry; its backend is fixed by the boot
  VIS_DEVINIT (§1–§2).

So the "console follows the KMS driver after modeset" model that all three BSD/XNU share is
exactly the model illumos lacks. Mapping it onto `tems_modechange_callback` is what produced
the ineffective recovered code.

## 4. Why even a boot-time i915 console is blocked on the X1 (second, independent fact)

The honest fallback — *"the console moves only at boot, when i915 binds the display before
gfxp/vgatext and serves tem its own framebuffer"* (the path `STAGED-ATTACH-PLAN.md`
assumes) — is implementable in principle: give i915 a `tem-support` property and a
gfxp-style `visual_io` console (FKIOCTL-gated VIS_DEVINIT, polledio over i915's own buffer).
But on **this** hardware it cannot produce output, for a reason unrelated to tem:

- i915's own scanout buffer is `drm_i915_private->ro.ri_bits`, populated by the OpenBSD
  modeset (`inteldrm_attachhook` → `rasops_init`, i915_driver.c L2454: `if (ri->ri_bits ==
  NULL) goto fail`). The repo defers that modeset to the **first card0/renderD128 open**
  (`i915_illumos.c i915_il_drm_attach`). Boot-time VIS_DEVINIT runs during `consconfig`,
  *before* any DRM open. **At VIS_DEVINIT time `ri_bits == NULL`.** i915 has no buffer to
  give tem.
- inteldrm never becomes the console on its own terms either: `dev_priv->console` is set
  from `vga_is_console()` (stubbed → 0, obsd_glue.c L390), `efifb_is_console()`
  (`NEFIFB == 0`, no efifb on illumos), or forced `= 1` only for Meteor Lake. The X1 is
  Comet Lake, so `dev_priv->console` stays 0 and `wsdisplay_cnattach` at i915_driver.c
  L2489 is never reached. inteldrm *does* fill `ri_bits` for its mode/backlight helpers, but
  only post-modeset.

The only way i915 could own a valid same-mode console buffer at boot is for its modeset to
**inherit the firmware GOP framebuffer as its fbdev scanout** (keep scanning out
`fb_info.paddr` rather than allocating a fresh plane) — an `intel_initial_plane_config` /
fb-inheritance change inside inteldrm, far outside the console contract, and still gated on
the modeset running at all. That is a separate, large piece of work and is explicitly out of
scope here; it is noted so the next bring-up knows the one real lever.

Therefore: **nothing in this task can make i915 paint the console on the X1 today.** The
correct and honest state is the repo's current one — console on `gfxp_fb` (GOP), i915 as a
render/mode device opened on demand.

## 5. What is correct to ship

Given §1–§4, the laziest *correct* change set is: **ship no console-handover code** (the
repo's `gfxp_fb` console is already the only working console path), and make the contract
**verifiable** so no future "success" log can lie:

1. Repo driver source unchanged (console stays on `gfxp_fb`). This is the module
   `STAGED-ATTACH-PLAN.md` already describes.
2. `test/test_console.c` extended with a **positive model of the correct mechanism**
   (FKIOCTL-gated VIS_DEVINIT: userland rejected; kernel VIS_DEVINIT moves `ts_fb_polledio`
   AND marks a repaint) in addition to the existing refutation of the modechange path — each
   with a negative control that must FAIL. See §6.
3. The module built and gate-checked on dixi (unchanged source) to confirm the gate still
   passes against the running kernel, per `CONSOLE-RECONCILIATION-DECISION.md`'s rationale.

## 6. Making correctness verifiable (test design)

`test/test_console.c` already (a) characterises the draw arithmetic against a RAM buffer
with a `SABOTAGE` control and (b) models `tems_check_videomode`/`tems_modechange_callback`
with a `SABOTAGE_TEM` control that proves the modechange path neither repaints nor moves the
polled pointer at same mode. This design adds a third part:

- **Part C — the VIS_DEVINIT ownership contract (the *correct* mechanism).** Model
  `do_gfx_ioctl`'s VIS_DEVINIT gate verbatim (gfxp_fb.c L354–L367): userland (`mode` without
  `FKIOCTL`) → `ENXIO`, pointer NOT captured; kernel (`FKIOCTL`) → devinit runs, tem adopts
  `polledio`. Assert:
  1. a userland VIS_DEVINIT returns `ENXIO` and leaves `ts_fb_polledio` unchanged (the RCE
     the recovered code enabled is refused);
  2. a kernel VIS_DEVINIT moves `ts_fb_polledio` to the new buffer AND repaints — the ONLY
     path that does both;
  3. negative control `SABOTAGE_DEVINIT`: a build that (wrongly) captures the pointer from a
     userland VIS_DEVINIT, or (wrongly) claims the move happened without it — must FAIL.

REAL-vs-MODEL tagging: the gate comparison and the five tem fields read by
`tems_check_videomode` are transcribed verbatim from pinned source and labelled MODEL
(`tem_impl.h` / `gfxp_fb_softc` are private kernel headers absent from the gate proto, so
the real bodies cannot be linked in userland). The draw arithmetic (Part A) is REAL math
against a RAM buffer. Nothing here exercises DDI attach or a GPU; it proves the *contract*,
which is exactly what the recovered success-log could not.

## 7. Effect on STAGED-ATTACH-PLAN.md

**Confirms it; tightens one sentence.** The plan already keeps the console on `gfxp_fb`
through both stages and warns (stage-2 caveat) that after a successful modeset the panel may
go black because "this module does not hand the console over to i915's fbdev buffer." This
design upgrades that from a module limitation to a platform fact: *live handover is
impossible in illumos, and a boot-time i915 console is additionally blocked on the X1 until
inteldrm inherits the GOP framebuffer at modeset.* Stage 2 must therefore be judged by
SSH/deadman liveness + `i915_glue_drm_unit >= 0`, never by the panel — not as a caution but
because there is no code path, present or possible-without-inteldrm-changes, that would keep
the panel lit after the modeset. No change to the stages themselves.

## 8. Provenance / licence

No source was imported. The illumos mechanism analysis cites CDDL files
(`/tmp/streamE5-illumos/*`, CDDL 1.0 headers intact). The OpenBSD comparison cites BSD/MIT
`inteldrm` (`/tmp/streamE5-obsd`); the only OpenBSD symbols already in the tree
(`wsdisplay_cnattach`, `rasops_*`) are the port's own no-op/metrics stubs in
`obsd-compat/obsd_glue.c`, not imported OpenBSD code. **No GPL is involved**; the Linux
`drm/i915` core in the port is the OpenBSD derivative (BSD/MIT), and nothing in this design
touches GPL-licensed source. The test's modelled snippets are short factual transcriptions
of CDDL control flow for a compatibility/interoperability check, attributed inline.
