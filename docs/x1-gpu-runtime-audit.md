# X1 GPU runtime audit: evidence, limits, next step

Preserved from `/tmp/streamGPU-resume-report.md`, with the maintainer-supplied
operator record and source-reconciliation proposal added on 2026-10-11. Sections
1–4 describe the earlier read-only investigation, not new laptop operations.

## Result

**The available evidence does not identify the original i915 fault or which attach phase failed. Do not apply a guessed fix or retry attachment yet.**

I found one saved crash, from **iwm**, and no matching saved i915 crash in `/var/crash/dixi`. I traced separate DDI/console and deferred DRM paths, recovered the external console-handover source, and found concrete blockers to the proposed i915/nouveau PRIME design.

This investigation made no configuration or source changes on dixi. It used bounded SSH for file reads, hashes and offline dump analysis. No live driver loads, DRM opens, alias changes, reboot, BE operations, disk probes, dump-device reads, live mdb, DTrace, builds or commits. SSH/pfexec may create normal access-log records. That investigation changed no repository files; the subsequent documentation-only
follow-up preserves this report and corrects the three source documents.

Repository examined: `/home/gburd/ws/solnix`, HEAD `739f67c59c98621c5d8bd6032573fa6d54917666`.
Checkpoint: `/tmp/streamGPU-resume-progress.txt`.
External evidence/source backup: `/tmp/streamGPU-resume.WIP/`.

## 1. Saved crash evidence (REAL, read-only)

`pfexec /usr/bin/ls -lan /var/crash/dixi` returned:

| File | Bytes | Timestamp reported by dixi |
|---|---:|---|
| bounds | 2 | Oct 10 12:19 |
| unix.0 | 2,429,856 | Oct 10 12:26 |
| vmcore.0 | 4,771,745,792 | Oct 10 12:27 |
| vmdump.0 | 890,109,952 | Oct 10 12:19 |

`bounds` contains `1`. The initial unprivileged listing returned permission denied (exit 2); the privileged listing succeeded (exit 0). An unreadable directory was not counted as empty.

I ran only these offline debugger commands against explicit saved files:

```sh
printf '::status\n::panicinfo\n$C\n' |
    pfexec /usr/bin/mdb -k /var/crash/dixi/unix.0 /var/crash/dixi/vmcore.0
```

MDB identified kernel `5.11 solnix-ac45d71fc2b0`, image UUID `c5e7bb76-9c12-4afa-b27d-b4f8126a5999`, kernel-pages-only dump, and:

```text
mutex_destroy: bad mutex, lp=fffffe58d45d36c0
owner=fffffe0079927c20 thread=fffffe0079927c20

vpanic
mutex_panic
mutex_destroy
rootnex_coredma_freehdl
rootnex_dma_freehdl
ddi_dma_freehdl
ddi_dma_free_handle
bus_dmamap_destroy
iwm_free_rx_ring
iwm_attach
iwm_il_attach
devi_attach
...
```

This stack identifies an iwm attach panic. It does not establish an i915 failure or justify changing wifi code.

`/var/adm/messages` ties the compressed and decompressed files together:

- Lines 2673–2674, Oct 10 12:19:34: the same mutex panic and saving `/var/crash/dixi/vmdump.0`.
- Line 2834: the same UUID.
- Lines 2849–2850, Oct 10 12:26:58: the same mutex panic and saving `{unix,vmcore}.0`.

Thus these files represent one crash, not a second i915 crash hidden behind a different format.

Current `/etc/dumpadm.conf` names `/dev/zvol/dsk/rpool/dump`, save directory `/var/crash/dixi`, kernel content, enabled saves and compression. That is a configuration observation, not proof that dumping worked during the failed i915 boot. I did not access the dump device, run savecore, or search other BEs.

Evidence files:

- `/tmp/streamGPU-resume.WIP/crash-inventory-root.txt`
- `/tmp/streamGPU-resume.WIP/dump0-status-stack.txt`
- `/tmp/streamGPU-resume.WIP/messages-gpu-crash.txt`
- `/tmp/streamGPU-resume.WIP/dump-config.txt`

## 2. What the historical logs establish

A bounded scan of the two existing `/var/adm/messages*` files found only these i915-specific entries:

