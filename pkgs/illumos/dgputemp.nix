# pkgs.solnix.dgputemp -- the ThinkPad X1 Extreme's dGPU temperature (the EC's GPUT) as a kstat,
# src/ports/dgputemp, built the touchpad-driver.nix way: kernel flags, unresolved = 0 against
# kernelNd (unix + genunix + misc/acpica), exports exactly _init/_fini/_info, no SIMD/x87, and a
# negative control (one bogus extern must come out as exactly one unresolved symbol).
# OUTPUT: $out/kernel/misc/amd64/dgputemp
{ gate, kernelNd, solnixDev, ld, system ? "x86_64-solaris"
, src ? builtins.path { path = ../../src/ports/dgputemp; name = "solnix-dgputemp-src";
    filter = path: type: baseNameOf path != "dgputemp" && builtins.match ".*\\.o" (baseNameOf path) == null; }
}:

derivation {
  name = "dgputemp";
  inherit system gate kernelNd solnixDev ld src;
  utsSrc = "${kernelNd.src}/usr/src/uts";
  builder = "/usr/bin/bash";
  PATH = "/usr/bin:/usr/sbin:/usr/gnu/bin";
  args = [ "-c" ''
    set -eu
    export PATH="$solnixDev/bin:$ld/usr/bin:$ld/bin:/usr/bin:/usr/sbin:/usr/gnu/bin"
    LDBIN="$ld/usr/bin/ld"; [ -x "$LDBIN" ] || LDBIN="$ld/bin/ld"; [ -x "$LDBIN" ] || LDBIN=/usr/bin/ld
    W=$(mktemp -d /tmp/dgputemp.XXXXXX); cp -r "$src" "$W/s"; chmod -R u+w "$W/s"; cd "$W/s"
    mk() { gmake -f Makefile.illumos UTSINC="$gate/usr/include" UTSSRC="$utsSrc" LD="$LDBIN" "$@"; }
    mk > build.log 2>&1 || { tail -30 build.log >&2; echo "FATAL: dgputemp build" >&2; exit 1; }
    K=$kernelNd
    for d in $K/platform/i86pc/kernel/amd64/unix $K/kernel/amd64/genunix $K/kernel/misc/amd64/acpica; do
      /usr/bin/nm -p $d; done | awk '$2 ~ /^[TDBRCW]$/ {print $3}' | sort -u > ks
    unres() { /usr/bin/nm -p "$1" | awk '$2=="U" {print $3}' | sort -u > u; comm -23 u ks | grep -v '^__dtrace_probe_' | grep -c . || true; }
    nu=$(/usr/bin/nm -p dgputemp | awk '$2=="U"' | grep -c . || true)
    [ "$nu" -ge 8 ] || { echo "FATAL: only $nu undefined (nm broken?)" >&2; exit 1; }
    [ "$(unres dgputemp)" = 0 ] || { comm -23 u ks >&2; echo "FATAL: unresolved symbols" >&2; exit 1; }
    g=$(/usr/bin/nm -p dgputemp | awk '$2 ~ /^[TDB]$/ {print $3}' | sort | tr '\n' ' ')
    [ "$g" = "_fini _info _init " ] || { echo "FATAL: exports '$g'" >&2; exit 1; }
    n=$(gobjdump -d --no-show-raw-insn dgputemp | grep -c -E '%[xyz]mm[0-9]|%mm[0-7]|%st\(' || true)
    [ "$n" = 0 ] || { echo "FATAL: $n SIMD/x87 instructions" >&2; exit 1; }
    # negative control: one extern no kernel has must count exactly 1
    printf 'extern int solnix_negctl_no_such_symbol;\nint dgt_neg(void){return solnix_negctl_no_such_symbol;}\n' > neg.c
    gcc -m64 -O2 -ffreestanding -mcmodel=kernel -mno-red-zone -mno-mmx -mno-sse -nostdinc -c neg.c -o neg.o
    "$LDBIN" -r -o negmod dgputemp.o neg.o
    [ "$(unres negmod)" = 1 ] || { echo "FATAL: negative control did not count 1 unresolved" >&2; exit 1; }
    mkdir -p "$out/kernel/misc/amd64"; cp dgputemp "$out/kernel/misc/amd64/dgputemp"; chmod 0555 "$out/kernel/misc/amd64/dgputemp"
    echo "dgputemp: undefined=$nu unresolved=0 exports=$g simd=0 negctl=1" > "$out/.dgputemp-gate"
    cd /; find "$W" -depth -delete
  '' ];
}
