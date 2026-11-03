# aarch64/tools.nix -- the store build tools of the store-only aarch64 set (a64h): what the stage0 box's /usr/gnu, /usr/bin,
# /opt/ooce and /opt/nixboot gave every build before (SEED-PLAN.md, dixa4). NixOS bootstrap model: seed = this set built the
# stage0 way (./. with stage = "seed"); its outs are the served aarch64 rows, so a fresh host substitutes every tool below.
# Not here (no aarch64 binutils upstream; binutils 2.47 has no aarch64-solaris target): gcc's /usr/bin/gas and mk-src-pkg's
# /usr/bin/gstrip, elfedit, elfdump, ldd, digest by absolute path. Those are the bootstrap tools, as the gate proto and gcc are.
{ gate, libcSlice, ld, gcc, seed, system
, perl ? null   # the perl build tool: the final set's own perl (../aarch64/default.nix)
}:
let
  sb = "${seed.bash}/bin/bash";
  basePath = builtins.concatStringsSep ":" (map (p: "${p}/bin") [ seed.coreutils seed.gnugrep seed.gnused seed.findutils ]);
  plainDrv = name: attrs: script: derivation ({ inherit name system; builder = sb;
    # trailing true: bash -c execs its last command, and a store coreutils one (ln) as the builder is killed by signal 9 (6/6 on dixa)
    args = [ "-c" "set -eu; export PATH=${basePath}; ${sb} ${../path-gate.sh}\n${script}\ntrue" ]; } // attrs);
in
rec {
  shell = sb;
  # a plain bash -c derivation (mkGateLibs, gccWrapper, top, cacert, ...), store-only: builder = the seed bash, PATH = the recipes'
  # store PATH + the gate, host PATH lines -> ':', host coreutils/bash by absolute path -> by name / the seed bash.
  plain = a: a // { builder = sb; PATH = toolPath; args = map (x: if x == "-c" then x else "export PATH=${toolPath}; ${sb} ${../path-gate.sh}\n" +
    builtins.replaceStrings [ "export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin" "export PATH=/usr/gnu/bin:/usr/bin" "export PATH=/usr/bin"
      "/usr/bin/bash" "/usr/bin/mkdir" "/usr/bin/ln" "/usr/bin/cp" "/usr/bin/cat" "/usr/bin/chmod" ]
      [ ":" ":" ":" sb "mkdir" "ln" "cp" "cat" "chmod" ] x + "\ntrue") a.args; };   # trailing true: see plainDrv
  toolPath = builtins.concatStringsSep ":" (map (p: "${p}/bin") (farm ++ [ shAlias seed.bash ]));   # no perl/cmake: no cycle via world
  # illumos tools a recipe runs by name (awk in configure, nm/ar in libtool), from the proto, RUNPATH -> libc slice + seed gate libs.
  illumosTools = plainDrv "illumos-build-tools" { inherit gate; libc = libcSlice; gl = seed.world; tools = "awk nawk nm ar getconf isainfo"; bash = sb; } ''
    mkdir -p $out/bin
    for t in $tools; do
      cp $gate/usr/bin/$t $out/bin/$t; chmod u+w $out/bin/$t
      /usr/bin/elfedit -e "dyn:runpath $libc/lib:$gl/lib" $out/bin/$t
    done
    unset LD_LIBRARY_PATH || true
    # ranlib: the proto's is a #!/usr/bin/sh script that exits 0 (illumos ar writes the symbol table itself); same, on the store shell
    printf '#!%s\nexit 0\n' "$bash" > $out/bin/ranlib; chmod +x $out/bin/ranlib
    [ "$(echo 1 2 | $out/bin/awk '{print $1+$2}')" = 3 ] || { echo "FATAL: awk self-check" >&2; exit 1; }   # first: the next check runs this awk
    bad=$(for t in $tools; do /usr/bin/ldd $out/bin/$t 2>&1 | $out/bin/awk -v f=$t '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}'; done)
    [ -z "$bad" ] || { echo "FATAL: illumos tools leave the store: $bad" >&2; exit 1; }
  '';
  # gcc/cc/g++/c++ by name (boost's b2 bootstrap, readline's shobj-conf) -> the bootstrap gcc with its runtime RUNPATH (the seed
  # gccWrapper's scripts start #!/usr/bin/bash, the host's). In the farm, so a baked path is de-baked to the bare name.
  ccNames = plainDrv "cc-store-names" { bash = seed.bash; inherit gcc; gccLib = gcc.lib; } ''
    mkdir -p $out/bin
    for t in gcc:gcc cc:gcc g++:g++ c++:g++; do
      printf '#!%s\nexec %s -Wl,-R,%s/lib "$@"\n' "$bash/bin/bash" "$gcc/bin/''${t#*:}" "$gccLib" > $out/bin/''${t%%:*}
      chmod +x $out/bin/''${t%%:*}
    done
  '';
  # sh by name (libtool, make) -> the seed bash. Not in the farm: a baked #!.../sh must stay a store path, not become "#!sh".
  shAlias = plainDrv "sh-store" { bash = seed.bash; } "mkdir -p $out/bin; ln -s $bash/bin/bash $out/bin/sh";
  # btPath = ONE farm dir (x86 seedBuildTools' shape): mk-src-pkg de-bakes each btPath entry from every shipped text file, once
  # per entry, so 15 dirs made ncurses' terminfo pass crawl (measured on dixa, tier 1 stopped). Later paths win a name clash.
  buildToolsFarm = plainDrv "solnix-a64-build-tools" { paths = [ seed.gnumake seed.gnutar seed.gnugrep seed.gnused seed.gzip seed.xz
      seed.coreutils seed.findutils seed.diffutils seed.gnupatch seed.gnum4 seed.pkgconf illumosTools ccNames ]; } ''
    mkdir -p $out/bin
    for p in $paths; do for f in $p/bin/*; do ln -sf $f $out/bin/; done; done
    for t in make gmake tar grep sed gzip xz cp install awk nm ar patch m4 pkg-config gcc cc; do [ -x $out/bin/$t ] || { echo "FATAL: no $t" >&2; exit 1; }; done
  '';
  farm = [ buildToolsFarm ];
  # ntPath (kept as references, as NixOS keeps perl/bash shebangs): sh, interpreters, cmake, the store link-editor. No perl for perl
  # itself: Configure records the first perl on PATH as perl5 and the recipe FAILs a perl5 that names .../bin/perl.
  defaultToolsFor = pname: [ shAlias seed.bash ] ++ (if builtins.elem pname perlBuild || perl == null then [ ] else [ perl ]) ++ [ seed.cmake ld ];
  perlBuild = [ "perl" "gnupatch" "zlib" ];   # perl's own build closure: nativeTools gnupatch, deps world (gate libs + zlib)
}
