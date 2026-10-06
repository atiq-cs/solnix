# pkgs.illumos.gate — the illumos-gate proto area, BUILT from pinned source
# inside a Nix derivation on illumos.
#
# GATE A of docs/design-gate-derivation.md §1, the real BUILD variant. This
# replaces the previous PROTO-INGEST (which imported an already-built
# /code/illumos-gate/proto/root_i386 via builtins.path). The ingest proved the
# proto-as-store-path model but left the kernel and core userland outside Nix.
# docs/image-nixification-gap.md measured the consequence: an installer image of
# 1,368 hand-copied ELF binaries with /nix EMPTY, because `df`, `useradd`,
# `zpool`, `svcadm` and the kernel were not derivations. They become derivations
# here, which is what makes `storeContents = [ toplevel ]` reachable at all.
#
# WHAT THIS RUNS: the recipe scripts/oi-gate-build.sh proved green —
#   usr/src/tools/env/illumos.sh -> solnix.sh, EMPTY the gcc-14 shadow compilers,
#   unset ON_CLOSED_BINS, PERL_VERSION=5.42 / PERL_VARIANT=-thread-multi,
#   MAKE=<gate>/wrapmake (dmake -m serial), then `nightly solnix.sh || true`.
# Serial, so hours rather than minutes — one-time, then cached.
#
# WHY `|| true` IS CORRECT, AND WHY THE ASSERTIONS ARE THEREFORE MANDATORY:
# nightly EXITS NON-ZERO WHILE STILL PRODUCING A GOOD KERNEL. Measured: without
# /usr/ast/bin/msgcc every libast `.mso` target dies Error 127 and the CHECK
# phase fails, while uts/ has ALREADY staged a working unix + genunix into the
# proto. The exit code is therefore not a verdict on the proto. This derivation
# INSPECTS THE PROTO instead: unix, genunix and libc must exist AND be
# ELFCLASS64/EM_AMD64, and usr/include must exist, or the build FAILS.
# That assertion has a runnable negative control — scripts/gatefod-assert-proto.sh
# holds the identical logic plus a selftest that fabricates empty / partial /
# wrong-arch / zero-byte-stub protos and requires each to be REJECTED (and a
# complete one to be ACCEPTED, so it cannot "pass" by rejecting everything).
#
# FOD (fixed-output) vs plain derivation — see docs/gate-fod-findings.md.
# An outputHash is only meaningful if the output is byte-reproducible, and a WRONG
# outputHash is worse than none: it fails at DOWNLOAD time with a confusing hash
# mismatch instead of failing loudly at build time. So outputHash is OPT-IN here
# (default null -> a plain derivation, content-addressed by its own NAR as usual).
# Set it only from a measured two-build comparison. The gate embeds build
# timestamps, the build host's name and $SRC paths (design §6 risk #2), so the
# honest default is the non-FOD form.
#
# Build inputs are HOST-IMPURE by design for Phase 1 (design §1.3): /opt/onbld
# (nightly, dmake, ctfconvert/ctfmerge), the primary gcc and the JDK come from the
# host, which is legal under sandbox=false. The builder ASSERTS each exists and
# NEVER installs anything (a derivation must not mutate the host). Host prep is
# scripts/oi-build-host-setup.sh; the non-obvious prereqs are listed below.

