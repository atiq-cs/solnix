#!/bin/sh
# fetch-obsd-drm.sh -- fetch the OpenBSD sys/dev/pci/drm tree the i915 port
# builds against (OBSD= for Makefile, link-gap.sh, build-module.sh), pinned.
#
# Pin: github.com/openbsd/src commit OBSD_REV; the git tree id of
# sys/dev/pci/drm at that commit must equal OBSD_TREE, which pins every byte
# of every file under it (git object ids are content hashes). The fetch is a
# depth-1 blobless clone with a sparse checkout of that one directory; amd/,
# radeon/ and apple/ (about 500 MB, not inteldrm) are left out.
#
# Usage: fetch-obsd-drm.sh DEST      -> DEST/obsd-drm (with an OPENBSD_REV file)
set -eu
OBSD_REV=37a498de2f7aa77a9e30afd65012af6434819316	# 2026-10-08T18:19:31Z
OBSD_TREE=f7bfaaae121cdc80ddd33287e7a87701c87617b5	# sys/dev/pci/drm at OBSD_REV
dest=${1:?usage: fetch-obsd-drm.sh DEST}
git=$dest/openbsd-src.git
mkdir -p "$dest"
[ -d "$git" ] || git init -q "$git"
cd "$git"
git remote get-url origin > /dev/null 2>&1 ||
    git remote add origin https://github.com/openbsd/src.git
git fetch -q --depth 1 --filter=blob:none origin "$OBSD_REV"
tree=$(git rev-parse "$OBSD_REV:sys/dev/pci/drm")
if [ "$tree" != "$OBSD_TREE" ]; then
	echo "FAIL: sys/dev/pci/drm tree is $tree, pinned $OBSD_TREE" >&2
	exit 1
fi
git sparse-checkout set --no-cone '/sys/dev/pci/drm/' \
    '!/sys/dev/pci/drm/amd/' '!/sys/dev/pci/drm/radeon/' '!/sys/dev/pci/drm/apple/'
git -c advice.detachedHead=false checkout -q --force "$OBSD_REV"
# Every checked-out file must hash to the blob the pinned tree names.
dirty=$(git status --porcelain -- sys/dev/pci/drm | wc -l)
if [ "$dirty" -ne 0 ]; then
	echo "FAIL: $dirty files differ from $OBSD_REV" >&2
	exit 1
fi
rm -rf "$dest/obsd-drm"
cp -R sys/dev/pci/drm "$dest/obsd-drm"
echo "$OBSD_REV" > "$dest/obsd-drm/OPENBSD_REV"
echo "obsd-drm: $(find "$dest/obsd-drm" -type f | wc -l) files at $OBSD_REV (tree $OBSD_TREE)"
