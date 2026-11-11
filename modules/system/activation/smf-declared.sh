#!/bin/sh
# smf-declared -- the toplevel's declared SMF state wins over the state the repository kept, as on NixOS, where a unit's
# state is the generation's: /etc/systemd/system comes from the store, `systemctl disable` of a declared unit cannot
# persist, and only runtime changes (`--runtime`, gone at reboot) can.
#
#   smf-declared <declared-list> [<profile>...]
#     <declared-list>  one "<fmri> true|false" line per smf.services instance of the toplevel (its enable)
#     <profile>        a profile's path as booted (/etc/svc/profile/site/solnix.xml): forget its hash, so the next
#                      manifest-import applies it again
#   live: activate runs it after the import (and applies the site profile itself). Offline, on a cloned BE's repository
#   (install-be): SVCCFG_REPOSITORY=<repo> SVCCFG_CONFIGD_PATH=<svc.configd> SVCCFG=<svccfg>. SMF_DECLARED_DRY=1 only logs.
#
# illumos SMF has no admin layer to delete: Solaris 11's svccfg listcust/delcust came after the fork, and illumos svccfg
# has neither (lixi, 2026-11-11: "Unknown command"). `svcadm enable/disable` writes general/enabled into the repository,
# `svccfg setprop/setenv` the property itself, and a beadm clone copies the repository. Then nothing the new generation
# declares replaces them:
#  - manifest-import never re-applies a profile it holds a hash for, whatever the file now says (manifest_hash.c
#    mhash_test_file: "we do not reread a profile"), so a new site profile's enables never land on a cloned BE;
#  - import never changes general/enabled of an existing instance, and keeps the current value of a property that
#    differs from the last import ("Conflict upgrading ... has different values": site/solnix-builder on lixi kept an
#    old BUILDER_GATES store path across generations).
# So, per declared instance that exists: log what differs from its last-import snapshot (the manifest the toplevel
# ships), `svccfg revert last-import`, set general/enabled to the declaration, refresh. revert skips NONPERSISTENT
# property groups (svccfg_libscf.c lscf_revert), so general_ovr, i.e. `svcadm disable -t`, lasts until reboot as a
# --runtime change does. The state before the revert is the instance's "previous" snapshot. Undeclared services are
# not touched, except as the site profile names them.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:$PATH
LIST=${1:?usage: smf-declared <declared-list> [<profile>...]}
shift
SVCCFG=${SVCCFG:-/usr/sbin/svccfg}
unset SVCCFG_CHECKHASH
T=$(mktemp -d /tmp/smf-declared.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT
say() { echo "smf-declared: $*"; }
rc=0

# persistent properties and groups of an instance and its service, one per line; general/enabled is handled apart.
props() {   # $1 = instance fmri, $2 = snapshot name, or "" for the editing view
  if [ -n "$2" ]; then printf 'select %s\nselectsnap %s\nlistprop\nunselect\nlistprop\n' "$1" "$2"
  else printf 'select %s\nlistprop\nselect %s\nlistprop\n' "$1" "${1%:*}"; fi | "$SVCCFG" 2>/dev/null |
    awk '{ g = $1; sub(/\/.*/, "", g) }
         $1 !~ /\// { np[g] = ($NF == "NONPERSISTENT") }
         np[g] || $1 == "general/enabled" { next }
         { $1 = $1; print }' | sort
}

while read -r fmri want; do
  case "$fmri" in svc:/*:*) ;; *) continue ;; esac
  case "$want" in true|false) ;; *) say "bad line for $fmri: '$want'" >&2; rc=1; continue ;; esac
  # not in the repository yet: its import creates it as declared
  "$SVCCFG" -s "$fmri" listpg >/dev/null 2>&1 </dev/null || continue
  rev=""
  if "$SVCCFG" -s "$fmri" listsnap 2>/dev/null </dev/null | grep -x last-import >/dev/null; then
    props "$fmri" "" > "$T/cur"; props "$fmri" last-import > "$T/li"
    [ -s "$T/li" ] || { say "FAILED to read the last-import snapshot of $fmri" >&2; rc=1; continue; }
    if ! cmp -s "$T/cur" "$T/li"; then
      comm -23 "$T/cur" "$T/li" | sed "s|^|smf-declared: $fmri: drop |"
      comm -13 "$T/cur" "$T/li" | sed "s|^|smf-declared: $fmri: back |"
      rev="revert last-import"
    fi
  else
    say "$fmri: no last-import snapshot, its properties are left as they are"
  fi
  cur=$("$SVCCFG" -s "$fmri" listprop general/enabled 2>/dev/null </dev/null | awk '{print $3}')
  [ "$cur" = "$want" ] || say "$fmri: general/enabled ${cur:-unset} -> $want"
  [ -n "$rev" ] || [ "$cur" != "$want" ] || continue
  [ -z "${SMF_DECLARED_DRY:-}" ] || continue
  # one session: revert drops general/enabled (last-import never has it), setprop puts the declared value back.
  { echo "select $fmri"; [ -z "$rev" ] || echo "$rev"; echo "setprop general/enabled = boolean: $want"; echo refresh; } \
    | "$SVCCFG" || { say "FAILED on $fmri" >&2; rc=1; }
done < "$LIST"

# manifest-import keys a profile's hash by its path (manifest_hash.c mhash_filename_to_propname: no leading /, every
# character but [A-Za-z0-9_-] becomes _). With no hash it reads the file again, as on a fresh install.
for p in "$@"; do
  pg=$(echo "${p#/}" | sed 's/[^A-Za-z0-9_-]/_/g')
  "$SVCCFG" -s smf/manifest listpg "$pg" 2>/dev/null </dev/null | grep "^$pg " >/dev/null || continue
  say "$p: forget its hash ($pg), manifest-import applies it again"
  [ -n "${SMF_DECLARED_DRY:-}" ] || "$SVCCFG" -s smf/manifest delpg "$pg" </dev/null || { say "FAILED to delete $pg" >&2; rc=1; }
done
exit $rc
