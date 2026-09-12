# Vendored OpenBSD `net80211` — provenance and licence

## Source

Fetched from OpenBSD `sys/net80211/`, **unmodified and read-only**, mirroring the
`src/wifi-port/iwx/openbsd-orig/` discipline so an upstream re-fetch stays a clean diff.

`orig/` is **never edited.** Adaptations live outside it — the probe headers under `compat/`, and
any future rewrite as a patch against `orig/`, exactly as `iwx/patches/if_iwx.illumos.patch`
works.

## Fetch method, and why it is two sources

21 files came from `cvsweb.openbsd.org/checkout/src/sys/net80211/<file>?rev=<rev>`. cvsweb then
began timing out (HTTP requests hanging past a 90 s timeout across three retries each), so the
remaining 10 came from `raw.githubusercontent.com/openbsd/src/master/sys/net80211/`.

⚠️ **The mirror was not assumed equivalent, it was checked.** Two files already fetched from
cvsweb were re-fetched from the GitHub mirror and compared with `cmp`:

```
cmp github/ieee80211.c        cvsweb/ieee80211.c        -> identical
cmp github/ieee80211_input.c  cvsweb/ieee80211_input.c  -> identical
```

Both are large files (1,507 and 3,652 lines) covering different subsystems. The `$OpenBSD$`
revision line in every mirror-fetched file also matches the revision cvsweb's directory index
advertised as current. That is the evidence for treating the 10 mirror files as upstream; it is
not a proof for every byte of every file, and it is recorded here rather than glossed.

## File list, line counts, CVS revisions

31 files, **24,665 lines** total. Revisions and dates are read from each file's own `$OpenBSD$`
tag, not from the index, so this table is reproducible from the files themselves:

| file | lines | rev | date |
|---|---|---|---|
| `ieee80211.c` | 1,507 | 1.92 | 2026/03/19 |
| `ieee80211.h` | 1,204 | 1.67 | 2026/05/28 |
| `ieee80211_amrr.c` | 127 | 1.12 | 2019/02/24 |
| `ieee80211_amrr.h` | 58 | 1.4 | 2007/06/16 |
| `ieee80211_crypto.c` | 682 | 1.81 | 2025/12/03 |
| `ieee80211_crypto.h` | 194 | 1.28 | 2025/03/22 |
| `ieee80211_crypto_bip.c` | 219 | 1.10 | 2018/11/09 |
| `ieee80211_crypto_ccmp.c` | 491 | 1.22 | 2020/05/15 |
| `ieee80211_crypto_tkip.c` | 789 | 1.34 | 2026/07/15 |
| `ieee80211_crypto_wep.c` | 305 | 1.17 | 2018/11/09 |
| `ieee80211_input.c` | 3,652 | 1.263 | 2026/05/28 |
| `ieee80211_ioctl.c` | 990 | 1.84 | 2025/12/03 |
| `ieee80211_ioctl.h` | 433 | 1.46 | 2026/05/28 |
| `ieee80211_node.c` | 3,611 | 1.216 | 2026/05/24 |
| `ieee80211_node.h` | 725 | 1.102 | 2026/05/28 |
| `ieee80211_output.c` | 2,303 | 1.148 | 2026/05/28 |
| `ieee80211_pae_input.c` | 1,198 | 1.39 | 2026/05/24 |
| `ieee80211_pae_output.c` | 640 | 1.33 | 2022/01/05 |
| `ieee80211_priv.h` | 135 | 1.5 | 2009/01/26 |
| `ieee80211_proto.c` | 1,463 | 1.113 | 2026/05/28 |
| `ieee80211_proto.h` | 192 | 1.51 | 2026/03/19 |
| `ieee80211_ra.c` | 744 | 1.5 | 2022/03/19 |
| `ieee80211_ra.h` | 82 | 1.2 | 2021/10/11 |
| `ieee80211_ra_vht.c` | 758 | 1.3 | 2022/03/23 |
| `ieee80211_ra_vht.h` | 91 | 1.1 | 2022/03/19 |
| `ieee80211_radiotap.h` | 215 | 1.17 | 2022/03/14 |
| `ieee80211_regdomain.c` | 184 | 1.10 | 2015/11/24 |
| `ieee80211_regdomain.h` | 768 | 1.9 | 2016/01/12 |
| `ieee80211_rssadapt.c` | 273 | 1.11 | 2014/12/23 |
| `ieee80211_rssadapt.h` | 103 | 1.5 | 2010/07/17 |
| `ieee80211_var.h` | 529 | 1.115 | 2026/05/28 |

**18** `.c` files, **13** `.h` files.

⚠️ `../iwx/STATUS.md` states "14 `.c` files" (and "31 files / 24,665 lines", which is right). The
file total and the line total check out; the **`.c` count is wrong — it is 18**. Recorded here at
the source rather than only in the doc that supersedes it.

## The 13 headers already staged in `iwx/compat/net80211/` are identical to these

Session two staged 13 headers into `src/wifi-port/iwx/compat/net80211/` (4,729 lines) to drive
`if_iwx.c`'s 802.11 error surface down. Every one is **byte-identical** to the copy fetched here:

```
13 compared, 13 identical, 0 differ      (cmp, per file)
```

So there is exactly one vendored version of each header and no divergence to reconcile. The
`iwx/compat/net80211/` copies remain where the driver's `-I` path expects them; `orig/` is the
provenance record and the source for any future re-fetch diff.

## Licence — verified, not assumed

OpenBSD `net80211` is **ISC/BSD throughout**; there is no dual-GPL text here, unlike `if_iwx.c`
(whose Intel-derived portions carry an explicit dual BSD/GPLv2 grant — see
`iwx/PROVENANCE.md`).

Copyright holders across the 31 files: Damien Bergamini, Stefan Sperling, Christian Ehrhardt /
genua gmbh, Reyk Floeter, Atsushi Onoe, Sam Leffler / Errno Consulting, the NetBSD Foundation,
David Young. All grants are ISC or 2/3-clause BSD.

⚠️ Checked by reading the grants, not by grepping for licence keywords — `iwx/PROVENANCE.md`
records why that distinction matters (grepping "GNU General Public" in `if_iwx.c` hits a
*dual-licence header* and is not contamination).

## What is here and what is NOT

* `orig/` — the 31 upstream files, read-only. **REAL** upstream source.
* `compat/` — **PROBE STUBS ONLY.** 16 near-empty headers created solely so the compiler gets
  past `#include` and reaches the function bodies, which is what made the error-surface
  measurement in `FINDINGS.md` possible. Every one is tagged in its own text as a probe.
  **They are not a port** and nothing here compiles to a usable object except the four files
  named in `FINDINGS.md`.

Nothing in this directory is built by any Nix derivation or referenced by any build. It is
measurement input and vendored reference.
