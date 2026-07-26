# SPARCv9 & RISC-V via QEMU-on-EC2 — feasibility

Answering: can we bootstrap RISC-V and UltraSPARCv9 using EC2 hosts running QEMU
as the foundation? Short: QEMU-on-EC2 is a fine SUBSTRATE for both (same pattern
as aarch64 — cross-build on an amd64 illumos host, boot a QEMU guest). But the
substrate is NOT the hard part. The hard part is whether an illumos PORT exists
for the ISA. The two diverge sharply.

## The distinction that governs everything

QEMU-on-EC2 answers "where do we build/boot," not "does an OS exist to boot."

| Arch     | illumos port?              | QEMU machine        | "bootstrap" = |
|----------|----------------------------|---------------------|---------------|
| x86_64   | yes (in-gate)              | native EC2          | DONE (boots)  |
| aarch64  | yes (out-of-tree, active)  | `virt` (GICv2)      | integrate the port — IN PROGRESS, kernel built |
| SPARCv9  | yes (in-gate, bit-rotting) | `sun4u` (sparc64)   | REVIVE + build-triage — medium |
| RISC-V   | **NO port at all**         | `virt` (great)      | WRITE the port first — multi-year, THEN QEMU-test |

## SPARCv9 (sun4u/sun4v = UltraSPARC / T-series) — startable QEMU track

- illumos HAS SPARC support in-gate (the original Solaris arch), bit-rotting but
  present; Tribblix + DilOS still ship SPARC builds.
- QEMU emulates SPARC64: `qemu-system-sparc64 -machine sun4u`. So the recipe
  MIRRORS aarch64:
  1. cross-build the SPARC gate on our amd64 illumos build host (`nightly` with
     the sparc MACH, or the distro forks' build recipes),
  2. boot the result in `qemu-system-sparc64 -machine sun4u` (OBP/SILO or the
     illumos sparc boot path),
  3. extract a seed, wire `sparcv9-solaris` (triple `sparcv9-sun-solaris2.11`)
     into lib.systems (mirror the x86_64-solaris pattern), stdenv + world slices,
  4. make-be for the sparc boot path.
- **Hardness: medium (revival, not port-from-scratch).** Risks: sun4u/sun4v code
  may not build clean on a modern gate (CTF/toolchain/mapfile drift); QEMU
  sun4u is less exercised than aarch64 `virt`; sun4v (T-series) emulation is
  weaker than sun4u. Lean on Tribblix/DilOS patches. Real T-series hardware (the
  maintainer's home UltraSPARC) is the eventual truth after QEMU.
- **Verdict: a legitimate QEMU-on-EC2 track we CAN start** (Phase 4). Same
  machinery as aarch64; the work is build-triage of existing code.

## RISC-V — QEMU substrate is trivial; there is nothing to run on it

- QEMU's `qemu-system-riscv64 -machine virt` is best-in-class. Substrate: run it
  on any amd64/Graviton EC2 host (no RISC-V EC2 needed).
- **BLOCKER (upstream, not us): illumos has NO RISC-V port.** No riscv kernel, no
  `uts/riscv`, no toolchain target, no mapfiles/CTF for riscv in the gate. QEMU
  gives a machine to boot NOTHING — there's no illumos-riscv64 kernel to load.
- So "bootstrap RISC-V via QEMU" = "write a RISC-V port of illumos FIRST": new
  HAL/locore/trap/interrupt/MMU, the toolchain target, drivers, CTF — a
  multi-year kernel effort (the aarch64 port took years + a formal illumos IPD).
  QEMU only helps TEST that port once it exists.
- **Verdict: RISC-V is a WRITE-THE-PORT research track, not a QEMU/package task.**
  QEMU readiness is not the gap; the OS is. Realistic options: (a) champion an
  upstream illumos RISC-V port (huge, community-scale), or (b) wait for one.
  Do NOT represent RISC-V as bootstrappable "just via QEMU."

## Recommendation

- **SPARCv9: schedulable now as a QEMU-on-EC2 revival track** (Phase 4), reusing
  the aarch64 machinery (cross-build → QEMU boot → seed → lib.systems → world).
  Start after aarch64 A3/A4 proves the QEMU-guest pattern end-to-end (it's the
  cheaper proof, and its lessons transfer).
- **RISC-V: keep as a research/upstream track** (Phase 5). QEMU is ready and
  waiting; the illumos port is the multi-year prerequisite. Revisit if/when an
  illumos RISC-V effort exists to build on.
