#!/usr/bin/env bash
# upstream-watch.sh -- weekly digest of new commits in the illumos forks and the BSD sources solnix tracks
# (docs/illumos-upstreams.md). For each watched branch: fetch a shallow, blob-less window of history into one
# bare cache repo, list the commits of the last DAYS days that touch the paths solnix cares about, and, for a
# fork, only the commits its base (illumos-gate) does not have; a base row must come before its forks. Dates are
# committer dates (an OpenZFS import keeps its years-old author date). git is the only dependency; nothing is built.
#   scripts/upstream-watch.sh [-d days] [-l list] [-s statedir] [-o digest.md]
# list rows (tab or space separated, # comments): name url branch base path... ; base "-" = none, path "." = all.
# Exit 0 = every branch fetched; 1 = at least one FETCH-FAILED or BAD-ROW (the digest is still written); 2 = usage.
set -u
DAYS=8 LIST='' STATE=${XDG_CACHE_HOME:-$HOME/.cache}/solnix-upstream-watch OUT=/dev/stdout MAX=${UPSTREAM_WATCH_MAX:-40}
while getopts d:l:s:o: c; do case $c in d) DAYS=$OPTARG ;; l) LIST=$OPTARG ;; s) STATE=$OPTARG ;; o) OUT=$OPTARG ;;
	*) sed -n '2,9s/^# \{0,1\}//p' "$0" >&2; exit 2 ;; esac; done
case $DAYS in '' | *[!0-9]*) echo "upstream-watch: -d wants a number of days" >&2; exit 2 ;; esac

G="usr/src/uts/common/brand usr/src/lib/brand usr/src/uts/intel/io/vmm usr/src/uts/intel/io/viona usr/src/cmd/bhyve \
 usr/src/lib/libvmmapi usr/src/uts/common/fs/zfs usr/src/common/zfs usr/src/uts/common/io/overlay usr/src/uts/common/io/vnd \
 usr/src/uts/common/io/mac usr/src/uts/aarch64 usr/src/uts/aarch64pf usr/src/uts/armv8 usr/src/uts/riscv64 usr/src/uts/riscv64pf \
 usr/src/uts/sparc usr/src/uts/sun4u usr/src/uts/sun4v usr/src/uts/oxide"
default_list() { cat <<EOF
illumos-gate	https://github.com/illumos/illumos-gate.git	master	-	$G
illumos-joyent	https://github.com/TritonDataCenter/illumos-joyent.git	master	illumos-gate	$G
illumos-omnios	https://github.com/omniosorg/illumos-omnios.git	master	illumos-gate	$G
oxide-stlouis	https://github.com/oxidecomputer/illumos-gate.git	stlouis	illumos-gate	$G
arm64-gate	https://github.com/richlowe/illumos-gate.git	arm64-gate	illumos-gate	$G
n-hys	https://github.com/n-hys/illumos-gate.git	osport/v2022.11-wip	illumos-gate	$G
dilos	https://bitbucket.org/dilos/dilos-illumos4.git	dilos4	illumos-gate	$G
gfx-drm	https://github.com/illumos/gfx-drm.git	master	-	.
smartos-live	https://github.com/TritonDataCenter/smartos-live.git	master	-	.
tribblix-sparc	https://github.com/tribblix/tribblix-build.git	master	-	illumos/sparc
oi-userland	https://github.com/OpenIndiana/oi-userland.git	oi/hipster	-	components/openindiana components/developer components/library
helios	https://github.com/oxidecomputer/helios.git	master	-	.
propolis	https://github.com/oxidecomputer/propolis.git	master	-	.
openzfs	https://github.com/openzfs/zfs.git	master	-	module/zcommon/zfeature_common.c include/zfeature_common.h
openbsd	https://github.com/openbsd/src.git	master	-	sys/dev/pci/drm sys/dev/pci/if_iwx.c sys/dev/pci/if_iwxreg.h sys/dev/pci/if_iwm.c
freebsd	https://github.com/freebsd/freebsd-src.git	main	-	sys/compat/linux
EOF
}

R=$STATE/cache.git
[ -d "$R" ] || git init -q --bare "$R" || { echo "upstream-watch: cannot create $R" >&2; exit 1; }
rows=$(if [ -n "$LIST" ]; then cat "$LIST"; else default_list; fi | sed -e 's/#.*//' -e '/^[[:space:]]*$/d') ||
	{ echo "upstream-watch: cannot read $LIST" >&2; exit 1; }
failed=0
{
	echo "# upstream-watch digest $(date -u +%Y-%m-%dT%H:%MZ), window $DAYS days"
	while read -r name url branch base paths; do
		[ -n "$paths" ] || { echo; echo "## $name: BAD-ROW (want: name url branch base path...)"; failed=1; continue; }
		ref=refs/watch/$name
		# --shallow-since fails when the branch has no commit in the window (n-hys): then take the tip alone.
		if git -C "$R" fetch -q --no-tags --filter=blob:none --shallow-since="$DAYS days ago" "$url" "+$branch:$ref" 2>/dev/null ||
			git -C "$R" fetch -q --no-tags --filter=blob:none --depth=1 "$url" "+$branch:$ref" 2>/dev/null; then :
		else
			echo; echo "## $name: FETCH-FAILED ($url $branch)"; failed=1; continue
		fi
		not=; [ "$base" != - ] && git -C "$R" rev-parse -q --verify "refs/watch/$base" > /dev/null && not="^refs/watch/$base"
		# shellcheck disable=SC2086 # paths is a word list on purpose
		log=$(git -C "$R" log --no-merges --since="$DAYS days ago" --date=short --format='- %h %cd %an: %s' "$ref" $not -- $paths)
		all=$(git -C "$R" rev-list --no-merges --count --since="$DAYS days ago" "$ref" $not)
		n=0; [ -n "$log" ] && n=$(printf '%s\n' "$log" | wc -l | tr -d ' ')
		tip=$(git -C "$R" log -1 --date=short --format='%h %cd' "$ref")
		echo; echo "## $name ($branch, tip $tip): $n of $all new commits touch watched paths${not:+ (not in $base)}"
		[ "$n" -gt 0 ] && printf '%s\n' "$log" | head -n "$MAX"
		[ "$n" -gt "$MAX" ] && echo "- ... $((n - MAX)) more: git -C $R log $ref"
	done <<< "$rows"
} > "$OUT"
exit $failed
