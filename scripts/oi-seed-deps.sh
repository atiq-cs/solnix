#!/usr/bin/env bash
# seed wave-1 gcc deps from cache, serially (avoids the Nix-2.3.16 illumos
# parallel-substitution "Error 0" race). Idempotent.
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin
export NIX_CONF_DIR=/nix-tools/etc/nix
PATHS="
y2awx84p469wpyzi9v5qyyyd29jbzf7s-solnix-zlib-1.3.1
q421vxfp6s81ikx6rxpnk06x6vyhghr0-solnix-bzip2-1.0.8
cxd3djc7gd873i6n0g74dwkw3951c592-solnix-xz-5.6.3
v7ciprqidzyvwdlygxxd5mfsadjnwcks-solnix-libffi-3.4.6
jbxnfvi2gl639yhjrl1h7ikvhcxqmzh3-solnix-openssl-3-3.4.0
w54ganzziy6vg3k6jdr6ig1d68n2aar2-solnix-ncurses-6.5
gnnlahqaj8vayh3k6hfp89dhhsiy1lzh-solnix-readline-8.2
zpdf2s47r4jlj55yixsqqx1s16zjpxwz-solnix-sqlite-3-3.47.2
7m969if2zmrwdavz18xn7r468dc5h9gk-solnix-expat-2.6.4
qgbv15kwj4djm5dka742fdikrz8rqky9-solnix-gmp-6.3.0
"
for h in $PATHS; do
  p="/nix/store/$h"
  if [ -d "$p" ]; then echo "have $h"; continue; fi
  # retry a few times: the Error-0 stat race is transient
  ok=""
  for try in 1 2 3 4 5; do
    if nix-store -r "$p" >/dev/null 2>&1; then ok=1; break; fi
    sleep 2
  done
  [ -n "$ok" ] && echo "seeded $h" || echo "FAIL $h"
done
