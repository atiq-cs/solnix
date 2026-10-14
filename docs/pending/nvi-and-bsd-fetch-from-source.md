# nvi (nvi2) and BSD fetch in the from-source closure — deferred, scaffolded

Status: DEFERRED (reported, not dangling-referenced). Opened by the
required-CLI-set stream (installer + AMI), HEAD a05e934.

The maintainer-required CLI set is curl, wget, BSD fetch, top, tree, htop, nano,
vi, nvi. All but **nvi** and **BSD fetch** now resolve as `pkgs.solnix.*`
from-source and are in the installer + AMI closures (base-src.nix: tree, wget;
already present: curl=nixChain.curl, top, htop, less, nano, vi=gate xpg4 vi).
This doc is why the last two are not yet in, and the concrete path to add them.

## Why nvi2 is not wired into `pkgs.solnix` today

`pkgs/illumos/nvi2.nix` and its `pkgs/illumos/db1.nix` dependency are **nixpkgs
`stdenv.mkDerivation`** derivations:

    { lib, stdenv, fetchFromGitHub, cmake, ncurses, pkg-config, db1 }:

They need a nixpkgs `callPackage`, a nixpkgs `stdenv`, and `cmake`. The
installer/AMI toplevels are built through `lib/host-pkgs.nix` (`mkPkgs`), whose
`pkgs.solnix` is `import ./pkgs/illumos` — a self-contained world with **no
`callPackage`, no `stdenv`, no `cmake`**, only `mk-src-pkg` (from source) and
`mk-illumos-component`/slices. The flake uses `mkPkgs` for toplevels *on
purpose* (flake.nix `mkPkgs` note): the nixpkgs-overlay path (`pkgsFor`) drags
~200 bootstrap derivations (perl, bison, texinfo, bash 5.3, libxml2 ...) that
are in no cache and that the installer media cannot build.

So `pkgs.callPackage ./nvi2.nix { db1 = pkgs.callPackage ./db1.nix {}; }`
(nvi2.nix's own usage note) only works in the `pkgsFor` world, not in the
`pkgs.solnix` world the images ship. Wiring it there would either (a) pull the
whole nixpkgs bootstrap into the installer closure, or (b) dangle an attr that
does not resolve — both rejected.

The editor requirement is already met: `pkgs.solnix.vi` (base-src.nix `vi`, the
gate's XPG4 vi/ex/view) resolves and is shipped. `nvi` is the nice-to-have
upgrade, not a gap in "an editor is present".

### Path to add nvi from source (the real work)

Port nvi2 to the `mk-src-pkg` idiom (like tree/wget), which means:

1. **db1 from source as `mk-src-pkg`.** Rewrite `db1.nix` from
   `stdenv.mkDerivation` to a `mkSrcPkg { pname="db1"; ... build = ''...''; }`
   in `base-src.nix`. The source (Debian db1-compat 2.1.3 orig) and the
   `patches/db1-cdefs.h` shim already exist; the build is a plain `make` of the
   BSD 1.85 hash/btree/recno/mpool tree into `lib/libdb-1.85.so.1` +
   `lib/libdb1.so` symlink + `include/db.h`. No cmake needed for db1 itself.
2. **cmake on the `mk-src-pkg` builder PATH.** nvi2 uses cmake. `mk-src-pkg`'s
   PATH is `buildTools:/usr/gnu/bin:/usr/bin:/usr/sbin`; the build-host AMI
   carries cmake 4.4.4 at the OS level (docs/solnix-buildhost-ami.md), so a
   build *there* can call it — but a bare solnix system (dixi/EC2 target) has no
   cmake, so this would not be reproducible-from-source on-target. Either
   (a) add a from-source cmake to the mk-src-pkg chain (large: cmake needs a C++
   toolchain + bootstrap), or (b) convert nvi2's build to its plain Makefile /
   hand-rolled `configure` if one exists, or (c) accept cmake as a build-host-only
   tool and document nvi as cache-substituted on bare targets.
3. **Carry nvi2's illumos fixups into the mk-src-pkg `build`**: the vendored
   `patches/bitstring.h` + `patches/util.h`, the three CMakeLists `sed`s
   (include dir, guard UTIL_LIBRARY / RESOLV_LIBRARY), `-lsocket -lnsl -lresolv`,
   and the ex-session edit smoke test. All already written in nvi2.nix; they
   translate directly.
4. Then `inherit (srcPkgs) nvi;` in `default.nix`, add `live.nvi` to
   installer.nix and `nvi` to base.nix, and link `vi`/`ex`/`view` → `nvi` only
   on the `nvi-edits-ok` marker (nvi2.nix already drops it).

Estimated effort: medium — step 1 is small, step 2 is the real decision (cmake
in the from-source chain is the blocker, same class as the Rust/autotools gaps
in docs/devtools-in-closure.md).

## Why BSD fetch is not packaged

FreeBSD `usr.bin/fetch` is a thin CLI over **`libfetch`** (FreeBSD
`lib/libfetch`), which pulls FreeBSD-specific headers and a FreeBSD build
(`bsd.lib.mk`). Porting libfetch to illumos + `mk-src-pkg` is a real port (its
HTTP/FTP/TLS state machine, FreeBSD `<netinet>` and `fetch.h` assumptions). It
is a genuine nice-to-have: `curl` and `wget` both resolve and ship, and either
covers "fetch a file over HTTP(S)/FTP". No partial/stub was added — a scaffolded
non-working `fetch` on PATH would be worse than its honest absence.

### Path to add BSD fetch

Port `libfetch` as a `mk-src-pkg` (autotools-free; it builds with a plain
Makefile and `common.c/http.c/ftp.c/file.c`), supplying illumos shims for the
few FreeBSD-isms (`__FBSDID`, `<sys/param.h>` bits, `strlcpy`/`strlcat` which
illumos libc has). Then build `usr.bin/fetch` against it. Medium effort,
lower priority than nvi.
