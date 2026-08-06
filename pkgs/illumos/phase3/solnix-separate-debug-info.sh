# solnix-separate-debug-info.sh — real split-debug for x86_64-solaris.
#
# nixpkgs' separate-debug-info.sh is gated to isLinux and depends on
# NIX_SET_BUILD_ID -> `ld --build-id` to stamp a .note.gnu.build-id note. On
# illumos the native Solaris link-editor (/usr/bin/ld) has no --build-id and
# emits no such note, so the stock hook is a no-op here.
#
# This hook produces the SAME artifact gdb consumes on any platform (a `-debug`
# output holding lib/debug/.build-id/XX/YY.debug reachable by build-id) using
# the illumos-native toolchain, WITHOUT changing the linker: keep the trusted
# Solaris ld for the link (correct Solaris relocs/mapfiles/direct-binding), then
# as a POST-LINK fixup on every ELF:
#   1. compute a build-id = sha1 of the fully-linked binary (deterministic,
#      unique per build; mirrors `ld --build-id=sha1` semantics closely enough
#      for the debug-file-lookup contract),
#   2. inject a real .note.gnu.build-id note section (built with pure printf;
#      GNU objcopy --add-section builds a SHT_PROGBITS section; illumos elfedit
#      retypes it to SHT_NOTE so readelf -n / gdb parse it),
#   3. objcopy --only-keep-debug into $debug/lib/debug/.build-id/XX/YY.debug,
#      objcopy --strip-debug the shipped ELF (KEEP CTF/.SUNW_ctf for mdb/dtrace),
#      objcopy --add-gnu-debuglink back.
# Proven: gdb loads the split debug via the injected build-id (info functions
# resolves source-level symbols from the -debug path), on both executables and
# shared libraries; both keep running.
#
# NOTE: the injected note is section-only (not covered by a PT_NOTE program
# header — Solaris ld emits none and illumos elfedit has no phdr module to add
# one). gdb reads the build-id from the section and finds the debug file; it
# prints a cosmetic "note outside of ELF segments" warning. Runtime build-id
# visibility via dl_iterate_phdr is therefore not provided; upgrade path is a
# PT_NOTE-segment rewrite (or GNU-ld linking) if that ever matters.
#
# Wired as a fixupOutput hook (runs after the RUNPATH fixup). Requires the
# `debug` output and OBJCOPY/READELF/ELFEDIT in the env (set by the overlay).

fixupOutputHooks+=(_solnixSeparateDebugInfo)

_solnixSeparateDebugInfo() {
    [ -e "$prefix" ] || return 0

    local debugOutput="${debug:-}"
    [ -n "$debugOutput" ] || return 0
    if [ "$prefix" = "$debugOutput" ]; then return 0; fi

    local OBJCOPY="${OBJCOPY:-/usr/gnu/bin/objcopy}"
    local ELFEDIT="${ELFEDIT:-/usr/bin/elfedit}"
    local SHA1="${SHA1SUM:-/usr/bin/sha1sum}"
    for t in "$OBJCOPY" "$ELFEDIT" "$SHA1"; do
        [ -x "$t" ] || { echo "_solnixSeparateDebugInfo: missing $t, skipping" >&2; return 0; }
    done

    mkdir -p "$debugOutput/lib/debug/.build-id"
    local dst="$debugOutput/lib/debug/.build-id"

    local i
    while IFS= read -r -d $'\0' i; do
        # ELF with debug info only (objcopy -only-keep-debug on a non-ELF fails).
        /usr/gnu/bin/objdump -h "$i" 2>/dev/null | grep -q '\.debug_info' || continue

        chmod u+w "$i" 2>/dev/null || true

        # 1) build-id = sha1 of the fully-linked ELF (before we mutate it).
        local id
        id="$("$SHA1" "$i" | awk '{print $1}')"
        [ "${#id}" = 40 ] || { echo "_solnixSeparateDebugInfo: bad sha1 for $i, skipping" >&2; continue; }

        # 2) inject a real .note.gnu.build-id note (namesz=4 "GNU\0", descsz=20,
        #    type=3 NT_GNU_BUILD_ID, 20-byte sha1). Skip if one already exists.
        #    Built with pure printf (no python: the nix builder PATH has neither
        #    python3 nor xxd).
        if ! /usr/gnu/bin/readelf -n "$i" 2>/dev/null | grep -qi 'Build ID:'; then
            local note; note="$(mktemp)"
            printf '\004\000\000\000\024\000\000\000\003\000\000\000GNU\000'"$(echo "$id" | sed 's/../\\x&/g')" > "$note"
            "$OBJCOPY" --add-section .note.gnu.build-id="$note" \
                --set-section-flags .note.gnu.build-id=alloc,readonly "$i" 2>/dev/null || { rm -f "$note"; continue; }
            "$ELFEDIT" -e "shdr:sh_type .note.gnu.build-id SHT_NOTE" "$i" 2>/dev/null || true
            rm -f "$note"
        else
            # already has a note (e.g. GNU-ld build): trust it.
            id="$(/usr/gnu/bin/readelf -n "$i" 2>/dev/null | sed 's/.*Build ID: \([0-9a-f]*\).*/\1/; t; d')"
            [ "${#id}" = 40 ] || continue
        fi

        # 3) split: only-keep-debug -> .build-id path, strip-debug, debuglink.
        local d2="$dst/${id:0:2}"
        mkdir -p "$d2"
        local dbgfile="$d2/${id:2}.debug"
        echo "solnix-separate-debug-info: $i (build ID $id)"
        if "$OBJCOPY" --only-keep-debug "$i" "$dbgfile" 2>/dev/null; then
            "$OBJCOPY" --strip-debug "$i" 2>/dev/null || true
            "$OBJCOPY" --add-gnu-debuglink="$dbgfile" "$i" 2>/dev/null || true
            # debuginfod-style back-symlinks (mirror nixpkgs layout).
            ln -sfn "$dbgfile" "$dst/../$(basename "$i")" 2>/dev/null || true
            ln -sfn "$i" "$d2/${id:2}.executable" 2>/dev/null || true
        else
            rmdir -p "$d2" --ignore-fail-on-non-empty 2>/dev/null || true
        fi
    done < <(find "$prefix" -type f -print0 2>/dev/null)

    # never leave an empty debug output (breaks the multi-output contract).
    [ -n "$(ls -A "$dst" 2>/dev/null)" ] || \
        echo "no split debug info in $prefix" > "$debugOutput/lib/debug/.empty"
}
