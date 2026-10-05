# mk-proto-world.nix -- the illumos userland of the gate proto as ONE store path,
# with every ELF's RUNPATH pointing inside the store.
#
# Why not more mk-proto-slice calls: a Nix-managed /usr/bin has to hold ALL of
# illumos userland (516 usr/bin, 364 usr/sbin, 55 sbin entries in this proto),
# plus the dlopen()ed objects nothing names in DT_NEEDED: PAM modules
# (/usr/lib/security), nss backends, mdb/dtrace modules, fs mount helpers. A
# bins-list slice cannot see dlopen edges, so it would ship a /usr/lib missing
# exactly the objects that fail at run time. This copies the whole userland
# tree and relocates every dynamic object in it.
#
# ONE libc per process. Measured on the build host: when two objects resolve
# libc.so.1 from two DIFFERENT files, ld.so.1 maps BOTH (LD_DEBUG=files shows two
# "generating link map" lines). ld.so.1 deduplicates by dev/inode, so a symlink to
# the same file is fine and a second copy is not. So every soname the libc slice
# ships is REPLACED here by a symlink to the libc slice's file, and everything
# else that links libc (src packages, other slices) points at that same slice.
#
# setuid/setgid: the store holds no setuid files (Nix normalises modes to
# 0444/0555). The bits are stripped and the list is recorded in
# $out/.world/setuid, so activation can install privileged copies outside the
# store (NixOS's security.wrappers, /run/wrappers/bin).
{ gate
, libcSlice                  # pkgs.solnix.libc
, deps ? [ ]                 # from-source libs the proto NEEDs but does not ship (libz, libxml2)
, name ? "illumos-userland"
, dirs ? [ "usr" "lib" "sbin" "opt" ]
, exclude ? [ "usr/kernel" "usr/share/man" ]   # kernel modules are the kernel slice's
, system ? "x86_64-solaris"
}:

derivation {
  inherit name system gate;
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  libc = libcSlice;
  dirsArg = builtins.concatStringsSep " " dirs;
  excludeArg = builtins.concatStringsSep " " exclude;
  depsArg = builtins.concatStringsSep " " deps;
  args = [ "-c" ''
    set -eu
    export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
    mkdir -p "$out/.world"
    cd "$gate"
    for d in $dirsArg; do [ -e "$d" ] && tar cf - "$d" | (cd "$out" && tar xf -); done
    cd "$out"
    for x in $excludeArg; do [ -e "$x" ] && find "$x" -depth -delete; done
    chmod -R u+w "$out"

    # setuid/setgid: record, then strip.
    find . -type f \( -perm -4000 -o -perm -2000 \) | sed 's,^\./,,' | sort > .world/setuid
    while read -r f; do
      ls -ln "$f" | awk -v f="$f" '{print $1, $3, $4, f}' >> .world/setuid.modes
      chmod ug-s "$f"
    done < .world/setuid

    elfclass() {
      [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = 7f454c46 ] || { echo none; return; }
      c=$(od -An -tu1 -j4 -N1 "$1" | tr -d ' \n'); [ "$c" -eq 2 ] && echo 64 || echo 32
    }

    # one libc: every libc-slice soname here becomes a link to the slice's file.
    n=0
    for sub in lib lib/amd64; do
      for s in "$libc/$sub"/*.so*; do
        b=$(basename "$s")
        for t in "$sub/$b" "usr/$sub/$b"; do
          if [ -f "$t" ] && [ ! -L "$t" ]; then rm -f "$t"; ln -s "$s" "$t"; n=$((n+1)); fi
        done
      done
    done
    echo "replaced $n libc-slice objects with links into $libc" >&2

    # flat per-ABI lib dirs: every shared object here + the deps', one RUNPATH entry per ABI.
    mkdir -p lib-32 lib-64
    link_flat() {
      cl=$(elfclass "$1"); [ "$cl" = none ] && return 0
      [ -e "lib-$cl/$(basename "$1")" ] || ln -s "$1" "lib-$cl/$(basename "$1")"
    }
    for sub in lib lib/amd64 usr/lib usr/lib/amd64 lib/fm lib/fm/amd64 usr/lib/fm usr/lib/fm/amd64 \
               lib/secure lib/secure/amd64 usr/lib/secure usr/lib/secure/amd64 usr/lib/mps usr/lib/mps/amd64; do
      [ -d "$sub" ] || continue
      for s in "$sub"/*.so*; do [ -e "$s" ] && link_flat "$out/$s"; done
    done
    for d in $depsArg; do
      for sub in lib lib/amd64; do
        [ -d "$d/$sub" ] || continue
        for s in "$d/$sub"/*.so*; do [ -e "$s" ] && link_flat "$s"; done
      done
    done
    RP="$out/lib-32:$out/lib-64"

    # relocate every dynamic object (not symlinks; hardlinks are visited per name, idempotent).
    : > .world/relocfail
    find . -type f ! -path './lib-*' | while read -r f; do
      /usr/bin/elfdump -d "$f" 2>/dev/null | grep -Eq 'NEEDED|SONAME' || continue
      chmod u+w "$f"
      /usr/bin/elfedit -e "dyn:runpath $RP" "$f" 2>/dev/null || echo "$f" >> .world/relocfail
    done
    if [ -s .world/relocfail ]; then
      echo "FATAL: elfedit failed on $(wc -l < .world/relocfail) objects:" >&2; head .world/relocfail >&2; exit 1
    fi

    # bin/: per-entry links to usr/bin, so a buildEnv profile gets sw/bin/<tool>.
    mkdir -p bin
    for e in usr/bin/*; do ln -s "../$e" "bin/$(basename "$e")"; done

    # the gate: no dynamic object may resolve outside /nix/store, nor fail to resolve.
    unset LD_LIBRARY_PATH LD_LIBRARY_PATH_32 LD_LIBRARY_PATH_64 || true
    : > .world/ldd-bad
    find . -type f ! -path './lib-*' | while read -r f; do
      /usr/bin/elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
      /usr/bin/ldd "$f" 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}' >> .world/ldd-bad
    done
    printf 'objects_relocated=%s ldd_bad_lines=%s setuid=%s\n' \
      "$(find . -type f ! -path './lib-*' | wc -l | tr -d ' ')" "$(wc -l < .world/ldd-bad | tr -d ' ')" \
      "$(wc -l < .world/setuid | tr -d ' ')" > .world/summary
    cat .world/summary >&2
  '' ];
}
