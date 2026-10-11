# i915 console-handover source reconciliation: fold/flag decision

Scope: review `docs/x1-gpu-console-reconciliation.diff` (+513/-8, the recovered 1119-line
console `i915_illumos.c` plus `i915_glue_fbinfo`/`struct i915_fb_desc`) hunk-by-hunk against
repo HEAD `src/drm-port/i915/{i915_illumos.c,i915_drmglue.c,i915_drmglue.h}` and the pinned
illumos reference `/tmp/streamE5-illumos/{tem.c,gfxp_fb.c}`. Decide what is correct and safe
to bring into repo source now vs what is unproven/unsafe.

Provenance verified: `git apply` of the diff onto HEAD yields files byte-identical to the
recovered tar (`/tmp/streamGPU-resume.WIP/dixi-console-source-complete.tar`). The diff *is* the
full recovered implementation. All `sys/visual_io.h` types it names exist in the gate proto on
dixi and the field order of `i915_cons_fill_devinit` matches the header.

## Verdict: fold NOTHING of the runtime handover path. Flag the whole thing.

This refutes the plan's implied "bring in the DDI/text-console attach path and the visual_io
console." The DDI/text-console attach path is **already in repo HEAD** and unchanged by the diff;
the diff only adds the *post-modeset fbdev handover*. That handover, as written, is both
**ineffective** (does not actually move the console) and **unsafe** (userland kernel-callback
injection), and is unproven at runtime. Folding it would add 513 lines of attack surface and
dead/incorrect logic for zero verified benefit. The audit's own sequencing — "first make the
tem-callback limitation an executable check, do not start by merging the renderer" — says the
same thing.

What stays in repo HEAD unchanged: `_init`, `i915_il_attach` (gfxp_fb_attach + text-0/card0/
renderD128 minors, F1 order), deferred `i915_il_drm_attach` on first card/render open, the cdev
(open/close/read/ioctl/chpoll/devmap), `i915_il_console_sync` (gfxp KDSETMODE path). None of
these is touched by my decision.

## Hunk-by-hunk

### H1 — `#include <sys/visual_io.h>` (i915_illumos.c @@36)
Harmless on its own. **Flag** (only needed by the flagged code).

### H2 — `struct i915_console` + `il_cons` field (i915_illumos.c @@48, @@90)
Pure state for the fbdev console. Correct types. **Flag**: no safe consumer once the handover
is flagged.

### H3 — draw routines `i915_cons_{pixel,bpp,display,copy,cursor,clear}` (i915_illumos.c @@119)
The offset arithmetic is **correct** and mirrors `gfxp_bitmap`'s `bitmap_cons_*` (row-stride
blit, bottom-up vs top-down overlap in copy, clip to buffer). This is exactly what the existing
`test/test_console.c` already characterizes against a RAM buffer with a working SABOTAGE negative
control.
Two true statements the docs got wrong, now confirmed against source:
- copy (`memmove` with src in `fb_bits`) and cursor (`row[x*bpp+b] = ~row[...]`) **read** the
  framebuffer. On the WC scanout mapping that is the ~67 MB/s read path, not "never reads back."
- clear/display are write-only and fine.
Correct in isolation, but these are `static` and have **no caller** except the flagged ioctl
and polled paths. Folding them alone = dead code. **Flag.** (Their behavior is covered by the
test, so nothing is lost by not folding them.)

### H4 — polled-I/O trampolines `i915_cons_polled_{display,copy,cursor}` (i915_illumos.c @@119)
Lock-free, touch only `ic_fb`. Structurally correct for panic/kmdb context. BUT they are only
reachable if tem's `ts_fb_polledio` is actually repointed at `ic_polledio` — which it is **not**
(see H6). So in the recovered design these trampolines are never called in polled context; the
panic/kmdb console stays on gfxp's GOP pointer. **Flag.**

### H5 — `i915_cons_fill_devinit` (i915_illumos.c @@119)
Field order matches `struct vis_devinit` in the gate proto header. Correct. **Flag** (only used
by flagged paths).

### H6 — `i915_cons_modeset_done` (i915_illumos.c @@119, called from i915_il_drm_attach @@639)
**Flag — INEFFECTIVE and over-claiming.** Mechanism, from pinned `tem.c`:
- `ts_fb_polledio` is assigned **only** inside tem's `VIS_DEVINIT` handler (tem.c L484:
  `tems.ts_fb_polledio = temargs.polledio`). The modechange path
  (`tems_modechange_callback` -> `tems_setup_terminal`/`tem_reinit`) never touches
  `ts_fb_polledio`. So handing a new `polledio` to `modechg_cb` does **not** move the polled
  console onto the i915 buffer. The panic/kmdb console keeps pointing at gfxp's GOP framebuffer.
- `tems_modechange_callback` begins `diff = tems_check_videomode(devinit); if (diff == 0) return;`
  A GOP->fbdev handover at the **same** 3840x2160/32bpp geometry gives `diff == 0`, so tem
  returns immediately: **no repaint**. The normal-console repaint the handover depends on does
  not happen for the common same-mode case.
