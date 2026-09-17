# pkgs/illumos/starter.nix — the FIRST declarative image's starter package set.
#
# Reads docs/registry/real-derivations.tsv (the GATE 1b-PURE real .drv-backed
# packages, each published to cache.solnix.io) and exposes each as
# `pkgs.solnix.starter.<pname>` via builtins.storePath, EXACTLY like cached.nix
# — but keyed off the proven real-derivation set, not the ~10k-row wave manifest
# (which mixes real derivations with placeholder ingests). Use this for the
# assembly milestone: a small, all-substitutable starter userland.
#
# Only rows with published=published AND deriver_resolves=y are exposed (a row that
# isn't actually in the cache would make the toplevel un-substitutable at boot).
# On x86_64-solaris some real-derivations rows are placeholders whose NAR was
# never pushed (e.g. gettext-1.0); those are dropped by the published-narinfo
# reality — the caller lists only names known-present (see base.nix).
#
# ⚠️ THE `published` COLUMN HOLDS A WORD, NOT A FLAG, and this file read it as a flag.
# The filter was `elemAt cols 6 == "y"`, but the column's actual values across the 340
# rows are `published` (225), `staged` (97) and -- on the sparc rows -- a SYSTEM name
# (18), because those rows carry an extra leading column and are shifted. So EVERY row
# was rejected and `pkgs.solnix.starter` evaluated to `{ }`. configurations/base.nix
# does `with pkgs.solnix.starter; [ coreutils file gnugrep ... ]`, which then failed
# with `error: undefined variable 'coreutils'` -- and that error is what blocked every
# toplevel from evaluating on the host.
#
# This was invisible from the Linux side because the flake's cachedOverlay supplies
# `cached` but not `starter`, so the failure only appears in the host eval path. Fixed
# by matching the real vocabulary and by validating the row SHAPE (col 3 must look like
# a store path) instead of trusting the column count -- a shifted row otherwise passes
# a `length >= 8` check while every field means something else.
#
# Same eval semantics + caveats as cached.nix: storePath forces a substituter
# check when the path is absent locally, so evaluate with cache.solnix.io as a
# substituter (base.nix sets it). Last-wins on duplicate pnames.

{
  system ? "x86_64-solaris",
  manifest ? ../../docs/registry/real-derivations.tsv,
}:

let
  hasPrefix =
    pfx: s:
    let lf = builtins.stringLength pfx;
    in builtins.stringLength s >= lf && builtins.substring 0 lf s == pfx;

  lines = builtins.filter (l: builtins.isString l && l != "")
    (builtins.split "\n" (builtins.readFile manifest));

  # header: pname version out_hash out_path deriver_resolves hermetic_closure published system tranche
  rows = map (l: builtins.filter builtins.isString (builtins.split "\t" l)) lines;

  # Keep rows for THIS system that are published and whose deriver resolves.
  #
  # `published` is a WORD (published | staged), not a y/n flag -- see the header note.
  # And the row shape is validated rather than assumed: col 3 must actually start with
  # /nix/store, which rejects the shifted sparc rows whose columns all mean something
  # else while still satisfying a column-count check.
  wanted = builtins.filter (
    cols:
    (builtins.length cols >= 8)
    && (builtins.elemAt cols 0 != "pname")
    && (hasPrefix "/nix/store/" (builtins.elemAt cols 3))
    && (builtins.elemAt cols 7 == system)
    && (builtins.elemAt cols 4 == "y")           # deriver_resolves
    && (builtins.elemAt cols 6 == "published")   # NOT "y"
  ) rows;

  # key by the tsv's own pname column (col 0) — no parseDrvName guessing needed.
  #
  # value is fetchClosure, not storePath: builtins.storePath is FORBIDDEN in
  # pure eval (nix eval .#), which blocks every toplevel from evaluating on a
  # flake-native host. fetchClosure is the pure-legal equivalent — it names the
  # substituter + the path, and Nix pulls the closure at eval time.
  #
  # inputAddressed = true is REQUIRED: our x86_64-solaris paths are
  # INPUT-addressed, and plain fetchClosure errors "fromPath ... is not
  # content-addressed" for that class. With inputAddressed = true, fetchClosure
  # does NOT re-verify content-addressing, so SIGNATURE TRUST does all the
  # integrity work: the path (and its whole closure) must be signed by a key in
  # trusted-public-keys (cache.solnix.io-1:5HAV..., baked into base.nix). A path
  # signed by an untrusted key is REFUSED at eval — which is why publishing only
  # under 5HAV... is load-bearing, not incidental.
  #
  # col 3 is a store path STRING ("/nix/store/...") passed unchanged; do NOT wrap
  # it in storePath (re-introduces the forbidden builtin) or coerce with ./. .
  # Needs the fetch-closure experimental feature on the evaluating Nix.
  entry = cols: {
    name = builtins.elemAt cols 0;
    value = builtins.fetchClosure {
      fromStore = "https://cache.solnix.io";
      fromPath = builtins.elemAt cols 3;
      inputAddressed = true;
    };
  };
in
builtins.listToAttrs (map entry wanted)