```text
Oct 10 18:47:14 WARNING: mod_installdrv: no major number for i915
Oct 10 18:47:53 WARNING: mod_installdrv: no major number for i915
```

The scan found no `console on gfxp_fb`, `inteldrm`, or `console on fbdev framebuffer` completion messages. It found later reboot records, but no matching i915 panic/savecore entry. The older `messages.0` returned no matches for the recorded GPU/crash pattern.

**These missing messages do not locate the failure.** An early kernel fault can occur before syslog persists records, and console messages need not appear in these files. Neither an absent success line nor a black panel proves that the kernel hung. The available artifacts also do not establish the precise failed-boot module or whether a DRM client opened a node.

The persistent alias on the default BE can explain repeated exposure to a fault. It does not explain the first fault. I found no evidence supporting boot-archive corruption caused by `bootadm -R`. SSH requires a functioning kernel and network; at/cron require userspace. None is a recovery guarantee for this failure class.

### Operator record added after the read-only audit

The maintainer supplied this historical operator-transcript summary:

- Candidate **c3**, hash prefix `1dacd9ae`, was copied into **solnix-4**.
- The operator rebooted around **2026-10-11 03:23:42 UTC**.
- The user reported a boot loop.
- The orchestrator issued **no explicit DRM open**.

This is an **operator record**, not independently captured loader provenance.
The audit independently hashed the existing c3 artifact as
`1dacd9aede76774823f33953c8bbbff488f74311`; that does not prove that the loader
loaded it during this attempt. No explicit orchestrator open does not exclude
opens by another process. Do not conclude “DDI failed” or “modeset never ran”
from that statement. The supplied summary has no raw transcript file path;
its source is the maintainer's follow-up request, not a newly inspected log.
Timestamps in `/var/adm/messages` above retain dixi's reported clock; no timezone
conversion or correlation to this UTC event was established.

## 3. DDI console attach and DRM modesetting are separate

### Current repository source

`/home/gburd/ws/solnix/src/drm-port/i915/i915_illumos.c`:

1. `_init` initializes soft state and compat facilities, creates clone IDs and installs the driver. Failures here precede both attach phases.
2. `i915_il_attach` (line 93) reads PCI identity, initializes state, calls `gfxp_fb_attach`, creates `text-0` first and then card/render minors. It does not call OpenBSD inteldrm.
3. Console `text-0` open/ioctl routes to gfxp. The cached illumos source has `gfxp_bm_attach` install callbacks; bitmap console initialization later maps the GOP framebuffer. Therefore completion of DDI attach does not itself prove successful tem `VIS_DEVINIT` and console output.
4. `i915_il_open` (line 313) returns through gfxp for the text minor. Only a card/render open calls `i915_il_drm_attach` (line 331).
5. `i915_il_drm_attach` invokes `inteldrm_ca.ca_attach` (line 218), leading to OpenBSD probe/modeset work. This is a distinct failure boundary.

The corresponding repository `i915_drmglue.c` supplies DRM unit, master, restore, poll and dumb-buffer mapping helpers. It has no fbdev-console handover helper.

### Recovered external console version

`CONSOLE-HANDOVER.md` describes a version absent from the current repository source. I recovered it from:

`dixi:/home/gburd/gpu-console/port/i915/`

The remote `i915_illumos.c` has 1,119 lines rather than the repository's 679, and adds `i915_cons_modeset_done` and visual_io rendering. It still defers inteldrm attach until the first card/render open. Its `i915_drmglue.c` adds `i915_glue_fbinfo`.

Existing module hashes:

- `dixi:/home/gburd/gpu-console/c3/i915`: `1dacd9aede76774823f33953c8bbbff488f74311`, matching the handover document.
- `dixi:/home/gburd/gpu-console/c4/i915`: `ceff98ca49faf86eb8825c4f3ae237220bcd64da`.

Both are 4,815,280 bytes. **I have not established which module the failed boot used.** A workspace source file and a build timestamp do not establish that provenance.

External backup: `/tmp/streamGPU-resume.WIP/dixi-console-source-complete.tar`, five source/build files, successful transfer and listing. The earlier `dixi-console-source.tar` is partial because illumos tar's `-C` handling failed after one member; use the `-complete` archive.

### The handover success claim is too strong (source finding, not crash diagnosis)

