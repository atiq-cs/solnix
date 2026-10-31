# pkgs.solnix.i915-driver -- the Intel integrated-GPU kernel module (OpenBSD
# inteldrm + drm, src/drm-port/i915 + src/drm-port/obsd-compat) built as a pure
# derivation, on the ./iwx-driver.nix pattern. The same objects and link as
# src/drm-port/i915/build-module.sh (which does it by hand on a live host):
# the files.drm "drm" + inteldrm + ttm set plus drm_drv.c (391 files), with
# -D__HAVE_ACPI -DNACPI=1, linked -r -Breduce with i915.mapfile.
#
# The OpenBSD source is the tree src/drm-port/i915/fetch-obsd-drm.sh pins
# (github openbsd/src 37a498de, sys/dev/pci/drm tree f7bfaaae; the script
# checks the git tree id). It runs here as a fixed-output derivation whose
# NAR hash was measured on its output (1462 files + OPENBSD_REV), so the
# store path is the pinned tree and nothing else.
#
# GATE (fail closed). The build FAILS unless:
#   * unresolved = 0 against the gate proto kernel and against kernelNd
#     (unix + genunix + misc/gfx_private, the module's _depends_on);
#   * the module exports no global but _init/_fini/_info/_depends_on (krtld
#     looks _depends_on up by name, kobj.c depends_on; it must stay global);
#   * no module global collides with a global of kernelNd's unix, genunix or
#     any of its modules (the pure analog of build-module.sh's /dev/ksyms
#     check), _init/_fini/_info excepted;
#   * SIMD (src/drm-port/i915/simd-gate.sh): every object is built -mno-mmx
#     -mno-sse (the gate's NO_SIMD); no object but i915_memcpy.o and
#     drm_cache.o has a SIMD/x87 instruction; in the linked module every SIMD
#     instruction is in a function of those two objects and between a call to
#     fpu_kernel_enter and a call to fpu_kernel_exit. Those two keep OpenBSD's
#     inline-asm movntdqa copies, which -mno-sse does not touch.
# Negative controls, run before the real result is trusted; each must FAIL:
#   * unresolved: the module + one object calling a symbol no kernel defines
#     must give exactly one more unresolved symbol, and name it;
#   * simd-sse: the module relinked with one object (drm_atomic.c) rebuilt
#     -msse must fail simd-gate.sh's object and function checks;
#   * simd-unbracketed: the module relinked with i915_memcpy.c rebuilt so
#     kernel_fpu_begin/end are no-ops must fail simd-gate.sh's bracket check.
#
# OUTPUT:
#   $out/kernel/drv/amd64/i915  the loadable kernel module
#   $out/.i915-gate             what was checked
{ gate                       # the gate proto (usr/include + reference kernel)
, kernelNd                   # pkgs.solnix.kernelNd: the kernel the images ship
, solnixDev                  # gcc 14.3.0 + binutils (gobjdump) + gmake on PATH
, ld                         # pkgs.solnix.ld: the gate link-editor slice
, system ? "x86_64-solaris"
, portSrc ? builtins.path {
    path = ../../src/drm-port;
    name = "solnix-drm-port-i915-src";
    # only the two directories the module is built from, without objects
    filter = path: type:
      let
        base = toString ../../src/drm-port;
        rel = builtins.substring (builtins.stringLength base + 1) 1000 (toString path);
        top = builtins.head (builtins.split "/" rel);
      in (top == "i915" || top == "obsd-compat")
         && !(type == "regular" && builtins.match ".*\\.o" (baseNameOf path) != null);
  }
, obsdDrm ? derivation {
    name = "openbsd-drm-37a498de";
    inherit system;
    builder = "/usr/bin/bash";
    PATH = "/usr/bin:/usr/gnu/bin";
    fetcher = ../../src/drm-port/i915/fetch-obsd-drm.sh;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-GjkvM7yjXvObYLT0QuzKIIVOWP8sCR73KcylDsHKJ7Y=";
    args = [ "-c" ''
      set -eu
      export HOME=$TMPDIR
      d=$(mktemp -d "$TMPDIR/obsd.XXXXXX")
      sh "$fetcher" "$d" >&2
      cp -R "$d/obsd-drm" "$out"
    '' ];
  }
}:

