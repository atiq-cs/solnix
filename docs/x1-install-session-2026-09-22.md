# X1 install session findings (2026-09-22) — the real blockers, measured

A long real-hardware install session on the X1 (`c1t001B448B485502D1d0`, 928G NVMe).
Each finding is MEASURED on hardware. Several of my hypotheses were REFUTED on the way;
they are recorded so they are not retried.

## What is SOLVED (fixes landed)

1. **Console-login regression (tui5)** — auto-login on raw /dev/console let the X1 hid
   keyboard flood drown the prompt. Fixed: stock ttymon by default + hid_errlevel=0.
   (commit 15926ebd / eb95dc13)
2. **dig/curl broken in the media** — the ldd-closure copy filtered `grep '^/usr/lib'`,
   dropping /lib deps (libidn2/libcurl/...). Broadened to `^(/usr)?/lib/`. Plus a
   RUNNABILITY GATE: the build now fails if any staged ELF's NEEDED libs are missing.
   (9b7871c0, abefc661) — NOTE: curl is STILL broken in images built before this.
3. **Stale EC2 resolv.conf** shipped in the media (VPC resolver poisons DNS on a home
   network). Scrubbed from the ramdisk at build. (27c82872)
4. **Suspended/FAULTED pool could not be torn down** — destroy/export/labelclear all
   D-state hang on a suspended pool; run_to cannot kill them. Installer now DETECTS a
   suspended pool and instructs a reboot instead of hanging. (9de3e216)
5. **Recurring rpool=FAULTED loop** — every failed run left solnixscratch (whole-disk on
   the target) + partial rpool; the next run imported a backingless fragment = FAULTED.
   AND a stale /etc/zfs/zpool.cache auto-imported the dead pool at every boot. cleanup()
   now destroys stranded scratch on failure. (8c09cc7b) A `solnix-zap` tool bakes the
   full clean-slate recovery (export ghost, clear cache, labelclear, 4K dd) into one
   command, staged in the media. (d4205e85)
6. **nixpkgs-solnix-patched was unpublished** — the flake's `lib = import "${nixpkgs}/lib"`
   forces realising an applyPatches DERIVATION; it was never in the cache, so on the X1
   it could only be BUILT (illumos refuses to build in a diverted store). Published it
   to s3.solnix.io signed by the correct key (5HAV...Rz4NEjRUVk=). MEASURED on the X1:
   `nix copy --to /a` of that path SUBSTITUTES + is TRUSTED (no signature error). (ce7806c3)

## Refuted hypotheses (do NOT retry)

- "Removing `--eval-store` fixes the diverted-store error" — REFUTED: `--store /a` alone
  is still diverted for build; the error recurred identically.
- "The diverted store refuses SUBSTITUTION" — REFUTED: the measured `nix copy --to /a`
  substituted the path fine (trusted, fetching); it only failed on SPACE.
- "Swap destroy for export/labelclear on a suspended pool" — REFUTED: export + labelclear
  also D-state hang.

## THE CURRENT OPEN BLOCKER (measured on hardware; ROOT CAUSE CORRECTED 2026-09-22)

At 5/9 the build runs `nix build --store /a` (`$ALTROOT=/a`). The manual substitution test
showed:
- `nix copy --to /a nixpkgs-solnix-patched` → **"No space left on device"**, and `df -h /a`
  → **`????????`** (not a healthy mount), while **`zpool list` shows rpool 928G / 926G free**.

Interpretation (MEASURED FACTS, all still true): at that moment `/a` was NOT the big pool — it
was a directory on the tiny RAM ramdisk (~9M free), so the substitute overflowed it while the
928G pool sat unused/unmounted.

### ⚠️ CORRECTED ROOT CAUSE (the earlier "reorder needed / option D" recommendation was WRONG)

The first write-up of this blocker recommended reordering the installer to create the pool
before the build (option D) and described a "build into solnixscratch then lose it at teardown"
DESIGN HAZARD. **Both were premised on a stale mental model of `scripts/solnix-install` and are
WRONG against the actual source** — verified by reading HEAD, not by reasoning about plausibility:

- Option D is **already implemented**. Commit `a26e5fb7` (Sep 18) moved `build_toplevel` to run
  AFTER `zpool create rpool` + `zfs mount $BEDS`. Both the images the X1 actually booted —
  tui5 (`9a0305e1`) and tui6 (`f693164d`) — build with `--store $ALTROOT` at step 5/9, which
  runs after the pool is created at step 4/9. There is no reorder to do.
