# mk-proto-slice.nix -- carve a component out of the already-built gate proto and
# let the DERIVATION compute its own library closure.
#
# THE POINT, stated as the difference from what came before:
#
#   pkgs/illumos/mk-illumos-component.nix takes `files` -- a HAND-WRITTEN list of
#   proto-relative paths -- and copies exactly those. Its callers in
#   pkgs/illumos/default.nix carry the closure as literal Nix lists (base-tools'
#   `baseToolLibs` is 60 sonames pasted in by hand, with a comment saying
#   "Re-run scripts/oi-closure.sh if the tool set changes; paste the result here").
#
#   That is the exact bug this whole campaign has been losing days to. Every image
#   failure was one entry missing from one human-maintained list: `vi` without
#   libmapmalloc.so.1, /dev with 0 of 13 nodes, `df` shipped as a dangling symlink,
#   `openssl` unrunnable through a SECOND-ORDER dangling symlink whose libssl was
#   itself a link into an unstaged tree. A list cannot notice its own omission.
#
#   mk-proto-slice takes `bins` -- what the slice is FOR -- and resolves the
#   transitive DT_NEEDED closure IN THE BUILDER with elfdump, ABI-aware, at build
#   time. Nothing is pasted. Adding a binary to `bins` pulls its libraries in
#   automatically, and REMOVING one drops the libraries only it needed.
#
# HOW THE CLOSURE IS COMPUTED (this is the claim to check, so it is spelled out):
#   1. Seed a queue with each `bins` entry, resolved under the proto.
#   2. For each queued ELF: `elfdump -d` and take every DT_NEEDED soname.
#      (elfdump, NOT ldd -- ldd RUNS the loader against the HOST's /lib, so it
#      reports what the host happens to have, not what the proto contains. ldd is
#      used LATER, as the exec-time check on the built slice, which is a different
#      question: "does it resolve from the store".)
#   3. Resolve each soname in the ABI-matching directories only. illumos is
#      dual-ABI: a 32-bit object resolves from lib/ + usr/lib/ (+ the fm/ and
#      secure/ variants); a 64-bit object from lib/amd64/ + usr/lib/amd64/. The
#      class is read from the ELF header (e_ident[EI_CLASS] at offset 4), not
#      guessed from the path -- so a 32-bit binary in a 64-bit slice cannot
#      silently pick up 64-bit libs that will never load.
#   4. Enqueue the resolved library and repeat until the frontier is empty.
#   5. Any soname that resolves NOWHERE in the proto is recorded and, unless the
#      caller lists it in `allowUnresolved`, is a FATAL build error.
#
#   Step 5 is what makes this a closure and not a wish. `allowUnresolved` exists
#   because some sonames genuinely are not in the proto (libxml2, libz, ICU --
#   pkgs/illumos/default.nix's `externalLibs` slices those from the host), and a
#   slice that needs one must say so out loud, in Nix, where it is reviewable.
#
# ⚠️ NORMALISE 64/ -> amd64/. In the proto, /usr/lib/64 and /lib/64 are SYMLINKS to
# amd64. illumos `mkdir -p` FAILS rc=2 when the last component of the path is a
# symlink-to-directory (GNU mkdir succeeds), which killed a build this campaign. So
# every path this builder handles is rewritten 64/ -> amd64/ BEFORE any mkdir, and
# the copy never creates a `64` component at all.
#
# ⚠️ HARDLINKS ARE PRESERVED. `cmd/halt/Makefile` declares
# ROOTLINKS = $(ROOTUSRSBIN)/poweroff $(ROOTUSRSBIN)/reboot and halt.c dispatches on
# argv[0], so halt/reboot/poweroff are ONE inode with THREE names. Copying them
# independently would trip the argv[0] dispatch (each name is checked against the
# basename, which still works) but would triple the bytes and, worse, would let the
# three drift. `hardlinkGroups` copies the first name and `ln` the rest, then the
# builder ASSERTS they share an inode.
#
# RUNPATH: same mechanism as mk-illumos-component (elfedit dyn:runpath; illumos ELF,
# so no patchelf). The RUNPATH is built from dirs that ACTUALLY EXIST in $out plus
# the dep store paths, because a long RUNPATH full of nonexistent dirs can exceed
# the .dynstr grow limit and make elfedit fail -- leaving an unrelocated binary that
# leaks to the host /lib at runtime.

