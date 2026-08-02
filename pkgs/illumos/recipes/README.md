# Phase-2 recipe overlay (real derivations)

The ~10k cached packages (`docs/registry/arch-manifest.tsv`, exposed via
`pkgs/illumos/cached.nix` as `storePath` roots) were built by
`scripts/oi-clib.sh` — host gcc + `nix-store --add`, NOT derivations. This
directory replays the RECOVERABLE build recipes as real
`stdenv.mkDerivation`s so they become source-buildable (provable provenance)
once the Phase-1 solnix `stdenv` lands. See
`docs/roadmap-fully-nixified.md` Phase 2 C1.

## Files

- `recipes.tsv` — normalized recipe table:
  `pname  version  url  buildsys  deps  flags  sha256  source`.
  Recovered from `pkgs/illumos/packages.nix` (114, sha256-pinned) +
  `artifacts/**/specs.tsv` wave specs (184, unpinned — sha256 empty).
- `build-recipes.py` — regenerates `recipes.tsv` from those two sources
  (`nix eval` of packages.nix + tab-parse of specs.tsv). Run from repo root.
- `mk-from-recipe.nix` — maps ONE recipe row to a real `mkDerivation`;
  buildsys phases modeled on `oi-clib.sh`; per-family portability hooks
  (gnulib const-qualify, GNU-linker option strip, C++ math-in-global-ns,
  endian shim, `__EXTENSIONS__`).
- `default.nix` — reads `recipes.tsv`, returns `recipePackages.<pname>`.

## The gap (honest)

298 distinct recipes recovered. The x86_64 cache has ~4799 distinct pnames
(arch-manifest), so ~4500 have NO recoverable recipe: the wave campaigns saved
only `results.tsv` (pname/version/storepath), not the `oi-clib.sh` args
(url/buildsys/deps/flags). Those need re-derivation from nixpkgs upstream
recipes, not recovery from artifacts.

## Eval check (offline)

```
nix eval --impure --expr 'let r = import ./pkgs/illumos/recipes {
    stdenv = null; fetchurl = null; lib = (import <nixpkgs> {}).lib; };
  in builtins.length (builtins.attrNames r.recipePackages)'   # -> 298
```

Forcing a value (`.drvPath`) needs a stdenv; until Phase-1 lands, pass
nixpkgs' `stdenv`/`fetchurl` to confirm the mapping instantiates a `.drv`
(referencing the placeholder stdenv) — builds only succeed once the solnix
stdenv is wired in.
