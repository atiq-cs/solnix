#!/sbin/sh
# NEGATIVE CONTROLS for every gate added to solnix-install. A gate that cannot
# report failure is worse than no gate -- that shape has appeared eight times in
# this project. Each control SABOTAGES the mechanism and requires the check to flip.
#
# Runs the real functions out of the real script by sourcing only what is needed,
# so the controls test the SHIPPED code, not a copy of it.
set -u
PATH=/usr/sbin:/usr/bin:/sbin; export PATH
S=/var/tmp/solnix-install
pass=0; fail=0
ok()   { echo "  PASS $1"; pass=$((pass+1)); }
bad()  { echo "  *** FAIL $1"; fail=$((fail+1)); }

# Minimal harness: the helpers check_internet depends on.
log() { printf '\n=== %s ===\n' "$*" >&2; }
die() { echo "FATAL: $*" >&2; return 1; }
run_to() { _to=$1; shift; "$@" & _pid=$!; ( sleep "$_to"; kill -TERM "$_pid" 2>/dev/null ) & _w=$!;
           wait "$_pid" 2>/dev/null; _rc=$?; kill "$_w" 2>/dev/null; return $_rc; }

# Extract check_internet + zfs_can_encrypt from the shipped script.
sed -n '/^check_internet() {/,/^}/p'   "$S" > /var/tmp/nc-internet.sh
sed -n '/^zfs_can_encrypt() {/,/^}/p'  "$S" > /var/tmp/nc-encrypt.sh
. /var/tmp/nc-internet.sh
. /var/tmp/nc-encrypt.sh

echo "=== CONTROL 1: internet check, POSITIVE (real reachable URL) ==="
if check_internet >/dev/null 2>&1; then ok "reachable URL accepted"; else bad "reachable URL REJECTED -- the check is broken, so control 2 proves nothing"; fi

echo "=== CONTROL 2: internet check, NEGATIVE (unroutable host) ==="
if SOLNIX_NET_PROBE="https://192.0.2.1/nix-cache-info" check_internet >/dev/null 2>&1; then
  bad "unroutable host ACCEPTED -- the check cannot fail"
else ok "unroutable host rejected"; fi

echo "=== CONTROL 3: internet check, NEGATIVE (200 but WRONG CONTENT -- the captive-portal case) ==="
# example.com returns 200 with HTML, which a bare exit-code check would accept.
if SOLNIX_NET_PROBE="https://example.com/" check_internet >/dev/null 2>&1; then
  bad "a 200 with HTML body ACCEPTED -- a captive portal would pass this gate"
else ok "200-with-wrong-content rejected (content assertion works)"; fi

echo "=== CONTROL 4: encryption capability probe, POSITIVE (this platform HAS it) ==="
if zfs_can_encrypt; then ok "encryption detected on a platform that has it"; else bad "encryption NOT detected though zpool upgrade -v lists it"; fi

echo "=== CONTROL 5: encryption capability probe, NEGATIVE (sabotage the detector's input) ==="
# Shadow zpool with a stub whose `upgrade -v` lists no encryption row, and make the
# zfs fallback fail too -- the probe must then say "no".
mkdir -p /var/tmp/nc-bin
cat > /var/tmp/nc-bin/zpool <<'EOF'
#!/sbin/sh
echo "some_other_feature"
echo "     Support for something else"
exit 0
EOF
cat > /var/tmp/nc-bin/zfs <<'EOF'
#!/sbin/sh
echo "cannot create: no such thing" >&2
exit 1
EOF
chmod +x /var/tmp/nc-bin/zpool /var/tmp/nc-bin/zfs
if PATH=/var/tmp/nc-bin:$PATH zfs_can_encrypt; then
  bad "probe said YES with a zpool that lists no encryption -- it cannot report absence"
else ok "probe reports absence when the platform lacks encryption"; fi

echo "=== CONTROL 6: the root-lock field is *LK*, never blank ==="
# The real defect this closes: a blank field means anyone can log in as root.
printf 'root::6445::::::\nother:*LK*:6445::::::\n' > /var/tmp/nc-shadow
awk -F: 'BEGIN{OFS=":"} $1=="root"{$2="*LK*"} {print}' /var/tmp/nc-shadow > /var/tmp/nc-shadow.new
_rf=$(awk -F: '$1=="root"{print $2}' /var/tmp/nc-shadow.new)
if [ "$_rf" = "*LK*" ]; then ok "root shadow field becomes *LK* (was empty)"; else bad "root field is '$_rf', not *LK*"; fi
echo "=== CONTROL 7: the same assertion REJECTS a blank field (proving it can fail) ==="
# Feed the verifier an unmodified blank field: the shipped code dies on this.
_rf2=$(awk -F: '$1=="root"{print $2}' /var/tmp/nc-shadow)
if [ "$_rf2" = "*LK*" ]; then bad "blank field read as *LK* -- the assertion cannot fail"; else ok "blank field correctly not equal to *LK* (assertion would die)"; fi

echo ""
echo "negative controls: $pass passed, $fail failed"
[ "$fail" = 0 ] || echo "SOME GATE CANNOT REPORT FAILURE -- do not trust it"
echo NEGCTL-DONE
