# pkgs.solnix.bluetooth -- the userland Bluetooth phase-0/1 tools for Intel AX2xx
# controllers that usb_mid leaves in ugen mode (docs/design-bluetooth.md,
# docs/bluetooth-phase1-plan.md). Plain derivations with the solnix-dev gcc,
# built like solnix-cputemp; each one runs its own self-test and negative
# controls at build time, so a store path exists only if those passed.
#
#   btintelfw  src/ports/bluetooth/iwmbtfw: FreeBSD iwmbtfw (BSD-2) over ugen,
#              the Intel firmware loader. $out/bin/btintelfw
#   hcitest    src/ports/bluetooth/netbt: NetBSD's netbt HCI core (BSD) in
#              userland over the same transport: unit up + inquiry, transcript
#              replay. $out/bin/hcitest, $out/share/hcitest/fixtures
#
# Neither is installed or run by any module; they are tools, run by hand with
# pfexec against /dev/usb/8087.33/0. Firmware is pkgs.solnix.ibtFirmware.
{ gate                 # the gate proto (usr/include/sys/usb/clients/ugen/usb_ugen.h)
, solnixDev            # gcc + binutils + gmake
, tools                # store coreutils, findutils, the world (cp/mkdir/find/mktemp, awk/cmp/sed/grep): base-src's hostTools
, libc                 # the libc slice: RUNPATH for the binaries
, system ? "x86_64-solaris"
}:

let
  # Both trees, because netbt builds bt1's ugen transport from ../iwmbtfw.
  src = builtins.path {
    path = ../../../src/ports/bluetooth;
    name = "solnix-bluetooth-src";
    filter = path: type:
      let b = baseNameOf path;
      in !(type == "regular" && (b == "btintelfw" || b == "hcitest" || builtins.match ".*\\.o" b != null))
         && builtins.match "\\.unison.*" b == null;   # the dev box's sync debris
  };
  tool = { name, dir, bin, extra ? "" }: derivation {
    inherit name system src gate solnixDev;
    builder = "/usr/bin/bash";
    args = [ "-c" ''
      set -eu
      # store tools only: with /usr/bin on PATH, cp/mkdir/find/awk came from the build host (OI's on chef, rows1 audit)
      export PATH="$solnixDev/bin:${builtins.concatStringsSep ":" (map (t: "${t}/bin") tools)}"
      /usr/bin/bash ${../path-gate.sh}
      [ -f "$gate/usr/include/sys/usb/clients/ugen/usb_ugen.h" ] || { echo "FATAL: gate proto has no usb_ugen.h" >&2; exit 1; }
      W=$(mktemp -d /tmp/${name}.XXXXXX)
      cp -r "$src/." "$W/"; chmod -R u+w "$W"; cd "$W/${dir}"
      export PROTOINC="$gate/usr/include"
      # check = build, self-test, (fixtures,) negative controls; fail closed
      gmake -f Makefile.illumos PROTOINC="$PROTOINC" check > check.log 2>&1 \
        || { tail -40 check.log >&2; echo "FATAL: ${name} check failed" >&2; exit 1; }
      awk '/^negative controls:/ { split($3, a, "/"); if (a[1] == a[2] && a[1] > 0) ok = 1 } END { exit !ok }' check.log \
        || { tail -20 check.log >&2; echo "FATAL: ${name}: no full negative-control line" >&2; exit 1; }
      # link the shipped binary against the store libc, not the build host's
      rm -f ${bin}; gmake -f Makefile.illumos PROTOINC="$PROTOINC" ${bin} \
        CC="gcc -Wl,-R,${libc}/lib/amd64" > link.log 2>&1 || { cat link.log >&2; exit 1; }
      mkdir -p "$out/bin" "$out/share/${name}"
      cp ${bin} "$out/bin/${bin}"; chmod 0555 "$out/bin/${bin}"
      cp check.log "$out/share/${name}/check.log"
      ${extra}
      cd /; find "$W" -depth -delete
    '' ];
  };
in
{
  btintelfw = tool { name = "btintelfw"; dir = "iwmbtfw"; bin = "btintelfw"; };
  hcitest = tool {
    name = "hcitest"; dir = "netbt"; bin = "hcitest";
    extra = ''cp -r fixtures "$out/share/hcitest/fixtures"'';
  };
}
