# Man pages & docs — systematic handling in the solnix package builder

Status: implemented (builder change + ledger backfill + sample-rebuild proof).
Owner: build team. Cache: solnix.io only (no AWS S3/ouch asset storage).

## Problem

Man pages rode along OPPORTUNISTICALLY. Whatever a package's `make install`
happened to drop under `$out/share/man` survived; nothing ensured or measured
it. Result: `nano` shipped 4 man pages, `rsync`/`wget` shipped ~0, and the build
ledger's `has_manpages` column was almost entirely `?` (unassessed). Two
packages (`curl`, `rsync`) were actively SUPPRESSING man via configure flags
(`--disable-manual`, `--disable-md2man`).

## Approach (builder — the core change)

`pkgs/illumos/mk-userland-pkg.nix`, mirroring the existing separate-`debug`-output
pattern (but simpler — man pages are small, so they stay in `$out`, no split):

1. **Honor the man install target.** For `autotools`/`configure` builds, pass
   `--mandir=$out/share/man` — but ONLY when `./configure --help` advertises
   `--mandir`. Hand-rolled configures (zlib and friends) ABORT on unknown flags,
   so the flag is probe-guarded. Most GNU autotools already default mandir to
   `$prefix/share/man`, so the flag is a no-op for them and a fix for the few
   that key off it. New params:
   - `mandir` (default `share/man`) — the man dir under `$out`.
   - `manInstallTargets` (default `""`) — extra make target(s) like
     `install-man` for packages whose man install is a separate rule.

2. **Never strip man pages.** The debug-split and RUNPATH passes only touch ELF
   files (guarded by `objdump`/`elfdump`), so man pages are untouched. No man
   removal anywhere.

3. **Verify + count after install.** After `postInstall`, count regular files
   under `$out/share/man`, `$out/man`, `$out/usr/share/man`, `$out/usr/man`
   (skipping `whatis`/`windex`/`man.cf`) and write the total to
   `$out/.manifest-man`. A real number (including 0) so the ledger backfill reads
   truth instead of guessing. The count never fails the build — some tools
   genuinely ship no man pages.

4. **No separate `man` output.** Man pages are small and belong with the tool.
   Keeping them in `$out` is simpler than a second store path; the `debug` split
   stays the only multi-output case.

illumos note: illumos uses both `/usr/share/man` (SVR4 sections 1, 1m, 3c, 5, …)
and per-package man dirs. The builder preserves whatever upstream ships to
`$out/share/man`; it does not rewrite sections or relocate to `/usr/share/man`.

## Backfilling `has_manpages` for the cached set

`scripts/oi-check-manpages.sh` (runs on a builder) inspects the REAL cached store
path — either by attr name (`nix-instantiate` → realise → count) or by explicit
`--paths <storepath>` (needed because the cached artifacts were produced by an
older builder, so re-instantiating gives a different hash). It pulls each closure
from the cache via `oi-pull.sh` and reads `$out/.manifest-man` (new builds) or
live-counts `share/man`/`man` (old builds).

`scripts/backfill-manpages.py` merges the results into
`docs/registry/build-ledger.tsv`:

- **Standalone tools** (finite set, ~40): mapped fmri→attr in
  `docs/registry/manpage-attr-map.tsv`; count>0 → `y`, count==0 → `n`.
- **Language modules** (`library/python/*`, `library/perl-5/*`, ~1950 rows): set
  to `n` as a CLASS. Spot-checked 4 real cached module NARs (2 perl, 2 python) —
  all shipped 0 man files. Language modules install module files, not
  `share/man`; realising ~1950 closures one-by-one to confirm each is wasteful,
  so the verified class rule applies.

Only `cached=yes` rows are touched; uncached rows keep `?` (no data = no claim).

## Results (this pass)

- Cached rows backfilled from `?`: 1950 library modules → `n`, 12 tools from
  real man-counts (rsync/curl/wget/nano/zsh/tmux/jq/tree/gawk/grep/sed/diffutils
  → `y`; cmake/git/perl → `n` — see below). Combined with prior `y`/`n`, the
  cached set is now 44 `y` / 1968 `n` / 2 `?` (down from 1962 `?`).
- 2 unresolved: `library/libidn2`, `library/libpsl` — their exact cached hash
  isn't in the artifacts index and the current builder hash differs, so their
  NAR couldn't be located to inspect honestly. Left `?` rather than guessed.
  (Both almost certainly ship man; will resolve on their next rebuild via
  `.manifest-man`.)
- `cmake`/`git`/`perl` show `n` from the cache because their man builds need
  extra tooling the OI build didn't wire (git: asciidoc/xmlto; cmake: sphinx;
  perl: versioned `man/` layout). Recorded as `n` = the honest cache reality;
  fixing them is a per-package follow-up, not a builder change.

## Suppressor fixes (packages.nix)

- `curl`: dropped `--disable-manual` (was killing `curl.1`; libcurl section-3
  pages install regardless — the cache already had 501).
- `rsync`: dropped `--disable-md2man` (rsync ships pre-built `*.1`; the flag
  zeroed `MAKE_MAN` and skipped installing even the shipped pages).

## doc_review (illumos-vs-Solaris divergence)

`doc_review=needed` flags core packages whose man CONTENT (not just presence)
describes an illumos/Solaris mechanic solnix replaces (IPS/BE/SMF/paths). This is
a CONTENT review, separate from `has_manpages`. Sampled findings in
`artifacts/manpages/doc-review-notes.md`; the process:

1. For a flagged fmri, read the shipped man page(s).
2. Flag any text describing IPS package operations, boot environments (`beadm`),
   SMF specifics, or Solaris-only paths that diverge from what solnix ships.
3. Note whether the page needs a solnix-specific rewrite or a pointer, or is
   fine as-is. Don't rewrite in this pass — record the divergence.

## Future waves

New builds inherit the fixed builder automatically: `--mandir` honored where
supported, man preserved, `.manifest-man` stamped. The ledger backfill for a
future wave is then just: read `.manifest-man` from each freshly-built out (no
guessing). No per-package man config needed unless a package uses a nonstandard
man target (then set `mandir`/`manInstallTargets`).