In the recovered source, `i915_cons_modeset_done` sets `ic_switched` and logs success even when `ic_modechg_cb` is NULL. In the cached illumos `/tmp/streamE5-illumos/tem.c`, `tems_modechange_callback` compares dimensions/depth and returns immediately if those have not changed. It does not replace `ts_fb_polledio`; initial `VIS_DEVINIT` supplies that pointer.

Consequently, the advertised same-resolution callback is not proof that tem repainted or moved its polled console to the new buffer. The success log also does not read back scanout configuration. This refutes the document's proposed proof of successful handover. It does **not** identify the historical fault: the failed binary and matching kernel source still need to be established, and this code runs after deferred DRM attachment.

The existing `test_console.c` reimplements draw arithmetic in RAM. It does not exercise DDI attach, `VIS_DEVINIT`, tem modechange semantics or the actual kernel routines. Its prior results cannot validate those paths.

## 4. Actual hybrid dependencies

| Component | Evidence/status |
|---|---|
| i915 DRM core | `src/drm-port/i915/build-module.sh` compiles and links the OpenBSD DRM objects plus obsd-compat and DDI glue. It does **not** link the separate C1 `src/drm-port/src/drm_prime.c`. |
| i915 fd export/import | **STUB**: `obsd-compat/obsd_glue.c:290–304` has `fdalloc = ENOTSUP`, `fd_getfile = NULL`, `fnew = NULL`. OpenBSD `drm_linux.c` uses these for dma-buf export/import. |
| OpenBSD dma-buf attachment | **STUB**: `include/linux/dma-buf.h` returns NULL from `dma_buf_attach`; detach panics. |
| i915 foreign-buffer import | **UNIMPLEMENTED/PANIC**: `i915/gem/i915_gem_dmabuf.c:293–360` supports the own-device shortcut, but places foreign-object setup behind `#ifdef notyet`; the normal alternative calls `panic(__func__)`. Implementing fd allocation alone would not make cross-driver PRIME safe. |
| Separate C1 PRIME | Has fd/vnode export code and a same-device import table. Import reissues a GEM handle from `dev->prime_exports`; it does not map a foreign driver's pages. It is not a bridge into the OpenBSD i915 object model. Its vnode validation also checks char type/minor without checking the exporting major, so it should not be treated as a validated foreign-fd boundary. |
| nouveau import/export | `nouveau_prime.c` depends on TTM pages, SG tables, shared `dma_resv`, GEM lifetime, GART buffer initialization and pinning. Those semantics need implementations, not just header names. |
| Two scoped modules | Local symbol maps reduce collision risk. They do not supply shared dma-buf identity, shared object lifetime, cross-device mapping, coherency or fencing. |
| NVIDIA rendering | Requires channel/FIFO and graphics engine initialization, command submission, memory management, synchronization and working Mesa/userspace. A display-only driver cannot provide accelerated render offload merely by exposing a render node or importing an fd. |

Reference OpenBSD revision: `37a498de2f7aa77a9e30afd65012af6434819316`, from `/tmp/streamE5-obsd/obsd-drm/OPENBSD_REV`. Copies of the decisive sources are in `/tmp/streamGPU-resume.WIP/reference/`.

### The nouveau probe did not demonstrate implementation reuse

I retrieved the actual `/var/tmp/streamNOUVEAU/nouveau-probe2.sh` from dixi. Its compiler command uses nouveau/Linux header trees, a seed, illumos gate headers and generated **empty missing-header stubs**, with `-fsyntax-only`. It does not compile against the OpenBSD shim or C1 implementation and performs no link/runtime check.

The saved results contain **418 rows, 71,389 errors, zero zero-error rows**. The 92/98 overlap reported in `docs/x1-dgpu-decision.md` measures header-name presence only. It cannot establish 94% implementation reuse, a working port, or the stated engineering schedule. The claim that C1 satisfied the DRM dependencies is not supported by this harness.

### Pascal conclusions supported by the reviewed source

The GP107 `nv137_chipset` entry has no clock subdevice. Its graphics path uses `gp107_gr_new`; `gp107.c` names FECS/GPCCS and other graphics firmware and selects `gm200_gr_load`. `nouveau_accel_init` separately initializes channels/fences and graphics/copy channels.