derivation {
  name = "i915-driver";
  inherit system gate kernelNd solnixDev ld portSrc obsdDrm;
  # The module is a copy of object code: it must name no store path (gcc's
  # __FILE__ of a gate header would otherwise pull the whole proto in).
  allowedReferences = [ ];
  builder = "/usr/bin/bash";
  PATH = "/usr/bin:/usr/sbin:/usr/gnu/bin";

  args = [ "-c" ''
    set -eu
    export PATH="$solnixDev/bin:$ld/usr/bin:$ld/bin:/usr/bin:/usr/sbin:/usr/gnu/bin"
    G="$gate/usr/include"
    [ -d "$G/sys" ] || { echo "FATAL: gate proto has no usr/include/sys" >&2; exit 1; }
    for t in gcc gmake gnm gobjdump; do
      command -v $t >/dev/null || { echo "FATAL: no $t" >&2; exit 1; }
    done
    LDBIN="$ld/usr/bin/ld"
    [ -x "$LDBIN" ] || LDBIN=/usr/bin/ld
    [ -x "$LDBIN" ] || { echo "FATAL: no ld" >&2; exit 1; }
    NM=/usr/bin/nm                         # illumos nm (see iwx-driver.nix)
    [ -x "$NM" ] || { echo "FATAL: no /usr/bin/nm" >&2; exit 1; }
    J=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

    W=$(mktemp -d /tmp/i915-driver.XXXXXX)
    cp -r "$portSrc" "$W/port"; chmod -R u+w "$W/port"
    cp -r "$obsdDrm" "$W/obsd"; chmod -R u+w "$W/obsd"
    P=$W/port; O=$W/obsd; C=$P/obsd-compat
    # kmap_atomic_prot / kunmap_atomic come from obsd-compat/obsd_vm.c (direct map;
    # OpenBSD's one shared VA raced across CPUs here, lixi vmdump.2). Rename the
    # OpenBSD definitions away; fail if the anchors moved.
    /usr/gnu/bin/sed -i 's/^kmap_atomic_prot(struct vm_page \*pg, pgprot_t prot)$/obsd_orig_kmap_atomic_prot(struct vm_page *pg, pgprot_t prot)/; s/^kunmap_atomic(void \*addr)$/obsd_orig_kunmap_atomic(void *addr)/' "$O/drm_linux.c"
    [ "$(grep -c '^obsd_orig_k' "$O/drm_linux.c")" -eq 2 ] \
      || { echo "FATAL: drm_linux.c kmap_atomic anchors not found" >&2; exit 1; }
    # The compat has no RCU (kfree_rcu frees at once): take frontbuffer
    # references under fb_tracking.lock, and make kref_get_unless_zero one CAS
    # (lixi vmdump.3). Fails if the patch does not apply exactly.
    ( cd "$O" && /usr/gnu/bin/patch -p1 --no-backup-if-mismatch -F0 < "$P/i915/obsd-norcu.patch" ) >&2
    # Linux errnos at their illumos (= Linux-meaning) values, not OpenBSD's aliases: userland (Mesa, libdrm) is built
    # against illumos <errno.h>. ETIME -> ETIMEDOUT made iris_bo_busy() never see a busy BO (rcs0 CS errors, lixi).
    ( cd "$O" && /usr/gnu/bin/patch -p1 --no-backup-if-mismatch -F0 < "$P/i915/obsd-errno.patch" ) >&2
    grep -q '^#define ETIME' "$O/include/linux/errno.h" && { echo "FATAL: linux/errno.h still aliases ETIME" >&2; exit 1; }

    echo "obsd drm $(cat "$O/OPENBSD_REV")" >&2

    # --- compile ---------------------------------------------------------------
    awk '$1=="file" && ($3=="drm" || $0 ~ /inteldrm/ || ($3=="ttm" && NF==3)) {sub("dev/pci/drm/","",$2); print $2}' \
      "$O/files.drm" > "$W/files.txt"
    echo drm_drv.c >> "$W/files.txt"
    nf=$(grep -c . "$W/files.txt")
    [ "$nf" -eq 391 ] || { echo "FATAL: $nf drm files, want 391 (files.drm changed?)" >&2; exit 1; }
    # NOSIMD: Makefile.master NO_SIMD. Appending -msse later re-enables SSE
    # (the simd-sse negative control relies on that, measured).
    NOSIMD="-mno-mmx -mno-sse"
    F="-m64 -mcmodel=kernel -mno-red-zone $NOSIMD -D_KERNEL -ffreestanding -nostdinc -std=gnu11 -O2"
    F="$F -fno-strict-aliasing -D__HAVE_ACPI -DNACPI=1 -include $C/obsd_prelude.h -I$C"
    # __FILE__ (WARN/BUG strings) names the mktemp dir and the gate path; map
    # both away so the module is the same bytes on every build.
    F="$F -I$O/include -I$O/include/uapi -I$O -I$O/i915 -I$G -fmacro-prefix-map=$W/= -fmacro-prefix-map=$gate/=/"
    mkdir -p "$W/obj"
    cd "$O"
    n=0
    for f in $(cat "$W/files.txt"); do
      o="$W/obj/$(echo "$f" | tr / _).o"
      { gcc $F -c "$f" -o "$o" > "$o.log" 2>&1 || echo "$f" >> "$W/cc-fail"; } &
      n=$((n + 1)); [ $((n % J)) -eq 0 ] && wait
    done
    wait
    if [ -s "$W/cc-fail" ]; then
      echo "FATAL: $(grep -c . "$W/cc-fail") drm files failed to compile, first:" >&2
      f=$(head -1 "$W/cc-fail"); grep -m10 error "$W/obj/$(echo "$f" | tr / _).o.log" >&2; exit 1
    fi
    nobj=$(ls "$W"/obj/*.o | grep -c .)
    [ "$nobj" -eq "$nf" ] || { echo "FATAL: $nobj objects for $nf files" >&2; exit 1; }
    ( cd "$C" && gmake obj GATE_INC="$G" ) > "$W/compat.log" 2>&1 || { tail -20 "$W/compat.log" >&2; exit 1; }
    grep -q -- '-mno-sse' "$W/compat.log" || { echo "FATAL: obsd-compat built without -mno-sse" >&2; exit 1; }
    gcc $F -I$P/i915 -I$P/i915/openbsd-orig/include -Werror -Wall \
      -c "$P/i915/i915_illumos.c" -o "$W/i915_illumos.o"
    gcc $F -I$P/i915 -c "$P/i915/i915_drmglue.c" -o "$W/i915_drmglue.o" > "$W/drmglue.log" 2>&1 \
      || { grep -E 'error' "$W/drmglue.log" >&2; exit 1; }
    gcc -m64 -mcmodel=kernel -mno-red-zone $NOSIMD -D_KERNEL -ffreestanding -nostdinc -std=gnu11 -O2 \
      -Wall -Werror -I$P/i915/openbsd-orig/include -I$P/i915 -I$G \
      -c "$P/i915/i915_pciid.c" -o "$W/i915_pciid.o"
    ls "$W"/obj/*.o "$C"/obsd_*.o "$W/i915_illumos.o" "$W/i915_drmglue.o" "$W/i915_pciid.o" > "$W/objs.txt"
    # ld -r records its output path as the module's first FILE symbol: link
    # from $W with a relative output name so the bytes do not carry the
    # mktemp name (measured: the only difference between two builds).
    link() { ( cd "$W" && "$LDBIN" -r -Breduce -M "$P/i915/i915.mapfile" -o "$1" $(cat "$2") ) > "$W/$1.ld.log" 2>&1 \
      || { cat "$W/$1.ld.log" >&2; exit 1; }; }
    link i915 objs.txt
    echo "built: i915 ($(wc -c < "$W/i915") bytes, $nobj drm objects)" >&2

    # --- GATE: symbols --------------------------------------------------------
    cd "$W"
    ksyms() {   # exported globals of unix + genunix + misc/gfx_private under $1
      for k in "$1/platform/i86pc/kernel/amd64/unix" "$1/kernel/amd64/genunix" \
               "$1/platform/i86pc/kernel/misc/amd64/gfx_private"; do
        [ -f "$k" ] || { echo "FATAL: reference kernel $k missing" >&2; exit 1; }
        $NM -p "$k"
      done | awk '$2 ~ /^[TDBRC]$/ {print $3}' | sort -u
    }
    undef() { $NM -p "$1" | awk '$2=="U" {print $3}' | sort -u; }
    defined() { $NM -p "$1" | awk '$2 ~ /^[TDBRC]$/ {print $3}' | sort -u; }
    ksyms "$gate" > ksyms-proto.txt
    ksyms "$kernelNd" > ksyms-nd.txt
    undef i915 > undef.txt
    defined i915 > defined.txt
    nund=$(grep -c . undef.txt || true)
    [ "$nund" -ge 100 ] || { echo "FATAL: only $nund undefined syms (nm printed too few; the gate cannot work)" >&2; exit 1; }

    printf 'extern int i915_gate_negctl_nosuch(void);\nint i915_gate_negctl(void) { return i915_gate_negctl_nosuch(); }\n' > negctl.c
    gcc -m64 -mcmodel=kernel -mno-red-zone $NOSIMD -ffreestanding -nostdinc -c -o negctl.o negctl.c
    "$LDBIN" -r -o i915-negctl i915 negctl.o
    undef i915-negctl > negctl-undef.txt
    nneg=$(comm -23 negctl-undef.txt ksyms-nd.txt | grep -c . || true)
    nreal=$(comm -23 undef.txt ksyms-nd.txt | grep -c . || true)
    [ "$nneg" -eq $((nreal + 1)) ] || { echo "FATAL: negative control (unresolved): $nneg, want $((nreal + 1))" >&2; exit 1; }
    comm -23 negctl-undef.txt ksyms-nd.txt | grep -qx i915_gate_negctl_nosuch \
      || { echo "FATAL: negative control (unresolved) symbol not reported" >&2; exit 1; }
    echo "gate: negative control (unresolved) FAILS as required: +1 (i915_gate_negctl_nosuch)" >&2

    comm -23 undef.txt ksyms-proto.txt > unres-proto.txt
    comm -23 undef.txt ksyms-nd.txt > unres-nd.txt
    np=$(grep -c . unres-proto.txt || true); nn=$(grep -c . unres-nd.txt || true)
    echo "gate: undefined=$nund unresolved-vs-proto=$np unresolved-vs-kernel-nd=$nn" >&2
    if [ "$np" -ne 0 ] || [ "$nn" -ne 0 ]; then
      sed 's/^/  proto: /' unres-proto.txt >&2; sed 's/^/  nd:    /' unres-nd.txt >&2
      echo "FATAL: unresolved symbols (must be 0)" >&2; exit 1
    fi
    grep -v -E '^(_init|_fini|_info|_depends_on)$' defined.txt > leaked.txt || true
    nleak=$(grep -c . leaked.txt || true)
    echo "gate: non-interface exported globals=$nleak" >&2
    [ "$nleak" -eq 0 ] || { sed 's/^/  /' leaked.txt >&2; echo "FATAL: non-interface globals exported" >&2; exit 1; }
    for s in _init _fini _info _depends_on; do
      grep -qx "$s" defined.txt || { echo "FATAL: $s not exported" >&2; exit 1; }
    done
    # every global of kernelNd's kernel and modules (krtld binds to these).
    # || true: the tree holds .conf files; under set -e one nm failure would
    # end the loop early (measured: 455 symbols instead of ~41000).
    find "$kernelNd/platform" "$kernelNd/kernel" "$kernelNd/usr/kernel" -type f 2>/dev/null \
      | while read -r f; do gnm -g --defined-only "$f" 2>/dev/null || true; done \
      | awk '{print $3}' | sort -u > ksyms-all.txt
    nall=$(grep -c . ksyms-all.txt || true)
    [ "$nall" -ge 10000 ] || { echo "FATAL: only $nall kernel globals: refusing a vacuous collision gate" >&2; exit 1; }
    comm -12 defined.txt ksyms-all.txt | grep -v -E '^(_init|_fini|_info)$' > collide.txt || true
    ncol=$(grep -c . collide.txt || true)
    echo "gate: collisions vs $nall kernelNd globals=$ncol" >&2
    [ "$ncol" -eq 0 ] || { sed 's/^/  /' collide.txt >&2; echo "FATAL: name collisions" >&2; exit 1; }

    # --- GATE: SIMD -------------------------------------------------------------
    SG="$P/i915/simd-gate.sh"
    EX="obj/i915_i915_memcpy.c.o obj/drm_cache.c.o"
    EXB="i915_i915_memcpy.c.o drm_cache.c.o"
    for e in $EX; do grep -qx "$W/$e" objs.txt || { echo "FATAL: exempt object $e not linked" >&2; exit 1; }; done
    # negative control simd-sse: drm_atomic.c rebuilt with -msse appended
    mkdir -p neg-sse/obj
    sed "s#^$W/obj/drm_atomic.c.o\$#$W/neg-sse/obj/drm_atomic.c.o#" objs.txt > neg-sse/objs.txt
    cmp -s objs.txt neg-sse/objs.txt && { echo "FATAL: simd-sse control did not swap the object" >&2; exit 1; }
    ( cd "$O" && gcc $F -msse -c drm_atomic.c -o "$W/neg-sse/obj/drm_atomic.c.o" ) > /dev/null 2>&1
    link neg-sse/i915 neg-sse/objs.txt
    if OBJDUMP=gobjdump sh "$SG" neg-sse/i915 "$EXB" $(cat neg-sse/objs.txt) > neg-sse/log 2>&1; then
      cat neg-sse/log >&2; echo "FATAL: NEGATIVE CONTROL (simd-sse) DID NOT FAIL" >&2; exit 1; fi
    grep -q 'FAIL (object): drm_atomic.c.o' neg-sse/log && grep -q 'FAIL (function)' neg-sse/log \
      || { cat neg-sse/log >&2; echo "FATAL: negative control (simd-sse) failed for the wrong reason" >&2; exit 1; }
    echo "gate: negative control (simd-sse) FAILS as required: $(grep 'FAIL (object)' neg-sse/log | head -1)" >&2
    # negative control simd-unbracketed: a copy of i915_memcpy.c with its
    # kernel_fpu_begin()/kernel_fpu_end() calls deleted, the movntdqa asm kept.
    mkdir -p neg-brk/obj
    sed "s#^$W/obj/i915_i915_memcpy.c.o\$#$W/neg-brk/obj/i915_i915_memcpy.c.o#" objs.txt > neg-brk/objs.txt
    cmp -s objs.txt neg-brk/objs.txt && { echo "FATAL: simd-unbracketed control did not swap the object" >&2; exit 1; }
    sed -e 's/kernel_fpu_begin();//' -e 's/kernel_fpu_end();//' "$O/i915/i915_memcpy.c" > "$O/i915/negbrk_memcpy.c"
    [ "$(grep -c 'kernel_fpu_' "$O/i915/i915_memcpy.c")" -ge 4 ] && ! grep -q 'kernel_fpu_' "$O/i915/negbrk_memcpy.c" \
      || { echo "FATAL: simd-unbracketed control did not remove the brackets" >&2; exit 1; }
    ( cd "$O" && gcc $F -c i915/negbrk_memcpy.c -o "$W/neg-brk/obj/i915_i915_memcpy.c.o" ) > neg-brk/cc.log 2>&1 \
      || { cat neg-brk/cc.log >&2; echo "FATAL: negative control (simd-unbracketed) did not compile" >&2; exit 1; }
    link neg-brk/i915 neg-brk/objs.txt
    if OBJDUMP=gobjdump sh "$SG" neg-brk/i915 "$EXB" $(cat neg-brk/objs.txt) > neg-brk/log 2>&1; then
      cat neg-brk/log >&2; echo "FATAL: NEGATIVE CONTROL (simd-unbracketed) DID NOT FAIL" >&2; exit 1; fi
    grep -q 'FAIL (bracket)' neg-brk/log \
      || { cat neg-brk/log >&2; echo "FATAL: negative control (simd-unbracketed) failed for the wrong reason" >&2; exit 1; }
    echo "gate: negative control (simd-unbracketed) FAILS as required: $(grep -c 'FAIL (bracket)' neg-brk/log) bracket lines" >&2
    # the real module
    OBJDUMP=gobjdump sh "$SG" i915 "$EXB" $(cat objs.txt) > simd.log 2>&1 || { cat simd.log >&2; echo "FATAL: SIMD gate" >&2; exit 1; }
    grep -E '^(exempt|module|SIMD-GATE PASS)' simd.log >&2

    mkdir -p "$out/kernel/drv/amd64"
    cp i915 "$out/kernel/drv/amd64/i915"
    chmod 0555 "$out/kernel/drv/amd64/i915"
    {
      echo "objects=$nobj undefined=$nund unresolved-proto=$np unresolved-kernel-nd=$nn non-interface-globals=$nleak collisions=$ncol/$nall"
      echo "negctl-unresolved=$nneg negctl-simd-sse=FAIL negctl-simd-unbracketed=FAIL"
      grep -E '^(exempt|module|SIMD-GATE PASS)' simd.log
      echo "obsd-drm=$(cat "$O/OPENBSD_REV")"
    } > "$out/.i915-gate"
    cd /; find "$W" -depth -delete 2>/dev/null || true
    echo "=== i915-driver: module built, gate green ===" >&2
  '' ];
}
