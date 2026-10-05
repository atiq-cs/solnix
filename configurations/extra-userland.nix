# configurations/extra-userland.nix -- OPT-IN: the cache-only starter packages
# that configurations/base.nix used to list. Not in the base: they substitute
# from cache.solnix.io instead of being built by a recipe here, and
# docs/cache-integrity-audit.md (with docs/registry/CACHE-RETIRE-20261005.tsv)
# found cache-only paths that are not installable (phantom narinfos, NAR 404s),
# coreutils among them. Import this module only on a machine that accepts that.
{ pkgs, ... }:
{
  environment.systemPackages = (with pkgs.solnix.starter; [
    coreutils file gnugrep gnused bzip2 xz zlib pcre2 nvi which gdb
  ]) ++ [ pkgs.solnix.starter."uutils-coreutils" ];
  nix.settings.experimental-features = "nix-command flakes fetch-closure";
}
