# solnix illumos world — standalone Nix expression for the illumos build host.
#
# GATES A/B of docs/design-gate-derivation.md, self-contained (no nixpkgs).
# Build on the host with Nix 2.3.16:
#   nix-build /var/tmp/solnix-nix/default.nix -A gate
#   nix-build /var/tmp/solnix-nix/default.nix -A libc
#
# Fork mapping: `gate` -> pkgs/os-specific/illumos/pkgs/gate.nix (as FOD),
# `libc`/`rtld`/... -> mkIllumosComponent calls in default.nix's rec block.

let
  # GATE A: the gate proto as a store path (ingest variant; full build FOD later).
  gate = import ./gate.nix { };

  mkIllumosComponent = args: import ./mk-illumos-component.nix ({ gate = gate; } // args);

  # GATE B: libc slice. Files per design §2.4. All siblings live inside this
  # component, so RUNPATH needs only $ORIGIN (deps = []).
  libc = mkIllumosComponent {
    name = "libc";
    files = [
      # runtime libc + historically-split siblings (versioned .so.N)
      "lib/amd64/libc.so.1"
      "lib/amd64/libm.so.1"
      "lib/amd64/libm.so.2"
      "lib/amd64/libsocket.so.1"
      "lib/amd64/libnsl.so.1"
      "lib/amd64/libresolv.so.2"
      "lib/amd64/libelf.so.1"
      "lib/amd64/libpthread.so.1"
      "lib/amd64/librt.so.1"
      "lib/amd64/libdl.so.1"
      # crt + values startup objects
      "usr/lib/amd64/crt1.o"
      "usr/lib/amd64/crti.o"
      "usr/lib/amd64/crtn.o"
      "usr/lib/amd64/values-Xa.o"
      "usr/lib/amd64/values-Xc.o"
      "usr/lib/amd64/values-Xs.o"
      "usr/lib/amd64/values-Xt.o"
      "usr/lib/amd64/values-xpg4.o"
      "usr/lib/amd64/values-xpg6.o"
      # link-editor symlinks (.so -> ../../../lib/amd64/.so.N)
      "usr/lib/amd64/libc.so"
      "usr/lib/amd64/libm.so"
      "usr/lib/amd64/libsocket.so"
      "usr/lib/amd64/libnsl.so"
      "usr/lib/amd64/libresolv.so"
      "usr/lib/amd64/libelf.so"
      # full system header tree
      "usr/include"
    ];
    # passthru-equivalent (consumed by cc-wrapper later): incdir=/usr/include,
    # libdir=/usr/lib/amd64. Plain derivation has no passthru; the fork sets it.
  };
in
{
  inherit gate libc;
}
