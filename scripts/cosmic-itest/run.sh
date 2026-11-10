#!/usr/bin/bash
# cosmic-itest: run the COSMIC-on-illumos integration checks (docs/cosmic-illumos-integration-tests.md) on a solnix desktop.
#   run.sh [t0] [--negctl]   (t1/t2: session tiers, see the doc; not in this file yet)
# --negctl re-runs tier-0 checks against the store paths that still have each fixed defect and expects every one to FAIL:
# a check that cannot fail is not a check. The paths are lixi's (2026-11-01); a host without them reports SKIP.
D=$(dirname "$0"); out=/var/tmp/cosmic-itest; mkdir -p $out; J=$out/$(date -u +%Y%m%dT%H%M%SZ).json
ITEST_JSON=$J bash $D/t0.sh; rc=$?
if [ "$1" = --negctl ] || [ "$2" = --negctl ]; then
  n=0 ok=0
  neg() { n=$((n+1)); env "$1=$2" bash $D/t0.sh 2>/dev/null | grep -E "^FAIL +$3 " > /dev/null && { ok=$((ok+1)); echo "negctl ok   $3 fails on $2"; } || echo "negctl MISS $3 did not fail on $2"; }
  k() { ls -d /nix/store/$1*-illumos-kernel-gpu 2>/dev/null | head -1; }
  [ -n "$(k ixi2vsij)" ] && neg ITEST_I915 "$(k ixi2vsij)/kernel/drv/amd64/i915" i915-intr-barrier          # pre-4dfacc1 (MSI toggle)
  [ -n "$(k 01mp92bd)" ] && neg ITEST_I915 "$(k 01mp92bd)/kernel/drv/amd64/i915" i915-errno-etime           # pre-b46be77 (ETIME = 145)
  a=$(ls -d /nix/store/3danjnp8*-cosmic-applets* 2>/dev/null | head -1); [ -n "$a" ] && neg ITEST_POLLING_BINS "$a/libexec/cosmic-applets" polling-epoll  # pre-73c4cf7
  p=/nix/store/mj98i4x43h07h3na5a604ss5909rdmaq-pop-launcher-1.5.0/bin/pop-launcher; [ -x $p ] && neg ITEST_POPLAUNCHER $p mimalloc-pop-launcher  # pre-72f6a23
  # help1: a share dir with no man: handler, and a plugin.ron whose bin does not exist
  e=$(mktemp -d /tmp/itest-help.XXXXXX); mkdir -p "$e/applications"; printf '(\n    bin: (path: "%s/none"),\n)\n' "$e" > "$e/plugin.ron"
  neg ITEST_HELP_SHARE "$e" help-man-uri; neg ITEST_HELP_PLUGIN "$e/plugin.ron" help-launcher-man; find "$e" -depth -delete
  neg ITEST_LOGINDEFS /nonexistent users-uid-range   # no /etc/login.defs: COSMIC's 1000..60000 fallback (pre-desk1)
  echo "cosmic-itest negctl: $ok of $n failed as expected"; [ $ok -eq $n ] || rc=1
fi
echo "results: $J"; exit $rc
