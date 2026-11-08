#!/usr/bin/bash
# world-links.sh <out> -- part 2 of the system world's fixups (mk-proto-world.nix fixups = true): symlinks and #! lines.
# Env: dropArg (mk-proto-world's dropUnloadable, already deleted by the caller).
set -eu
o=$1; cd "$o"
# lexical resolution of a relative link inside the out: prints the out-relative path, or "^" if it climbs out of the out
lex() { awk -v p="$(dirname "$1")/$2" 'BEGIN{n=split(p,a,"/"); k=0; for(i=1;i<=n;i++){ if(a[i]==""||a[i]==".") continue;
  if(a[i]==".."){ if(k==0){print "^"; exit} k--; continue } s[++k]=a[i] } r=""; for(i=1;i<=k;i++) r=r (i>1?"/":"") s[i]; print r}'; }
rl() { ls -ld "$1" 2>/dev/null | sed -n 's/.* -> //p'; }   # readlink(1): GNU only, a solnix host has none
dangling() { find . -type l | sed 's|^\./||' | while read -r l; do [ -e "$l" ] || echo "$l"; done; }
# 1. links to objects dropUnloadable deleted (libhal*.so, libpolkit*, libfmd_snmp.so, pkinit.so, pkcs11_tpm.so, rmumount, newaliases,
# and link_flat's lib-32/lib-64 entries): delete them, to a fixpoint (a link to a deleted link goes too).
printf '%s\n' $dropArg > "$o/.world/gone"
while :; do n=0
  for l in $(dangling); do t=$(rl "$l")
    case "$t" in "$o"/*) r=${t#"$o"/};; /*) continue;; *) r=$(lex "$l" "$t");; esac
    grep -qxF "$r" "$o/.world/gone" || continue
    rm -f "$l"; echo "$l" >> "$o/.world/gone"; n=$((n + 1))
  done; [ "$n" = 0 ] && break; done
rm -f "$o/.world/gone"
# 2. the gate's root-relative links (usr/mail -> ../var/mail, usr/man -> share/man, usr/lib/fs/ufs/mount -> ../../../../etc/fs/ufs/mount,
# usr/lib/cron -> ../../etc/cron.d, usr/share/lib/fonts -> ../../../boot/fonts): they resolve against a root, never inside the
# store path, where they dangle (gate B6). Recorded for activation (install-be.sh makes them in the BE), then removed.
: > .world/rootlinks
for l in $(dangling); do t=$(rl "$l")
  case "$t" in /*) echo "FATAL: world: absolute dangling link $l -> $t" >&2; exit 1;; esac
  printf '%s\t%s\n' "$l" "$t" >> .world/rootlinks; rm -f "$l"
done
LC_ALL=C sort -o .world/rootlinks .world/rootlinks
[ -z "$(dangling | head -1)" ] || { echo "FATAL: world: dangling links left:" >&2; dangling | head >&2; exit 1; }
# 3. #! of executables: an absolute host interpreter becomes the world's own copy of it (the same binary, a self-reference: no
# closure change; NixOS patchShebangs). perl and bash are not in the world (perl depends on the world): #!/usr/bin/env <x>, the
# gate's portable form; a perl switch (-w) cannot ride on an env line, so it is dropped (warnings only).
find . -type f -perm -u+x | while read -r f; do
  [ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ] || continue
  set -- $(head -1 "$f" | sed 's/^#![[:space:]]*//'); i=${1:-}; shift || :
  case "$i" in /bin/sh|/usr/bin/sh|/usr/bin/env|/nix/store/*|'') continue;; esac
  case "$i" in
    /usr/perl5/bin/perl|/usr/bin/perl|/bin/perl) new="/usr/bin/env perl";;
    /bin/bash|/usr/bin/bash) new="/usr/bin/env bash";;
    /bin/*) [ -e "usr$i" ] && new="$o/usr$i${1:+ $*}" || { echo "FATAL: world: $f #!$i not in the world" >&2; exit 1; };;
    /*) [ -e ".$i" ] && new="$o$i${1:+ $*}" || { echo "FATAL: world: $f #!$i not in the world" >&2; exit 1; };;
    *) continue;;
  esac
  chmod u+w "$f"; { printf '#!%s\n' "$new"; tail -n +2 "$f"; } > .world/sb && cat .world/sb > "$f"
done
rm -f .world/sb
bad=$(find . -type f -perm -u+x | while read -r f; do [ "$(head -c 2 "$f")" = '#!' ] || continue
  i=$(head -1 "$f" | sed 's/^#![[:space:]]*//; s/[[:space:]].*//'); case "$i" in /bin/sh|/usr/bin/sh|/usr/bin/env|"$o"/*) ;; /*) echo "$f #!$i";; esac; done)
[ -z "$bad" ] || { echo "FATAL: world: host #! left:" >&2; echo "$bad" | head >&2; exit 1; }
# the long #! (a store path) is exec'able: one script through the world's own sh (illumos intp: the #! line is read whole)
printf '#!%s/sbin/sh\necho world-sb-ok\n' "$o" > "$TMPDIR/sbt"; chmod +x "$TMPDIR/sbt"
[ "$("$TMPDIR/sbt")" = world-sb-ok ] || { echo "FATAL: world: a store-path #! did not run" >&2; exit 1; }
echo "=== world-links: $(wc -l < .world/rootlinks | tr -d ' ') root links recorded, no dangling link, no host #! ===" >&2