{ # Pinned source. `srcDir` = a local checkout, imported with builtins.path so the
  # store path IS the pin (content-addressed by NAR hash). `rev` + `srcHash` =
  # fetch the tarball instead (the standalone analog of fetchFromGitHub; this
  # expression uses plain `derivation`, not nixpkgs stdenv, to match the rest of
  # pkgs/illumos and to iterate against the host's Nix directly).
  rev ? "ac45d71fc2b04a5422e72a14b54dd1e746e7be07"
, srcHash ? null          # sha256 of the source tarball. null => srcDir required,
                          # since an unpinned network fetch is not reproducible.
, srcDir ? null           # local illumos-gate checkout to build from

  # protoUrl/protoHash — a PREBUILT proto, fetched by pinned hash. This is the
  # only variant reachable from a PURE evaluation (`nix eval .#...`), which is
  # what an installer front-end runs. Measured, not assumed:
  #   * builtins.getEnv returns "" in pure mode, so SOLNIX_GATE_PROTO is INERT
  #     there -- it works only under --impure or on the host eval path;
  #   * builtins.storePath is a hard error in pure mode ("not allowed in pure
  #     evaluation mode"), so falling through to a published store path does NOT
  #     help a pure eval either, even once that path substitutes;
  #   * builtins.fetchTarball WITH a sha256 IS pure-legal.
  # So a hash-pinned fetch of the already-built proto is the pure-eval path. It
  # differs from srcHash below in WHAT it fetches: srcHash fetches SOURCE and
  # then runs a ~2h nightly build, whereas this fetches the BUILT proto and runs
  # no build at all.
, protoUrl ? "https://s3.solnix.io/solnix-cache/proto/x86_64-gate-ac45d71fc2-20260914/proto-root_i386-gate-ac45d71fc2.tar.gz"
, protoHash ? "0f0jr9xlrc1a0xkpn4fqc4xsl9l2fhqmpxkwyl7pqf6yfvr3zn8x"
, onbld ? "/opt/onbld"
, gcc ? "/usr/gcc/10"     # primary compiler (the gate's own default at this rev)
, javac ? "/usr/java/bin/javac"
, perlVersion ? "5.42"    # gate default is 5.10.0; OI Hipster ships 5.42
, perlVariant ? "-thread-multi"
, outputHash ? null       # set ONLY from a measured reproducible build; see above
, keepLog ? true          # copy the nightly logs to $out/.nightly-log; they are
                          # small next to a ~1 GB proto and every failure so far
                          # was diagnosed from them
, buildRoot ? "/var/tmp"  # where the writable build copy lives. NOT /tmp: illumos
                          # /tmp is tmpfs (RAM) and the tree grows tens of GB.
}:

# THE ASSERTION STAYS, and it still throws rather than yielding a silently empty
# world -- it has just moved down one rung. protoUrl+protoHash is a THIRD way to
# have a gate, so it joins the disjunction; with all three absent this fails
# exactly as before, at eval time, naming the cause.
assert srcDir != null || srcHash != null || (protoUrl != null && protoHash != null);

let
  src =
    if srcDir != null
    then builtins.path { path = srcDir; name = "illumos-gate-${builtins.substring 0 10 rev}"; }
    else builtins.fetchTarball {
      url = "https://github.com/illumos/illumos-gate/archive/${rev}.tar.gz";
      sha256 = srcHash;
    };

  # Host tools the build needs, and what breaks without each. Every one of these
  # was found by a build FAILING, not by reading documentation.
  hostPrereqs = [
    { path = "${onbld}/bin/nightly";         why = "the build driver itself"; }
    { path = "${onbld}/bin/i386/dmake";      why = "MAKE=wrapmake execs it with -m serial"; }
    { path = "${onbld}/bin/i386/ctfconvert"; why = "CTF for the kernel objects (mdb/dtrace)"; }
    { path = "${onbld}/bin/i386/ctfmerge";   why = "CTF merge into genunix"; }
    { path = "${gcc}/bin/gcc";               why = "primary compiler"; }
    { path = javac;                           why = "gate build tools (nightly probes this exact path)"; }
  ];

  # Soft prereqs: absent ones do not stop the kernel from building, but they DO
  # make nightly report FAILED — exactly the trap the proto assertions exist for.
  # Warn loudly so the log names which one was missing.
  softPrereqs = [
    { path = "/usr/ast/bin/msgcc";     why = "libast .mso targets; absent => Error 127 storm + CHECK FAILED, kernel still fine"; }
    { path = "/usr/bin/makeinfo";      why = "texinfo doc targets"; }
    { path = "/usr/include/idn/api.h"; why = "libc iconv/idnkit headers"; }
    { path = "/usr/bin/git";           why = "some gate tools probe it for version stamps"; }
  ];

  prereqCheck = pfx: fatal: ps:
    builtins.concatStringsSep "\n" (map (p: ''
      if [ ! -e "${p.path}" ]; then
        echo "${pfx}: missing ${p.path} -- ${p.why}" >&2
        ${if fatal then ''exit 1'' else ":"}
      fi
    '') ps);
  # PREBUILT path: fetch the already-built proto by pinned hash. No build runs,
  # and this is the branch a pure eval takes.
  # name: fetchTarball's default store name is "source", which gives the same
  # bytes a different store path from the host's `nix store add-path` copy
  # (...-illumos-gate-proto). MEASURED: identical NAR hash
  # (sha256-Hdk/8nbe..., 679,840,760 B) at /nix/store/swgg9jyp...-source on the
  # dev box and /nix/store/wn8w5j1p...-illumos-gate-proto on bhost, so EVERY
  # derivation hash differed between a flake eval and a host build, and a
  # `--flake` install would rebuild the whole chain (gcc included) instead of
  # reusing it. Naming it makes both evaluations agree.
  prebuiltProto = builtins.fetchTarball { url = protoUrl; sha256 = protoHash; name = "illumos-gate-proto"; };