Display-only work and accelerated render offload therefore have different prerequisites. Absence of a direct `request_firmware` call in display source is not a transitive firmware audit. Lack of reclocking does not mean hardware acceleration is impossible, nor establish performance relative to the Intel GPU. No acceleration or performance result was measured here.

Keep i915-first as the immediate priority. Treat nouveau display and hybrid render offload as separate unproven milestones, with fd ownership, SG import, fences/coherency, GPU execution, firmware and userspace dependencies made explicit.

## 5. Minimal next step and bounded diagnostic plan (PLANNED, not executed)

**Immediate next step: corroborate the operator record before any attach.** The
record now identifies c3, solnix-4 and an approximate UTC reboot time. Still
needed: the raw attempt transcript/last visible output or independent console
capture, loader identity evidence, and evidence of any card/render opener beyond
the orchestrator. Compare with preserved artifacts; do not infer loader identity
from the newest directory or treat the lack of an explicit open as global absence.

If no matching dump or console record exists, stop historical diagnosis at **failing phase unknown**. Do not substitute the iwm dump, alias persistence, missing syslog output or a bootadm theory.

For a future separately approved test:

1. Review the exact candidate binary/source and kernel identity. Reconcile the source/doc drift before building; build only on dixi or authorized EC2. Preserve provenance and symbols off-laptop.
2. Establish recovery that does not depend on kernel scheduling, SSH, cron or at. Require an operator physically present, a known-good selectable boot environment without the experimental binding, and an agreed manual recovery procedure. A separate approved test must not leave the experimental binding in the unattended default boot path. None of these changes is authorized or performed by this report.
3. Verify an independent early-console/capture method on a known-good boot before relying on it. Laptop SSH `dmesg` is not an independent console, and EC2 `get-console-output` does not exist for dixi. If no usable early capture exists, record that limitation and do not describe the next attempt as diagnostically safe. Dump configuration alone cannot capture every hard hang.
4. Separate the experiments: first DDI/text-console only, with no automatic DRM opener; then, only after evidence of working text-console initialization, one explicit card/render open under separate approval. Keep bounded, sparse stage evidence for `_init`, DDI entry/return, text `VIS_DEVINIT`, first DRM open, inteldrm return, and handover. A pre-userspace failure with independently confirmed no DRM open excludes deferred modeset; without that confirmation it does not.
5. Stop at the first failure and preserve its matching dump/console evidence. Do not chain fixes or unattended retries. Phase evidence must distinguish failure before DDI, DDI/tem failure, and deferred modeset/handover failure. A panel or log line alone cannot establish scanout, kernel liveness or recovery availability.

The smallest useful deliverable now is the missing attempt record, not a patch.

## Reproducing the read-only observations

All remote invocations used this bounded transport, one short operation per call, with stdin closed and output saved locally:

```sh
timeout -s KILL 25 setsid ssh -F /dev/null \
  -i ~/.ssh/id_auth_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none \
  -o ControlMaster=no -o ControlPath=none -o BatchMode=yes \
  -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  gburd@192.168.1.124 '<read-only command>' </dev/null
```

Offline mdb used a 35-second outer bound. Saved outputs include access failures rather than suppressing them. No new test harness or purported runtime validation was added.


## 6. Source reconciliation (review-only, NOT applied)

The companion [reconciliation diff](x1-gpu-console-reconciliation.diff) compares
repository source at HEAD `739f67c59c98621c5d8bd6032573fa6d54917666` with the five
files recovered earlier from `dixi:/home/gburd/gpu-console/port/i915/`.
It contains **513 insertions and 8 deletions across three files**: the main DDI
file grows by 440 lines (448 additions, 8 deletions), plus 37 glue lines and 28
header lines. Mapfile and build-module.sh are byte-identical and produce no hunk.
No hunk was merged. `git apply --check` validates patch applicability only, not
code correctness; do not apply it to the driver as an approved change.

Recovery archive:
`/tmp/streamGPU-resume.WIP/dixi-console-source-complete.tar`

```text
archive SHA256 210f4c6ef993a471b569e1535a2ed6cb68911e7a7b31eef30c35305ac639eae8
diff    SHA256 f0910939ff010946051a80a25f17113ae4dd1b9e66733d40d3252f0174be7314
```

