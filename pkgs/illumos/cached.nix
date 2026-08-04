# pkgs/illumos/cached.nix — every wave-built package in the cache, exposed as a
# referenceable Nix attribute keyed by pname.
#
# The wave build (docs/registry/arch-manifest.tsv) produced ~10k packages whose
# NARs live in the cache (cache.solnix.io). This turns that manifest into
# `pkgs.solnix.cached.<pname>` so a config can do
#   environment.systemPackages = with pkgs.solnix.cached; [ vim curl htop ... ];
# and each name resolves to the concrete /nix/store/... path via
# `builtins.storePath`. At realise time those paths SUBSTITUTE from the cache;
# nothing is rebuilt from source.
#
# CHECK (pname keying, offline): the hash-strip + parseDrvName split is the only
# non-trivial logic. Verify it without touching the store:
#   nix eval --impure --expr 'let c = import ./pkgs/illumos/cached.nix {}; in
#     builtins.all (n: c ? ${n}) [ "file" "less" "vim" "curl" "htop" "git" ]'
# -> true.
#
# CAVEATS (read before relying on this):
#  (a) storePath IMPORTS a path, it does NOT define a derivation. There is no
#      source recipe here. Runtime/build deps ARE preserved: the NARs in the
#      cache carry their real .references (e.g. vim pulls zlib; curl pulls
#      openssl/zlib), so once a path is substituted its closure comes with it and
#      Nix tracks it for GC. What is missing is only the *source* recipe — treat
#      cached.* as prebuilt leaf inputs, not as buildable/overridable derivations.
#  (b) Realisation substitutes the NAR (and its closure) from cache.solnix.io
#      (base.nix sets it as a substituter with the cache.solnix.io-1 trusted
#      key). No local build.
#  (c) EVAL is NOT fully offline. builtins.storePath validates the path at the
#      moment its VALUE is forced: if the path is absent from the local store,
#      Nix 2.34 asks the configured substituters whether it can be fetched, and
#      errors ("no substituter that can build it") when none is set. So:
#        - eval that only reads attrNames / `?` membership never forces a value
#          and is fully offline;
#        - eval that forces a value (interpolation, a buildEnv over the list)
#          needs the path present OR a substituter reachable. The base.nix config
#          sets cache.solnix.io as a substituter, so evaluating the real system
#          works; a bare `nix eval` needs
#          `--option substituters https://cache.solnix.io
#           --option trusted-public-keys cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=`.
#  (d) pname keying is BEST-EFFORT via builtins.parseDrvName (the same splitter
#      Nix itself uses: cut at the first "-" followed by a digit). Odd names
#      (git-tagged "v0.x", "master", date stamps) land a slightly-off key; the
#      version-bearing store path is still correct. On x86_64 the arch never
#      leaks into the name (it sits in the version, e.g. "libuv-1.49.2-sparcv9"
#      -> name "libuv"); the arch-suffix strip below is a guard for other arches.
#  (e) DUPLICATE pnames (multiple versions in the manifest) are LAST-WINS in
#      manifest order. The manifest is hash-sorted, so "last" is arbitrary, not
#      "newest". If a specific version matters, reference the store path directly
#      rather than through this attrset.

# Self-contained: uses only `builtins` (no nixpkgs lib), so both eval paths can
# import it the same way — the host path (lib/host-pkgs.nix, classic Nix, no
# nixpkgs) and the flake path.
{
  system ? "x86_64-solaris",
  manifest ? ../../docs/registry/arch-manifest.tsv,
}:

let
  hasSuffix =
    sfx: s:
    let
      ls = builtins.stringLength s;
      lf = builtins.stringLength sfx;
    in
    ls >= lf && builtins.substring (ls - lf) lf s == sfx;

  archSuffixes = [ "-x86_64" "-aarch64" "-sparcv9" "-amd64" ];

  stripArch =
    name:
    builtins.foldl'
      (
        n: sfx:
        if hasSuffix sfx n then builtins.substring 0 (builtins.stringLength n - builtins.stringLength sfx) n else n
      )
      name
      archSuffixes;

  # split on newlines; builtins.split interleaves match-group lists, so keep only
  # the string pieces and drop blanks.
  lines = builtins.filter (l: builtins.isString l && l != "") (builtins.split "\n" (builtins.readFile manifest));

  # each line: <hash>\t<storePath>\t<system>
  rows = map (l: builtins.filter builtins.isString (builtins.split "\t" l)) lines;

  # keep this system, drop -debug roots (they are not runtime packages).
  wanted = builtins.filter (
    cols:
    (builtins.length cols >= 3) && (builtins.elemAt cols 2 == system) && !(hasSuffix "-debug" (builtins.elemAt cols 1))
  ) rows;

  # /nix/store/<32-char-hash>-<name>-<version> -> drop the store dir and the
  # leading hash so parseDrvName sees just "<name>-<version>".
  dropHash = basename: builtins.substring 33 (builtins.stringLength basename) basename;

  entry =
    cols:
    let
      storePath = builtins.elemAt cols 1;
      pname = stripArch (builtins.parseDrvName (dropHash (baseNameOf storePath))).name;
    in
    {
      name = pname;
      value = builtins.storePath storePath;
    };

  # listToAttrs is last-wins on duplicate names (caveat e).
in
builtins.listToAttrs (map entry wanted)
