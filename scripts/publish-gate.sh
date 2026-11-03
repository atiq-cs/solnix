#!/usr/bin/bash
# publish-gate.sh <store path>... -- the solnix-cache-publish skill's gate, on illumos.
# A path passes only if: deriver resolves to an existing .drv; it is not host/user
# specific; every ELF has a store-only RUNPATH and ldd (no LD_LIBRARY_PATH) resolves
# every NEEDED inside /nix/store; it names no build-host identity (uname -n, its DNS domain,
# compute.internal, GATE_HOST_STRINGS); the declared references cover every store path the
# NAR names, counting only names inside the deriver's input closure (a store-path
# string outside it, such as nix's --help examples, is text, not a dependency).
# Prints PASS/FAIL per path; exit 1 if any FAIL. --selftest proves the reference rule.
# GATE_DOF_EXEMPT=0 drops the DOF-utsname exemption below (infra protocol v2 exception E1); the aarch64 set needs none.
# Plus the out checks over the NAR stream (scripts/gate-checks.py nar, the bytes that get published): B6 every symlink
# resolves inside the out or /nix/store; B7 every bin/ sbin/ file is executable; B8 no unmapped build dir
# (/var/tmp/srcpkg- ...; the mapped /build/ is counted); B9 no #! outside the store but /bin/sh and /usr/bin/env (counted);
# B10 no timestamp-mode pyc; B13 no /usr/gnu/ /opt/ooce /opt/nixboot /usr/gcc/ /var/tmp/big string (/usr/local and
# documentation mentions WARN); B15 no host link/include dir in a recorded build config (perl Config_heavy.pl link vars,
# .pc, .la, *-config, *Config.cmake, _sysconfigdata). And the mirror of the server's NAR content gate (infra
# k8s/validate-nar-content.py; enforced for tier 1): S1 DT_RUNPATH/DT_RPATH under /nix/store or $ORIGIN, S2 PT_INTERP the
# store or the illumos ld.so.1, S3 no *.compute.internal / *.ec2.internal / solnix-builder-build (any case, files and
# symlink targets; NO DOF exemption there, unlike the host-name check above), S4 no dixi dixa dixr lixi floki as a word.
# GATE_PYTHON: a python3 >= 3.9 (a solnix host has none on PATH: a store python3).
# shortcut: the reference scan greps /nix/store/<hash>- strings in the NAR, so a reference
# written without the /nix/store/ prefix would go unseen; Nix's own scan is per-hash.