{ gate                        # store path of the built gate proto (pkgs.illumos.gate)
, name                        # slice name -> store name is plain <name>
, bins ? [ ]                  # proto-relative BINARIES/objects this slice is FOR.
                              #   Their library closure is COMPUTED, not listed.
, extraPaths ? [ ]            # proto-relative files/dirs to copy verbatim with NO
                              #   closure analysis: manifests, headers, kernel trees,
                              #   data files. Anything whose deps Nix cannot read.
, hardlinkGroups ? [ ]        # [[ "usr/sbin/halt" "usr/sbin/reboot" ... ]] -- names
                              #   that MUST share one inode in $out. First is copied,
                              #   the rest are `ln`ed to it, then asserted same-inode.
, deps ? [ ]                  # other mk-proto-slice outputs whose lib dirs go in the
                              #   RUNPATH. A soname found in a dep is NOT re-copied.
, allowUnresolved ? [ ]       # sonames permitted to resolve nowhere (external libs).
                              #   Anything unresolved and NOT here is a build FAILURE.
, closureRoots ? true         # include the computed libs in $out. false = compute and
                              #   REPORT only (used by the libs slice's own audit).
, extraRunpaths ? [ ]         # absolute dirs appended to the RUNPATH verbatim.
, elfedit ? "/usr/bin/elfedit"
, elfdump ? "/usr/bin/elfdump"
  # system IS AN ARGUMENT, defaulted to the literal -- NOT builtins.currentSystem.
  # currentSystem does not EXIST in pure eval (hard "attribute 'currentSystem'
  # missing"), which blocked the toplevel via the proto slices. Same fix class as
  # mk-illumos-component.nix + lib/build-env.nix. The slice still builds ON illumos;
  # naming the system as a literal is what lets a flake-native host EVALUATE it.
, system ? "x86_64-solaris"
}:

let
  # NOTE Dep libs are reached through this slice's own per-ABI flat lib dirs
  # (symlinks), NOT by naming each dep lib dir in the RUNPATH: the .dynstr ceiling is
  # a measured HARD 511 chars and naming them blew it at 519. See the builder's
  # RUNPATH section for the measurement.
