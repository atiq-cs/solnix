{ config, lib, solnixSystem ? "x86_64-solaris", ... }:
# modules/config/user-limit.nix -- where a 64-bit process's address space ends (illumos _userlimit).
#
# Upstream illumos amd64 puts the top of user space just below the kernel, at 0xFFFFFC7F.FFE00000
# (uts/i86pc/sys/machparam.h USERLIMIT), above the x86_64 VA hole. The stack, ld.so.1 and every
# shared library are mapped top-down from there, so their addresses have bits 47..63 set. Linux
# (and so NixOS) never hands user space an address >= 2^47.
#
# Runtimes that keep tags in the top bits of a pointer (NaN-boxing, tagged pointers) assume the
# Linux layout. SpiderMonkey stores a native function pointer as JS::PrivateValue; with libxul at
# 0xfffffc7f... that value looks like a GC thing, the post-write barrier reads a chunk header at an
# unmapped address, and Firefox SEGVs creating its first JS global (browser4, 2026-11-11: the same
# Firefox binary SEGVed 6/6 with the upstream layout and wrote its headless screenshot 8/8 with this
# tunable). Mozilla closed the general case WONTFIX (bug 577056, "Memory layout for 64-bit Solaris is
# different"). mimalloc has the same assumption (pop-launcher, 72f6a23).
#
# OpenIndiana has shipped the fix as a system default since 2021 (oi-userland aaa97980d8,
# components/openindiana/illumos-gate overlay etc/system.d/reserve_bits_for_tagged_pointers,
# x86 only): `set _userlimit=0x7fffc0000000`. A 64-bit process still has ~128 TB below 2^47. This
# module makes that the solnix default, so processes are laid out as on Linux/NixOS. x86_64 only:
# OI keeps the upstream value on SPARC (199ab5beb7), and the aarch64 kernel has its own layout.
#
# It is a kernel tunable read from /etc/system.d at boot (install-be assembles .self-assembly), so a
# change takes effect at the next boot of the generation, not on switch.
let
  cfg = config.solnix.kernel;
  x86 = solnixSystem == "x86_64-solaris";
in
{
  options.solnix.kernel.userLimit47 = lib.mkOption {
    type = lib.types.bool;
    default = x86;
    defaultText = lib.literalExpression ''solnixSystem == "x86_64-solaris"'';
    description = ''
      Keep every 64-bit user address below 2^47, as Linux does: `set _userlimit=0x7fffc0000000` in
      /etc/system.d (OpenIndiana's default since 2021, oi-userland aaa97980d8). Without it, upstream
      illumos maps shared libraries and the stack at 0xFFFFFC7F..., and runtimes that tag the top
      pointer bits crash: Firefox's SpiderMonkey (NaN-boxed JS::Value, Mozilla bug 577056 WONTFIX)
      and mimalloc. Takes effect at the next boot. x86_64 only.
    '';
  };

  config = lib.mkIf cfg.userLimit47 {
    assertions = [ {
      assertion = x86;
      message = "solnix.kernel.userLimit47 is the x86_64 illumos layout (amd64 _userlimit); ${solnixSystem} has none.";
    } ];
    environment.generatedEtc."system.d/solnix-userlimit47" = ''
      * solnix.kernel.userLimit47 (modules/config/user-limit.nix): 64-bit user addresses stay below 2^47,
      * as on Linux, for NaN-boxing/tagged-pointer runtimes (SpiderMonkey, mimalloc). OpenIndiana's
      * reserve_bits_for_tagged_pointers (oi-userland aaa97980d8).
      set _userlimit=0x7fffc0000000
    '';
  };
}
