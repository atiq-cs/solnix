#!/usr/bin/env bash
# test-gate.sh -- every negative control of the cache publish gate, no store or network needed (run on floki, dixi, chef):
#   gate-checks.py selftest  drv A1-A4 (28 crafted .drvs incl. the exemptions both ways), NAR out checks B6-B13 (crafted
#                            NARs incl. a corrupt one and a minimal ELF), store form B5/B11 (a real temp tree), closure
#                            B12 (the not-for-cache list), the stamp key
#   publish-gate.sh --selftest  the undeclared-reference rule
#   cache-submit.py             --stamps: no stamp / wrong NarHash / wrong path -> NO-STAMP; a matching stamp gets past
#                               it to the drv-gate --leaf hook, which refuses a narinfo without a Deriver (DRV-GATE-FAIL);
#                               --submit as a host builder id without --stamps is refused
# Exit 0 iff every control behaves. A control that cannot fail is reported as BAD.
set -u
export PYTHONDONTWRITEBYTECODE=1   # no __pycache__ in the checkout
here=$(cd "$(dirname "$0")" && pwd)
py=${GATE_PYTHON:-$(command -v python3)}
rc=0
echo "== gate-checks.py selftest"; "$py" "$here/gate-checks.py" selftest > /tmp/test-gate.$$ 2>&1 || rc=1
grep -c '^ok ' /tmp/test-gate.$$ | sed 's/^/   ok controls: /'; grep -v '^ok ' /tmp/test-gate.$$; rm -f /tmp/test-gate.$$
echo "== publish-gate.sh --selftest"; bash "$here/publish-gate.sh" --selftest || rc=1
echo "== cache-submit.py --stamps interlock"
T=$(mktemp -d "${TMPDIR:-/tmp}/test-gate.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/c/nar" "$T/st"
# a one-file NAR and its narinfo, built here (no store): the planner re-hashes it, so the hashes must be real
GATE_HERE=$here "$py" - "$T" <<'EOF' || rc=1
import hashlib, lzma, os, sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("gc", os.path.join(os.environ["GATE_HERE"], "gate-checks.py"))
gc = importlib.util.module_from_spec(spec); spec.loader.exec_module(gc)
nar = gc.nar_bytes({"type": "reg", "exec": False, "data": b"hello\n"})
xz = lzma.compress(nar, format=lzma.FORMAT_XZ)
fh = gc.nix32(hashlib.sha256(xz).digest()); nh = gc.nix32(hashlib.sha256(nar).digest())
sp = "/nix/store/" + "a" * 32 + "-gate-test"
open(f"{T}/c/nar/{fh}.nar.xz", "wb").write(xz)
open(f"{T}/c/{'a' * 32}.narinfo", "w").write(f"StorePath: {sp}\nURL: nar/{fh}.nar.xz\nCompression: xz\nFileHash: sha256:{fh}\n"
    f"FileSize: {len(xz)}\nNarHash: sha256:{nh}\nNarSize: {len(nar)}\nReferences: \n")
open(f"{T}/p", "w").write(sp + "\n")
open(f"{T}/r.tsv", "w").write("pname\tversion\turl\tsha256\tbuildsys\tdeps\tflags\tsystem\tout\tdebug\n"
    f"t\t1\tu\ts\tb\t\t\tx86_64-solaris\t{sp}\t\n")
open(f"{T}/nh", "w").write(f"sha256:{nh}")
EOF
sp=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-gate-test; nh=$(cat "$T/nh"); k=${nh#sha256:}
plan() { "$py" "$here/cache-submit.py" --cache-dir "$T/c" --paths "$T/p" --recipes "$T/r.tsv" --stamps "$T/st" 2>&1 | awk -v p="$sp" '$2==p && $1 !~ /^(DRY-RUN|SUBMIT|StorePath:)$/{print $1}'; }
chk() { local want=$1 label=$2 got; got=$(plan); if [ "$got" = "$want" ]; then echo "ok  $label: $got"; else echo "BAD $label: $got (want $want)"; rc=1; fi; }
chk NO-STAMP "no stamp"
printf '%s\t%s\tt\th\n' "$sp" "sha256:0000000000000000000000000000000000000000000000000000" > "$T/st/$k.ok"; chk NO-STAMP "stamp with another NarHash"
printf '%s\t%s\tt\th\n' "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-gate-test" "$nh" > "$T/st/$k.ok"; chk NO-STAMP "stamp naming another path"
printf '%s\t%s\tt\th\n' "$sp" "$nh" > "$T/st/$k.ok"
chk DRV-GATE-FAIL "matching stamp: past the interlock, then the drv-gate --leaf hook refuses a narinfo without a Deriver"
out=$("$py" "$here/cache-submit.py" --cache-dir "$T/c" --paths "$T/p" --submit 2>&1); case "$out" in
  *"need"*) echo "ok  --submit without --key refused";; *) echo "BAD --submit ran: $out"; rc=1;; esac
if command -v ssh-keygen > /dev/null; then
  ssh-keygen -q -t ed25519 -N '' -f "$T/k" > /dev/null 2>&1 && chmod 600 "$T/k"
  out=$("$py" "$here/cache-submit.py" --cache-dir "$T/c" --paths "$T/p" --submit --key "$T/k" --builder dixi 2>&1); case "$out" in
    *"needs --stamps"*) echo "ok  --submit as host builder dixi without --stamps refused";; *) echo "BAD host --submit without stamps: $out"; rc=1;; esac
else echo "SKIP host-builder --stamps control: no ssh-keygen here (not counted as a pass)"; fi
echo "== test-gate: $([ $rc = 0 ] && echo PASS || echo FAIL)"
exit $rc
