# pkgs/illumos/recipes/default.nix — the Phase-2 REAL-derivation overlay.
#
# Reads recipes.tsv (build recipes recovered from packages.nix + wave specs.tsv,
# see docs/roadmap-fully-nixified.md Phase 2 C1) and maps EACH row through
# mk-from-recipe.nix into a real stdenv.mkDerivation. The result is
#   recipePackages.<pname> = <derivation>
# the source-buildable parallel to cached.nix's storePath overlay (which stays
# as the bootstrap: cached.* are prebuilt leaf inputs, recipePackages.* are
# provable derivations once the Phase-1 solnix stdenv lands).
#
# stdenv/fetchurl come from the caller (the flake overlay threads the solnix
# stdenv here). Until Phase-1 stdenv exists these EVALUATE (parse + instantiate
# the attrset structure + .drv referencing a placeholder stdenv.cc) but do NOT
# fully build — that is expected and is the head-start: the recipes are captured
# so no one re-discovers how each package was built.
#
# EVAL CHECK (offline, no stdenv needed for attrNames):
#   nix eval --impure --expr 'let r = import ./pkgs/illumos/recipes {
#       stdenv = null; fetchurl = null; lib = (import <nixpkgs> {}).lib; };
#     in builtins.length (builtins.attrNames r.recipePackages)'
# Forcing a value needs a stdenv; see the validation notes in the task report.

{ stdenv
, fetchurl
, lib
, recipesFile ? ./recipes.tsv
}:

let
  # --- parse recipes.tsv (tab-separated, '#'-comment lines skipped) ---
  raw = builtins.readFile recipesFile;
  allLines = builtins.filter (l: builtins.isString l && l != "")
    (builtins.split "\n" raw);
  dataLines = builtins.filter (l: builtins.substring 0 1 l != "#") allLines;

  # split a line on tabs, keeping only the string pieces (builtins.split
  # interleaves the regex match-groups as lists).
  splitTab = l: builtins.filter builtins.isString (builtins.split "\t" l);

  # column order: pname version url buildsys deps flags sha256 source
  col = cols: i: if builtins.length cols > i then builtins.elemAt cols i else "";
  toRecipe = l:
    let c = splitTab l; in
    {
      pname = col c 0;
      version = col c 1;
      url = col c 2;
      buildsys = col c 3;
      deps = col c 4;
      flags = col c 5;
      sha256 = col c 6;
      src = col c 7;
    };

  recipes = map toRecipe dataLines;

  # --- resolveDep: a recipe's dep name -> another recipe's derivation.
  # recipePackages is defined below via `rec`, so deps cross-reference each
  # other. Names with no matching recipe resolve to null (dropped as a buildInput;
  # a stricter Phase-2.1 could fall back to nixpkgs or throw).
  resolveDep = name:
    if builtins.hasAttr name recipePackages
    then builtins.getAttr name recipePackages
    else null;

  mkFromRecipe = import ./mk-from-recipe.nix {
    inherit stdenv fetchurl lib resolveDep;
  };

  # --- build the attrset: pname -> derivation (last-wins on dup pname, but
  #     recipes.tsv is already deduped by the extractor). ---
  recipePackages = builtins.listToAttrs
    (map (r: { name = r.pname; value = mkFromRecipe r; }) recipes);

in
{
  inherit recipePackages;
  # convenience: how many recipes, and how many carry a real sha256 pin.
  recipeCount = builtins.length recipes;
}
