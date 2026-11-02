# pkgs.solnix.touchpad-driver -- the X1E Gen 5 touchpad: dwiic (Intel LPSS
# DesignWare I2C controller, OpenBSD dwiic(4) logic) and ihid (HID over I2C,
# OpenBSD ihidev(4) sequence) from src/ports/touchpad, as a pure derivation on
# the iwx-driver.nix pattern. ihid is a STREAMS driver shaped like usb hid(4D):
# consconfig_dacf pushes usbms on its internal_mouse node and links it under
# consms (dacf.conf rule, laid by hardware.touchpad.i2cHid), so /dev/mouse and
# the console pointer see it beside the PS/2 TrackPoint.
#
# HEADERS. The gate proto ships no sys/i2c/*.h, sys/acpica.h or
# usba/usbai_private.h, so the build also searches the kernel's own source
# (kernelNd.src, the tree kernelNd was built from), AFTER the proto.
#
# GATE (fail closed). For each module:
#   * unresolved = 0 against the gate proto AND kernelNd (unix + genunix +
#     drv/i2cnex + misc/acpica + misc/hidparser, plus dwiic for ihid: ihid
#     calls dwiic_xfer for reads longer than i2cnex's 256-byte request cap);
#   * exported globals are exactly _init/_fini/_info (dwiic also dwiic_xfer);
# with the iwx negative controls: >= 40 undefined refs, and one bogus extern
# linked into a copy must come out as exactly one more unresolved symbol.
#
# OUTPUT: $out/kernel/drv/amd64/{dwiic,ihid}, $out/.touchpad-gate

{ gate                       # the gate proto (usr/include + reference kernel)
, kernelNd                   # the shipped non-DEBUG kernel; .src = its gate source
, solnixDev                  # gcc + gas + gmake on PATH
, ld                         # the gate link-editor slice
, kmodPath ? null             # wave6: store bin dirs replacing /usr/bin:/usr/sbin:/usr/gnu/bin (default.nix kmodTools); null = old
, pathGate ? null
, system ? "x86_64-solaris"
, tpSrc ? builtins.path {
    path = ../../src/ports/touchpad;
    name = "solnix-touchpad-src";
    filter = path: type:
      let b = baseNameOf path;
      in !(type == "regular" && (b == "dwiic" || b == "ihid" || builtins.match ".*\\.o" b != null));
  }
}:

