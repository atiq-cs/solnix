# Vendored OpenBSD `iwx` — provenance and licence

## Source

Fetched from the OpenBSD tree (`sys/dev/pci/`), unmodified, as read-only reference:

| file | lines | version |
|---|---|---|
| `if_iwx.c` | 12,884 | `$OpenBSD: if_iwx.c,v 1.229 2026/05/28 10:51:52 kirill Exp $` |
| `if_iwxreg.h` | 8,961 | |
| `if_iwxvar.h` | 858 | |

`openbsd-orig/` is **never edited**. Adaptations live beside it, so an upstream re-fetch stays a clean diff
— the same discipline as `src/aarch64-arm64-gate-patches/` and `src/drm-port/`.

## Licence — verified, not assumed

The Intel-derived portions carry an explicit dual grant:

> This file is provided under a dual BSD/GPLv2 license. **When using or redistributing this file, you may
> do so under either license.**

So the BSD option is exercisable. Stefan Sperling's OpenBSD-authored portions are ISC
("Permission to use, copy, modify, and distribute this software for any purpose…").

⚠️ The files *do* contain the GPLv2 summary text, because that is what a dual-licence header looks like.
Grepping for "GNU General Public" returns hits in all three files — that is **not** contamination, and
anyone auditing this should read the grant rather than the grep count.

⚠️ Per the maintainer's note: iwlwifi's **`dwm` (device memory management)** portion is GPL-only and is
excluded from BSD builds. OpenBSD's `iwx` already does not include it, which is one more reason this is
the right source rather than Linux's tree.

## Hardware covered

`PCI_PRODUCT_INTEL_WL_22500_1` … `_18` — the **AX200/AX201** family, i.e. the X1 Carbon Extreme's card.

## Firmware

Proprietary and required. OpenBSD **renames** the Intel blobs, so the names differ from Linux's:

| OpenBSD name | chip |
|---|---|
| `iwx-cc-a0-77` | AX200 |
| `iwx-QuZ-a0-hr-b0-77` | AX201 (QuZ stepping) |
| `iwx-Qu-b0-hr-b0-77`, `iwx-Qu-c0-hr-b0-77` | AX201 (Qu steppings) |
| `iwx-so-a0-gf-a0-77` | AX210 |
| `iwx-ty-a0-gf-a0-77` | AX210 (Ty) |

The driver picks one at attach from the PCI id + hardware revision (`if_iwx.c:12387-12421`) and loads it
via `loadfirmware()` (`:1220`). A port must supply that path plus the blob.
