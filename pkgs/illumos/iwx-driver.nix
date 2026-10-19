# pkgs.solnix.iwx-driver -- the Intel AX2xx wireless driver (OpenBSD iwx(4) +
# OpenBSD net80211 + the illumos glue) built as a pure derivation, under the
# giant-lock model that iwm uses (src/ports/wifi/net80211/n80211_giant.c).
# Modelled on ./iwm-driver.nix; see that file for why it is a derivation and
# why the sources are regenerated with git apply (no python3/patch on hosts).
#
#   iwx  patch: upstream/if_iwx.c    -> build/if_iwx_illumos.c       (git apply -p0)
#        patch: upstream/if_iwxvar.h -> build/dev/pci/if_iwxvar.h    (git apply -p0)
#   n80  patch: orig/<f>.c           -> build/<f>.c                  (git apply -p1, x10)
#
# GATE (fail closed). The build FAILS unless:
#   * unresolved = 0 against the gate proto kernel (unix + genunix + misc/mac),
#   * unresolved = 0 against the solnix kernel-nd kernel (unix + genunix +
#     misc/mac) -- the non-DEBUG kernel the images ship, which exports a SUBSET
#     of the DEBUG proto's globals, so this is the check that matters at load,
#   * the module exports no global except _init/_fini/_info,
#   * the module has no GLOBAL or UNDEFINED iwm_* symbol (the shared iwm layers'
#     public names are renamed at compile time; a leftover would bind into a
#     loaded iwm). File-static iwm_* helpers from iwm_bus.c/iwm_gld.c stay:
#     local symbols are never bound across modules (kobj.c do_symbols).
# Negative controls run in the builder, before the real checks are trusted:
#   * nm must report >= 50 undefined references (else nm produced nothing and
#     every check below is vacuous),
#   * a copy of the module linked with one extra reference to a symbol no
#     kernel defines must come out of the SAME unresolved check with exactly 1.
#
# OUTPUT:
#   $out/kernel/drv/amd64/iwx   the loadable kernel module
#   $out/.iwx-gate              what was checked

{ gate                       # the gate proto (usr/include headers + reference kernel)
, kernelNd                   # pkgs.solnix.kernelNd: the shipped non-DEBUG kernel
, solnixDev                  # gcc 14.3.0 + gas + gmake on PATH
, ld                         # pkgs.solnix.ld: the gate link-editor slice
, system ? "x86_64-solaris"
, wifiSrc ? builtins.path {
    path = ../../src/ports/wifi;
    name = "solnix-wifi-src";
    # Drop generated/output dirs and the two built module files by RELATIVE
    # role, not basename alone: the source dirs are also named iwm/ and iwx/.
    filter = path: type:
      let b = baseNameOf path;
      in !((type == "directory" && (b == "build" || b == "obj"))
           || (type == "regular" && (b == "iwm" || b == "iwx")));
  }
}:

