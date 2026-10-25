#!/usr/bin/env bash
# stage-dropbear.sh <stage-dir> <authorized_keys> -- rvlogin session root: pkginit runs dropbearkey (host key into
# /data on first boot) then dropbear in the foreground, key-only. gburd (uid 1000) gets the given authorized_keys.
set -euo pipefail
S="$1"; AK="$2"; OUT="${OUT:-$HOME/scratch/rvlogin/out}"
mkdir -p "$S/sbin" "$S/bin" "$S/etc" "$S/home/gburd/.ssh" "$S/tmp"
cp "$OUT/pkginit" "$S/sbin/init"; cp "$OUT/dropbear" "$OUT/dropbearkey" "$OUT/dash" "$OUT/sbase-box" "$S/bin/"
ln "$S/bin/dash" "$S/bin/sh"	# ustar '1' entry: the kernel's reader has no symlinks
for a in uname whoami ls cat echo; do ln "$S/bin/sbase-box" "$S/bin/$a"; done
printf '%s\n' 'root:x:0:0:Super-User:/:/bin/sh' 'gburd:x:1000:1000:gburd:/home/gburd:/bin/sh' > "$S/etc/passwd"
cp "$AK" "$S/home/gburd/.ssh/authorized_keys"; chmod 700 "$S/home/gburd/.ssh"; chmod 600 "$S/home/gburd/.ssh/authorized_keys"
cat > "$S/etc/rvpkg.tests" <<'T'
perms|0|/bin/ls|ls|-ld|/home/gburd|/home/gburd/.ssh|/home/gburd/.ssh/authorized_keys
hostkey|0|/bin/dropbearkey|dropbearkey|-t|ed25519|-f|/data/dropbear_ed25519_host_key
dropbear|0|/bin/dropbear|dropbear|-F|-w|-j|-m|-P|/tmp/dropbear.pid|-p|22|-r|/data/dropbear_ed25519_host_key
T
