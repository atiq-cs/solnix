# The desktop's web browser: Firefox ESR, unbranded

solnix builds Firefox ESR from Mozilla's source (`pkgs/illumos/desktop/gtk/firefox.nix`). It installs as `firefox`, and its
desktop entry gives it the app id `firefox`, so COSMIC's dock favourite finds it.

## Why it isn't called Firefox

The build is unbranded. Its own branding files (brand.properties and brand.ftl in omni.ja) name it "Nightly", its launcher entry
copies that name, and its icon is a globe. Those are the name and logo mach uses when `--enable-official-branding` is off.

Mozilla's code is free software, but the name and the logo are trademarks. The [Distribution
Policy](https://www.mozilla.org/en-US/foundation/trademarks/distribution-policy/) (read 2026-11-13) lets anyone ship
*unaltered* Mozilla builds under the Firefox marks. It needs written permission for a modified one, and "adding, modifying, or
deleting source files" counts as modified. To build on illumos, this one applies 40 of OpenIndiana's patches and four of its own.

NixOS ships the official branding. It relies on a 2017 statement from Mozilla's release manager about Nix's own patch queue
(quoted in nixpkgs' `build-mozilla-mach/default.nix`, and NixOS keeps the branding on by default). solnix has no such statement,
so here we leave NixOS's default. If Mozilla gives solnix the same permission, turning `--enable-official-branding` on is a
one-line change, and the desktop entry then follows the name the build reports.
