# i915 staged attach plan (for the orchestrator to execute later — NOT now)

Status: **PLAN ONLY. No load, bind, alias, BE change, reboot, or network action is performed
by this document or by the agent that wrote it.** The failing boot phase from the earlier loop
is still UNKNOWN (docs/x1-gpu-runtime-audit.md); this plan is written so the *next* live attempt
produces the evidence that would identify a phase, and so a failure is recoverable without SSH,
cron, or a timer.

This supersedes the "alias = attach = modeset" expectation. The two phases are physically
separate and must be tested separately, with the DDI/text-console phase proven on the real panel
*before* any DRM open is attempted.

> **DO NOT USE modules 229d0e54 or 614a0cba (built with SIMD outside FPU sections).** Both were
> compiled without `-mno-mmx -mno-sse`, unlike every illumos kernel module (Makefile.master
> `NO_SIMD`): the banked 614a0cba has 6150 SIMD instructions, 6120 of them outside any
> `fpu_kernel_enter`/`fpu_kernel_exit` section (measured with `simd-gate.sh`), and 229d0e54 was
> built by the same scripts. Kernel threads run with CR0.TS set, so the first such instruction is a
> `#NM` panic, and in a user thread's kernel context it corrupts that thread's FPU state. Use the
> module from `pkgs.solnix.i915-driver` (pkgs/illumos/i915-driver.nix), whose build fails unless
> SIMD appears only in `i915_memcpy.o`/`drm_cache.o` and only between those calls. Its sha256 is
> in the image's boot sheet; confirm it before each stage. The text below names 229d0e54 as it
> was written; read it as "the i915-driver module".

Module to attach: the gate-green repo-source module built in this stream
(dixi:`/home/gburd/streamI915-build-r2/out/i915`, sha256
`229d0e544c86b35532f8b9fc27dcd0ab17e09b171b473e30bef8eb6122187643`, built with
`XFLAGS=-D__HAVE_ACPI -DNACPI=1` against kernel `solnix-ac45d71fc2b0`; 0 unresolved, 0 ksyms
collisions, exactly 4 interface globals). This module contains **no** console-handover code
(the recovered +513-line path was reviewed and flagged, not folded — see FOLD-DECISION.md), so
stage 1 exercises only the gfxp (GOP firmware framebuffer) text console, exactly as vgatext
does. Confirm the attached binary's hash matches before each stage; do not infer identity from a
directory name or build time (an earlier near-miss).

## Preconditions for EITHER stage (all required, none optional)

1. **Operator physically present at the X1.** No stage may run unattended. Recovery is by the
   operator at the physical keyboard/power, not by a scheduled job.
2. **Boot-once experimental BE, never the default.** Create a BE that carries the experimental
   driver binding and activate it for ONE boot only with `beadm activate -t <be>` (verified
   present on dixi: `beadm activate [-v] [-t | -T] beName`; `-t` = next boot only, falls back to
   the default on the subsequent reboot). The default BE must remain a known-good environment
   with **no** `pciex8086,3e9b` alias and no i915 driver file, so an uncontrolled power-cycle
   lands back on a bootable system. Verify the known-good default boots clean *before* arming the
   experimental BE. (Observed BEs on dixi: active/default `solnix-3` [NR]; `solnix-4`;
   `solnix-gpu` created 2026-10-11. Do NOT assume what any non-default BE contains — hash-verify
   the module actually in the experimental BE before arming; the audit's operator record is not
   independent loader provenance.)
3. **Deadman armed — currently it is NOT.** Measured on the running kernel in this stream:
   `deadman_enabled = 0` (deadman is OFF). A hard hang right now would wedge silently with no
   dump. The orchestrator MUST actually enable the deadman before the reboot and confirm it, not
   assume it; this is a real precondition, not boilerplate. (Enable per the illumos default
   mechanism; do not invent a solnix-specific knob.)