derivation {
  name = "touchpad-driver";
  inherit system gate kernelNd solnixDev ld tpSrc;
  utsSrc = "${kernelNd.src}/usr/src/uts";
  builder = "/usr/bin/bash";
  PATH = if kmodPath == null then "/usr/bin:/usr/sbin:/usr/gnu/bin" else kmodPath;
  pathGate = if pathGate == null then "" else pathGate;

  args = [ "-c" ''
    set -eu
    export PATH="$solnixDev/bin:$ld/usr/bin:$ld/bin:$PATH"   # $PATH = the drv's: store tools (kmodPath), or the old host dirs
    [ -z "$pathGate" ] || PATH_GATE_ALLOW="" /usr/bin/bash "$pathGate"
    UTSINC="$gate/usr/include"
    [ -d "$UTSINC/sys" ] || { echo "FATAL: gate proto has no usr/include/sys" >&2; exit 1; }
    [ -f "$utsSrc/common/sys/i2c/client.h" ] || { echo "FATAL: $utsSrc has no sys/i2c/client.h" >&2; exit 1; }
    for t in gcc gmake; do command -v $t >/dev/null || { echo "FATAL: no $t" >&2; exit 1; }; done
    LDBIN="$ld/usr/bin/ld"
    [ -x "$LDBIN" ] || LDBIN="$ld/bin/ld"
    [ -x "$LDBIN" ] || LDBIN=/usr/bin/ld
    WORK=$(mktemp -d "${TMPDIR:-/tmp}"/touchpad-driver.XXXXXX)
    cp -r "$tpSrc" "$WORK/tp"; chmod -R u+w "$WORK/tp"; cd "$WORK/tp"

    gmake -f Makefile.illumos UTSINC="$UTSINC" UTSSRC="$utsSrc" LD="$LDBIN" >build.log 2>&1 \
      || { echo "FATAL: touchpad build failed" >&2; tail -40 build.log >&2; exit 1; }

    # illumos nm (GNU nm -p prints nothing for these ET_REL objects).
    NM=$(command -v nm || echo /usr/bin/nm); [ -x "$NM" ] || NM=nm
    defs() { for k in "$@"; do [ -f "$k" ] || { echo "FATAL: reference $k missing" >&2; exit 1; }; $NM -p "$k"; done \
      | awk '$2 ~ /^[TDBRC]$/ {print $3}' | sort -u; }
    undef() { $NM -p "$1" | awk '$2=="U" {print $3}' | sort -u; }
    refs() { echo "$1/platform/i86pc/kernel/amd64/unix $1/kernel/amd64/genunix $1/kernel/drv/amd64/i2cnex" \
      "$1/kernel/misc/amd64/acpica $1/kernel/misc/amd64/hidparser"; }
    gate_one() {   # gate_one <module> <exports regex> [extra reference module]
      m=$1; want=$2; extra=''${3:-}
      defs $(refs "$gate") $extra > $m.ref-proto; defs $(refs "$kernelNd") $extra > $m.ref-nd
      undef $m > $m.undef; nu=$(grep -c . $m.undef || true)
      [ "$nu" -ge 40 ] || { echo "FATAL: $m: only $nu undefined syms (nm produced too few)" >&2; exit 1; }
      printf 'extern int tp_gate_negctl_nosuch(void);\nint tp_gate_negctl(void) { return tp_gate_negctl_nosuch(); }\n' > negctl.c
      gcc -m64 -ffreestanding -nostdinc -c -o negctl.o negctl.c; "$LDBIN" -r -o $m.negctl $m negctl.o
      nreal=$(comm -23 $m.undef $m.ref-nd | grep -c . || true)
      nneg=$(undef $m.negctl | comm -23 - $m.ref-nd | grep -c . || true)
      [ "$nneg" -eq $((nreal + 1)) ] || { echo "FATAL: $m negative control gave $nneg, want $((nreal + 1))" >&2; exit 1; }
      np=$(comm -23 $m.undef $m.ref-proto | grep -c . || true)
      [ "$np" -eq 0 ] && [ "$nreal" -eq 0 ] || { echo "FATAL: $m unresolved: proto $np, kernel-nd $nreal" >&2;
        comm -23 $m.undef $m.ref-nd | sed 's/^/  /' >&2; exit 1; }
      ex=$($NM -p $m | awk '$2 ~ /^[TDBRC]$/ {print $3}' | sort -u | tr '\n' ' ')
      printf '%s\n' $ex | grep -vxE "$want" | grep . >&2 && { echo "FATAL: $m exports more than $want" >&2; exit 1; }
      [ "$(printf '%s\n' $ex | grep -cxE "$want")" -eq "$(echo "$want" | tr '|' '\n' | grep -c .)" ] \
        || { echo "FATAL: $m exports [$ex], want $want" >&2; exit 1; }
      echo "$m: undefined=$nu unresolved-proto=$np unresolved-kernel-nd=$nreal negctl=$nneg exports=[$ex]" | tee -a gate.txt >&2
    }
    gate_one dwiic '_init|_fini|_info|dwiic_xfer'
    gate_one ihid '_init|_fini|_info' "$PWD/dwiic"

    mkdir -p "$out/kernel/drv/amd64"
    cp dwiic ihid "$out/kernel/drv/amd64/"; chmod 0555 "$out/kernel/drv/amd64/"*
    { cat gate.txt; echo "reference-kernels=$gate $kernelNd"; } > "$out/.touchpad-gate"
    cd /; rm -rf "$WORK" || true
    echo "=== touchpad-driver: dwiic + ihid built, gate green ===" >&2
  '' ];
}
