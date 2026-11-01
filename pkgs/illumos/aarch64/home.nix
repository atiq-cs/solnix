# aarch64/home.nix -- the packages a solnix HOME needs on aarch64 (lib/home-manager-pkgs.nix's
# tools, home-manager itself, the headless C tier), from the x86 recipes in ../base-src.nix and
# ../cli/c-*.nix, built natively with mk-src-pkg's aarch64 rewrite. No Rust or Go: neither has an
# illumos/aarch64 target upstream (rustc: no aarch64-unknown-illumos; go: GOOS=illumos is amd64 only).
{ gate, libcSlice, gcc, srcPkgs, system ? "aarch64-solaris" }:

let
  # x86 links these against `world` (the whole relocated userland, mk-proto-world.nix), which aarch64
  # does not have; this is the subset the recipes below NEED (measured with elfdump on the proto).
  world = srcPkgs.mkGateLibs "illumos-gate-libs-home"
    "libsec.so.1 libgen.so.1 libxnet.so.1 libsendfile.so.1 libcurses.so.1 libkstat.so.1 libnvpair.so.1 libumem.so.1 libintl.so.1";
  base = import ../base-src.nix { inherit gate libcSlice world gcc system; aarch64 = true; };
  # the aarch64 srcPkgs builds (nix chain, ncurses, bash, ...) stand in for base-src's x86-only ones.
  base' = base // { inherit (srcPkgs) mkSrcPkg zlib openssl ncurses libiconv readline bash nixChain less nano nvi tree htop top git wget; };
  cli = import ../cli { base = base'; inherit world; graphics = null; };
in
{
  inherit world;
  # lib/home-manager-pkgs.nix's tools + home-manager
  inherit (base) coreutils findutils gnused gnugrep diffutils gnutar gzip jq lndir gettext hostname
    gnumake pkgconf rsync libevent tmux;
  # on the aarch64 bash (./src.nix, built for the image): base-src's bash links the x86 world's curses and its
  # examples/loadables pick SunPro's `-K pic` on aarch64 (measured).
  home-manager = derivation (base.home-manager.drvAttrs // { inherit (srcPkgs) bash; });
  # the headless C tier (file bc screen socat sqlite ncdu tig lsof perl ... as cli/ builds them)
  inherit (cli) file bc gnum4 socat sqlite ncdu tig perl autoconf automake libtool
    gnupg quilt gnupatch getopt xxhash cmake ccache pkg-config gdbm isync fortune-mod;
  # not yet on aarch64 (first native build 2026-10-28 failed; each is a recipe port):
  #   python3 (cli/c-dev.nix links graphics.libffi + graphics.expat; no aarch64 graphics set)
  #   lsof (lib/dialects/sun/dproc.c: ARCH64B undeclared), screen (doc needs makeinfo), neomutt (autosetup runs `cc`),
  #   lynx (configure finds no curses functions), w3m (its bdwgc: os_dep.c open/O_RDONLY undeclared).
}