in
# Prefer a real BUILD when the caller pinned source (srcDir/srcHash); otherwise
# use the hash-pinned prebuilt proto. The assertion above guarantees at least one
# of the three exists, so there is no silent-empty-world branch here.
if srcDir == null && srcHash == null then prebuiltProto else
derivation ({
  name = "illumos-gate-proto";
  system = builtins.currentSystem; # x86_64-solaris; BUILDS only on illumos.
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin:/sbin";

  inherit src rev onbld gcc javac perlVersion perlVariant buildRoot;
  keepLog = if keepLog then "1" else "";

  args = [ "-c" ''
    set -eu

    # NIX'S BUILDER HAS NO LOGNAME/USER, AND THE GATE REQUIRES THEM.
    # Measured on this host, not assumed: a probe derivation's `env` prints exactly
    # HOME=/homeless-shelter, NIX_BUILD_CORES, NIX_BUILD_TOP, NIX_LOG_FD, NIX_STORE,
    # PATH, PWD, SHLVL, TEMP*, TERM, TMP*, builder, name, out, system -- no LOGNAME
    # and no USER. usr/src/tools/env/illumos.sh does `export STAFFER="$LOGNAME"`, and
    # nightly's staffer() runs `eval su $STAFFER -c '...'` whenever it is root
    # (ISUSER -eq 0). With STAFFER empty that expands to `su -c <cmd>`, where illumos
    # su reads -c as the USERNAME and prints "Usage: su [-] [ username [ arg ... ] ]";
    # nightly then dies before it ever creates proto/. THIS IS THE FIRST REAL
    # NIX-VS-NIGHTLY INCOMPATIBILITY, and it is a missing environment variable -- not
    # a sandbox restriction and not the absent SYS_spawn. Setting LOGNAME/USER fixes
    # it: staffer() becomes a well-formed `su root -c`.
    export LOGNAME="''${LOGNAME:-root}"
    export USER="''${USER:-$LOGNAME}"

    echo "=== host prereqs (impure by design, Phase 1; design §1.3) ==="
    ${prereqCheck "FATAL" true hostPrereqs}
    ${prereqCheck "WARN" false softPrereqs}

    # The gate build WRITES into its source tree (proto/, log/, objects), so the
    # read-only store src must be copied out first.
    # ⚠️ THE BUILD PATH MUST BE FIXED, NOT RANDOM. This was `mktemp -d
    # "$buildRoot/gate-build.XXXXXX"`, and the measured cost was the single largest
    # source of irreproducibility: 125 of 152 differing files in the two-build
    # comparison differed ONLY because the random directory name is embedded in their
    # DWARF/comment sections. Verified by dumping the bytes -- run A carried
    # "/var/tmp/gate-build.VPWgKb/illumos-gate/usr/src/common/avl/..." where run B
    # carried "/var/tmp/gate-build.mPafJD/...", same length, same everything else.
    # A fixed path makes those 125 files reproducible for free. It also means two
    # concurrent builds on one host would collide, which is why the lock is explicit.
    GATE="$buildRoot/solnix-gate-build/illumos-gate"
    WORK="$buildRoot/solnix-gate-build"
    if [ -e "$WORK/.lock" ]; then
      echo "FATAL: $WORK/.lock exists -- another gate build is using the fixed build" >&2
      echo "       path. Wait for it, or remove the lock if it is stale." >&2
      exit 1
    fi
    # A previous run's tree would make this build incremental (and its staleness has
    # caused bogus link failures before), so start clean. find -delete, never a
    # recursive force remove.
    if [ -d "$WORK" ]; then
      find "$WORK" -mindepth 1 -delete 2>/dev/null || true
    fi
    mkdir -p "$WORK"
    : > "$WORK/.lock"
    # HOME=/homeless-shelter does not exist, and gate build tools write dot-files
    # into $HOME. Point it at a real writable dir inside the build tree (fixed path,
    # so it cannot leak a random name into anything either).
    export HOME="$WORK/home"
    mkdir -p "$GATE" "$HOME"
    echo "=== copy pinned source -> $GATE ==="
    cp -a "$src/." "$GATE/"
    chmod -R u+w "$GATE"
    cd "$GATE"

    echo "=== env file: solnix.sh (the oi-gate-build.sh recipe) ==="
    cp usr/src/tools/env/illumos.sh solnix.sh
    # gcc-14 shadow compilers are not installed; an EMPTY shadow is fine, a
    # missing one is a hard failure.
    sed -i '/^export SHADOW_CCS=gcc14/d; /^export SHADOW_CCCS=gcc14/d' solnix.sh
    printf 'export SHADOW_CCS=\nexport SHADOW_CCCS=\n' >> solnix.sh
    # fully-open gate: nightly errors if ON_CLOSED_BINS is set but the dir is absent.
    sed -i '/^export ON_CLOSED_BINS=/d' solnix.sh
    echo 'unset ON_CLOSED_BINS' >> solnix.sh
    # without this, every cmd/perl/contrib module dies
    # "/usr/perl5/5.10.0/bin/.../perl: not found" and packaging silently skips.
    printf 'export PERL_VERSION=%s\nexport PERL_VARIANT=%s\n' "$perlVersion" "$perlVariant" >> solnix.sh
    # nightly hardcodes DMAKE_MODE=parallel, under which libc's target-specific
    # conditional CPPFLAGS leak between object variants that share a source file
    # (-D_C89_INTMAX32, meant for vsprintf_c89.o, lands on pics/vsprintf.o) and
    # libc.so.1 fails to link with `_sprintf_c89 multiply-defined`. DMAKE_MAX_JOBS=1
    # is NOT enough -- it only limits jobs inside the parallel engine. Pointing
    # $MAKE at a wrapper running `dmake -m serial` disables that engine for every
    # recursive make.
    cat > "$GATE/wrapmake" <<WRAP
    #!/bin/sh
    exec $onbld/bin/i386/dmake -m serial "\$@"
    WRAP
    chmod +x "$GATE/wrapmake"
    echo "export MAKE=$GATE/wrapmake" >> solnix.sh
    # nightly writes proto/ and log/ under CODEMGR_WS. The template derives it from
    # `git rev-parse --show-toplevel`, which cannot work here (the store copy carries
    # no .git), so pin it at our writable copy.
    sed -i "s,^export CODEMGR_WS=.*,export CODEMGR_WS=\"$GATE\"," solnix.sh
    # STAFFER defaults to $LOGNAME (absent under Nix, see the top of this builder).
    # Pin it explicitly so `su $STAFFER -c` stays well-formed regardless, and point
    # MAILTO at the same name -- the sendmail notification cannot work on this image
    # ("mailwrapper: cannot exec /usr/lib/smtp/sendmail/sendmail") but that is
    # cosmetic, affecting only the completion mail.
    printf 'export STAFFER=%s\nexport MAILTO=%s\n' "$LOGNAME" "$LOGNAME" >> solnix.sh
    # VERSION: nightly does `git -C $CODEMGR_WS describe --long --all --dirty` and
    # fatal_error "Error: VERSION not set" if that comes back empty. It DOES come back
    # empty here, and the reason is not a missing .git -- measured: the build copy has
    # one. `git describe` only considers refs that are ANCESTORS of HEAD, and a pinned
    # historical rev has none (refs/heads/master is a DESCENDANT), so it prints
    # "fatal: No tags can describe 'ac45d71...'". Pinning VERSION explicitly fixes it
    # and is strictly BETTER for reproducibility than letting git derive it: a
    # describe-derived version carries --dirty state and whatever refs the local clone
    # happens to have, which is per-machine. This string lands in `uname -v`.
    printf 'export VERSION=solnix-%s\n' "$(echo "$rev" | cut -c1-12)" >> solnix.sh
    # No `git clean`: the store src is pristine by construction (that is what
    # pinning it buys), so the interrupted-run reset the imperative script needs
    # is moot here.

    echo "=== nightly. Its EXIT CODE IS NOT THE VERDICT -- see the header. ==="
    "$onbld/bin/nightly" solnix.sh \
      || echo "nightly exited non-zero (expected; the proto assertions decide)"

    PROTO="$GATE/proto/root_i386"
    echo "=== assert the proto is REAL (negative control: scripts/gatefod-assert-proto.sh selftest) ==="
    [ -d "$PROTO" ] || { echo "FATAL: no proto dir at $PROTO -- the build produced nothing" >&2; exit 1; }

    # POSIX-only ELF check: illumos has no stat(1) (not even gstat) and no
    # readlink(1), and both have SILENTLY broken checks in this project before (a
    # `stat -c %s` gate that was always false; a `$(readlink)` that expanded empty
    # so `ln -sf ""` no-oped and a ramdisk shipped 0 of 13 /dev nodes). od(1) and
    # wc(1) ship on every illumos.
    # ELFCLASS64 = e_ident[EI_CLASS] (offset 4) == 2; EM_AMD64 = e_machine (18) == 62.
    # The numbers are compared with -eq, NOT with `=`: illumos od ZERO-PADS numeric
    # output and GNU od does not, so the same byte reads "2" under GNU od and "002"
    # under illumos od (e_machine: "62" vs "00062"). A string compare passed on Linux
    # and FAILED on illumos, which is where this actually runs. Arithmetic comparison
    # is padding-agnostic.
    elf64_amd64() {
      [ -f "$1" ] || return 1
      magic=$(od -An -tx1 -N4 "$1" | tr -d ' \n')
      [ "$magic" = "7f454c46" ] || return 1
      cls=$(od -An -tu1 -j4 -N1 "$1" | tr -d ' \n')
      [ "$cls" -eq 2 ] 2>/dev/null || return 1
      mach=$(od -An -tu2 -j18 -N2 "$1" | tr -d ' \n')
      [ "$mach" -eq 62 ] 2>/dev/null || return 1
      return 0
    }

    fail=0
    check_elf() {  # $1 = proto-relative path, $2 = what it is
      f="$PROTO/$1"
      if [ ! -f "$f" ]; then
        echo "FATAL: proto missing $1 ($2)" >&2; fail=1; return
      fi
      if elf64_amd64 "$f"; then
        echo "OK   $1 -- ELFCLASS64/EM_AMD64 ($(wc -c < "$f" | tr -d ' ') bytes)"
      else
        echo "FATAL: $1 is not ELFCLASS64/EM_AMD64 ($2)" >&2; fail=1
      fi
    }
    check_elf platform/i86pc/kernel/amd64/unix "the kernel"
    check_elf kernel/amd64/genunix            "the generic kernel module"
    check_elf lib/amd64/libc.so.1             "libc"
    [ -d "$PROTO/usr/include" ] || { echo "FATAL: proto has no usr/include (headers)" >&2; fail=1; }
    [ "$fail" = 0 ] || { echo "FATAL: proto assertions FAILED -- refusing to install a broken proto" >&2; exit 1; }

    echo "=== install: proto -> \$out ==="
    mkdir -p "$out"
    # cp -a preserves symlinks (usr/lib/amd64/*.so -> ../../../lib/amd64/*.so.N),
    # perms, and -- critically -- the CTF sections in the kernel objects. No strip
    # and no fixup: this is illumos ELF and Linux ELF fixup would corrupt it.
    cp -a "$PROTO/." "$out/"

    if [ -n "$keepLog" ] && [ -d "$GATE/log" ]; then
      mkdir -p "$out/.nightly-log"
      # log/latest is a symlink into log/<date>; -L copies the real contents.
      cp -aL "$GATE/log/latest/." "$out/.nightly-log/" 2>/dev/null || true
      # the build's own mail spool is pure noise and embeds the hostname.
      rm -f "$out/.nightly-log/mail_msg" 2>/dev/null || true
    fi

    echo "=== gate proto installed: $(find "$out" -type f | wc -l | tr -d ' ') files ==="

    # Reclaim the build tree and release the lock. The tree is tens of GB and
    # $buildRoot is a real filesystem, so leaving it behind fills the disk after a few
    # builds (and the determinism measurement deliberately builds twice). find -delete,
    # never a recursive force remove. Only on SUCCESS: a failed build's tree is the
    # evidence, and its .lock deliberately stays so the failure is noticed.
    find "$WORK" -mindepth 1 -delete 2>/dev/null || true
    rmdir "$WORK" 2>/dev/null || true
  '' ];
}
// (if outputHash == null then { } else {
  # FOD form, reachable only when a caller passes a hash it MEASURED.
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  inherit outputHash;
}))
