# Architecture Support — Reality & Phasing

The project goal names four architectures: **x86_64, aarch64, SPARC v9, RISC-V**.
Their real-world illumos status differs enormously. This file is the single
source of truth for what "supported" means and the order we tackle them. Do not
promise parity across all four — they are not equal.

## Status matrix (verify before relying)

| Arch        | illumos status today                                     | solnix phase | Risk |
|-------------|----------------------------------------------------------|--------------|------|
| **x86_64 (amd64)** | Primary, only maintained x86 target. 64-bit only (i386 removed ~2018). | Phase 1 | Low |
| **aarch64** | Real **out-of-tree** port (Hayashi Naoyuki); runs on RPi/QEMU, cross-built from amd64 illumos. **Not in illumos-gate.** | Phase 3 | Medium — tracks an unmerged fork |
| **SPARC v9 (sun4v)** | Bit-rotting in-gate; kept alive by **Tribblix/DilOS**. sun4u effectively dead. | Phase 4 | High — fragile, no CI upstream |
| **RISC-V**  | **No known illumos port exists.** Would require writing one first. | Phase 5 (research/upstream) | Very high — multi-year kernel work, not a packaging task |

## What this means for planning

- **Phase 1 is amd64-only.** Everything (stage0 bootstrap, `pkgs.illumos.*`,
  SMF module, images) targets `x86_64-illumos` first. Get one arch fully working
  before generalizing.
- **The Nix platform tuples** are designed multi-arch from day one
  (`x86_64-illumos`, `aarch64-illumos`, `sparcv9-illumos`, `riscv64-illumos`) so
  the plumbing doesn't need reworking later — but only amd64 is wired to a real
  toolchain in Phase 1.
- **aarch64 (Phase 3)** means integrating Hayashi Naoyuki's port as an illumos
  source input and getting its cross-build to run under Nix. It does **not** mean
  waiting for upstream merge. Contribute upstream where possible.
- **SPARC v9 (Phase 4)** means reviving the in-gate sun4v path, likely leaning on
  Tribblix/DilOS patches. Expect toolchain and CTF pain. Real hardware (T4/T5) or
  a SPARC emulator is required for boot testing.
- **RISC-V (Phase 5)** is honestly a **research track**, not a delivery: there is
  no OS to package yet. The deliverable here is either (a) an upstream illumos
  RISC-V port effort, or (b) documenting it as out of scope until such a port
  exists. Do not spend Phase-1 effort pretending the Nix side is the hard part.

## Rule

Any doc, commit message, or status update that lists supported architectures
must reflect this matrix. "Planned" ≠ "supported". Supported means: builds a
world, boots to multi-user SMF milestone, and passes the smoke test on that arch.
