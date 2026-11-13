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
  qsv = { prep = jemallocFix; };   # tikv-jemalloc-sys, as ruff (its configure also needs GNU grep/sed: /usr/gnu first on PATH)
  uv = { prep = jemallocFix; };
  # starship-battery (default "battery") and nvml have no illumos arm: build without them; "zfs" (the ARC on the memory
  # widget) has Linux/FreeBSD arms only, so it stays off too.
  # sysinfo has no illumos backend in any release: its illumos build is the "unknown" stub, so every collector bottom takes
  # from it (CPU, memory, swap, disks, network, processes, temperatures) read zero. Carry the illumos backend of sysinfo
  # PR #1741 (notpeter/sysinfo dfcd8a2c, MIT: kstat, /proc, /etc/mnttab + statvfs, ksensor), ported to the 0.40.3 API
  # (rust-fixups/sysinfo-0.40.3-illumos.patch says how). Drop it when a sysinfo release has an illumos backend.
  bottom = { noDefault = true; prep = ''
    d=$V/sysinfo; grep -q '^version = "0.40.3"$' $d/Cargo.toml || { echo "FATAL: bottom's sysinfo is not 0.40.3" >&2; exit 1; }
    ( cd $d && patch -p1 --no-backup-if-mismatch < ${./rust-fixups/sysinfo-0.40.3-illumos.patch} ) || { echo "FATAL: sysinfo illumos patch" >&2; exit 1; }
    [ -f $d/src/unix/illumos/kstat.rs ] && grep -q 'target_os = "illumos"' $d/src/unix/mod.rs || { echo "FATAL: sysinfo illumos backend missing" >&2; exit 1; }
    # bottom refreshes sysinfo's disk list only on Windows and FreeBSD (collection.rs): on illumos it stayed empty ("No data")
    f=src/collection.rs; a='            #[cfg(any(target_os = "windows", target_os = "freebsd"))]'
    [ "$(grep -cxF "$a" $f)" = 1 ] || { echo "FATAL: bottom disk-refresh cfg anchor" >&2; exit 1; }
    sed -i 's/^            #\[cfg(any(target_os = "windows", target_os = "freebsd"))\]$/            #[cfg(any(target_os = "windows", target_os = "freebsd", target_os = "illumos"))]/' $f
    grep -q 'target_os = "freebsd", target_os = "illumos"))]' $f || { echo "FATAL: bottom disk-refresh cfg" >&2; exit 1; }
    # its process table: get_processes() routes only linux/freebsd/macos/windows/android/ios to a collector ("Unsupported"
    # otherwise); illumos takes the generic unix one (GenericProcessExt over sysinfo, as any other unix)
    f=src/collection/processes.rs; a='                target_os = "ios"'
    [ "$(grep -cxF "$a" $f)" = 1 ] || { echo "FATAL: bottom get_processes cfg anchor" >&2; exit 1; }
    sed -i 's/^                target_os = "ios"$/                target_os = "ios",\n                target_os = "illumos"/' $f
    grep -qx '                target_os = "illumos"' $f || { echo "FATAL: bottom get_processes cfg" >&2; exit 1; }
    # process states: process_status_str and the state letter have no illumos arm ("Unknown", '?'); psinfo's pr_sname letters
    "$python3/bin/python3" - src/collection/processes.rs src/collection/processes/unix/process_ext.rs <<'PY'
import sys
def ed(p, old, new):
    s = open(p).read()
    if s.count(old) != 1: sys.exit("FATAL: bottom state anchor in %s" % p)
    open(p, "w").write(s.replace(old, new))
ed(sys.argv[1], '        _ => "Unknown",\n    }\n}', '        target_os = "illumos" => match status {\n            ProcessStatus::Idle => "Idle",\n'
   '            ProcessStatus::Run => "Runnable",\n            ProcessStatus::Sleep => "Sleeping",\n            ProcessStatus::Stop => "Stopped",\n'
   '            ProcessStatus::Zombie => "Zombie",\n            _ => "Unknown",\n        },\n        _ => "Unknown",\n    }\n}')
ed(sys.argv[2], "        _ => '?',\n    }\n}", "        target_os = \"illumos\" => match status {\n            ProcessStatus::Idle => 'I',\n"
   "            ProcessStatus::Run => 'R',\n            ProcessStatus::Sleep => 'S',\n            ProcessStatus::Stop => 'T',\n"
   "            ProcessStatus::Zombie => 'Z',\n            _ => '?',\n        },\n        _ => '?',\n    }\n}")
PY
    # and its disk table needs an I/O map, which it makes only on Linux/macOS/Windows/FreeBSD ("Unsupported OS" elsewhere
    # drops the whole widget): on illumos, sysinfo's per-disk counters (rust-fixups/bottom-io-illumos.rs, as FreeBSD's)
    "$python3/bin/python3" - src/collection/disks.rs ${./rust-fixups/bottom-io-illumos.rs} <<'PY'
import sys
p, arm = sys.argv[1], open(sys.argv[2]).read(); s = open(p).read(); a = '    not(target_os = "freebsd") => {\n'
if s.count(a) != 1: sys.exit("FATAL: bottom io-usage cfg anchor")
open(p, "w").write(s.replace(a, arm + a))   # cfg_select takes the first arm that matches: illumos before not(freebsd)
PY
    # the vendored crate's checksums: the patched files are this build's own, so cargo checks none of them
    printf '{"files":{},"package":"%s"}' "$(sed -n 's/.*"package":"\([0-9a-f]*\)".*/\1/p' $d/.cargo-checksum.json)" > $d/.cargo-checksum.json
  ''; };
  # --- batch C1.
  # tree-sitter's portable/endian.h: see difftastic. Its default qjs-rt feature builds rquickjs-sys, whose build.rs
  # needs bindgen + libclang for a target without shipped bindings (x86_64-unknown-illumos; measured): build without it
  # (`tree-sitter generate` then needs node for grammar.js, as before 0.25).
  tree-sitter = { env = ''export CFLAGS="-D__illumos__"''; noDefault = true; };
  # harper: only the CLI + language server (nixpkgs' cargoBuildFlags); the workspace also holds a tauri desktop app.
  # blanket 0.4.0 (harper-core's #[blanket(derive(Arc, Ref))] on trait Dictionary) collects the derives in a std HashSet, whose
  # iteration order is per-process random (RandomState), and emits one impl per element in that order: rustc numbers the impls by
  # it, so 30 v0 symbols (impl Dictionary for Arc<D> / &D) flipped run to run on one host (wave6w, measured). A BTreeSet makes the
  # order the enum's declaration order (nixpkgs has no fix; upstream althonos/blanket has the HashSet at master).
  # ahash's compile-time-rng (harper's tree enables it) bakes const_random!() seeds, which const-random-macro draws from getrandom
  # when the proc macro is built unless CONST_RANDOM_SEED is set (its reproducible-build knob): two builds differed in exactly
  # those 4 u64 immediates (32 bytes of .text in harper-cli and harper-ls, holds1). A fixed seed; ahash still seeds at run time.
  harper = { env = ''export CFLAGS="-D__illumos__" CONST_RANDOM_SEED=solnix-harper''; prep = ''
    grep -qx 'resolver = "2"' Cargo.toml || { echo "FATAL: harper workspace anchor" >&2; exit 1; }
    sed -i 's/^resolver = "2"$/resolver = "2"\ndefault-members = ["harper-cli", "harper-ls"]/' Cargo.toml
    vfix blanket src/lib.rs "'use std::collections::HashSet;'" "'use std::collections::BTreeSet as HashSet;'"
    vfix blanket src/types/mod.rs "'#[derive(Debug, PartialEq, Eq, Hash)]\npub enum Type {'" "'#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]\npub enum Type {'"
    ! grep -rqE "std::collections::(HashSet|HashMap)[;,}]" .nix-cargo-vendor/blanket/src || { echo "FATAL: blanket still uses a std hash set/map" >&2; exit 1; }
  ''; };
  # socket2 0.5 has no set_tos/set_tclass_v6/set_reuse_port on illumos (cfg'd out). illumos has IP_TOS and
  # IPV6_TCLASS (int setsockopt) and no SO_REUSEPORT: a SockExt trait gives trippy-core the first two, the third is a no-op.
  trippy = { prep = ''
    f=crates/trippy-core/src/net/platform/unix.rs; a='    use socket2::{Domain, Protocol, SockAddr, Type};'
    grep -qxF "$a" $f || { echo "FATAL: trippy socket2 anchor" >&2; exit 1; }
    sed -i "s|^$a\$|$a\n    #[cfg(target_os = \"illumos\")]\n    use super::sockopt_illumos::SockExt;|" $f
    cat ${./rust-fixups/trippy-sockopt-illumos.rs} >> $f
  ''; };
  # uu_ls: illumos libc's major()/minor() are `unsafe fn` (E0133). uu_sort: rustix is not a dependency on illumos
  # (its Cargo.toml), so take the portable access() arm. Default features (feat_common_core, 89 utils): feat_os_unix
  # adds who/users/uptime/pinky (uucore's utmpx module has no illumos arm, E0432) and stdbuf (libstdbuf link fails); measured.
  uutils-coreutils = { prep = ''
    f=src/uu/ls/src/display.rs
    grep -q 'let major = major(dev);' $f || { echo "FATAL: uutils ls major anchor" >&2; exit 1; }
    sed -i 's/let major = major(dev);/#[allow(unused_unsafe)] let major = unsafe { major(dev) };/; s/let minor = minor(dev);/#[allow(unused_unsafe)] let minor = unsafe { minor(dev) };/' $f
    f=src/uu/sort/src/sort.rs
    grep -qx '#\[cfg(all(unix, not(target_os = "redox")))\]' $f && grep -qx '#\[cfg(any(not(unix), target_os = "redox"))\]' $f || { echo "FATAL: uutils sort cfg anchor" >&2; exit 1; }
    sed -i 's/^#\[cfg(all(unix, not(target_os = "redox")))\]$/#[cfg(all(unix, not(target_os = "redox"), not(target_os = "illumos")))]/; s/^#\[cfg(any(not(unix), target_os = "redox"))\]$/#[cfg(any(not(unix), target_os = "redox", target_os = "illumos"))]/' $f
  ''; man = ''
    cd "$out/bin"; mv coreutils uutils-coreutils
    for u in $(./uutils-coreutils --list); do [ "$u" = coreutils ] || ln -s uutils-coreutils "uutils-$u"; done; cd - >/dev/null
  ''; };
  # illumos libc exports wait4 (sys/wait.h), the libc crate has no solarish binding: declare it.
  hyperfine = { prep = ''
    f=src/timer/unix_timer.rs
    grep -q 'libc::wait4(' $f || { echo "FATAL: hyperfine wait4 anchor" >&2; exit 1; }
    sed -i 's/libc::wait4(/illumos_wait4(/' $f
    printf '\n#[cfg(target_os = "illumos")]\nextern "C" { #[link_name = "wait4"] fn illumos_wait4(pid: libc::pid_t, status: *mut libc::c_int, options: libc::c_int, rusage: *mut libc::rusage) -> libc::pid_t; }\n#[cfg(not(target_os = "illumos"))]\nuse libc::wait4 as illumos_wait4;\n' >> $f
  ''; };
}
