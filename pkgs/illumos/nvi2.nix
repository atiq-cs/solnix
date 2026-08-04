# pkgs/illumos/nvi2.nix — nvi2 (github.com/lichray/nvi2): the modernized nvi editor.
#
# solnix's default `vi`. A small, wide-char, C++ nvi fork — a clean, illumos-friendly
# vi with no vim dependency. Packaged as `nvi`; `vi`/`ex`/`view` link to it.
#
# Build: cmake, C++ (needs the C++ stdenv). Deps: ncurses (curses UI). nvi2 uses the
# system/bundled DB for recovery files. Installs bin/{nvi,vi,ex,view} + share/vi.
#
# Usage (in the fork overlay / a callPackage site):
#   nvi = pkgs.callPackage ./nvi2.nix { };
{ lib, stdenv, fetchFromGitHub, cmake, ncurses, pkg-config }:

stdenv.mkDerivation (finalAttrs: {
  pname = "nvi";
  version = "2.2.1-unstable"; # nvi2 is versioned loosely; pin the rev below.

  src = fetchFromGitHub {
    owner = "lichray";
    repo = "nvi2";
    # Pin an explicit rev for reproducibility (a recent lichray/nvi2 commit).
    # NOTE: the build agent resolves + fills the real rev + hash from the repo HEAD
    # at build time and reports them back for this pin.
    rev = "@NVI2_REV@";
    hash = "@NVI2_SRC_HASH@";
  };

  nativeBuildInputs = [ cmake pkg-config ];
  buildInputs = [ ncurses ];

  # nvi2 is a straightforward cmake build. On illumos: ensure the curses lib is
  # ncurses (wide, from the store), and link -lsocket -lnsl if the DB/recovery
  # code pulls them. The gawkReal hermeticity pattern applies (store -L before
  # any host lib dir) so ncurses resolves from /nix/store, not /usr/lib/64.
  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
  ];
  env.NIX_CFLAGS_COMPILE_BEFORE = "-L${lib.getLib ncurses}/lib";
  env.NIX_LDFLAGS = "-lsocket -lnsl";

  # nvi2 installs `nvi`; provide the classic vi/ex/view names as links to it.
  postInstall = ''
    if [ -x "$out/bin/nvi" ]; then
      for n in vi ex view; do
        [ -e "$out/bin/$n" ] || ln -s nvi "$out/bin/$n"
      done
    fi
  '';

  meta = with lib; {
    description = "nvi2 — modernized Berkeley nvi (solnix default vi)";
    homepage = "https://github.com/lichray/nvi2";
    license = licenses.bsd3; # nvi is BSD (CSRG); nvi2 keeps the BSD license
    mainProgram = "nvi";
    platforms = platforms.illumos or [ "x86_64-solaris" ];
  };
})
