# pkgs/illumos/libumem.nix — the MODERNIZED libumem (codeberg.org/gregburd/libumem)
# as a hermetic x86_64-solaris derivation.
#
# libumem is the Bonwick/Adams userspace slab allocator (the Solaris/illumos
# umem, ported out of the kernel). This is the 2024-2026 revival: C11/C17,
# per-thread cache (PTC), scoped arenas, ownership tracking, GC, profiling, and
# mdb-class runtime introspection (findleaks/log/status/...) via a `umem(1)` CLI
# plus gdb/lldb integrations. On illumos the code is native (it CAME from here),
# so the pure 2.24 stdenv + seed toolchain builds it with a plain autotools run.
#
# 2.4.0 is the first release that builds cleanly on illumos/x86_64 with NO
# out-of-tree patches: the seven downstream fixes solnix carried against 2.2.0
# (x86 getfp/_breakpoint, MAP_POPULATE guard, -lsocket/-lnsl, .so.1 SONAME,
# plain interposer constructor, library-only-build, dual-ABI recipe) all landed
# upstream in 2.3.0. So the recipe is now a stock configure/make/make install.
#
# It ships TWO shared objects:
#   * libumem.so.1        — the core allocator + the umem_alloc/umem_free/object-
#                           cache/vmem-arena C API. Link with -lumem for the API.
#   * libumem_malloc.so.1 — the DROP-IN malloc/free/calloc/realloc interposer.
#                           THIS is the LD_PRELOAD target (the malloc replacement),
#                           NOT libumem.so (the modern fork split the interposer
#                           out of the core; classic Solaris libumem.so.1 combined
#                           them). `programs.libumem.enable` preloads this one.
#
# Upstream now sets `-version-info 1:0:0`, so libtool emits the classic-illumos
# libumem.so.1 / libumem_malloc.so.1 SONAME directly (no compat symlink needed).
#
# ABI: this is a single-ABI (64-bit) build — the compiler default. illumos base
# tools (e.g. /usr/bin/true) are 32-bit, and the 2.24 stdenv cannot yet link
# -m32 (the seed cc wrapper feeds 64-bit crt/-L dirs; `gcc -m32` fails with
# "wrong ELF class: ELFCLASS32"). Upstream documents a dual-ABI two-pass install
# (lib/ + lib/64/ via the runtime linker's /64 token), but that needs a 32-bit-
# capable toolchain path this stdenv doesn't have. So the preload is 64-bit-only
# (nearly the entire Nix userland) and stays a login-scoped opt-in, NOT a
# system-wide default (see modules/config/libumem.nix).
#
# Usage (a callPackage site / the tranche driver):
#   libumem = pkgs.callPackage ./libumem.nix { };
# Opt-in as the allocator: modules/config/libumem.nix (programs.libumem.enable)
# — a login-scoped LD_PRELOAD of libumem_malloc.so.1.
{ lib, stdenv, fetchFromGitea, autoconf, automake, libtool, pkg-config }:

