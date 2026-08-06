# libumem opt-in allocator (level a: ship + easy opt-in, default OFF).
#
# libumem is the modernized Bonwick/Adams userspace slab allocator
# (codeberg.org/gregburd/libumem, packaged as pkgs.solnix.libumem). It is a
# drop-in malloc replacement with per-thread caches, better multithreaded
# scaling, and UMEM_DEBUG runtime error detection (double-free, buffer overrun,
# use-after-free). It is NOT the system default (the default stays illumos libc
# malloc until benchmarked -- see docs/post-stable-backlog.md PS-3); this option
# only makes it a trivially-enabled login-scoped preload.
#
# ENABLE:  solnix.programs.libumem.enable = true;
# REVERT:  set it back to false (or remove) and rebuild -> next login drops the
#          preload; running processes are unaffected.
#
# Mechanism: a /etc/profile.d export of LD_PRELOAD for login shells (SAFE,
# login-scoped -- does not affect the boot path, SMF services, or setuid
# programs, which ignore LD_PRELOAD from an untrusted dir anyway). The
# system-wide alternative (`crle -e LD_PRELOAD=...`, which affects the runtime
# linker default for ALL processes) is intentionally NOT used here -- that is a
# heavier, benchmarked decision (PS-3).
#
# NOTE: the packaged libumem is currently 64-bit only, so the preload applies to
# 64-bit programs (nearly the entire Nix userland). 32-bit base-OS binaries keep
# libc malloc (see the libumem.nix ABI TODO).
{ config, lib, pkgs, ... }:
let cfg = config.solnix.programs.libumem;
in {
  options.solnix.programs.libumem.enable = lib.mkEnableOption
    "the libumem slab allocator as a login-shell LD_PRELOAD (opt-in; default illumos libc malloc)";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.solnix.libumem ];
    # login-scoped preload of the malloc interposer (libumem_malloc.so.1).
    environment.shellInit = ''
      export LD_PRELOAD="${pkgs.solnix.libumem}/lib/libumem_malloc.so.1''${LD_PRELOAD:+:$LD_PRELOAD}"
    '';
  };
}