4. **Dump armed and verified writable.** `/etc/dumpadm.conf` already names
   `/dev/zvol/dsk/rpool/dump`, savecore dir `/var/crash/dixi`, kernel content, enabled+compressed
   (audit §1). Before the stage, confirm `savecore -L` (or an equivalent dry test on a known-good
   boot) can actually write there — the audit warns configuration is not proof a dump will land,
   and a hard hang before the dump path initialises can still produce nothing.
5. **Independent early console capture if one exists.** SSH `dmesg` is NOT an independent console
   (it needs a live kernel+network); EC2 `get-console-output` does not exist for a laptop. If no
   serial/EFI early-console capture is available, record that limitation explicitly and treat a
   black panel as *inconclusive*, not as "hung".
6. **One change per boot. Stop at the first failure.** Preserve the matching dump/console
   evidence and do not chain a second change. Judge nothing from a single boot where the
   phenomenon could be bursty; if a stage is retried for a rate, report the clustering.

## Stage 1 — DDI / text-console attach ONLY, NO automatic DRM opener

Goal: prove that `_init`, DDI `i915_il_attach` (gfxp_fb_attach + minor creation), and tem's
`VIS_DEVINIT` text-console initialisation all succeed on the real panel, with **no** card0/
renderD128 open and therefore **no** OpenBSD inteldrm modeset. The repo driver only calls
`i915_il_drm_attach` from the first card/render open (`i915_il_open`), so if nothing opens those
minors, no modeset runs. The stage's job is to guarantee nothing opens them.

Setup:
- Install the gate-green module and a `pciex8086,3e9b` driver alias in the boot-once BE only.
- **Suppress every automatic DRM opener.** Before arming, confirm no Xorg/display-manager/
  greeter/`drm`-probing service is enabled in that BE (an X server or a Wayland compositor opens
  card0 and would silently trigger stage 2). The audit's "no explicit orchestrator open does not
  exclude opens by another process" is the exact trap: enumerate and disable console/display SMF
  services, and verify no `devfsadm` consumer auto-opens the DRM nodes. This is the single most
  important invariant of stage 1.
- Keep card0/renderD128 minors created (the driver creates them in attach) but leave them
  unopened; do not run any DRM/libdrm/Mesa client.

Per-phase console evidence (strings are the driver's actual `cmn_err` text, repo
`i915_illumos.c`):

| Observation | Phase reached | Interpretation |
|---|---|---|
| No `i915` line at all; a panic/dump with `_init`/`mod_install`/`obsd_compat_init`/`ddi_soft_state` on the stack | **_init failure** | Driver load / compat init failed before any attach. Preserve dump; this is before DDI. |
| `i915%d: ... : not a supported Intel GPU` or `inteldrm_match refused`-free attach that returns DDI_FAILURE with a fail-path dump (`gfxp_fb_attach`, `ddi_create_minor_node`) | **DDI-attach failure** | PCI match or gfxp attach or minor creation failed. The GOP console state is as the firmware left it. |
| `?i915%d: <plat> gen<n> gt<n>, console on gfxp_fb; OpenBSD inteldrm attach on first open` **and** legible text continues to paint on the panel (login/console prompt visible, scrolls) | **DDI attach + text console OK** | The success line (line 147) means minors were created; the *panel painting and scrolling* is the independent proof tem's `VIS_DEVINIT` bound and gfxp is drawing. The log line alone is not enough — require visible, scrolling text. |
| `?i915 ... console on gfxp_fb` logged **but** panel black / frozen, kernel still alive (SSH answers, deadman quiet) | **text VIS_DEVINIT suspect** | DDI returned but tem did not initialise/draw; distinguish from a hung kernel by the fact that SSH/deadman show liveness. Inconclusive without early console capture; record as such. |
| `?i915 ... console on gfxp_fb` logged, then hard hang (no SSH, deadman fires → dump) | **post-DDI hang** | Attach returned but something after (interrupt/taskq registered by a path reached during attach) wedged. Preserve the deadman dump. |

Stage 1 PASS criterion: the success line is logged AND the panel shows live, scrolling text AND
no `inteldrm`/modeset message appears (confirming no DRM open happened) AND the box is reachable.
Only then is stage 2 considered.