- The function sets `ic_switched = 1` and prints `?i915%d: console on fbdev framebuffer ...`
  **before** checking `ic_modechg_cb != NULL`, so the success line prints even when tem never
  sent a callback (device is not the console, or capture failed). The log is not evidence of
  handover.

### H7 — `i915_cons_ioctl` VIS_DEVINIT interception (i915_illumos.c @@119, wired from i915_il_ioctl @@863)
**Flag — SECURITY REGRESSION (hard blocker).** Mechanism, from pinned `gfxp_fb.c`:
- gfxp's `do_gfx_ioctl` explicitly rejects userland VIS_DEVINIT:
  `case VIS_DEVINIT: if (!(mode & FKIOCTL)) { "kernel only"; return ENXIO; }` (gfxp_fb.c L354).
  tem issues VIS_DEVINIT with `FWRITE|FKIOCTL` (tem.c L466), i.e. only the kernel may set the
  console up.
- The recovered `i915_cons_ioctl` copies in a `vis_devinit` and stores
  `ic->ic_modechg_cb = di.modechg_cb; ic->ic_modechg_arg = di.modechg_arg;` **with no FKIOCTL
  check**, *before* forwarding to gfxp. A userland process that opens `text-0` and issues
  VIS_DEVINIT supplies an arbitrary `modechg_cb` function pointer and `modechg_arg`, which the
  kernel then **calls** in `i915_cons_modeset_done` (L384) and `i915_il_console_sync` (L733).
  That is an arbitrary-kernel-code-execution primitive handed to any process that can open the
  console device. gfxp closes exactly this hole; the diff reopens it.
- Even the capture-only intent is wrong: it must gate on `mode & FKIOCTL` before trusting the
  pointers, exactly as gfxp does.

### H8 — `i915_cons_ioctl` draw/KDSETMODE/KDGETMODE/VIS_DEVFINI (post-switch) (i915_illumos.c @@119)
Draw cases only fire when `ic_switched` (never set safely, given H6/H7 flagged). `KDSETMODE`
sets `ic_mode = (int)arg` from a possibly-userland ioctl with no `GFXP_IS_CONSOLE`/validation
(gfxp's KDSETMODE only acts when it owns the console and the mode changed). Trust-boundary
sloppy, not code-exec. **Flag** (dead without H6/H7 anyway).

### H9 — `i915_il_console_sync` fbdev branch (i915_illumos.c @@704)
Calls `ic_modechg_cb(...)` on DROP_MASTER in the fbdev phase. Same ineffective-repaint (H6) and
same reliance on a captured callback (H7). **Flag.**

### H10 — `i915_il_ioctl` text-minor dispatch to `i915_cons_ioctl` (i915_illumos.c @@863)
Only the entry point for H7/H8. **Flag.**

### H11 — `mutex_init(&il->il_cons.ic_lock)` + `ic_mode = KD_TEXT` in attach (@@530)
Init for flagged state. **Flag.**

### H12 — `i915_glue_fbinfo` + `struct i915_fb_desc` + proto (i915_drmglue.c @@174, i915_drmglue.h)
`i915_glue_fbinfo` is a clean read-only accessor of `drm_i915_private->ro` (rasops_info): returns
ENXIO until `ri_bits != NULL`, copies geometry/stride/depth/RGB positions. No trust-boundary, no
correctness defect. BUT its **only** caller is `i915_cons_modeset_done` (flagged). Folding a
read-only accessor with no caller is pure surface. **Flag** (fold together with a corrected
handover, if/when one is designed and reviewed).

## Consequence for the module build

Because nothing of the diff is folded, the module to build and gate is the **current repo
source** (byte-identical to HEAD). That build confirms (a) the gate infra works on the restored
proto, (b) the repo as-is still links clean against the running kernel, and (c) I am not shipping
anything unproven. The recovered c3/c4 handover module is a separate artifact and is NOT what
should ship.

## What a corrected handover would need (NOT folded, NOT designed here)

For a future, separately-reviewed production patch (audit section 6 "follow-up"):
1. Gate VIS_DEVINIT capture on `mode & FKIOCTL` (reject userland), mirroring gfxp.
2. Do not rely on `modechg_cb` for the same-mode repaint; tem returns early. Choose an explicit
   repaint/ownership mechanism, and understand that `ts_fb_polledio` is only settable through a
   fresh VIS_DEVINIT, not the modechange callback.
3. Do not log "console on fbdev framebuffer" / set `ic_switched` unless the switch is actually
   effected and observable (read-back of scanout state, not a returned callback).
4. Match the exact candidate-kernel `tem.c`/`gfxp_fb.c` (the pinned `/tmp/streamE5-illumos` copy
   is a reviewed reference, not yet matched to `solnix-ac45d71fc2b0`).
