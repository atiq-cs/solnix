# Cache integrity audit: 47 of 340 published derivations are unfetchable

Measured directly against `cache.solnix.io` (and cross-checked on the
`s3.solnix.io/solnix-cache` origin), walking every row of
`docs/registry/real-derivations.tsv`.

This matters because of the project's founding claim: **solnix must be *exactly*
Nix — every package a real derivation where `nix-build` works and
`nix-store --query --deriver` resolves.** A derivation whose output cannot be
fetched fails that claim in practice, however well-formed its metadata is.

## The numbers

| | count |
|---|---|
| fetchable end to end (narinfo 200 → NAR 200) | **293** |
| **unfetchable** (7 phantom + 40 missing narinfo) | **47** |
| total published rows audited | 340 |

## Two distinct failure modes

**A. Missing narinfo (40 packages).** The `.narinfo` itself is 404, so a client is
simply told the path is not in the cache. Undesirable but *honest* — Nix falls back
to building from source.

**B. Phantom entries (7 packages) -- the serious one.** The `.narinfo` is served
**200 with complete, plausible metadata**, and the NAR it points at is **404**. The
cache asserts it has the path, then cannot deliver it. Nix does not fall back
gracefully from this: it has already committed to a substitution that then fails.

Confirmed precisely for `coreutils`:

```
GET /3wlwvk71i6dfwiq63kdakq02fig8m68p.narinfo      -> 200
  StorePath: /nix/store/3wlwvk71i6dfwiq63kdakq02fig8m68p-coreutils
  URL:       nar/0bag7hfib3c66ar9gnv6x59cjgg4irkvij8jwvw7fs05hlg97rlq.nar.xz
  FileSize:  1049264
  NarHash:   sha256:0rhyi9qyzr5wk2l2i8walsbh36xbxr1vzqx080qh967iww4q1kvb
GET nar/0bag7hfib3c66ar9gnv6x59cjgg4irkvij8jwvw7fs05hlg97rlq.nar.xz
  cache.solnix.io -> 404 404 404
  s3.solnix.io    -> 404 404 404
```

**This is not the S3 read non-determinism** described in
`docs/registry/AUDIT-cache-phantom-2026-08-03.md`. That audit found objects
flipping 200→404 between requests. Here the NAR is **consistently absent from both
the CDN and the origin across repeated GETs** — the object is gone, not flaky. A
sub-agent reported exactly this for `coreutils` earlier and it could not be
reproduced at the time for want of a specific path; this is that reproduction.

## The affected packages

Mode B (phantom -- narinfo 200, NAR 404), the exact 7 from `docs/registry/AUDIT-cache-unfetchable.tsv`: `coreutils`, `pkg-config`, `libgcrypt`, `autoconf`, `sqlite`, `libxslt`, `binutils`.
`autoconf`, `sqlite`, `libxslt`, `binutils`.

Mode A (narinfo 404): `ncurses`, `readline`, `perl`, `libtool`, `openssl`,
`libedit`, `curl`, `openssh`, `gmp` (+dev/info), `libffi` (info/man), `gawk`
(+man), `tzdata`, `ed`, `libidn2`, `git`, `wget`, `tmux`, `vim`, `rsync`,
`libssh2`, `nghttp2`, `xz`, `re2c`, `ninja`, `npth`, `zsh`, `sqlite`.

Note the profile: these are not obscure leaves. `coreutils`, `openssl`, `curl`,
`git`, `perl`, `sqlite`, `binutils` are exactly the packages a user would reach for
first, which makes the gap more visible than 47/340 suggests.

## What this is and is not

* It is **not** a claim that the derivations are wrong. `deriver_resolves=y` and
  `hermetic_closure=y` in the registry were established at build time and are not
  invalidated by a missing binary artifact.
* It **is** a claim that the cache cannot currently satisfy them, so a user on a
  fresh machine would have to rebuild those 47 from source — and for the 8 phantoms
  would hit a substitution failure rather than a clean fallback.

## Recommended repair, in order

1. **Delete the 7 phantom narinfos** (or re-upload their NARs). A 404 narinfo is
   strictly better than a lying one: it degrades to "build from source" instead of
   failing mid-substitution. This is the only item that changes user-visible
   behaviour from *broken* to *slow*, so it goes first.
2. **Re-publish the 47** from a host that still has the store paths. The registry
   rows give exact `out_path`s, so this is mechanical rather than a rebuild — if any
   machine still holds them.
3. **Add a fetchability check to the publish path.** Publishing currently records
   `published=y` without verifying the object is retrievable afterwards. A
   narinfo→NAR GET immediately after upload would have caught all 47 at the moment
   they were introduced, and is cheap.
4. **Re-run this audit as a gate**, not an investigation. The whole walk takes a few
   minutes and produces a single number; drift is invisible until measured.

## Reproducing

Walk `docs/registry/real-derivations.tsv`, and for each `out_hash`: GET
`$hash.narinfo`, parse its `URL:` line, GET that. Count end-to-end 200s. Treating
a 200-narinfo-with-404-NAR as a *distinct* failure class from a 404 narinfo is the
part that matters — collapsing them hides the mode that actually breaks clients.

## Machine-readable output

`docs/registry/AUDIT-cache-unfetchable.tsv` — 47 rows, columns
`pname / out_hash / out_path / failure_mode` where the mode is `phantom_nar_404`
(7) or `narinfo_404` (40). Sorted so the phantoms come first, since those are the
ones that break a client rather than merely slow it down. The `out_path` column is
what a re-publish needs, so repair is mechanical if any host still holds the paths.
