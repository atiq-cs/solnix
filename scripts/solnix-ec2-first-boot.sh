#!/bin/sh
# solnix-ec2-first-boot.sh -- cloud-init-lite: on an EC2 instance, fetch the
# launcher's public SSH key from instance metadata (IMDSv2) and install it into
# root's (and the operator user's) ~/.ssh/authorized_keys, so a PUBLIC AMI is
# loginnable with whatever keypair the launcher chose at RunInstances.
#
# This is the illumos analog of NixOS's amazon-init / cloud-init ssh-key seeding
# (nixos/modules/virtualisation/amazon-init.nix pulls the key from the EC2 user
# data / IMDS). base.nix is identity-free (PermitRootLogin prohibit-password, no
# baked key); without this, a public launch boots but accepts no key. The build
# host's baked key path (users.users.*.openssh.authorizedKeys) is unaffected --
# this only ADDS the launch key alongside anything already present.
#
# FAIL-SAFE: no IMDS (bare metal, the X1, a non-EC2 VM) -> no-op, exit 0. The
# same image boots unharmed off-EC2. Idempotent: a run-once stamp skips the
# fetch on later boots, but a re-launch of the SAME disk under a NEW keypair is
# the EC2 norm, so the stamp is keyed to the metadata instance-id -- a new
# instance-id (a fresh launch / AMI-derived instance) re-fetches.
#
# The IMDSv2 token+GET helper is the proven one from scripts/solnix-mtu.sh.

exec >>/var/log/solnix-ec2-first-boot.log 2>&1
set -x
echo "=== solnix-ec2-first-boot $(date) ==="

STATE=/var/lib/solnix
STAMP="$STATE/ec2-authkey-instance-id"   # the instance-id we last seeded for
mkdir -p "$STATE" 2>/dev/null || true

# illumos ships NO curl in the base world, so the SMF method hands us one by
# absolute store path in SOLNIX_CURL (modules/config/ec2-first-boot.nix). Fall
# back to a PATH `curl` for manual/off-EC2 use. A missing HTTP client is the one
# way this silently installs no key, so resolve it explicitly.
CURL="${SOLNIX_CURL:-curl}"
# the world's tools (getent, sort, grep, chown, ...) live here.
PATH=/usr/sbin:/usr/bin:/sbin:$PATH
export PATH
IMDS=http://169.254.169.254/latest

# IMDSv2: PUT a session token (this account class enforces v2; v1 GETs 401/empty).
imds_token() {
	"$CURL" -s --connect-timeout 2 --max-time 5 -X PUT \
	    -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' \
	    "$IMDS/api/token" 2>/dev/null
}
# imds <meta-data-path> -> value (v2 token header; falls back to v1 if no token).
imds() {
	_t=$(imds_token)
	if [ -n "$_t" ]; then
		"$CURL" -s --connect-timeout 2 --max-time 5 \
		    -H "X-aws-ec2-metadata-token: $_t" "$IMDS/$1" 2>/dev/null
	else
		"$CURL" -s --connect-timeout 2 --max-time 5 "$IMDS/$1" 2>/dev/null
	fi
}

# --- fail-safe gate: are we on EC2 at all? ----------------------------------
# RETRY: svc:/milestone/network going online does NOT guarantee the DHCP lease /
# route is up yet (illumos: the solnix-net transient oneshot may still be running
# when a require_all dependent starts). IMDS at 169.254.169.254 is link-local, so
# it answers as soon as an interface is plumbed -- but if we run a hair too early
# the token PUT times out and a single probe would wrongly conclude "off-EC2" and
# no-op, leaving a PUBLIC AMI unloginnable (measured: boot-verify v5 came up clean
# but my key was absent because the one-shot ran before the lease settled). So
# probe up to ~60s; only after that give up as genuinely off-EC2 (bare metal/X1).
IID=""
_tries=0
while [ "$_tries" -lt 20 ]; do
	IID=$(imds meta-data/instance-id)
	case "$IID" in i-*) break ;; esac
	_tries=$((_tries + 1))
	sleep 3
