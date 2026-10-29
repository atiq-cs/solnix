# aarch64 static TLS (arm64-gate 6cd2521c1e): rtld + libc + ld, 2026-10-29

These fix the aliased thread-locals on aarch64 found by dixa1 (tls-finding.md, bank `~/solnix-bank/dixa1-20261028/tls/`). Before the
fix, every shared object's `__thread` data resolved to tp+16, so libc's, libstdc++'s and nix's thread-locals overlapped and nix-daemon
crashed.

## The diffs (against richlowe/illumos-gate 6cd2521c1e)

| file | change |
|---|---|
| `aa64tls-rtld.diff` | `elf_static_tls()` variant 1 returns `16 + TLSSTATOFF(lmp) + value`; before, `TLSSTATOFF` was dropped, which is right only for the executable. `tls_assign()` variant 1 rounds a module's offset up to max(16, p_align) and counts the pad in its size. |
| `aa64tls-libc.diff` | `slow_tls_get_addr()` variant 1 static base = `self + sizeof (ulwp_t) + tm_stattlsoffset`; before, the offset was dropped, so every GD access hit the executable's block. Adds `CTASSERT(sizeof (ulwp_t) % 64 == 0)`, so the TLS area after the ulwp_t is 64-aligned (lmalloc gives 64). |
| `aa64tls-ld.diff` | `ld_reloc_TLS()`: an executable's GD reference keeps its GD GOT pair (DTPMOD/DTPREL). Before, it got an IE (TPREL) slot while `tls_fixups()` is `#if 0`, so the GD code (`bl __tls_get_addr`) read a TP offset as a `tls_index`. |

**Why keep GD instead of writing tls_fixups.** The AArch64 GD->IE relaxation rewrites four instructions (`adrp/add/bl/nop` to `adrp/ldr/mrs/add`) and must match each sequence. The fix here is one condition, and it is correct for every input. Its cost is a `__tls_get_addr` call in executables built `-fPIC`, which is the same as in shared objects. The template and per-thread copy in libc were already right (`tls-layout.sh` measured them), so these address computations are the whole fix.

## Measured (dixa, c6gd.metal; nothing installed; test/)

`run-matrix.sh` runs `tls-repro2.sh` under each rtld x libc combination; output in `test/step3-matrix.txt`:

| rtld | libc | result |
|---|---|---|
| image | image (store rs4hiizl) | 0/6 PASS, rc 1 (negative control) |
| rebuilt, no diffs | rebuilt, no diffs | 0/6, rc 1 (rebuild control) |
| fixed | image | 2/6: the IE cases pass, every GD case fails |
| image | fixed | 3/6: A, A' and B-gd pass, the IE cases fail |
| fixed | fixed | **6/6, rc 0**: A at +16/+32/+64/+112, A' at +160/+128/+80/+16, B 0/50 bad, aligned(64) mod64=0 |

`tls-ldtest.sh` (`test/step3-ldtest.txt`): the image ld gives 1 TPREL slot under GD code, and tv reads garbage in 20/20 threads. The fixed ld gives a DTPMOD+DTPREL pair, tv=42, and 0/20 threads go wrong.

nix-daemon, `nix-store -r --dry-run` of real drvs, which aren't on any cache:
- Before: 34/34 runs crashed, each leaving a core: SIGSEGV addr=8 in `ThreadPool::doWork`.
- After, with the store set rebuilt on the new proto: 0 crashes in 51 daemon sessions, including a gburd@dixa home realise of 63 builds with substituters on.

## Build

- `bh-tls.sh` runs on the restored cross host and builds libc and cmd/sgs.
- `bh-proto.sh` builds the new proto tarball: the 20260912 proto with only lib/libc.so.1, lib/ld.so.1 and lib/libld.so.4 replaced. Its sha256 is `81192a7c...` and its NAR `0d1szk5c...`.
