# Fork-world blockers hit by cosmic-term through solnix-pkgs (2026-10-27, cosmic2)

Build: `nix-store -r` of cosmic-term drv wc7ygfv5qpb8jv1az3vxw9s6b9k7bs6m (harness
/scratch/solnix/cosmic2/eval-ct.nix = overlays.default + shellPathOverlay + cosmic overlay)
on a fresh us-west-2 build host (ami-0c3f16422f8943a8b) with `library/mpfr` installed.
The fork stdenv built (wbg7bkl6). These 9 failed. Log: bh /var/tmp/big/ct.log, excerpt in
/scratch/solnix/cosmic2/fork-errs.txt. First failing line each (`nix log <drv>`):

| drv | first error |
|---|---|
| perl-5.42.0 hc2d797r | `Hunk #1 FAILED at 585.` (patch to hints/solaris_2.sh; 1 of 2 hunks rejected) |
| unzip-6.0 x1cf7lf5 | `globals.h:146:12: fatal error: bzlib.h: No such file or directory` |
| pkg-config-0.29.2 jliaiplv | `checking for res_query... configure: error: not found` (bundled glib; needs -lresolv) |
| byacc-20260126 jcvnr6az | `make: *** [makefile:152: check] Error 1` (the check phase, after the build passed) |
| c-ares-1.34.8 7g6ha62f | `ld: fatal: symbol referencing errors. No output written to .libs/ahost` (connect/recvfrom/freeifaddrs: no -lsocket) |
| tcl-8.6.16 k5njvkk9 | `compat/fake-rfc2553.c:44:1: error: static declaration of 'strlcpy' follows non-static declaration` (also `isainfo: command not found` in configure) |
| gettext-1.0 ajjrz7qb | `checking whether the C compiler works... no` / `C compiler cannot create executables` (gettext-runtime) |
| rhash-1.4.6 hqwg0y9g | `Error: Unknown target OS, please specify the --target option` |
| cosmic-term-1.5.0.tar.gz r5km2rz9 (FOD) | `builder.sh: line 14: curl: command not found` (fork fetchurl has no curl) |

Also seen in configure output, not fatal on its own: `./configure: line 6610: file: command
not found` (pkg-config, c-ares: libtool's nm-parse check fails).

Not pursued (orchestrator 2026-10-27): cosmic-term is built solnix-side instead. The
mpfr/seed defect behind the earlier attempts is fixed separately
(solnix-pkgs-unpack-seed.diff); whether it changes any of the nine above was not tested.