Hashes below identify the source snapshots, **not a source-to-c3 build proof**:

| File under src/drm-port/i915 | Repository SHA256 | Recovered SHA256 |
|---|---|---|
| `i915_illumos.c` | `85f4b68881108ae5ed5c946e63fe2fd1c0399eae37754feb404a2502b27a57c5` | `535305d7063839b1df8b253348c1ce5bdb74723d5dd1f67b6f197aa9612fba76` |
| `i915_drmglue.c` | `ec8dbb7b90439a6c6eef604520715b4d17aa92aa3585b05589699cc0842f4a05` | `0540bd592c6b5900747cd9e0bb05317dc843fd1fc2494eb4a5a8c89a981748cb` |
| `i915_drmglue.h` | `0ab158993762b5566118a7bf987bd77ff8881b87ceb76abc092aa830f6599309` | `6e1b5479e208f6fc16e4568401a214d5945d79baf0ab77b434302d2497378309` |
| `i915.mapfile` | `86a180c0194febd225025e6516b256bd13de00d94555f1c7c4466ca4946f28dd` | `86a180c0194febd225025e6516b256bd13de00d94555f1c7c4466ca4946f28dd` |
| `build-module.sh` | `8fd64ed4e4388819d462bff984a6a7a41f2a82d061b738013dbfeb3a1fc58f6d` | `8fd64ed4e4388819d462bff984a6a7a41f2a82d061b738013dbfeb3a1fc58f6d` |

The archive contains no Makefile or test snapshot; the existing untracked
`test/test_console.c` is not replaced. Comparing this workspace does not identify
which compat/OpenBSD object set produced c3/c4. Keep candidate-build provenance
separate from this source reconciliation.

### Small next implementation/test proposal (requires review, not implemented)

**First patch: a test-only characterization of tem's callback contract.** Do not
start by merging the renderer or by enabling PRIME fds. A same-mode callback is
not a demonstrated console-switch interface, so first make that limitation an
executable check. The current repository can keep its gfxp forwarding unchanged.

Proposed files: a new `src/drm-port/i915/test/test_tem_modechange.c` and a bounded
`test-tem-modechange` target in `src/drm-port/i915/Makefile`. Leave the existing
untracked draw-arithmetic test untouched. This is a proposal, not a build request.

- Pin the illumos tem source to the candidate kernel before implementation.
  `/tmp/streamE5-illumos/tem.c` is a reviewed reference, not yet matched to that
  kernel. Record its revision/hash alongside the test.
- Compile the **actual** `tems_check_videomode` and `tems_modechange_callback`
  bodies from that pinned source with a minimal userland boundary harness.
  Do not reimplement their decisions in the test or count a mocked callback as
  tem. If compiling those bodies requires a broad tem emulator, stop and review
  the harness scope rather than adding one.
- Initialize an existing polled-I/O pointer and 3840x2160/32bpp geometry; pass
  unchanged geometry with a different polled-I/O pointer. Assert no repaint and
  the original pointer retained. Add changed-geometry and changed-depth controls
  asserting the corresponding reinitialization path. Count boundary calls; do
  not infer rendering from a returned status.
- Add a negative control that incorrectly expects same-mode repaint/pointer
  replacement; it must fail. This validates the detector without a GPU or load.
  A NULL captured driver callback must be recorded as “handover unavailable,”
  not silently counted as a successful callback invocation.
- Run only on authorized EC2 or dixi after build authorization; record compiler,
  pinned inputs, ordinary result and failing negative control. Nothing is built
  during this documentation task. This proves callback behavior only, not DDI
  runtime, scanout or the historical crash cause.

**Follow-up production patch, separately reviewed:** choose an explicit supported
repaint/polled-I/O ownership mechanism after this check. Review FKIOCTL validation
before storing callbacks, callback lifetime, unchanged-mode restore, NULL callback
handling and normal-vs-panic output paths. Keep its scope to that state transition;
review draw routines separately. Do not force fake geometry changes or print
“console moved” to work around an unproven contract. A missing callback or a
returned callback cannot establish hardware scanout.

This sequencing gives a small first review gate without accepting the recovered
440-line implementation, inventing a boot-loop fix, or claiming a new runtime
milestone. The diagnostic provenance/capture work in section 5 remains required
before any live attach.
