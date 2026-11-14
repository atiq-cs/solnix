# The desktop's web browser: Firefox, unbranded

solnix builds Firefox from Mozilla's source (`pkgs/illumos/desktop/gtk/firefox.nix`), in two of nixpkgs' editions, one attr
each as in nixpkgs:

| attr | edition | version |
|---|---|---|
| `firefox` | Release, the default | 159.0 |
| `firefox-esr` | Extended Support Release | 153.6.0 |

Both come from one recipe (its `edition` argument picks the version, the source and OpenIndiana's patch set for it). Both install
as `firefox`, and their desktop entry gives them the app id `firefox`, so COSMIC's dock favourite finds either. Both
ship bin/firefox and the same desktop entry, so install one of them in a profile.

## Why it isn't called Firefox

The build is unbranded. Its own branding files (brand.properties and brand.ftl in omni.ja) name it "Nightly", its launcher entry
copies that name, and its icon is a globe. Those are the name and logo mach uses when `--enable-official-branding` is off.

Mozilla's code is free software, but the name and the logo are trademarks. The [Distribution
Policy](https://www.mozilla.org/en-US/foundation/trademarks/distribution-policy/) (read 2026-11-13) lets anyone ship
*unaltered* Mozilla builds under the Firefox marks. It needs written permission for a modified one, and "adding, modifying, or
deleting source files" counts as modified. To build on illumos, ESR applies 40 of OpenIndiana's patches and Release 42, and
each four of solnix's own.

NixOS ships the official branding. It relies on a 2017 statement from Mozilla's release manager about Nix's own patch queue
(quoted in nixpkgs' `build-mozilla-mach/default.nix`, and NixOS keeps the branding on by default). solnix has no such statement,
so here we leave NixOS's default. If Mozilla gives solnix the same permission, turning `--enable-official-branding` on is a
one-line change, and the desktop entry then follows the name the build reports.