## Stage 2 — ONE explicit card0/renderD128 open, to trigger inteldrm modeset

Goal: with stage 1 proven, perform exactly **one** explicit open of card0 (or renderD128) and
observe the deferred OpenBSD inteldrm attach / modeset. Nothing else changes between stages.

Setup:
- Same boot-once BE discipline, deadman, dump, operator-present. Fresh boot (do not reuse the
  stage-1 boot — a clean baseline).
- Still no automatic DRM opener; the operator issues a single controlled open (e.g. one
  `open("/devices/.../card0")` from a tiny purpose-built program, or one well-understood client),
  then stops. This isolates the modeset to one observable event.

Per-phase console evidence:

| Observation | Phase reached | Interpretation |
|---|---|---|
| Stage-1 success line present, then on the open: `i915%d: inteldrm_match refused` | **modeset refused at match** | OpenBSD `inteldrm_ca.ca_match` rejected the device. No modeset attempted. Driver leaves console on gfxp. |
| `inteldrm_match` passes, then `i915%d: inteldrm attach failed; the console stays on the firmware framebuffer` | **deferred-modeset failure (attach)** | `inteldrm_ca.ca_attach` ran but `inteldrm_fatal_error` set or `drm_dev_register` never completed (`i915_glue_drm_unit` < 0). Console *should* remain on gfxp; verify the panel still shows text. |
| open hard-hangs the box (no SSH, deadman → dump) with inteldrm/`i915_driver_probe`/BAR0/MSI/`hat_devload`/`contig_alloc` on the stack | **deferred-modeset failure (hang)** | The modeset itself wedged — the untested kernel paths (`ddi_regs_map_setup`, MSI, device-tree walk, GEM/GGTT). This is the first time those run; the deadman dump is the primary evidence. |
| open returns success, panel changes to the modeset output / stays legible, box reachable | **modeset OK** | inteldrm attached and registered. (Console handover to the fbdev buffer is NOT in this module; the panel after modeset shows whatever inteldrm's fbdev leaves scanned out. A black panel here is NOT proof of failure — see note.) |

Important caveat for stage 2 (from the fold review): this module does **not** hand the console
over to i915's fbdev buffer. After a successful modeset, gfxp may repaint a GOP buffer that is no
longer scanned out, so the panel may go black even though the kernel is alive and the modeset
succeeded. Judge stage 2 by SSH/deadman liveness + the `i915_glue_drm_unit >= 0` success path,
**not** by the panel alone. The console-handover work is deferred until a corrected,
FKIOCTL-gated, effective handover is designed and separately reviewed (FOLD-DECISION.md §"What a
corrected handover would need").

## Distinguishing the three failure classes at a glance

- **_init failure**: no `i915` success line ever; stack names `_init`/`mod_install`/
  `obsd_compat_init`. Occurs before DDI, so no gfxp attach, no minors.
- **DDI/text-console failure**: no success line + a fail-path dump in `i915_il_attach`
  (gfxp_fb_attach / ddi_create_minor_node), OR success line logged but panel never paints live
  text. Pre-DRM; if independently confirmed no card/render open happened, deferred modeset is
  excluded.
- **Deferred-modeset failure**: only reachable in stage 2 (or if stage 1's "no opener" invariant
  leaked). Evidenced by `inteldrm_match refused` / `inteldrm attach failed` / a hang with
  inteldrm/`i915_driver_probe` on the stack. A stage-1 pass with a confirmed no-open invariant is
  what lets a later hang be attributed to the modeset rather than to DDI.

## Back-out (must not depend on the kernel/SSH/cron)

The only guaranteed back-out is the operator selecting the known-good default BE at the boot
menu (no experimental alias/driver). Confirm that selection works on a dry run before arming.
Neither an SSH cleanup script, a cron/at job, nor a named historical BE (`solnix-3`) is a
guaranteed recovery for a pre-userspace hang. If stage 1 fails such that the box will not reach
userspace, the operator power-cycles and selects the known-good BE; the boot-once activation
means a plain reboot already falls back to the default.