derivation {
  name = "iwx-driver";
  inherit system gate kernelNd solnixDev ld wifiSrc;
  builder = "/usr/bin/bash";
  PATH = "/usr/bin:/usr/sbin:/usr/gnu/bin";

  args = [ "-c" ''
    set -eu
    export PATH="$solnixDev/bin:$ld/usr/bin:$ld/bin:/usr/bin:/usr/sbin:/usr/gnu/bin"
    UTSINC="$gate/usr/include"
    [ -d "$UTSINC/sys" ] || { echo "FATAL: gate proto has no usr/include/sys" >&2; exit 1; }
    for t in git gcc gmake; do
      command -v $t >/dev/null || { echo "FATAL: no $t" >&2; exit 1; }
    done
    LDBIN="$ld/usr/bin/ld"
    [ -x "$LDBIN" ] || LDBIN="$ld/bin/ld"
    [ -x "$LDBIN" ] || LDBIN=/usr/bin/ld
    [ -x "$LDBIN" ] || { echo "FATAL: no ld" >&2; exit 1; }

    WORK=$(mktemp -d /tmp/iwx-driver.XXXXXX)
    cp -r "$wifiSrc" "$WORK/wifi"
    chmod -R u+w "$WORK/wifi"
    cd "$WORK/wifi"

    # --- regenerate the patched sources (each asserted not a no-op) ---------
    mkdir -p iwx/build/dev/pci
    cp iwx/upstream/if_iwx.c iwx/build/if_iwx_illumos.c
    cp iwx/upstream/if_iwxvar.h iwx/build/dev/pci/if_iwxvar.h
    ( cd iwx && git apply -p0 patches/if_iwx.illumos.patch patches/if_iwxvar.illumos.patch ) \
      || { echo "FATAL: git apply iwx patches failed" >&2; exit 1; }
    cmp -s iwx/upstream/if_iwx.c iwx/build/if_iwx_illumos.c \
      && { echo "FATAL: if_iwx patch applied as a no-op" >&2; exit 1; }
    cmp -s iwx/upstream/if_iwxvar.h iwx/build/dev/pci/if_iwxvar.h \
      && { echo "FATAL: if_iwxvar patch applied as a no-op" >&2; exit 1; }
    echo "gen: iwx/build/if_iwx_illumos.c ($(wc -l < iwx/build/if_iwx_illumos.c) lines)" >&2

    mkdir -p net80211/build
    for f in ieee80211_node ieee80211_crypto ieee80211_input ieee80211_output \
             ieee80211_crypto_wep ieee80211_crypto_tkip ieee80211_crypto_ccmp \
             ieee80211_crypto_bip ieee80211_pae_input ieee80211_pae_output; do
      cp "net80211/orig/$f.c" "net80211/build/$f.c"
      ( cd net80211/build && git apply -p1 "../patches/$f.illumos.patch" ) \
        || { echo "FATAL: git apply net80211/$f failed" >&2; exit 1; }
      cmp -s "net80211/orig/$f.c" "net80211/build/$f.c" \
        && { echo "FATAL: net80211/$f patch applied as a no-op" >&2; exit 1; }
    done

    # --- build ----------------------------------------------------------------
    cd iwx
    gmake -f Makefile.illumos -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" \
      UTSINC="$UTSINC" LD="$LDBIN" >/tmp/iwx-build.$$.log 2>&1 \
      || { echo "FATAL: iwx build failed" >&2; grep -m20 -B2 'error' /tmp/iwx-build.$$.log >&2 || tail -40 /tmp/iwx-build.$$.log >&2; exit 1; }
    [ -f iwx ] || { echo "FATAL: no iwx module produced" >&2; exit 1; }
    echo "built: iwx ($(wc -c < iwx) bytes)" >&2

    # --- GATE -----------------------------------------------------------------
    # illumos nm, not gnm: GNU nm -p prints nothing for these ET_REL objects
    # (measured on dixi), which would make every check below vacuous.
    NM=/usr/bin/nm
    [ -x "$NM" ] || NM=nm
    ksyms() {   # exported globals of unix + genunix + misc/mac under $1
      for k in "$1/platform/i86pc/kernel/amd64/unix" "$1/kernel/amd64/genunix" \
               "$1/kernel/misc/amd64/mac"; do
        [ -f "$k" ] || { echo "FATAL: reference kernel $k missing" >&2; exit 1; }
        $NM -p "$k"
      done | awk '$2 ~ /^[TDBRC]$/ {print $3}' | sort -u
    }
    undef() { $NM -p "$1" | awk '$2=="U" {print $3}' | sort -u; }
    unresolved() { comm -23 "$1" "$2" | grep -c . || true; }

    ksyms "$gate" > ksyms-proto.txt
    ksyms "$kernelNd" > ksyms-nd.txt
    undef iwx > iwx-undef.txt
    $NM -p iwx | awk '$2 ~ /^[TDBRC]$/ {print $3}' | sort -u > iwx-defined.txt

    nunref=$(grep -c . iwx-undef.txt || true)
    [ "$nunref" -ge 50 ] || { echo "FATAL: only $nunref undefined syms (nm produced too few; the gate cannot work)" >&2; exit 1; }

    # negative control: one bogus reference must be counted as exactly 1
    printf 'extern int iwx_gate_negctl_nosuch(void);\nint iwx_gate_negctl(void) { return iwx_gate_negctl_nosuch(); }\n' > negctl.c
    gcc -m64 -ffreestanding -nostdinc -c -o negctl.o negctl.c
    "$LDBIN" -r -o iwx-negctl iwx negctl.o
    undef iwx-negctl > negctl-undef.txt
    nneg=$(unresolved negctl-undef.txt ksyms-nd.txt)
    nreal=$(unresolved iwx-undef.txt ksyms-nd.txt)
    [ "$nneg" -eq $((nreal + 1)) ] || { echo "FATAL: negative control: bogus ref gave $nneg unresolved, want $((nreal + 1))" >&2; exit 1; }
    comm -23 negctl-undef.txt ksyms-nd.txt | grep -qx iwx_gate_negctl_nosuch \
      || { echo "FATAL: negative control symbol not reported" >&2; exit 1; }
    echo "gate: negative control LIVE (bogus ref reported, $nneg unresolved)" >&2

    comm -23 iwx-undef.txt ksyms-proto.txt > iwx-unres-proto.txt
    comm -23 iwx-undef.txt ksyms-nd.txt > iwx-unres-nd.txt
    np=$(grep -c . iwx-unres-proto.txt || true)
    nn=$(grep -c . iwx-unres-nd.txt || true)
    echo "gate: undefined=$nunref unresolved-vs-proto=$np unresolved-vs-kernel-nd=$nn" >&2
    if [ "$np" -ne 0 ] || [ "$nn" -ne 0 ]; then
      echo "FATAL: unresolved symbols (must be 0):" >&2
      sed 's/^/  proto: /' iwx-unres-proto.txt >&2
      sed 's/^/  nd:    /' iwx-unres-nd.txt >&2
      exit 1
    fi

    grep -v -E '^(_init|_fini|_info)$' iwx-defined.txt > iwx-leaked.txt || true
    nleak=$(grep -c . iwx-leaked.txt || true)
    echo "gate: non-interface exported globals=$nleak" >&2
    [ "$nleak" -eq 0 ] || { echo "FATAL: exports non-interface globals:" >&2; sed 's/^/  /' iwx-leaked.txt >&2; exit 1; }
    for s in _init _fini _info; do
      grep -qx "$s" iwx-defined.txt || { echo "FATAL: $s not exported" >&2; exit 1; }
    done

    niwm=$($NM -p iwx | awk '$2 ~ /^[TDBRCU]$/ {print $3}' | grep -c '^iwm_' || true)
    [ "$niwm" -eq 0 ] || { echo "FATAL: $niwm global/undefined iwm_* symbols in the iwx module" >&2; $NM -p iwx | awk '$2 ~ /^[TDBRCU]$/ {print $3}' | grep '^iwm_' >&2; exit 1; }

    mkdir -p "$out/kernel/drv/amd64"
    cp iwx "$out/kernel/drv/amd64/iwx"
    chmod 0555 "$out/kernel/drv/amd64/iwx"
    {
      echo "undefined=$nunref unresolved-proto=$np unresolved-kernel-nd=$nn non-interface-globals=$nleak iwm-symbols=$niwm negctl=$nneg"
      echo "reference-kernels=$gate $kernelNd"
    } > "$out/.iwx-gate"
    cd /; rm -rf "$WORK" || true
    echo "=== iwx-driver: module built, gate green ===" >&2
  '' ];
}
