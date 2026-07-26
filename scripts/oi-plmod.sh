#!/usr/bin/env bash
# oi-plmod.sh — build Perl modules from CPAN tarballs against a cached solnix
# perl, register each as a Nix store path, verify it loads. Runs ON a builder.
# Anti-wedge: launched detached via oi-job.
#
#   oi-plmod.sh <perl-bin> <Module::Name>=<tarball-url> [more...]
#
# Uses `perl Makefile.PL INSTALL_BASE` (installs to $prefix/lib/perl5). For the
# handful with Build.PL only, falls back to `perl Build.PL`.
# Output: RESULT<TAB>Module::Name<TAB>OK|FAIL<TAB>storepath|reason
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
GCC=/nix/store/1sif429w2gpwzxcjqljb481anq0y7wh2-illumos-gcc14
CCBIN="$GCC/usr/gcc/14/bin/gcc"
export CC="$CCBIN"
# A python is handy for clean pax tar extraction (illumos /usr/bin/tar mangles
# pax 'x' typeflags into PaxHeaders/ junk that breaks Makefile.PL globbing).
PYX=/nix/store/63f9kp8ixyw0mq18fhmk4zj2j0lv6fcw-solnix-python-39-3.9.20/bin/python3.9
[ -x "$PYX" ] || PYX=/nix/store/kvl140jbk20aqiq9qqrr79vvwv7hnsaf-solnix-python-313-3.13.1/bin/python3.13

PERL="$1"; shift
# Shared @INC across this batch: each module we install is prepended to
# PERL5LIB so later modules in the batch see it at build+test time (lightweight
# fixpoint for intra-batch deps like JSON::XS->common::sense). Order your specs
# deps-first. Cross-batch deps: publish + they resolve from the cache next time.
BATCHLIB=""
for spec in "$@"; do
  mod="${spec%%=*}"; url="${spec#*=}"
  safe=$(printf '%s' "$mod" | tr 'A-Z:' 'a-z-' | tr -s '-')
  w=$(mktemp -d "/var/tmp/plmod.$safe.XXXXXX")
  tb="$w/src.tar.gz"
  if ! curl -fsSL -o "$tb" "$url" 2>"$w/.dl.log"; then
    echo "RESULT	$mod	FAIL	download"; continue
  fi
  ( cd "$w" && "$PYX" -c "import tarfile,sys;tarfile.open(sys.argv[1]).extractall(sys.argv[2])" "$tb" "$w" ) 2>/dev/null \
    || ( cd "$w" && gzip -dc "$tb" | tar xf - ) 2>/dev/null
  # pick the extracted source dir that actually has a build script (skip the
  # PaxHeaders/ pseudo-dir GNU tar may materialise from pax extended headers).
  srcd=""
  for cand in "$w"/*/; do
    cand="${cand%/}"
    case "$cand" in *PaxHeaders*) continue;; esac
    if [ -f "$cand/Makefile.PL" ] || [ -f "$cand/Build.PL" ]; then srcd="$cand"; break; fi
  done
  [ -n "$srcd" ] || { echo "RESULT	$mod	FAIL	untar/no-build-script"; continue; }
  pfx="$w/inst"; mkdir -p "$pfx"
  log="$w/.build.log"
  (
    cd "$srcd"
    export PERL5LIB="$BATCHLIB${BATCHLIB:+:}${PERL5LIB:-}"
    if [ -f Makefile.PL ]; then
      "$PERL" Makefile.PL INSTALL_BASE="$pfx" CC="$CCBIN" LD="$CCBIN" \
        OPTIMIZE="-m64 -fPIC -O2" \
        && gmake -j"$(nproc)" CC="$CCBIN" && gmake install
    elif [ -f Build.PL ]; then
      "$PERL" Build.PL --install_base "$pfx" --config cc="$CCBIN" --config ld="$CCBIN" \
        && "$PERL" ./Build && "$PERL" ./Build install
    else
      echo "no Makefile.PL/Build.PL"; exit 1
    fi
  ) >"$log" 2>&1
  if [ $? -ne 0 ]; then
    echo "RESULT	$mod	FAIL	build (see $log)"; tail -3 "$log" | sed 's/^/  /'; continue
  fi
  ver=$(find "$srcd" -maxdepth 1 -name META.json -o -maxdepth 1 -name META.yml 2>/dev/null | head -1)
  v=$(basename "$srcd" | sed 's/^[A-Za-z:_-]*-//')
  named="/var/tmp/solnix-perl542-${safe}-${v:-0}"
  [ -e "$named" ] && named="$named.$$"
  cp -a "$pfx" "$named"
  sp=$(nix-store --add "$named" 2>/dev/null)
  [ -n "$sp" ] || { echo "RESULT	$mod	FAIL	nix-store-add"; continue; }
  # make this module visible to later modules in the batch
  for d in "$sp"/lib/perl5 "$sp"/lib/perl5/*-solaris*; do
    [ -d "$d" ] && BATCHLIB="$d${BATCHLIB:+:}$BATCHLIB"
  done
  # verify load: own dirs + everything built earlier in this batch (BATCHLIB)
  inc=$(find "$sp/lib/perl5" -maxdepth 1 -type d 2>/dev/null | sed 's/^/-I/' | tr '\n' ' ')
  incarch=$(find "$sp/lib/perl5" -maxdepth 2 -type d -name '*-solaris*' 2>/dev/null | sed 's/^/-I/' | tr '\n' ' ')
  batchinc=$(printf '%s' "$BATCHLIB" | tr ':' '\n' | sed 's/^/-I/' | tr '\n' ' ')
  if "$PERL" $inc $incarch $batchinc -e "require ${mod}; print \"ok\\n\"" >/dev/null 2>&1; then
    echo "RESULT	$mod	OK	$sp"
  else
    err=$("$PERL" $inc $incarch $batchinc -e "require ${mod};" 2>&1 | head -1)
    echo "RESULT	$mod	FAIL	load: $err (built at $sp)"
  fi
done
echo "=== oi-plmod done ==="
