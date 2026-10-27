# cli/rust-extra.nix -- per-package overrides for ./rust.nix (vendorHash, features, man pages).
{ openssl, ... }:
let
  jemallocFix = ''vfix tikv-jemalloc-sys build.rs "'        s => s.to_string(),\n    }\n}\n\nfn make_cmd'" "'        \"x86_64-unknown-illumos\" => \"x86_64-pc-solaris2.11\".to_string(),\n        s => s.to_string(),\n    }\n}\n\nfn make_cmd'"
    # jemalloc's configure adds -herror_on_warning (a Sun cc flag) when a -c compile accepts it;
    # gcc passes -h to the illumos ld as the SONAME, so every later link probe fails
    # ("ld: fatal: flags processing errors" -> "cannot determine return type of strerror_r").
    vfix tikv-jemalloc-sys configure/configure "'T_APPEND_V=-herror_on_warning'" "'T_APPEND_V='"
    # background-thread CPU pinning: illumos has neither sched_setaffinity nor pthread cpusets
    # (processor_bind is the native call). Pinning is a placement hint: skip it on __sun.
    vfix tikv-jemalloc-sys jemalloc/src/background_thread.c "'static inline bool\nset_current_thread_affinity(int cpu) {\n'" "'#if defined(__sun)\nstatic inline bool\nset_current_thread_affinity(int cpu) { (void)cpu; return false; }\n#else\nstatic inline bool\nset_current_thread_affinity(int cpu) {\n'"
    vfix tikv-jemalloc-sys jemalloc/src/background_thread.c "'\n#define BILLION UINT64_C(1000000000)'" "'\n#endif /* !__sun */\n#define BILLION UINT64_C(1000000000)'"
  '';
in
{
  # onig_sys (oniguruma, C) calls alloca() without <alloca.h>, which illumos does not pull in.
  bat = { env = ''export CFLAGS="-include alloca.h"''; };
  git-delta = { env = ''export CFLAGS="-include alloca.h"''; };
  # tree-sitter's portable/endian.h has an __illumos__ arm (<endian.h>), but gcc only predefines
  # __sun; its __sun arm then calls LE_16 without <sys/byteorder.h> macros (measured).
  difftastic = { env = ''export CFLAGS="-D__illumos__"''; };
  ast-grep = { env = ''export CFLAGS="-D__illumos__"'';
    # fs2's allocate() has no illumos arm; illumos libc has posix_fallocate (the Linux one).
    prep = ''vfix fs2 src/unix.rs "'          target_os = \"nacl\"))]\npub fn allocate'" "'          target_os = \"nacl\", target_os = \"illumos\"))]\npub fn allocate'"''; };
  # openssl-sys: the store openssl (lib/amd64), not a probe of the host.
  atuin = { env = ''export CFLAGS="-D__illumos__" OPENSSL_DIR=${openssl} OPENSSL_LIB_DIR=${openssl}/lib/amd64 OPENSSL_INCLUDE_DIR=${openssl}/include''; libs = [ openssl ]; };
  # tikv-jemalloc-sys passes the rust triple to jemalloc's configure, and config.sub rejects
  # x86_64-unknown-illumos (measured): map it to x86_64-pc-solaris2.11 (jemalloc's Solaris port).
  ruff = { prep = jemallocFix; };
  uv = { prep = jemallocFix; };
  # starship-battery (default "battery") and nvml have no illumos arm: build without them.
  bottom = { noDefault = true; };
  # illumos libc exports wait4 (sys/wait.h), the libc crate has no solarish binding: declare it.
  hyperfine = { prep = ''
    f=src/timer/unix_timer.rs
    grep -q 'libc::wait4(' $f || { echo "FATAL: hyperfine wait4 anchor" >&2; exit 1; }
    sed -i 's/libc::wait4(/illumos_wait4(/' $f
    printf '\n#[cfg(target_os = "illumos")]\nextern "C" { #[link_name = "wait4"] fn illumos_wait4(pid: libc::pid_t, status: *mut libc::c_int, options: libc::c_int, rusage: *mut libc::rusage) -> libc::pid_t; }\n#[cfg(not(target_os = "illumos"))]\nuse libc::wait4 as illumos_wait4;\n' >> $f
  ''; };
}
