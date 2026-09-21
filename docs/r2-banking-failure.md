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