done
case "$IID" in
	i-*) : ;;                                 # looks like a real instance-id
	*)   echo "no EC2 instance metadata after ${_tries} tries (got '$IID'); off-EC2 no-op"; exit 0 ;;
esac
echo "instance-id: $IID (after ${_tries} retries)"

# --- idempotency: skip only if we already seeded for THIS instance-id -------
if [ "$(cat "$STAMP" 2>/dev/null)" = "$IID" ]; then
	echo "already seeded authorized_keys for $IID; nothing to do"
	exit 0
fi

# --- fetch the launcher's public key(s) -------------------------------------
# IMDS exposes keys under meta-data/public-keys/<index>/openssh-key. A launch
# normally has one (index 0); read whatever indices are listed so a multi-key
# launch works too. The listing lines look like "0=my-key".
KEYS=""
INDEXES=$(imds meta-data/public-keys/ 2>/dev/null | sed 's/=.*//' | grep -E '^[0-9]+$')
[ -n "$INDEXES" ] || INDEXES=0
for _i in $INDEXES; do
	_k=$(imds "meta-data/public-keys/$_i/openssh-key")
	# a public key line starts with a known key type; ignore anything else
	# (an error page, empty body) so we never write junk to authorized_keys.
	case "$_k" in
		ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-*\ *|ssh-dss\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-*)
			KEYS="$KEYS$_k
" ;;
		*) echo "public-keys/$_i: no usable openssh-key (skipped)" ;;
	esac
done

if [ -z "$KEYS" ]; then
	echo "no launch SSH key in IMDS; leaving authorized_keys unchanged"
	# Record the stamp anyway: a key-less launch (e.g. SSM-only) should not
	# re-probe every boot. A later launch gets a new instance-id and re-runs.
	printf '%s\n' "$IID" > "$STAMP"
	exit 0
fi

# --- install into root's authorized_keys, and the operator user's if present
# Who gets the key: root always (PermitRootLogin prohibit-password means a key
# still logs in). ALSO the first non-system interactive account (uid>=1000 with
# a real login shell) if the installer/first-boot created an operator -- matching
# the identity-free first-boot model where the operator is created on the box.
seed_user() {   # seed_user <home> <uid> <gid>
	_home=$1; _uid=$2; _gid=$3
	[ -d "$_home" ] || { echo "home $_home missing; skip"; return 0; }
	mkdir -p "$_home/.ssh" || return 0
	# ADD, don't clobber: keep any key already there (a baked key, or a prior
	# boot's). De-dup so a re-run does not pile up copies.
	_ak="$_home/.ssh/authorized_keys"
	{ [ -f "$_ak" ] && cat "$_ak"; printf '%s' "$KEYS"; } \
	    | sort -u | grep -E '^(ssh-|ecdsa-|sk-)' > "$_ak.new" || return 0
	mv -f "$_ak.new" "$_ak"
	chown "$_uid:$_gid" "$_home/.ssh" "$_ak" 2>/dev/null || true
	chmod 700 "$_home/.ssh"; chmod 600 "$_ak"
	echo "seeded $(printf '%s' "$KEYS" | grep -c .) launch key(s) into $_ak"
}

# root
_rhome=$(getent passwd root 2>/dev/null | cut -d: -f6)
[ -n "$_rhome" ] || _rhome=/root
seed_user "$_rhome" 0 0

# operator: the lowest-uid non-system account with a login shell, if any.
getent passwd 2>/dev/null \
    | awk -F: '($3+0)>=1000 && $1!="nobody" && $1!="noaccess" && $1!="nobody4" \
               && $7!="" && $7!="/bin/false" && $7!="/usr/bin/false" \
               {print $3":"$4":"$6}' \
    | sort -n | head -1 \
    | while IFS=: read -r _ouid _ogid _ohome; do
		[ -n "$_ohome" ] && seed_user "$_ohome" "$_ouid" "$_ogid"
	done

printf '%s\n' "$IID" > "$STAMP"
echo "=== solnix-ec2-first-boot done ($IID) ==="
exit 0