- The installer has **never** built the toplevel into `solnixscratch` as the store; it has used
  `--store $ALTROOT` (the pool, mounted at `/a`) since `a26e5fb7`. The DESIGN HAZARD's flow and
  its line numbers (1295/1360/1881) do not match any real revision. There was no committed
  "half fix" building into scratch to revert.

**The REAL bug** (which reproduces every measured fact): after `zfs mount "$BEDS"` the guard was
`[ -d "$ALTROOT/." ]`. That is TRUE whether or not the mount succeeded, because `$ALTROOT` (`/a`)
is `mkdir -p`'d up front. So a **silent `zfs mount` failure** (a `run_to 30` timeout, an EBUSY
race, a keyed dataset) passed the guard, left `/a` a bare dir on the ~9M RAM ramdisk, and the
later `nix build --store /a` wrote the store there → "No space left on device", `df /a` = ramdisk,
rpool 926G free but unmounted. `solnixscratch` was correctly absent at test time — it was never
the issue; the unverified BE mount was.

### THE FIX (landed post-2026-09-22, in `scripts/solnix-install`)

Harden the mount verification — do NOT reorder anything (the order is already correct):

- New helper `assert_mounted_on_pool <dataset> <mountpoint> [errfile]`: asserts the ZFS
  `mounted` property == `yes` AND `df -n <mountpoint>` reports fstype `zfs` (a ramdisk dir
  reports ufs/tmpfs, never zfs). Both signals are illumos-safe (no GNU `stat`/`readlink`).
  Fails LOUD, naming the dataset, and prints the captured `zfs mount` stderr so the operator
  sees WHY (busy mountpoint / needs load-key / EBUSY).
- Wired at the BE mount (replacing the weak `[ -d "$ALTROOT/." ]`), capturing mount stderr to
  `/tmp/solnix-be-mount.err`, and again for `$POOL/nix` (verified `mounted`, not just that
  `zfs list` shows it).
- Belt-and-braces AT THE BUILD SITE: `build_toplevel` re-asserts, right before `nix build`,
  that `$ALTROOT` is a real zfs mount (fstype `zfs`) with a hard free-space floor (2 GiB —
  a real 928G pool clears it trivially; the 9M ramdisk cannot). This is the doc's own "fail
  LOUD rather than silently build on the ramdisk" note applied at the exact build site.

Verified in isolation with negative controls (fake `zfs`/`df`): the guard fires when
`mounted=no` (the X1 bug) and when the fstype is shadowed to ufs, and passes when mounted.
End-to-end on illumos is verified-by-reasoning + the maintainer's next X1 run (single-user
nix + diverted-store behavior is illumos-only and cannot be exercised off-hardware).

## Media tooling gaps found

- `curl` broken (libcurl.so.4) — same class as dig; fixed for images after abefc661.
- `solnix-diag fetch` uses curl → unusable on the X1. Should fall back to nix/openssl.
- `fmadm` not staged. `iostat`, `openssl`, `nix`, `git`, `dladm`, `ipadm`, `zpool` present.
- The self-uploading diagnostic pattern that WORKED on the X1: a script that POSTs its
  output via `openssl s_client` to paste.rs (curl is broken; openssl runs). Presigned R2
  PUTs 403 (rustfs rejects presigned SigV4); authenticated `aws s3 cp`/`nix copy` work.
- The disk is HEALTHY (iostat -En all zeros) — every pool fault was install-caused.

## ~~DESIGN HAZARD found while fixing~~ — RETRACTED (premised on a stale model)

This section originally described an NVMe-scratch-on-target "ordering conflict" (build toplevel
into `solnixscratch`, destroy scratch before rpool, then fail to copy the closure) and
recommended reordering the installer (option D). **It is RETRACTED.** The installer never built
the toplevel into `solnixscratch` as the store, and the pool-first ordering it recommended was
already in place (commit `a26e5fb7`). The cited line numbers (1295/1360/1881) matched no real
revision. The actual blocker was a silent `zfs mount` failure passing a directory-exists guard
— see "CORRECTED ROOT CAUSE" above. Kept as a record so the retraction is annotated at the
source, not only where it is superseded (per the campaign's "the summary outlives the caveat"
rule).

The one durable, still-true observation from the analysis: on a single-disk target,
`solnixscratch` (a whole-disk pool on the target) and `rpool` cannot coexist, so `solnixscratch`
is only ever a transient name-gate scratch that must be destroyed before the install pool is
created — which the installer already does. It is NOT the toplevel build store; the build store
is the mounted `rpool` at `$ALTROOT`.
