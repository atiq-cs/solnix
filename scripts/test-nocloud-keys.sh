#!/usr/bin/env bash
# test-nocloud-keys.sh [script]: solnix-ec2-first-boot.sh's NoCloud user-data reader (nocloud_keys), extracted from the
# real script and run on crafted user-data: which public keys it takes, and that it takes nothing else. Runs anywhere
# (awk, grep, head). The seed-volume search and the install are exercised on illumos (lofi cidata ISOs, KVM).
set -u
S=${1:-$(dirname "$0")/solnix-ec2-first-boot.sh}
W=$(mktemp -d); trap 'find "$W" -mindepth 1 -delete; rmdir "$W"' EXIT
eval "$(awk '/^nocloud_keys\(\) \{/,/^\}/' "$S")"
type nocloud_keys >/dev/null 2>&1 || { echo "FAIL  nocloud_keys not found in $S"; exit 1; }
K1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA one@x'
K2='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 two@y'
bad=0
t() { # t <name> <want: comment fields, ;-joined> <user-data printf format> [args]
  local n=$1 want=$2 fmt=$3; shift 3
  printf "$fmt" "$@" > "$W/ud"; local got; got=$(nocloud_keys "$W/ud" 2>/dev/null | awk '{print $NF}' | tr '\n' ';')
  if [ "$got" = "$want" ]; then echo "PASS  $n -> ${got:-none}"; else echo "FAIL  $n: want '${want:-none}', got '${got:-none}'"; bad=1; fi
}
t "top-level list, plain and quoted"   "one@x;two@y;" '#cloud-config\nssh_authorized_keys:\n  - %s\n  - "%s"\n' "$K1" "$K2"
t "runcmd and write_files are not read" "one@x;" '#cloud-config\nruncmd:\n  - %s\nssh_authorized_keys:\n  - %s\nwrite_files:\n  - path: /x\n' "$K2" "$K1"
t "users[]: root's keys only"          "one@x;" '#cloud-config\nusers:\n  - default\n  - name: root\n    ssh_authorized_keys:\n      - %s\n  - name: alice\n    ssh_authorized_keys:\n      - %s\n' "$K1" "$K2"
t "not #cloud-config: nothing"          ""       '#!/bin/sh\necho %s\n' "$K1"
t "malformed: nothing"                  ""       '#cloud-config\nssh_authorized_keys: [ unclosed\n  - not-a-key\n'
t "a non-key list item is dropped"      "two@y;" '#cloud-config\nssh_authorized_keys:\n  - "ssh-ed25519 AAAA; touch /tmp/x"\n  - %s\n' "$K2"
[ $bad = 0 ] && echo "ALL NOCLOUD CHECKS PASS" || { echo "NOCLOUD CHECKS FAILED"; exit 1; }