in
derivation {
  inherit name;
  inherit system;                    # arg (literal default), not currentSystem: elfdump/elfedit run ON illumos.
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin:/sbin";

  inherit gate elfedit elfdump;
  binsArg = builtins.concatStringsSep " " bins;
  extraArg = builtins.concatStringsSep " " extraPaths;
  # each group is space-free names joined by '|', groups separated by space.
  hardlinkArg = builtins.concatStringsSep " " (map (g: builtins.concatStringsSep "|" g) hardlinkGroups);
  depsArg = builtins.concatStringsSep " " deps;
  extraRunpathArg = builtins.concatStringsSep " " extraRunpaths;
  allowUnresolvedArg = builtins.concatStringsSep " " allowUnresolved;
  wantClosure = if closureRoots then "1" else "";

  args = [ "-c" ''
    set -eu
    G="$gate"
    mkdir -p "$out"

    # ---------------------------------------------------------------- helpers
    # norm64: rewrite a 64/ path component to amd64/. The proto's /usr/lib/64 and
    # /lib/64 are SYMLINKS to amd64, and illumos mkdir -p fails rc=2 on a trailing
    # symlink-to-dir. Every path below goes through this before any mkdir.
    norm64() { printf '%s\n' "$1" | sed -e 's,^lib/64/,lib/amd64/,' -e 's,^usr/lib/64/,usr/lib/amd64/,' -e 's,/lib/64/,/lib/amd64/,g'; }

    # elfclass: 32 or 64, read from e_ident[EI_CLASS] (byte 4) of the ELF header.
    # NOT from the path -- a 32-bit object living under a 64-bit-looking dir must
    # still resolve 32-bit libs. od(1) is used because illumos has no stat(1) and
    # `file` output has bitten this project before; -tu1 with an arithmetic compare
    # is padding-agnostic (illumos od ZERO-PADS numeric output, GNU od does not,
    # and a string compare on that passed on Linux and failed here).
    elfclass() {
      m=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
      [ "$m" = "7f454c46" ] || { echo none; return; }
      c=$(od -An -tu1 -j4 -N1 "$1" 2>/dev/null | tr -d ' \n')
      if [ "$c" -eq 2 ] 2>/dev/null; then echo 64; else echo 32; fi
    }

    # needed: the DT_NEEDED sonames of an ELF, one per line. elfdump, NOT ldd:
    # ldd runs the loader against the HOST's /lib and would report the host's
    # world instead of the proto's.
    needed() { "$elfdump" -d "$1" 2>/dev/null | awk '$2=="NEEDED"{print $NF}'; }

    # searchdirs: the proto dirs a given ABI resolves sonames from. illumos is
    # dual-ABI and the loader will NOT load a mismatched class, so these sets must
    # not be merged.
    searchdirs() {
      if [ "$1" = 64 ]; then
        echo "lib/amd64 usr/lib/amd64 lib/fm/amd64 usr/lib/fm/amd64 lib/secure/amd64 usr/lib/secure/amd64 lib/svc/amd64 usr/lib/mps/amd64"
      else
        echo "lib usr/lib lib/fm usr/lib/fm lib/secure usr/lib/secure lib/svc usr/lib/mps"
      fi
    }

    # ------------------------------------------------- what deps already provide
    # A soname a dep ships must NOT be re-copied here: two copies of libc in one
    # closure is how you get a slice whose binaries load the wrong one. The dep's
    # lib dir is in the RUNPATH, so resolution finds it there.
    : > provided.txt
    for d in $depsArg; do
      for s in lib/amd64 lib usr/lib/amd64 usr/lib lib-all; do
        [ -d "$d/$s" ] || continue
        # record soname:class so a 32-bit dep lib does not satisfy a 64-bit need
        find "$d/$s" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | while read -r p; do
          case "$(basename "$p")" in *.so*) ;; *) continue;; esac
          rp="$p"; [ -L "$rp" ] && rp=$(cd "$(dirname "$p")" && pwd)/$(basename "$p")
          cl=$(elfclass "$p" 2>/dev/null || echo none)
          [ "$cl" = none ] && continue
          echo "$(basename "$p"):$cl" >> provided.txt
        done
      done
    done
    sort -u provided.txt -o provided.txt
    echo "=== deps provide $(wc -l < provided.txt | tr -d ' ') soname:class pairs ===" >&2

    # ------------------------------------------------------ copy the named bins
    : > queue.txt
    : > copied.txt
    for b in $binsArg; do
      src="$G/$b"
      if [ ! -e "$src" ] && [ ! -L "$src" ]; then
        echo "FATAL: bins entry not in proto: $b (looked at $src)" >&2; exit 1
      fi
      dst=$(norm64 "$b")
      mkdir -p "$out/$(dirname "$dst")"
      # cp -a preserves the symlink IF the proto entry is one. A proto symlink whose
      # target we do not also copy is precisely the dangling-symlink class that made
      # `df` and `openssl` unrunnable, so DEREFERENCE bins: -L gives us the real
      # object under the name the caller asked for.
      cp -aL "$src" "$out/$dst"
      chmod u+w "$out/$dst" 2>/dev/null || true
      echo "$b" >> copied.txt
      echo "$out/$dst" >> queue.txt
    done

    # ----------------------------------------------------------- hardlink groups
    # halt/reboot/poweroff: ONE binary, THREE names, dispatched on argv[0]
    # (usr/src/cmd/halt/halt.c) and declared as ROOTLINKS in cmd/halt/Makefile.
    for grp in $hardlinkArg; do
      first=""
      for nm in $(printf '%s\n' "$grp" | tr '|' ' '); do
        dst=$(norm64 "$nm")
        if [ -z "$first" ]; then
          if [ ! -e "$out/$dst" ]; then
            src="$G/$nm"
            [ -e "$src" ] || { echo "FATAL: hardlink group head not in proto: $nm" >&2; exit 1; }
            mkdir -p "$out/$(dirname "$dst")"
            cp -aL "$src" "$out/$dst"
            chmod u+w "$out/$dst"
            echo "$out/$dst" >> queue.txt
          fi
          first="$out/$dst"
        else
          mkdir -p "$out/$(dirname "$dst")"
          rm -f "$out/$dst"
          ln "$first" "$out/$dst" || { echo "FATAL: hardlink $first -> $out/$dst failed" >&2; exit 1; }
        fi
      done
    done

    # ------------------------------------------- THE CLOSURE: transitive DT_NEEDED
    # BFS. The frontier is queue.txt; each pass resolves the NEEDED of everything
    # on it and appends newly-found libs. Terminates because `seen` is monotone.
    : > seen.txt
    : > libs.txt
    : > unresolved.txt
    pass=0
    while [ -s queue.txt ]; do
      pass=$((pass + 1))
      [ "$pass" -gt 64 ] && { echo "FATAL: closure BFS did not converge in 64 passes" >&2; exit 1; }
      mv queue.txt cur.txt
      : > queue.txt
      while read -r f; do
        cls=$(elfclass "$f")
        [ "$cls" = none ] && continue
        dirs=$(searchdirs "$cls")
        for so in $(needed "$f"); do
          key="$so:$cls"
          grep -qxF "$key" seen.txt 2>/dev/null && continue
          echo "$key" >> seen.txt
          # already shipped by a declared dep -> resolve there, do not re-copy
          grep -qxF "$key" provided.txt 2>/dev/null && continue
          found=""
          for d in $dirs; do
            if [ -f "$G/$d/$so" ] || [ -L "$G/$d/$so" ]; then found="$d/$so"; break; fi
          done
          if [ -z "$found" ]; then
            echo "$key" >> unresolved.txt
            continue
          fi
          echo "$found:$cls" >> libs.txt
          dst=$(norm64 "$found")
          if [ -n "$wantClosure" ] && [ ! -e "$out/$dst" ]; then
            mkdir -p "$out/$(dirname "$dst")"
            # -L again: a proto lib is often a symlink to a versioned file. Copying
            # the LINK and not its target is the second-order dangling symlink that
            # made openssl unrunnable in image l2. Deref so the in-store file IS
            # the soname with real content.
            cp -aL "$G/$found" "$out/$dst"
            chmod u+w "$out/$dst"
          fi
          # walk the lib's own NEEDED next pass -- from the PROTO copy, so the
          # analysis is identical whether or not wantClosure copied it.
          echo "$G/$found" >> queue.txt
        done
      done < cur.txt
    done
    sort -u libs.txt -o libs.txt
    sort -u unresolved.txt -o unresolved.txt
    echo "=== closure: $(wc -l < libs.txt | tr -d ' ') libs over $pass BFS passes ===" >&2
    sed 's,^,    ,' libs.txt >&2

    # ------------------------------------------- the gate: unresolved must be declared
    # THIS is what makes the closure a closure. Without it the slice would ship a
    # binary whose NEEDED cannot be satisfied -- the "file exists but will not exec"
    # class. Anything unresolved must be named in allowUnresolved, in Nix, where a
    # reviewer sees it.
    if [ -s unresolved.txt ]; then
      bad=""
      while read -r key; do
        so=''${key%%:*}
        ok=""
        for a in $allowUnresolvedArg; do [ "$a" = "$so" ] && ok=1 && break; done
        [ -n "$ok" ] || bad="$bad $key"
      done < unresolved.txt
      if [ -n "$bad" ]; then
        echo "FATAL: sonames NEEDED by this slice resolve nowhere in the proto and are" >&2
        echo "       not in allowUnresolved:$bad" >&2
        echo "       Either add a dep that ships them, or declare them external." >&2
        exit 1
      fi
      echo "WARN: declared-external unresolved sonames: $(tr '\n' ' ' < unresolved.txt)" >&2
    fi

    # ------------------------------------------------------------- extraPaths
    # Verbatim copies with NO closure analysis: kernel modules (not userland ELF,
    # no DT_NEEDED), SMF manifests, headers, data. cp -a, not -aL: a kernel tree's
    # internal symlinks are meaningful and self-contained.
    for p in $extraArg; do
      src="$G/$p"
      if [ ! -e "$src" ] && [ ! -L "$src" ]; then
        echo "FATAL: extraPaths entry not in proto: $p" >&2; exit 1
      fi
      dst=$(norm64 "$p")
      mkdir -p "$out/$(dirname "$dst")"
      cp -a "$src" "$out/$dst"
    done

    # ------------------------------------------------------------------ RUNPATH
    # ⚠️ THE .dynstr CEILING IS EXACTLY 511 CHARACTERS, and it is a HARD CAP rather
    # than per-file slack. Measured by binary search with elfedit on five different
    # proto objects -- usr/bin/cat, usr/bin/ls, usr/bin/ksh93, usr/sbin/svccfg and
    # usr/lib/libpool.so.1 -- each of which accepted 511 chars and rejected 512 with
    #   elfedit: [0: .dynstr]: String table does not have room to add string
    # All five carry the SAME existing RUNPATH (/usr/gcc/10/lib, 15 chars), so the
    # limit does not scale with what was already there. The first version of this
    # builder produced a 519-char RUNPATH by naming each real lib dir separately, and
    # elfedit failed on 12 objects.
    #
    # THE FIX: one FLAT lib dir PER ABI, holding a symlink to every library this
    # slice resolves -- its own AND its deps'. The RUNPATH is then three entries
    # ($ORIGIN + two flat dirs, ~120 chars) regardless of how many subdirs the
    # libraries actually live in, so it cannot creep back over the ceiling as slices
    # grow. This is the same tactic mk-illumos-component's `flattenLibsInto` uses for
    # base-tools, extended to BOTH ABIs.
    #
    # ⚠️ TWO FLAT DIRS, NOT ONE, and that is required rather than tidy: illumos is
    # dual-ABI and lib/libc.so.1 and lib/amd64/libc.so.1 share a filename. One flat
    # dir would have to drop one of them, silently breaking every binary of that
    # class. ld.so.1 is ABI-aware -- it skips a wrong-class object and keeps walking
    # the RUNPATH -- so carrying both dirs is safe and each binary finds its match.
    L32="$out/lib-32"; L64="$out/lib-64"
    mkdir -p "$L32" "$L64"
    link_flat() {   # $1 = real lib path (in $out or in a dep store path)
      cl=$(elfclass "$1"); [ "$cl" = none ] && return 0
      d="$L32"; [ "$cl" = 64 ] && d="$L64"
      b=$(basename "$1")
      [ -e "$d/$b" ] && return 0
      ln -s "$1" "$d/$b"
    }
    # this slice's own libraries
    find "$out" -type f -name '*.so*' 2>/dev/null | while read -r so; do
      case "$so" in "$L32"/*|"$L64"/*) continue;; esac
      link_flat "$so"
    done
    # the deps' libraries. A symlink into a dep's store path is a real Nix reference
    # (Nix scans symlink targets), so the dependency edge is recorded exactly as if
    # the path were baked into the RUNPATH -- while costing zero RUNPATH characters.
    for dep in $depsArg; do
      for s in lib/amd64 lib usr/lib/amd64 usr/lib lib-all lib-32 lib-64; do
        [ -d "$dep/$s" ] || continue
        find "$dep/$s" -maxdepth 1 \( -type f -o -type l \) -name '*.so*' 2>/dev/null | while read -r so; do
          link_flat "$so"
        done
      done
    done
    # $ORIGIN is written literally into the ELF; ld.so.1 expands it at load time, so
    # a binary still finds a true sibling without an absolute path.
    rp="\$ORIGIN:$L32:$L64"
    for d in $extraRunpathArg; do
      [ -d "$d" ] || continue
      case ":$rp:" in *":$d:"*) ;; *) rp="$rp:$d";; esac
    done
    echo "=== RUNPATH (''${#rp} chars; hard .dynstr ceiling is 511) -> $rp ===" >&2
    if [ "''${#rp}" -gt 511 ]; then
      echo "FATAL: RUNPATH is ''${#rp} chars, over the measured 511-char .dynstr ceiling." >&2
      echo "       elfedit would fail per-object and leave binaries resolving against" >&2
      echo "       the HOST /lib at runtime. Shorten it (fewer extraRunpaths)." >&2
      exit 1
    fi
    echo "flat lib dirs: 32-bit $(find "$L32" -maxdepth 1 -type l | wc -l | tr -d ' '), 64-bit $(find "$L64" -maxdepth 1 -type l | wc -l | tr -d ' ')" >&2

    rm -f relocfail
    # -type f only: a hardlink is a type-f entry so each name is visited, which is
    # harmless (idempotent write to one inode). Symlinks are skipped -- elfediting
    # through a link would rewrite the target twice.
    find "$out" -type f 2>/dev/null | while read -r f; do
      "$elfdump" -d "$f" 2>/dev/null | grep -Eq 'SONAME|NEEDED|RUNPATH|RPATH' || continue
      chmod u+w "$f" 2>/dev/null || true
      if ! "$elfedit" -e "dyn:runpath $rp" "$f" 2>elferr.txt; then
        echo "FATAL: elfedit runpath failed on $f" >&2
        cat elferr.txt >&2
        touch relocfail
      fi
    done
    [ -e relocfail ] && { echo "FATAL: RUNPATH relocation failed (len ''${#rp})" >&2; exit 1; }

    # --------------------------------------------------------- hardlink assertion
    # A copy would also "work" for argv[0] dispatch, so the inode check is the only
    # thing that proves the link survived. illumos has no stat(1); `ls -i` does.
    for grp in $hardlinkArg; do
      ino=""; nm0=""
      for nm in $(printf '%s\n' "$grp" | tr '|' ' '); do
        dst=$(norm64 "$nm")
        [ -e "$out/$dst" ] || { echo "FATAL: hardlink member missing: $dst" >&2; exit 1; }
        i=$(ls -i "$out/$dst" | awk '{print $1}')
        if [ -z "$ino" ]; then ino="$i"; nm0="$dst"; else
          [ "$i" = "$ino" ] || { echo "FATAL: $dst inode $i != $nm0 inode $ino -- hardlink NOT preserved" >&2; exit 1; }
        fi
      done
      echo "hardlink group OK (inode $ino): $(printf '%s' "$grp" | tr '|' ' ')" >&2
    done

    # ------------------------------------------------------------- 64/ assertion
    # The normalisation is only real if nothing named `64` was created. A `64`
    # DIRECTORY in $out means norm64 missed a path and a later illumos mkdir -p
    # against it will fail rc=2.
    if find "$out" -type d -name 64 2>/dev/null | grep -q .; then
      echo "FATAL: a '64' directory exists in \$out -- norm64 missed a path:" >&2
      find "$out" -type d -name 64 >&2
      exit 1
    fi

    # ------------------------------------------------------------- the manifest
    # Machine-readable record of what the closure computation DECIDED, so a
    # verification script reads the derivation's own answer instead of recomputing
    # it with different logic (and agreeing by luck).
    mkdir -p "$out/.slice"
    cp copied.txt "$out/.slice/bins.txt"
    cp libs.txt "$out/.slice/closure-libs.txt"
    cp unresolved.txt "$out/.slice/unresolved.txt" 2>/dev/null || : > "$out/.slice/unresolved.txt"
    printf '%s\n' "$rp" > "$out/.slice/runpath.txt"
    printf 'name=%s\nbins=%s\nclosure_libs=%s\nunresolved=%s\nbfs_passes=%s\n' \
      "$name" "$(wc -l < copied.txt | tr -d ' ')" "$(wc -l < libs.txt | tr -d ' ')" \
      "$(wc -l < "$out/.slice/unresolved.txt" | tr -d ' ')" "$pass" > "$out/.slice/summary"
    cat "$out/.slice/summary" >&2
    echo "=== slice $name -> $out ===" >&2
  '' ];
}
