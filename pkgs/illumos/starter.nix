# pkgs/illumos/starter.nix — the FIRST declarative image's starter package set.
#
# Reads docs/registry/real-derivations.tsv (the GATE 1b-PURE real .drv-backed
# packages, each published to cache.solnix.io) and exposes each as
# `pkgs.solnix.starter.<pname>` via builtins.storePath, EXACTLY like cached.nix
# — but keyed off the proven real-derivation set, not the ~10k-row wave manifest
# (which mixes real derivations with placeholder ingests). Use this for the
# assembly milestone: a small, all-substitutable starter userland.
#
# Only rows with published=y AND deriver_resolves=y are exposed (a row that
# isn't actually in the cache would make the toplevel un-substitutable at boot).
# On x86_64-solaris some real-derivations rows are placeholders whose NAR was
# never pushed (e.g. gettext-1.0); those are dropped by the published-narinfo
# reality — the caller lists only names known-present (see base.nix).
#
# Same eval semantics + caveats as cached.nix: storePath forces a substituter
# check when the path is absent locally, so evaluate with cache.solnix.io as a
# substituter (base.nix sets it). Last-wins on duplicate pnames.

{
  system ? "x86_64-solaris",
  manifest ? ../../docs/registry/real-derivations.tsv,
}:

let
  hasSuffix =
    sfx: s:
    let ls = builtins.stringLength s; lf = builtins.stringLength sfx;
    in ls >= lf && builtins.substring (ls - lf) lf s == sfx;

  lines = builtins.filter (l: builtins.isString l && l != "")
    (builtins.split "\n" (builtins.readFile manifest));

  # header: pname version out_hash out_path deriver_resolves hermetic_closure published system tranche
  rows = map (l: builtins.filter builtins.isString (builtins.split "\t" l)) lines;

  # keep this system, published=y, deriver_resolves=y, skip the header row.
  wanted = builtins.filter (
    cols:
    (builtins.length cols >= 8)
    && (builtins.elemAt cols 0 != "pname")
    && (builtins.elemAt cols 7 == system)
    && (builtins.elemAt cols 4 == "y")   # deriver_resolves
    && (builtins.elemAt cols 6 == "y")   # published
  ) rows;

  # key by the tsv's own pname column (col 0) — no parseDrvName guessing needed.
  entry = cols: {
    name = builtins.elemAt cols 0;
    value = builtins.storePath (builtins.elemAt cols 3);
  };
in
builtins.listToAttrs (map entry wanted)
