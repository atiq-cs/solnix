#!/usr/bin/env bash
# oi-build-host-setup.sh — run ON the OpenIndiana build host (as root) to install
# the illumos-gate build prerequisites. Idempotent-ish.
#
# Captures the hard-won fixes from the first run:
#  - The image's incorporations lag the Hipster catalog, so `pkg update` first
#    (advances them; creates a new BE; REBOOT before running this).
#  - pkg.openindiana.org redirects http->https and the AWS->mirror (Hetzner) path
#    is heavily shaped (~30s/request). Use HTTPS origin + raised pkg timeouts, or
#    the whole install framework-stalls.
#  - MTU clamped to 1400 on the NIC (metadata-shim does this at boot) to keep
#    fetches from black-holing.
#  - `build-essential` metapackage is rejected by incorporations; install the
#    concrete packages. gcc-10 is primary; gcc-14 (shadow) is optional — we
#    disable the shadow compiler in the env file instead.
set -euo pipefail

echo "=== HTTPS-only publisher (avoid the 308 redirect stall) ==="
pkg set-publisher -G '*' -g https://pkg.openindiana.org/hipster/ openindiana.org

echo "=== install gate build prerequisites (raised timeouts for the slow mirror) ==="
env PKG_CLIENT_CONNECT_TIMEOUT=60 \
    PKG_CLIENT_LOWSPEED_TIMEOUT=180 \
    PKG_CLIENT_MAX_CONSECUTIVE_ERROR=10 \
    PKG_CLIENT_MAX_TIMEOUT=20 \
  pkg install -v \
    developer/gcc-10 \
    developer/build/onbld \
    developer/build/gnu-make \
    developer/lexer/flex \
    developer/parser/bison-38 \
    developer/versioning/git

echo "=== verify ==="
/usr/gcc/10/bin/gcc --version | head -1
ls /opt/onbld/bin/nightly /opt/onbld/bin/bldenv
ls /opt/onbld/bin/i386/ctfconvert /opt/onbld/bin/i386/ctfmerge
git --version
echo "prerequisites OK"
