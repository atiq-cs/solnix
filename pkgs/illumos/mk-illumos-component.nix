# mkIllumosComponent — carve files out of the gate proto store path and relocate
# their RUNPATHs into the store with elfedit. docs/design-gate-derivation.md §2.
#
# Standalone (plain `derivation` + bash), no nixpkgs stdenv/lib. Maps 1:1 onto
# the fork's stdenvNoCC.mkDerivation version in §2.3 (the report notes the map).
#
# RUNPATH story (design §2.2, unchanged from the seed method):
#   - $ORIGIN-relative entries for SIBLINGS inside this component's lib dirs.
#   - absolute store lib/amd64 of each declared dependency for CROSS-component
#     deps (baked as a literal store path — $ORIGIN only covers intra-component).
#   - NO patchelf (illumos ELF). elfedit's dyn:runpath sets DT_RUNPATH.
#
# elfedit note (design §2.3 was WRONG here): the design said use the SEED's
# elfedit (${seed}/usr/bin/elfedit). But the seed did NOT ship elfedit's loadable
# modules (/usr/lib/elfedit/{dyn,...}.so), so the seed elfedit fails with
# "no such module: dyn". We use the HOST /usr/bin/elfedit instead — a bootstrap
# tool, host-path, legal under sandbox=false and the design's Phase-1 host-impure
# stance (§1.3). TODO(P2): ship elfedit + its modules in the seed, or nixify.

{ gate                      # store path of illumos.gate proto (GATE A $out)
, name                      # component name -> illumos-<name>
, files                     # list of proto-relative paths (files/dirs) to copy
, depRunpaths ? [ ]         # absolute store lib/amd64 dirs of cross-component deps
, elfedit ? "/usr/bin/elfedit"  # host elfedit (has its dyn.so module; seed's lacks it)
, elfdump ? "/usr/bin/elfdump"
}:

let
  # $ORIGIN for the loader is written literally into the ELF; single-quote it in
  # the shell so neither Nix's `''` nor bash expand it — ld.so.1 expands at load.
  originParts = [ "$ORIGIN" "$ORIGIN/../lib/amd64" "$ORIGIN/../../lib/amd64" ];
  runpath = builtins.concatStringsSep ":" (originParts ++ depRunpaths);
  filesArg = builtins.concatStringsSep " " files;
in
derivation {
  name = "illumos-${name}";
  system = builtins.currentSystem; # relocation runs on illumos.
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";

  inherit gate elfedit elfdump runpath filesArg;

  args = [ "-c" ''
    set -eu
    mkdir -p "$out"
    # copy each requested file/dir, preserving its proto-relative layout.
    for f in $filesArg; do
      src="$gate/$f"
      if [ ! -e "$src" ] && [ ! -L "$src" ]; then
        echo "FATAL: $f not in gate proto ($src)" >&2; exit 1
      fi
      mkdir -p "$out/$(dirname "$f")"
      cp -a "$src" "$out/$f"
    done

    # relocate RUNPATH on every dynamic ELF we copied (single-quoted $ORIGIN is
    # already literal in $runpath). Only touch objects that actually carry a
    # .dynamic section (shared libs / dynamic executables); headers and ET_REL
    # .o startup objects (crt*, values-*) have none and are skipped silently.
    # Make files writable first (proto is r-x).
    find "$out" -type f | while read -r f; do
      # SONAME|RUNPATH|NEEDED lines only appear for a real .dynamic section.
      if "$elfdump" -d "$f" 2>/dev/null | grep -Eq 'SONAME|NEEDED|RUNPATH|RPATH'; then
        chmod u+w "$f"
        if "$elfedit" -e "dyn:runpath $runpath" "$f" 2>/dev/null; then
          :
        else
          echo "WARN: elfedit runpath failed (grow-in-place?): $f" >&2
        fi
      fi
    done
    echo "relocated RUNPATH -> $runpath" >&2
  '' ];
}
