# pkgs.solnix.iwm-driver -- the Intel AC 7260..9560 wireless driver (OpenBSD
# iwm(4) + OpenBSD net80211 + the illumos glue) built as a PURE Nix derivation,
# plus the wpa-pmk userland PMK deriver. The declarative replacement for the
# hand-run src/ports/wifi/iwm/build-dixi.sh.
#
# WHY A DERIVATION. build-dixi.sh ships the tree to dixi, generates the patched
# sources with python3/patch on floki first (dixi has neither), gmake's it, and
# checks symbols against the RUNNING kernel. None of that is reproducible: the
# toolchain path and the proto headers were hand-pinned, and the "generate on
# floki, build on dixi" split means the inputs are not captured. This derivation
# captures them: the vendored tree (builtins.path), the gate proto headers, the
# solnix-dev toolchain and the gate ld are all store-path inputs, so the output
# is content-addressed by its NAR given those pins.
#
# SOURCE GENERATION WITHOUT python3/patch. build-dixi.sh runs gen-illumos-src.py
# (needs python3) and net80211/gen-illumos-src.sh (needs patch); dixi has NO
# python3 and NO patch. But dixi HAS git, and the committed .patch files are
# plain unified diffs, so `git apply` regenerates build/*.c byte-for-byte
# identically to the python/patch output (verified: iwm 1/1 + net80211 10/10
# "MATCHES"). The builder therefore applies the committed patches with git apply
# -- no python3, no GNU patch, self-contained on any illumos host with git.
#
#   iwm   patch: a/if_iwm.c      -> build/if_iwm_illumos.c   (git apply -p1)
#   n80   patch: orig/<f>.c      -> build/<f>.c              (git apply -p1, x10)
#   iwx   gen is NOT needed: build-dixi.sh runs only the iwm + net80211 gens.
#
# GATE (scripts/check-compat-local.sh logic + the unresolved check, inlined so
# the build is self-contained, exactly as build-dixi.sh inlines them): the build
# FAILS if the linked module has any unresolved symbol against the reference
# kernel OR exports any non-interface global (a compat global that escaped
# iwm.mapfile -- krtld would cross-wire it against i915). This is the brief's
# "fail if unresolved!=0 or non-interface globals!=0".
#
# OUTPUT:
#   $out/kernel/drv/amd64/iwm   the loadable kernel module (install-be lays this
#                               into the BE kernel tree when attachAtBoot)
#   $out/usr/lib/inet/wpa-pmk   the WPA2 PMK deriver the solnix-wifi-join SMF
#                               service calls (ESSID-only, PATH=/usr/lib/inet:...)
#
# NOTE: the symbol-resolution reference is the GATE PROTO kernel (unix + genunix
# + misc/mac), which is already a build input (headers come from it) so the gate
# is reproducible. The proto is a DEBUG kernel and so exports a SUPERSET of the
# shipped non-DEBUG kernel's globals; the module's undefined set (127 symbols per
# STATUS.md) resolving against it is necessary but, for the few DEBUG-only
# helpers, not sufficient on its own -- the dixi proof additionally compares
# against the running non-DEBUG kernel (STATUS.md rung 5, 0 unresolved there).

{ gate                       # the gate proto (usr/include headers + reference kernel)
, solnixDev                  # pkgs.solnix.solnix-dev: gcc 14.3.0 + gas + gmake on PATH
, ld                         # pkgs.solnix.ld: the gate link-editor slice (usr/bin/ld)
, system ? "x86_64-solaris"
  # The vendored driver tree. The whole src/ports/wifi is needed: the iwm
  # Makefile references ../net80211 and ../iwx. builtins.path captures the
  # tracked sources (upstream/, patches/, compat/, Makefile.illumos, mapfile);
  # the gitignored build/ and obj/ are regenerated/produced in the builder.
, wifiSrc ? builtins.path {
    path = ../../src/ports/wifi;
    name = "solnix-wifi-src";
    # exclude the gitignored generated/output dirs so the input hash does not
    # depend on a stale working-tree build/ (regenerated deterministically here).
    # Match by RELATIVE path, not basename: the driver's source dir is also named
    # "iwm", and the built module is the file "iwm/iwm" -- a basename filter would
    # delete the whole iwm/ source tree.
    filter = path: type:
      let b = baseNameOf path;
      in !((type == "directory" && (b == "build" || b == "obj"))
           || (type == "regular" && b == "iwm"));
  }
}:

