#!/usr/bin/bash
# host-path-scan.sh <dir> [allow-regex] | --selftest: a store-only build must not have CONFIGURED itself against a host path.
# A store-only PATH does not stop configure from naming an absolute host path: jq 1.8.2's configure.ac sets MAKE=/usr/gnu/bin/make
# on SunOS when MAKE is unset, and the OI host (which has it) built and even reproduced that; a solnix host failed (recipes1,
# main 147fb91). This scans what configure/cmake/meson GENERATED under <dir> (config.status, config.log, libtool, a Makefile that
# has a Makefile.in beside it, CMakeCache.txt, build.ninja) for /usr/gnu, /opt, /usr/local, /usr/sfw, and /usr/bin/<tool> for the
# tools the store provides. A match preceded by a path character (".../illumos-userland/usr/bin/sed", a store path) is not a host
# path and does not count. allow-regex (a recipe's documented exception, grep -E) drops matching lines. Exit 1 with the hits.
# --selftest is the negative control (run on every call): a planted /usr/gnu/bin/make must be found and a store path must not.
pat='(^|[^A-Za-z0-9_.+/-])(/usr/gnu/|/opt/|/usr/local/|/usr/sfw/|/usr/bin/(make|gmake|install|ginstall|m4|gm4|sed|gsed|awk|gawk|grep|ggrep|tar|gtar|python3|perl)([^A-Za-z0-9_.+-]|$))'
scan() {  # <dir> [allow]: prints "file: line" for each hit
  find "$1" -type f \( -name config.status -o -name config.log -o -name libtool -o -name CMakeCache.txt -o -name build.ninja \
    -o \( -name Makefile -newer "$1" \) -o -name Makefile \) 2>/dev/null | while read -r f; do
    case "${f##*/}" in Makefile) [ -f "$f.in" ] || [ -f "${f%/*}/Makefile.am" ] || continue;; esac
    p=$pat; case "${f##*/}" in CMakeCache.txt) p='(^|[^A-Za-z0-9_.+/-])(/usr/bin/|/usr/sbin/|/usr/gnu/|/opt/|/usr/local/|/usr/sfw/)';; esac
    grep -a -n -E "$p" "$f" 2>/dev/null | { if [ -n "${2:-}" ]; then grep -a -v -E "$2"; else cat; fi; } | head -5 | sed "s|^|$f: |"
  done
}
T=$(mktemp -d "${TMPDIR:-/tmp}/hps.XXXXXX") || exit 1
mkdir -p "$T/good" "$T/bad"
printf 'MAKE=/nix/store/00000000000000000000000000000000-illumos-userland/usr/bin/sed\nSHELL=/bin/sh\n' > "$T/good/config.status"
printf "MAKE='/usr/gnu/bin/make'\n" > "$T/bad/config.status"
mkdir -p "$T/badc" "$T/goodc"; printf 'CMAKE_AR:FILEPATH=/usr/bin/ar\n' > "$T/badc/CMakeCache.txt"
printf 'CMAKE_AR:FILEPATH=/nix/store/00000000000000000000000000000000-w/usr/bin/ar\n' > "$T/goodc/CMakeCache.txt"
[ -n "$(scan "$T/bad")" ] && [ -z "$(scan "$T/good")" ] && [ -n "$(scan "$T/badc")" ] && [ -z "$(scan "$T/goodc")" ] || { echo "FATAL: host-path-scan selftest failed" >&2; find "$T" -depth -delete; exit 1; }
find "$T" -depth -delete
[ "${1:-}" = --selftest ] && { echo "host-path-scan selftest PASS"; exit 0; }
hits=$(scan "$1" "${2:-}")
[ -z "$hits" ] || { echo "FATAL: configure named a host path (a store-only build must not; set the tool from the store):" >&2; echo "$hits" | head -20 >&2; exit 1; }
echo "=== host-path-scan: no host tool path in the configure output ===" >&2
