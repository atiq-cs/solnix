#!/bin/sh
# license-audit.sh -- classify every .c/.h under the given directories by license,
# for the rule in docs/x1-gpu-route.md: a file whose only license is GPL/LGPL never
# enters solnix; a GPL-OR-permissive dual-licensed file is used under the
# permissive license with its header kept.
#
# Usage: license-audit.sh [-l] DIR...
#   prints one summary line per DIR:  DIR total PERM PD DUAL GPL NONE
#   -l additionally lists every GPL and NONE file (the ones a human must look at).
#
# Classes, decided from the first 60 lines of each file:
#   PERM  SPDX id is permissive only (MIT, BSD-*, X11, ISC, Zlib, Apache-2.0, curl)
#         OR no SPDX line but an MIT/BSD/ISC permission grant in the header text.
#   DUAL  SPDX expression is "<GPL/LGPL> OR <permissive>" (either order).
#   GPL   SPDX expression names only GPL/LGPL terms, or ANDs one in, or (no SPDX)
#         the header text references the GNU (Lesser) General Public License
#         without a permissive grant.
#   PD    no SPDX/grant, header says "public domain" (the BSD stub reimplementations).
#   NONE  no SPDX line and no recognisable license text (generated headers etc.).
#         NOT automatically usable: each needs a provenance check. Inside a Linux
#         tree a file with no notice falls under the kernel default, GPL-2.0-only
#         (COPYING + Documentation/process/license-rules.rst), so treat it as GPL
#         unless the same file is found with a permissive notice elsewhere.
set -u
list=0
[ "${1:-}" = "-l" ] && { list=1; shift; }
[ $# -ge 1 ] || { echo "usage: $0 [-l] DIR..." >&2; exit 2; }

classify() {
	# $1 = file; prints the class word.
	head -n 60 "$1" | awk '
	BEGIN { spdx = ""; perm = 0; gpl = 0; pd = 0 }
	/SPDX-License-Identifier:/ && spdx == "" {
		s = $0; sub(/.*SPDX-License-Identifier:[ \t]*/, "", s)
		sub(/[ \t]*(\*\/|-->)?[ \t]*$/, "", s); spdx = s
	}
	/Permission is hereby granted, (free of charge|without written agreement)/ { perm = 1 }
	/Permission to use, copy, modify, (and(\/or)? )?distribute/ { perm = 1 }
	/Redistribution and use in source and binary forms/ { perm = 1 }
	/GNU (Lesser |Library )?General Public License/ { gpl = 1 }
	/[Pp]ublic [Dd]omain/ { pd = 1 }
	END {
		if (spdx != "") {
			e = spdx; gsub(/[()]/, " ", e)
			n = split(e, t, /[ \t]+/)
			hasg = 0; hasp = 0; hasor = 0; hasand = 0
			for (i = 1; i <= n; i++) {
				w = t[i]
				if (w == "OR" || w == "or") hasor = 1
				else if (w == "AND" || w == "and") hasand = 1
				else if (w ~ /^L?GPL/) hasg = 1
				else if (w ~ /^(MIT|BSD|X11|ISC|Zlib|Apache|curl|0BSD|CC0|Unlicense)/) hasp = 1
				else if (w == "WITH" || w ~ /exception/ || w ~ /^Linux-syscall-note/) ;
				else if (w != "") hasp = hasp
			}
			if (hasg && hasp && hasor && !hasand) print "DUAL"
			else if (hasg) print "GPL"
			else if (hasp) print "PERM"
			else print "NONE"
		} else if (perm) print "PERM"
		else if (gpl) print "GPL"
		else if (pd) print "PD"
		else print "NONE"
	}'
}

for d in "$@"; do
	tot=0; p=0; pd=0; du=0; g=0; no=0; gl=""; nl=""
	# find -type f avoids following symlinks into unrelated trees.
	for f in $(find "$d" -type f \( -name '*.c' -o -name '*.h' \) | LC_ALL=C sort); do
		tot=$((tot + 1))
		case $(classify "$f") in
		PERM) p=$((p + 1)) ;;
		PD)   pd=$((pd + 1)) ;;
		DUAL) du=$((du + 1)) ;;
		GPL)  g=$((g + 1)); gl="$gl $f" ;;
		*)    no=$((no + 1)); nl="$nl $f" ;;
		esac
	done
	printf '%s total=%d PERM=%d PD=%d DUAL=%d GPL=%d NONE=%d\n' "$d" "$tot" "$p" "$pd" "$du" "$g" "$no"
	if [ $list = 1 ]; then
		for f in $gl; do echo "  GPL  $f"; done
		for f in $nl; do echo "  NONE $f"; done
	fi
done
