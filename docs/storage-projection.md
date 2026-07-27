# Storage projection for the solnix cache (all artifacts, all arches)

Anchored on MEASURED cache data: 3,270 packages = 2.9 GB compressed today,
avg 923 KB/pkg (incl big ones: clang 229MB, gcc14 135MB, rust 158MB, most
py/perl modules <1MB). solnix.io stores COMPRESSED NARs (~5:1 vs uncompressed).

## Projected final size (compressed, on solnix.io)

| Component | Packages | Compressed |
|-----------|----------|-----------|
| x86_64-solaris: Hipster current | 5,920 | 5.2 GB |
| + clang dual variants (~40%) | 2,368 | 2.1 GB |
| + separate debug outputs (~0.6x) | 8,288 | 4.4 GB |
| **x86_64 subtotal** | | **11.7 GB** |
| aarch64-solaris (~80% of core + debug) | ~4,700 | 6.7 GB |
| sparcv9-solaris (~60%, sun4u+sun4v share userland) | ~3,500 | 5.0 GB |
| riscv64-solaris (future, ~50%) | ~3,000 | 4.2 GB |
| seed/proto archives (4 arches) | | 2.0 GB |
| **Hipster set, ALL 4 arches + debug + archives** | | **~29.5 GB** |
| + pkgsrc superset (x86_64, ~8,000 later) | | +11.3 GB |
| **GRAND TOTAL with pkgsrc** | | **~41 GB** |

## Takeaways
- **~30 GB** for the full Hipster set across all 4 architectures + debug symbols
  + seed/proto archives. **~41 GB** if we add the pkgsrc superset on x86_64.
- Uncompressed client-side (a full closure materialized in /nix/store) is ~5x,
  but NO single client pulls everything — they pull only their closure. The
  CACHE (solnix.io) stores compressed: ~30-41 GB total.
- This is SMALL — fits comfortably on solnix.io's S3-compatible storage; a single
  cheap object-store bucket. Not a cost concern. The P2P BitTorrent cache (T2.11)
  is about DISTRIBUTION/resilience, not capacity.
- Debug outputs are ~37% of x86_64 size but pulled only when debugging — the
  split-output design keeps normal installs lean.
