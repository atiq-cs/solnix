# seed-main: main's aarch64 seed, frozen (wave6x, 2026-11-05; orchestrator decision (A))

wave6's aarch64 set builds from main's SERVED aarch64 seed outs. Here the seed rung is a fixed bootstrap, as in nixpkgs'
bootstrap-tools: the stdenv takes a pinned toolchain whose bytes are not rebuilt by every stdenv change.

`illumos/` is a verbatim copy of the 26 files that main 773733a's `import ./pkgs/illumos/aarch64 { stage = "seed"; }` reads. The list
was measured with strace over nix eval, and every file is byte-identical to main 773733a. ../default.nix imports
`./seed-main/illumos/aarch64` for `seed` only, so wave6's own recipe text (mk-src-pkg, base-src, ...) does not move these drvs.

Check (re-run after any edit here, or when main's seed changes):
- every seed attr's outPath equals main's and is served (narinfo 200);
- gate, gcc, libc, ld, rtld and sys are the same drvs in wave6 and here (one bootstrap toolchain).

Do not edit these files. Replace the whole directory from a newer main when main's seed moves, and re-check.