derivation {
  name = "iwm-driver";
  inherit system gate solnixDev ld wifiSrc;
  builder = "/usr/bin/bash";
  # git for `git apply` (source gen); the rest of the toolchain is prepended below.
  PATH = "/usr/bin:/usr/sbin:/usr/gnu/bin";

  args = [ "-c" ''
    set -eu
    export PATH="$solnixDev/bin:$ld/usr/bin:$ld/bin:/usr/bin:/usr/sbin:/usr/gnu/bin"
    UTSINC="$gate/usr/include"
    [ -d "$UTSINC/sys" ] || { echo "FATAL: gate proto has no usr/include/sys" >&2; exit 1; }
    command -v git >/dev/null  || { echo "FATAL: no git for source generation" >&2; exit 1; }
    command -v gcc >/dev/null  || { echo "FATAL: no gcc (solnix-dev not on PATH)" >&2; exit 1; }
    command -v gmake >/dev/null || { echo "FATAL: no gmake" >&2; exit 1; }

    # the gate link-editor: the ld slice puts it at usr/bin/ld; some gate ld
    # layouts use bin/ld. Probe both, fall back to the host /usr/bin/ld (which on
    # a solnix host is itself a store link into the gate userland).
    LDBIN="$ld/usr/bin/ld"
    [ -x "$LDBIN" ] || LDBIN="$ld/bin/ld"
    [ -x "$LDBIN" ] || LDBIN=/usr/bin/ld
    [ -x "$LDBIN" ] || { echo "FATAL: no ld found under $ld or /usr/bin" >&2; exit 1; }

    WORK=$(mktemp -d /tmp/iwm-driver.XXXXXX)
    cp -r "$wifiSrc" "$WORK/wifi"
    chmod -R u+w "$WORK/wifi"
    cd "$WORK/wifi"

    # --- regenerate the patched sources with git apply (replaces gen-*.sh) -----
    # git apply works outside a repo; -p1 strips the a//orig/ prefix. Each output
    # is asserted non-identical to its input, the same no-op-patch guard the gen
    # scripts carry (a .patch with no hunks silently ships unpatched source).
    #
    # iwm: a/if_iwm.c -> build/if_iwm_illumos.c. git apply -p1 writes if_iwm.c in
    # the target dir, so apply into a temp named dir then rename to the output.
    mkdir -p iwm/build
    cp iwm/upstream/if_iwm.c iwm/build/if_iwm.c
    ( cd iwm/build && git apply -p1 ../patches/if_iwm.illumos.patch 2>/tmp/iwm-apply.err ) \
      || { echo "FATAL: git apply if_iwm.illumos.patch failed" >&2; cat /tmp/iwm-apply.err >&2; exit 1; }
    mv iwm/build/if_iwm.c iwm/build/if_iwm_illumos.c
    cmp -s iwm/upstream/if_iwm.c iwm/build/if_iwm_illumos.c \
      && { echo "FATAL: if_iwm patch applied as a no-op" >&2; exit 1; }
    echo "gen: iwm/build/if_iwm_illumos.c ($(wc -l < iwm/build/if_iwm_illumos.c) lines)" >&2

    # net80211: orig/<f>.c -> build/<f>.c for each patched file. The Makefile
    # prefers $(N)/build/$*.c when present; without these it would compile the
    # UNPATCHED orig/, so this is load-bearing, not cosmetic.
    mkdir -p net80211/build
    for f in ieee80211_node ieee80211_crypto ieee80211_input ieee80211_output \
             ieee80211_crypto_wep ieee80211_crypto_tkip ieee80211_crypto_ccmp \
             ieee80211_crypto_bip ieee80211_pae_input ieee80211_pae_output; do
      cp "net80211/orig/$f.c" "net80211/build/$f.c"
      ( cd net80211/build && git apply -p1 "../patches/$f.illumos.patch" 2>/tmp/iwm-apply.err ) \
        || { echo "FATAL: git apply net80211/$f failed" >&2; cat /tmp/iwm-apply.err >&2; exit 1; }
      cmp -s "net80211/orig/$f.c" "net80211/build/$f.c" \
        && { echo "FATAL: net80211/$f patch applied as a no-op" >&2; exit 1; }
    done
    echo "gen: net80211/build (10 patched sources)" >&2

    # --- build the module (Makefile.illumos; same flags as build-dixi.sh) ------
    cd iwm
    gmake -f Makefile.illumos clean >/dev/null 2>&1 || true
    # -std=gnu17: the gate's sys/systm.h declares `int nodev(); int nulldev();`, which C23 (GCC 15) reads as (void), so
    # every cb_ops initialiser mismatches (gcc1 STDENV-SWITCH.md 2.2). The real fix is prototypes in the gate.
    gmake -f Makefile.illumos -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" \
      UTSINC="$UTSINC" LD="$LDBIN" CC="gcc -std=gnu17" >/tmp/iwm-build.log 2>&1 \
      || { echo "FATAL: iwm build failed" >&2; tail -40 /tmp/iwm-build.log >&2; exit 1; }
    [ -f iwm ] || { echo "FATAL: no iwm module produced" >&2; exit 1; }
    echo "built: iwm ($(ls -l iwm | awk '{print $5}') bytes)" >&2

    # --- GATE: unresolved symbols + non-interface globals (fail closed) --------
    # nm -p prints "value type name"; a global/exported def is upper-case
    # T/D/B/R/C, U is undefined. Use ILLUMOS nm (/usr/bin/nm), NOT gnm: GNU nm's
    # -p produces NO output on these ET_REL kernel objects (measured on dixi),
    # which would make `undefined=0` and the whole gate a check that cannot fail.
    # build-dixi.sh uses plain nm for the same reason.
    NM=/usr/bin/nm
    [ -x "$NM" ] || NM=nm
    U=$gate/platform/i86pc/kernel/amd64/unix
    G=$gate/kernel/amd64/genunix
    M=$gate/kernel/misc/amd64/mac
    for k in "$U" "$G" "$M"; do [ -f "$k" ] || { echo "FATAL: reference kernel $k missing" >&2; exit 1; }; done

    # exported globals of the reference kernel (unix+genunix+misc/mac)
    for k in "$U" "$G" "$M"; do $NM -p "$k"; done \
      | awk '$2 ~ /^[TDBRC]$/ {print $3}' | sort -u > ksyms.txt
    # the module's undefined references, and its exported definitions
    $NM -p iwm | awk '$2=="U"      {print $3}' | sort -u > iwm-undef.txt
    $NM -p iwm | awk '$2 ~ /^[TDBRC]$/ {print $3}' | sort -u > iwm-defined.txt

    # NEGATIVE CONTROL against the false-green class: a kernel module linking the
    # kernel API MUST have undefined references (iwm has ~127). Zero means nm
    # emitted nothing and the unresolved check below is vacuous -- fail loudly.
    nunref=$(grep -c . iwm-undef.txt || true)
    [ "$nunref" -ge 50 ] || { echo "FATAL: only $nunref undefined syms (nm produced too few; check cannot work)" >&2; exit 1; }

    # unresolved = undefined refs the reference kernel does not export.
    comm -23 iwm-undef.txt ksyms.txt > iwm-unresolved.txt
    nunres=$(grep -c . iwm-unresolved.txt || true)
    echo "gate: undefined=$nunref unresolved-vs-gate-proto-kernel=$nunres" >&2
    if [ "$nunres" -ne 0 ]; then
      echo "FATAL: $nunres unresolved symbols (brief: unresolved must be 0):" >&2
      sed 's/^/  /' iwm-unresolved.txt >&2
      exit 1
    fi

    # non-interface exported globals (check-compat-local.sh logic): the only
    # globals a correctly-scoped module exports are _init/_fini/_info
    # (iwm has no _depends_on; it links -N misc/mac). Anything else is a compat
    # global that escaped iwm.mapfile; krtld would cross-wire it against i915.
    grep -v -E '^(_init|_fini|_info|_depends_on)$' iwm-defined.txt > iwm-leaked.txt || true
    nleak=$(grep -c . iwm-leaked.txt || true)
    echo "gate: non-interface exported globals (must be 0)=$nleak" >&2
    if [ "$nleak" -ne 0 ]; then
      echo "FATAL: module exports non-interface globals (brief: must be 0):" >&2
      sed 's/^/  /' iwm-leaked.txt >&2
      exit 1
    fi

    # --- build wpa-pmk (userland; no deps by default, PMK deriver) -------------
    # Plain C, self-contained SHA1/HMAC/PBKDF2; shells out to dladm at run time so
    # it needs no library. Self-test MUST pass (money/crypto path).
    gcc -O2 -o wpa-pmk wpa-pmk.c \
      || { echo "FATAL: wpa-pmk build failed" >&2; exit 1; }
    ./wpa-pmk -t >/dev/null 2>&1 || { echo "FATAL: wpa-pmk self-test (-t) failed" >&2; exit 1; }
    echo "built: wpa-pmk (self-test OK)" >&2

    # --- install --------------------------------------------------------------
    mkdir -p "$out/kernel/drv/amd64" "$out/usr/lib/inet"
    cp iwm "$out/kernel/drv/amd64/iwm"
    cp wpa-pmk "$out/usr/lib/inet/wpa-pmk"
    chmod 0555 "$out/kernel/drv/amd64/iwm" "$out/usr/lib/inet/wpa-pmk"

    # record what was checked, for the ledger / audit
    {
      echo "undefined=$nunref unresolved=$nunres non-interface-globals=$nleak"
      echo "reference-kernel=$gate (DEBUG proto: unix+genunix+misc/mac)"
    } > "$out/.iwm-gate"

    cd /; rm -rf "$WORK" || true
    echo "=== iwm-driver: module + wpa-pmk built, gate green ===" >&2
  '' ];
}
