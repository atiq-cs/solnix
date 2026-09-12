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
      developer/versioning/git \
      developer/versioning/patch \
      text/texinfo \
      developer/object-file

# FIVE host prereqs an aarch64 gate build needs that were absent here, each found
# the expensive way -- the build printed FAILED and the cause was a missing host
# tool rather than the port:
#   patch(1)          arm64-gate applies patches during `make download`
#   makeinfo/texinfo  gcc doc targets
#   astdev / msgcc    ⚠️ WITHOUT IT every libast .mso target dies Error 127 and the
#                     CHECK phase fails -- while uts/ has ALREADY staged a good
#                     unix + genunix into proto. So "nightly FAILED" did NOT mean
#                     the kernel failed. Inspect the proto on disk before
#                     believing the summary line.
#   illumos-closed    ON_CLOSED_BINS
#   u-boot / dtc      image assembly
# msgcc comes from onbld's own ast tree rather than a separately-named package, so
# it is gated rather than installed: fail loudly here instead of at the check phase.
if [ ! -x /usr/ast/bin/msgcc ] && [ ! -x /opt/onbld/bin/msgcc ]; then
  echo "WARN: no msgcc -- libast .mso targets will die Error 127 and the gate will" >&2
  echo "      report FAILED even when unix/genunix built fine. Check proto on disk." >&2
fi

# JDK for the gate's build tools (provides /usr/java/bin/javac)
[ -x /usr/java/bin/javac ] || pkg install -v developer/java/openjdk8

# Build-dependency headers the gate needs but the cloud image lacks. Missing
# these causes late link failures (fatal: <header>.h: No such file) that cascade
# into a collect2 storm. Install ALL of these up front:
#   - idnkit headers      -> usr/src/lib/libc utf-8 iconv (idn/api.h)
#   - mozilla-nss/nspr    -> mps/{nss,ssl,cert}.h for lib/ldap/ssldap, nsswitch
#   - cups (full pkg)     -> cups/cups.h for smbsrv smbd_spool
env PKG_CLIENT_CONNECT_TIMEOUT=60 PKG_CLIENT_LOWSPEED_TIMEOUT=180 \
  pkg install -v \
    library/idnkit library/idnkit/header-idnkit \
    system/library/mozilla-nss/header-nss library/nspr/header-nspr \
    print/cups

echo "=== verify ==="
/usr/gcc/10/bin/gcc --version | head -1
ls /opt/onbld/bin/nightly /opt/onbld/bin/bldenv
ls /opt/onbld/bin/i386/ctfconvert /opt/onbld/bin/i386/ctfmerge
git --version
echo "prerequisites OK"
