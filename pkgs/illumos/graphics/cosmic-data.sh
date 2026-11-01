#!/usr/bin/bash
# cosmic-data.sh: data-file install helpers for graphics/cosmic.nix apps (the justfile `install`
# recipes, written as shell so no `just` is needed). Sourced by cosmic-build.sh's $install, run
# in the unpacked source dir with $out set. Every helper FAILS if its source is missing.
set -eu
need() { [ -e "$1" ] || { echo "FATAL: cosmic-data: missing $1" >&2; exit 1; }; }
# app <file.desktop>...: share/applications
app() { for f in "$@"; do need "$f"; install -Dm0644 "$f" "$out/share/applications/$(basename "$f")"; done; }
# meta <file.metainfo.xml>: share/metainfo
meta() { need "$1"; install -Dm0644 "$1" "$out/share/metainfo/$(basename "$1")"; }
# tree <srcdir> <dest under $out>: copy a data tree (default_schema, icons/hicolor, ...)
tree() { need "$1"; mkdir -p "$out/$2"; (cd "$1" && find . -type f | while read -r f; do install -Dm0644 "$f" "$out/$2/$f"; done); }
# schema <srcdir> [appid]: share/cosmic/<appid>/ (cosmic-config defaults); no appid = srcdir holds appid dirs
schema() { if [ $# -gt 1 ]; then tree "$1" "share/cosmic/$2"; else tree "$1" share/cosmic; fi; }
# icon <svg> [name]: share/icons/hicolor/scalable/apps
icon() { need "$1"; install -Dm0644 "$1" "$out/share/icons/hicolor/scalable/apps/${2:-$(basename "$1")}"; }
# link <target-in-bin> <name>...: multicall links (cosmic-applets)
link() { local t=$1; shift; for n in "$@"; do ln -sf "$t" "$out/bin/$n"; done; }
