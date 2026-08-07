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
# The packaged libumem is a single-ABI (64-bit) build, so the preload
# applies to 64-bit programs (nearly the entire Nix userland). A system-wide
# global preload stays UNSAFE and is deliberately NOT offered: (1) illumos base
# tools are 32-bit (e.g. /usr/bin/true) and the 2.24 stdenv cannot yet build a
# 32-bit libumem (gcc -m32 fails: "wrong ELF class: ELFCLASS32"), so a global
# LD_PRELOAD would break every 32-bit exec; upstream 2.4.0 documents a two-pass
# lib/+lib/64 dual-ABI install but that needs a 32-bit-capable toolchain path we
# do not have. (2) libumem 2.4.0's malloc interposer has a calloc bug: calloc()
# above ~2 KiB returns NULL (a global preload would break large-array callocs).
# Both keep this login-scoped and opt-in, not a system default (see libumem.nix).
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
