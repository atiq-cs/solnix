#!/usr/bin/ksh93
# scripts/test-core-prune.sh [core-prune.sh]: modules/config/core-prune.sh in a scratch dir (ksh93, an illumos host; cosmic8)
set -e; S=${1:-$(dirname "$0")/../modules/config/core-prune.sh}; D=$(mktemp -d /tmp/cptest.XXXXXX); now=$(date +%s)
mk() { dd if=/dev/zero of="$D/$1" bs=1024 count=$2 2>/dev/null; }
for i in 1 2 3 4 5; do mk core.app.$i.$((now - i)) 1; done          # 5 of one program, newest = .1
mk core.old.9.$((now - 20 * 86400)) 1                                # older than 14 days
mkdir "$D/1000"; mk 1000/core.term.7.$((now - 10)) 1                 # per-uid dir
mk core.big.8.$((now - 100)) 3000; mk core.big2.9.$((now - 200)) 2000  # 5 MB total, cap 4 MB below
ln -s /etc/passwd "$D/core.link.1.$now"; mk notacore 1
CORE_DIR=$D CORE_MAX_USE_MB=4 ksh93 "$S" --once > "$D.out"
want="core.app.1 core.app.2 core.app.3 core.big.8 1000/core.term.7 core.link.1 notacore"
for w in $want; do ls "$D" "$D/1000" | grep -q "^${w##*/}" || { echo "FAIL: $w removed"; exit 1; }; done
for g in core.app.4 core.app.5 core.old.9 core.big2.9; do ls "$D" | grep -q "^$g" && { echo "FAIL: $g kept"; exit 1; }; done
[ -e /etc/passwd ] || { echo "FAIL"; exit 1; }
# a cap above 2 GiB must keep everything the other rules keep (ksh93 32-bit -i overflowed 4096 MiB to 0)
mk core.keep.5.$now 1; CORE_DIR=$D CORE_MAX_USE_MB=4096 ksh93 "$S" --once > /dev/null
ls "$D" | grep -q "^core.keep.5" || { echo "FAIL: large cap removed a core"; exit 1; }
echo "PASS core-prune ($(wc -l < "$D.out") removed)"; find "$D" -depth -delete; rm -f "$D.out"
