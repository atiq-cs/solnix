# R2 image banking has been silently failing (measured 2026-09-21)

## The finding

`install-media/` in the R2 cache (s3.solnix.io/solnix-cache) is EMPTY. Every installer image whose README claims
"banked in R2, read-back verified" -- o, p, p2, tui, tui2, tui3, tui4 -- returns **404**. The bytes were never
actually in R2, despite success reports.

## Root cause

Large image uploads (1.7-5.9 GB) go via S3 multipart. The R2/backing endpoint has intermittently returned 503
`ServiceUnavailable` on `CreateMultipartUpload` and dropped parts mid-transfer. The result: a multipart upload is
INITIATED but never COMPLETED, so no object materializes -- yet the upload is left STRANDED (list-multipart-uploads
showed tui4's from 2026-09-20 still open, never aborted). The `aws s3 cp` either errored (and a background retry
was reported as "will finish") or the read-back "verification" checked the LOCAL file, not R2. Either way the
banked-in-R2 claim was FALSE.

This is the "verify cited evidence exists / a check that cannot fail proves nothing" failure: read-back must fetch
FROM R2 (head-object + sha256 of the downloaded object), not stat the local build output.

## What is actually recoverable

The image BYTES exist locally on the dev box (the builds succeeded):
`/var/tmp/tui5-out/`, `/tmp/tui2-build/out/`, `/tmp/imagep-work/out/`, `/tmp/imagep2-work/out/`, `/tmp/usb-image-m/`
etc. So no image is lost -- they were just never uploaded.

## The fix

1. Tuned multipart: `multipart_chunksize 32MB` + `max_concurrent_requests 2` + `retry_mode adaptive` +
   `max_attempts 10`. Smaller parts survive the flaky endpoint's transient 503s where the default 8MB@10-concurrent
   did not. tui5's img upload PROGRESSED under this (27+ of ~183 parts) where prior big uploads stalled.
2. Abort stranded multiparts (`s3api abort-multipart-upload`) so they do not accumulate.
3. ⚠️ VERIFY BY head-object + downloaded-sha256, NEVER by local stat or `s3 cp` exit code. A banking claim is only
   true when `head-object` returns the right ContentLength AND a re-download hashes correctly.

## Consequence

The READMEs of o/p/p2/tui/tui2/tui3/tui4 overstate R2 banking -- treat them as "built + verified in the shipped
artifact locally" but NOT R2-durable. Re-bank the current image (tui5) properly; older ones can be re-banked from
their local bytes if needed, but tui5 supersedes them all.

## ROOT CAUSE FOUND (measured 2026-09-22, tui6) -- it is not flakiness, it is EVICTION

The "tuned multipart" fix above did NOT solve it, and the reason is now understood. Under head-object +
re-download-sha verification (never local stat), the `rustfs` backing endpoint was proven to **retain only the
SINGLE most-recently-completed multipart object per prefix -- each new multipart completion EVICTS the previous
one.** Reproduced with multiple controls:

1. Uploaded the iso-tree alone -> COMPLETED + verified (head-object ContentLength + re-download sha == SHA256SUMS),
   PERSISTED at 60s.
2. Then uploaded store.iso alone -> COMPLETED + verified -- but the tree was EVICTED the instant store.iso's
   multipart completed (prefix held ONLY store.iso).
3. Re-uploaded the tree -> store.iso was EVICTED (prefix held ONLY the tree). Symmetric.
4. Forcing a single-part PUT above the multipart threshold: the 1.36 GB PUT evicted the tree AND then failed
   outright (endpoint dropped the large PUT).
5. Small SINGLE-PART objects (nix-cache-info = 21 B, releases/v2026.08.07/, the bucket root listing) are stable
   throughout. The defect is specific to LARGE / MULTIPART objects.

So `install-media/` was always empty not because uploads were "stranded" (that was a symptom) but because **no two
large objects can co-reside in a prefix on this endpoint, and completing one drops the others.** An install-media
set needs 3 large artifacts co-resident, so it can NEVER be durably banked here as-is.

Evidence: `artifacts/install-media/usb-image-20260922-tui6/boot-logs/verify-R2-banking-status.txt`.

### What this changes

- The fix is NOT "retry harder" / "smaller parts" -- it is an ENDPOINT DEFECT that must be fixed on the rustfs side
  (the operator of s3.solnix.io), or worked around by a backend that actually retains multipart objects (real R2/S3,
  or a rustfs version without the eviction bug). File this with whoever runs the endpoint.
- Until then, install-media images are LOCAL-ONLY on the dev box. This is stated honestly in each image README; the
  maintainer flashes from the local bytes. Do NOT claim banked.
- The RECIPE is still banked (the repo builds the image reproducibly); only the large OUTPUT cannot be co-retained.
  A single large object CAN be temporarily parked (it persists until the next large completion in its prefix) -- so
  a one-artifact-per-prefix scheme (distinct prefixes per file) MIGHT survive; untested, and fragile enough that
  local bytes remain the source of truth.