# --selftest: prove the undeclared-reference rule bites without the store. A path
# NAMED in the NAR is a violation iff it is in the deriver's input closure and not
# declared; help-text strings (outside the inputs) and declared refs are not.
if [ "${1:-}" = "--selftest" ]; then
  chk() { for n in $1; do echo "$2" | grep -qx "$n" && continue; echo "$3" | grep -qx "$n" && echo "undeclared $n"; done; }
  I=$'/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  R='/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  r1=$(chk /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$R" "$I")
  r2=$(chk /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$R" "$I")
  r3=$(chk /nix/store/cccccccccccccccccccccccccccccccc "$R" "$I")
  [ -n "$r1" ] && [ -z "$r2" ] && [ -z "$r3" ] && { echo "SELFTEST PASS"; exit 0; }
  echo "SELFTEST FAIL: [$r1] [$r2] [$r3]"; exit 1
fi

PATH=${GATE_GREP_DIR:+$GATE_GREP_DIR:}/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH
unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64 LD_LIBRARY_PATH_32
# fail closed: the host-name and reference scans need GNU grep (-a -o -b); illumos grep rejects -a, and the checks
# then passed silently (a solnix host has no /usr/gnu/bin/grep; seen on dixi 2026-11-01). There, run with
# GATE_GREP_DIR=$(nix build --print-out-paths .#gnugrep)/bin.
printf 'a\000b\n' | grep -a -b -o -F b > /dev/null 2>&1 || {
  echo "publish-gate: $(command -v grep) is not GNU grep (needs -a -b -o); set GATE_GREP_DIR to a gnugrep bin" >&2; exit 2; }
py=${GATE_PYTHON:-$(command -v python3)}
[ -n "$py" ] && "$py" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null || {
  echo "publish-gate: no python3 >= 3.9 for the out checks (set GATE_PYTHON)" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
rc=0
for p in "$@"; do
  why=""
  d=$(nix-store -q --deriver "$p" 2>/dev/null)
  case "$d" in /nix/store/*.drv) [ -e "$d" ] || why="$why deriver $d not in store;";; *) why="$why no deriver;";; esac
  case "$(basename "$p")" in *-solnix-system-*|*-etc|*-system-path|*home-manager-generation*|*home-files*) why="$why host/user-specific;";; esac
  while IFS= read -r f; do
    [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = 7f454c46 ] || continue
    elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
    rp=$(elfdump -d "$f" | awk '$2=="RUNPATH"||$2=="RPATH"{print $4}')
    for e in $(echo "$rp" | tr ':' ' '); do
      case "$e" in /nix/store/*|'$ORIGIN'*) ;; *) why="$why $f RUNPATH $e;";; esac
    done
    bad=$(ldd "$f" 2>&1 | awk '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//)' | head -2 | tr '\n' ' ')
    [ -n "$bad" ] && why="$why $f ldd: $bad;"
  done < <(find "$p" -type f)
  # the build host's own identity must not be in a published NAR (perl's Configure recorded myhostname/mydomain:
  # wave3 2026-10-30). Strings: this host's name and DNS domain, and the EC2 internal domain; GATE_HOST_STRINGS adds more.
  hs="$(uname -n) $(sed -n 's/^domain[[:space:]]*//p; s/^search[[:space:]]*//p' /etc/resolv.conf 2>/dev/null) compute.internal ${GATE_HOST_STRINGS:-}"
  for h in $hs; do
    [ ${#h} -ge 6 ] || continue   # too short to mean a host (e.g. "local")
    n=$(nix-store --dump "$p" 2>/dev/null | grep -a -o -F -- "$h" | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] || continue
    # Exempt ONLY a hit that is the nodename of a DTrace DOF utsname record: inside an ELF's .SUNW_dof section, with the
    # sysname "SunOS\0" 257 bytes before it (struct utsname, 257-byte fields). `dtrace -G` wrote the illumos-gate build
    # machine's name there (solnix-builder-build, the generic OI build-host image name); the gate proto and served libc carry it.
    # Every other hit FAILs: free text, a non-ELF file, outside .SUNW_dof, no SunOS record, a file name or symlink target
    # (the dump's count must equal the exempt count).
    ex=0; where=""
    while IFS= read -r f; do
      offs=$(grep -a -b -o -F -- "$h" "$f" | cut -d: -f1); [ -n "$offs" ] || continue
      doff=""; dsz=""
      read -r doff dsz < <(elfdump -c "$f" 2>/dev/null | awk '/sh_name: \.SUNW_dof$/ {d=1; next} d && /sh_size:/ {sz=$2} d && /sh_offset:/ {print $2, sz; exit}')
      for o in $offs; do
        if [ "${GATE_DOF_EXEMPT:-1}" = 1 ] && [ -n "$dsz" ] && [ "$o" -ge $((doff)) ] && [ $((o + ${#h})) -le $((doff + dsz)) ] && [ "$o" -ge 257 ] &&
           [ "$(dd if="$f" bs=1 skip=$((o - 257)) count=6 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 53756e4f5300 ]; then
          ex=$((ex + 1))
        else [ -n "$where" ] || where="${f#$p/} @$o"; fi
      done
    done < <(find "$p" -type f)
    [ "$ex" = "$n" ] || why="$why names the build host ($h in ${where:-a file name or symlink target});"
  done
  refs=$(nix-store -q --references "$p" | sort -u)
  named=$(nix-store --dump "$p" | grep -a -o -E '/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]+' | cut -c1-44 | sort -u)
  # A reference is a path the build could see: Nix scans the output only for the
  # hashes of the derivation's input closure. A store-path string outside that
  # closure (nix's own --help examples: /nix/store/0i2jd...-hello-2.10) is text,
  # not a dependency, and upstream nix ships the same strings. Flag a named path
  # only if it is in the input closure and was NOT declared.
  drv=$(nix-store -q --deriver "$p")
  inputs=$(nix-store -qR "$drv" 2>/dev/null | cut -c1-44 | sort -u)
  for n in $named; do
    echo "$refs" | grep -q "^$n" && continue
    echo "$inputs" | grep -qx "$n" && why="$why undeclared ref $n;"
  done
  # the out checks B6-B13 over the NAR (FAIL lines fail the gate; WARN/INFO are printed for the record)
  outc=$("$py" "$here/gate-checks.py" nar "$p" 2>&1); oc=$?
  echo "$outc" | grep -E '^(WARN|INFO) ' | cut -c1-300 | sed 's/^/  /'
  [ $oc = 0 ] || why="$why $(echo "$outc" | grep -E '^FAIL B' | head -6 | sed "s|^FAIL \(B[0-9]*-[a-z]*\) $p: |\1 |" | tr '\n' ';')"
  if [ -z "$why" ]; then echo "PASS $p ($(echo "$refs" | grep -c . ) refs)"; else echo "FAIL $p:$why" | cut -c1-1200; rc=1; fi
done
exit $rc
