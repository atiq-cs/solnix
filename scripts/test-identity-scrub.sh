#!/usr/bin/env bash
# test-identity-scrub.sh -- oi-make-raw-img.sh's identity-free scrub strips the build
# host's personal accounts but keeps every account the toplevel declares (nixbld1..32,
# uid 30001..). The 26.11 DP AMI shipped without them: nix's build-users-group had no users.
set -u
S=${1:-$(dirname "$0")/oi-make-raw-img.sh}
W=$(mktemp -d /tmp/scrub.XXXXXX); trap 'find "$W" -mindepth 1 -delete; rmdir "$W"' EXIT
eval "$(awk '/^scrub_names\(\) \{/,/^\}/' "$S")"
type scrub_names >/dev/null 2>&1 || { echo "FAIL: no scrub_names() in $S"; exit 1; }
printf 'root:x:0:0::/root:/bin/sh\nnixbld1:x:30001:30000::/var/empty:/bin/false\n' > "$W/tl"
printf 'root:x:0:0::/root:/bin/sh\nnobody4:x:65534:65534::/:\njdoe:x:1000:10::/home/jdoe:/bin/sh\nnixbld1:x:30001:30000::/var/empty:/bin/false\n' > "$W/be"
bad=0
t() { local got; got=$(scrub_names "$W/be" "$1" | tr '\n' ' '); [ "$got" = "$2" ] && echo "ok: $3 -> '$got'" || { echo "FAIL: $3: want '$2', got '$got'"; bad=1; }; }
t "$W/tl" "jdoe " "declared nixbld1 kept, personal jdoe stripped"
# negative control: a toplevel that declares nothing (the old rule) strips nixbld1 too
: > "$W/empty"; t "$W/empty" "jdoe nixbld1 " "empty toplevel passwd strips all uid>=1000"
t "$W/missing" "jdoe nixbld1 " "missing toplevel passwd strips all uid>=1000 (never strips nothing)"
exit $bad