stdenv.mkDerivation (finalAttrs: {
  pname = "libumem";
  version = "2.4.0";

  src = fetchFromGitea {
    domain = "codeberg.org";
    owner = "gregburd";
    repo = "libumem";
    rev = "376589a67ae860fa4859f8aae58f66def981b029";
    hash = "sha256-wlVGf8j2krhH2SnAMq30EQh8ZcpXsmtXXE3fWBfB3AU=";
  };

  # autogen.sh runs `autoreconf -f -i -s`; run it via the standard tools rather
  # than the shell wrapper so the store autoconf/automake/libtool are used.
  nativeBuildInputs = [ autoconf automake libtool pkg-config ];

  # No runtime deps beyond libc/libpthread/libm — all libc-family on illumos.
  # -lsocket/-lnsl (the umemctl unix-domain control channel) are wired by the
  # upstream configure (AC_SEARCH_LIBS -> SOLARIS_SOCKET_LIBS), not by us.
  # numa/rseq auto-detect OFF (no libnuma, no linux/rseq.h). percpu-caching and
  # introspection stay default-off (percpu is marked experimental upstream); a
  # consumer wanting the per-CPU magazines rebuilds with the flag below.
  preConfigure = ''
    ./autogen.sh
  '';

  # Platform detection is automatic (config.guess -> *-solaris2.11 -> SOLARIS_BUILD,
  # which wires x86_subr_compat.c for getfp/_breakpoint and the socket libs).
  # __EXTENSIONS__ so the illumos headers expose the POSIX/SUS symbols umem uses.
  configureFlags = [ ];
  env.NIX_CFLAGS_COMPILE = "-D__EXTENSIONS__";

  enableParallelBuilding = true;

  # Prove it's a real allocator BEFORE install: the interposer must export the
  # malloc family, LD_PRELOAD of it must run a malloc-heavy program, and
  # UMEM_DEBUG must catch a heap-corruption (buffer overrun past the redzone).
  #
  # Two 2.4.0 interposer behavior notes the checks below encode:
  #  * KNOWN 2.4.0 DEFECT (upstream, not packaging): the malloc interposer's
  #    calloc() uses a process-global (non-thread-local) `in_calloc` re-entrancy
  #    guard backed by a 2 KiB static buffer for the pthread-TLS bootstrap. A
  #    calloc() whose malloc() re-enters calloc for a size > 2 KiB is served from
  #    (or overflows) that 2 KiB buffer and returns NULL. Net effect:
  #    calloc(n, sz) with n*sz greater than ~2 KiB returns NULL under the
  #    interposer, while malloc() of the same size works. This is a real
  #    allocator bug and a strong reason the preload stays a 64-bit-only,
  #    login-scoped OPT-IN (a system-wide global preload would break programs
  #    that calloc large arrays). Fix is upstream in malloc_interpose.c.
  #  * The interposer sets `umem_abort = 0` in its constructor (glibc-like: log,
  #    do not crash on an invalid/double free under LD_PRELOAD). So a plain
  #    double-free is tolerated by design; UMEM_DEBUG corruption detection
  #    (redzone overrun) still faults. The check tests the overrun, not a
  #    double-free (which no longer aborts, unlike 2.2.0).
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    mal=.libs/libumem_malloc.so
    core=.libs/libumem.so
    [ -f "$mal" ] || { echo "FATAL: $mal not built" >&2; exit 1; }
    [ -f "$core" ] || { echo "FATAL: $core not built" >&2; exit 1; }

    echo "=== exports check: malloc/free/calloc/realloc DEFINED in libumem_malloc.so ===" >&2
    syms=$(/usr/bin/nm -D "$mal" 2>/dev/null || /usr/gnu/bin/nm -D "$mal" 2>/dev/null || /usr/bin/nm "$mal")
    for s in malloc free calloc realloc; do
      echo "$syms" | grep -Eq "[[:space:]]T[[:space:]]+$s\b|\b$s\$" \
        || { echo "FATAL: libumem_malloc.so does not export $s" >&2; exit 1; }
      echo "  exports $s" >&2
    done

    echo "=== LD_PRELOAD smoke test: a malloc/realloc/free-heavy program runs ===" >&2
    cat > umem_preload_check.c <<'EOF'
    #include <stdlib.h>
    #include <string.h>
    #include <stdio.h>
    int main(void) {
        for (int i = 0; i < 20000; i++) {
            size_t n = (i % 4096) + 1;
            char *p = malloc(n);
            if (!p) return 2;
            memset(p, 0xAB, n);
            char *q = realloc(p, n * 2);
            if (!q) return 3;
            free(q);
        }
        /* calloc up to the interposer's small threshold works and zeroes. */
        char *z = calloc(1, 2048);
        if (!z || z[2047] != 0) return 4;
        free(z);
        printf("umem preload OK: 20000 malloc/realloc/free + small calloc\n");
        return 0;
    }
    EOF
    $CC -O2 umem_preload_check.c -o umem_preload_check
    LD_PRELOAD="$PWD/$mal" ./umem_preload_check || { echo "FATAL: LD_PRELOAD run failed" >&2; exit 1; }

    echo "=== documents the known 2.4.0 large-calloc defect (upstream) ===" >&2
    cat > umem_calloc_defect.c <<'EOF'
    #include <stdlib.h>
    int main(void) { return calloc(1, 65536) != 0; }  /* 0 == confirmed NULL */
    EOF
    $CC -O2 umem_calloc_defect.c -o umem_calloc_defect
    set +e
    LD_PRELOAD="$PWD/$mal" ./umem_calloc_defect; cr=$?
    set -e
    if [ "$cr" = 0 ]; then
      echo "  confirmed: calloc(1,64KiB) returns NULL under the interposer (known upstream bug)" >&2
    else
      echo "  NOTE: large calloc now succeeds -- upstream may have fixed the in_calloc guard" >&2
    fi

    echo "=== UMEM_DEBUG catches a heap-buffer-overrun (redzone; the debug value) ===" >&2
    cat > umem_overrun.c <<'EOF'
    #include <stdlib.h>
    #include <string.h>
    int main(void) {
        char *p = malloc(16);
        memset(p, 0x41, 64);  /* deliberate 48-byte overrun past the redzone */
        free(p);              /* UMEM_DEBUG verify catches the clobbered redzone */
        return 0;
    }
    EOF
    $CC -O0 umem_overrun.c -o umem_overrun
    # UMEM_DEBUG=default arms audit/redzone/verify; UMEM_ABORT=1 restores the
    # crash-on-corruption the interposer otherwise suppresses. The overrun must
    # NOT exit 0: libumem detects the clobbered redzone and faults.
    set +e
    UMEM_ABORT=1 UMEM_DEBUG=default LD_PRELOAD="$PWD/$mal" ./umem_overrun >dbg.out 2>&1
    rc=$?
    set -e
    if [ "$rc" = 0 ]; then
      echo "FATAL: UMEM_DEBUG did NOT catch the buffer overrun (exit 0)" >&2
      cat dbg.out >&2; exit 1
    fi
    echo "UMEM_DEBUG caught the overrun (exit $rc, not 0):" >&2
    head -5 dbg.out >&2
    runHook postCheck
  '';

  meta = with lib; {
    description = "libumem — modernized Solaris/illumos userspace slab allocator (per-CPU magazines, UMEM_DEBUG, mdb-class introspection)";
    homepage = "https://codeberg.org/gregburd/libumem";
    license = licenses.cddl; # OpenSolaris/illumos CDDL
    platforms = platforms.illumos or [ "x86_64-solaris" ];
  };
})
