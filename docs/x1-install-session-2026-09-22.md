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

## THE CURRENT OPEN BLOCKER (measured, not yet fixed)

At 5/9 the build runs `nix build --store /a` (`$ALTROOT=/a`). The manual substitution test
showed:
- `nix copy --to /a nixpkgs-solnix-patched` → **"No space left on device"**, and `df -h /a`
  → **`????????`** (not a healthy mount), while **`zpool list` shows rpool 928G / 926G free**.

Interpretation: at build time `/a` is NOT on the big pool — it is a directory on the tiny
RAM ramdisk (~9M free), so a 329MB substitute overflows it. The 928G pool sits unused.
`solnixscratch` was NOT in the zpool list at test time (only rpool), so either scratch was
never created this run or was already destroyed. detect_target DOES run before
setup_scratch (ordering is fine), so the failure is elsewhere — scratch create/mount, or
$ALTROOT not being pointed at the scratch/pool mount for the build.

NEXT DIAGNOSTIC NEEDED (from the X1, mid-install at the 5/9 failure, BEFORE any cleanup):
`df -h /a`, `zpool list`, `mount | grep /a`, `echo $SCRATCH_STORE $ALTROOT`, and whether
`solnixscratch` exists at that moment. The fix is almost certainly: ensure the 5/9 build's
`--store`/HOME/TMPDIR point at the big scratch (or the pool), and fail LOUD if scratch is
the ramdisk rather than silently building there.

## Media tooling gaps found

- `curl` broken (libcurl.so.4) — same class as dig; fixed for images after abefc661.
- `solnix-diag fetch` uses curl → unusable on the X1. Should fall back to nix/openssl.
- `fmadm` not staged. `iostat`, `openssl`, `nix`, `git`, `dladm`, `ipadm`, `zpool` present.
- The self-uploading diagnostic pattern that WORKED on the X1: a script that POSTs its
  output via `openssl s_client` to paste.rs (curl is broken; openssl runs). Presigned R2
  PUTs 403 (rustfs rejects presigned SigV4); authenticated `aws s3 cp`/`nix copy` work.
- The disk is HEALTHY (iostat -En all zeros) — every pool fault was install-caused.

## ⚠️ DESIGN HAZARD found while fixing (must resolve, not patch around)

The NVMe-scratch-on-target design has a fundamental ordering conflict:
  5/9 build toplevel INTO solnixscratch (whole-disk pool on the TARGET)
  ~1295 DESTROY solnixscratch (it occupies the target the real rpool needs)
  1360-1408 partition + create rpool
  1881 copy toplevel closure to rpool  <-- but scratch (holding it) was destroyed at 1295

So building the toplevel into scratch-on-target LOSES it at the scratch teardown, because
scratch and rpool cannot coexist on one disk. Options, in order of cleanliness:
  A. Don't put scratch on the target at all. Require/prefer a second device (USB stick as a
     real disk -- blocked on the X1 by scsa2usb; or a second USB/NVMe). Cleanest but needs
     hardware the X1 lacks.
  B. Partition the target ONCE up front: a small scratch slice + the rpool slice, build into
     the scratch slice, then copy to rpool, then reclaim the scratch slice. Avoids the
     whole-disk collision but complicates partitioning.
  C. Build into scratch, then `nix copy` the toplevel closure to a HOLDING location that
     survives the scratch destroy (there is none big enough except the target itself -> back
     to the collision).
  D. Create rpool FIRST (small), build toplevel with --store on rpool directly (no separate
     scratch), accepting that eval+build share the final pool. Simplest if rpool-first works:
     the pool is 928G, eval copy (~100k files) + build outputs fit, and it is a real chroot
     store (substitution of nixpkgs-solnix-patched proven to work into a real store). This is
     likely the RIGHT answer: skip the separate scratch entirely on a single-disk machine --
     create the install pool first and build straight into it.

RECOMMENDATION: option D. On a single-disk target with no usable second device, create the
install pool first, then build the toplevel with --store <pool> (and HOME/TMPDIR on the pool).
No separate scratch, no teardown collision, no ramdisk overflow. The name gate + substitution
both proved a real chroot --store on the NVMe works. This removes the whole solnixscratch
whole-disk-on-target mechanism and its FAULTED-loop failure mode.
