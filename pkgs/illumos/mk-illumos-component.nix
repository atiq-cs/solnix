# mkIllumosComponent — carve files out of the gate proto store path and relocate
# their RUNPATHs into the store with elfedit. docs/design-gate-derivation.md §2.
#
# Standalone (plain `derivation` + bash), no nixpkgs stdenv/lib. Maps 1:1 onto
# the fork's stdenvNoCC.mkDerivation version in §2.3 (the report notes the map).
#
# RUNPATH story (design §2.2):
#   - $ORIGIN-relative entries for SIBLINGS inside this component's lib dirs
#     ($ORIGIN, $ORIGIN/../lib/amd64, $ORIGIN/../../lib/amd64).
#   - `selfLibDirs`: extra dirs INSIDE this component that need an absolute store
#     path because $ORIGIN can't bridge them. A component whose libs are spread
#     across lib/amd64 + usr/lib/amd64 + lib/fm/amd64 (e.g. base-tools) can't reach
#     a usr/lib/amd64 lib from a lib/amd64 lib with one $ORIGIN rule, so we bake
#     $out/<dir> as an absolute path. $out is only known in the builder, so these
#     are expanded there (design §2.2 — absolute store paths for anything $ORIGIN
#     can't see, whether cross-component OR cross-subdir intra-component).
#   - `depRunpaths`: absolute store lib/amd64 of each declared CROSS-component dep
#     (baked as a literal store path).
#   - NO patchelf (illumos ELF). elfedit's dyn:runpath sets DT_RUNPATH+DT_RPATH.
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
, selfLibDirs ? [ ]         # component-relative lib dirs to bake as $out-absolute
                            #   RUNPATH entries (for cross-subdir intra-component refs)
, depRunpaths ? [ ]         # absolute store lib/amd64 dirs of cross-component deps
, elfedit ? "/usr/bin/elfedit"  # host elfedit (has its dyn.so module; seed's lacks it)
, elfdump ? "/usr/bin/elfdump"
}:

let
  # $ORIGIN for the loader is written literally into the ELF; single-quote it in
  # the shell so neither Nix's `''` nor bash expand it — ld.so.1 expands at load.
  originParts = [ "$ORIGIN" "$ORIGIN/../lib/amd64" "$ORIGIN/../../lib/amd64" ];
  # $ORIGIN parts + cross-component dep store paths are known now.
  staticRunpath = builtins.concatStringsSep ":" (originParts ++ depRunpaths);
  filesArg = builtins.concatStringsSep " " files;
  # selfLibDirs are joined with a marker the builder turns into $out/<dir>.
  selfDirsArg = builtins.concatStringsSep " " selfLibDirs;
in
derivation {
  name = "illumos-${name}";
  system = builtins.currentSystem; # relocation runs on illumos.
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";

  inherit gate elfedit elfdump filesArg selfDirsArg;
  staticRunpath = staticRunpath;

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

    # build the final RUNPATH: static ($ORIGIN + cross-component dep store paths)
    # plus this component's own lib dirs as $out-absolute paths (selfLibDirs).
    runpath="$staticRunpath"
    for d in $selfDirsArg; do
      runpath="$runpath:$out/$d"
    done

    # relocate RUNPATH on every dynamic ELF we copied (single-quoted $ORIGIN is
    # already literal). Only touch objects that carry a .dynamic section (shared
    # libs / dynamic executables); kernel modules, headers and ET_REL .o startup
    # objects (crt*, values-*) have none and are skipped silently.
    # elfdump -d exits 0 on non-ELF, so gate on the SONAME|NEEDED|RUNPATH lines.
    # elfedit dyn:runpath updates BOTH DT_RUNPATH and DT_RPATH (same str offset),
    # so the proto's host /usr/gcc/10 RPATH leak is scrubbed too.
    # NOTE: the `while` runs in a pipe subshell, so a bare `exit 1` there won't
    # fail the builder — we drop a marker file and check it after the loop.
    rm -f relocfail
    find "$out" -type f | while read -r f; do
      if "$elfdump" -d "$f" 2>/dev/null | grep -Eq 'SONAME|NEEDED|RUNPATH|RPATH'; then
        chmod u+w "$f"
        if ! "$elfedit" -e "dyn:runpath $runpath" "$f" 2>err.txt; then
          # design risk #1: .dynstr can't grow to hold this RUNPATH. FATAL —
          # a silent skip would ship an unrelocated binary that leaks to host
          # /lib at runtime. Shorten the RUNPATH (fewer selfLibDirs / single
          # ABI) or relink the object with a longer -R.
          echo "FATAL: elfedit runpath failed on $f" >&2
          cat err.txt >&2
          touch relocfail
        fi
      fi
    done
    if [ -e relocfail ]; then
      echo "FATAL: RUNPATH relocation failed (len ''${#runpath}): $runpath" >&2
      exit 1
    fi
    echo "relocated RUNPATH -> $runpath" >&2
  '' ];
}
