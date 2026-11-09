#!/usr/bin/env bash
# bene-provision-dixi.sh — one command that turns a fresh solnix x86_64 base AMI
# into `dixi`, the PostgreSQL build-farm animal, end to end.
#
# WHY THIS EXISTS: dixi has now been rebuilt from archaeology twice, because the
# animal only ever existed as a running instance in an account that later closed
# (docs/durability-account-loss.md). The durable artifacts are THIS SCRIPT plus a
# snapshot of the build volume — deliberately NOT a derivative AMI: baking an AMI
# from a running node loses the cold-boot DHCP reliability of the base
# (docs/build-farm-animal-provisioning.md, docs/ena-rx-coldboot-fix.md).
#
# WHAT IT DOES
#   launch  — cold-launch the base AMI with a separate build volume
#             (DeleteOnTermination=false) attached at run time, so illumos
#             enumerates the disk during its FIRST boot (no reboot-to-see-disk
#             step is needed; the older runbook's reboot was an artifact of
#             attaching after launch).
#   prep    — everything ON the node: pool, IPS update + toolchain, pgbf user,
#             buildfarm client + config, Nix 2.24 + the by-name flake.
#   build   — start run_build.pl --test HEAD as pgbf, detached.
#   status  — short poll of every log (safe to run repeatedly).
#   snap    — snapshot the build volume (the durable data artifact).
#
# Each stage is IDEMPOTENT: re-running skips work whose output already exists, so
# a partial failure is resumed by re-invoking the same stage.
#
# ANTI-WEDGE: every remote call is one short non-interactive command under
# `timeout -s KILL … setsid ssh`; long work is nohup'd on the node and polled
# from separate short reads. Never chain disk probes or a zpool import over ssh.
#
# SECURITY: uses ONLY the pre-existing locked SG (:22 from the operator /24).
# Creates no SG, opens nothing to 0.0.0.0/0. Verify with scripts/sg-guard.sh audit.
# If the operator's egress changes (Starlink), re-add the new /24 with
#   bash scripts/sg-guard.sh authorize us-east-2 <sg> tcp 22 <newprefix>/24
#
# USAGE
#   scripts/bene-provision-dixi.sh launch          # -> instance id + ip
#   scripts/bene-provision-dixi.sh prep            # ~25 min (detached on node)
#   scripts/bene-provision-dixi.sh prep-poll       # until PREP_DONE
#   scripts/bene-provision-dixi.sh build           # run_build.pl --test HEAD
#   scripts/bene-provision-dixi.sh status          # poll everything
#   scripts/bene-provision-dixi.sh nixname         # by-name install proof
#   scripts/bene-provision-dixi.sh snap            # snapshot the build volume
#   scripts/bene-provision-dixi.sh info            # print connection details
set -euo pipefail
cd "$(dirname "$0")/.."

export AWS_PROFILE=bene
REGION=us-east-2
BASE_AMI="${BASE_AMI:-ami-014c4aaccd37b2356}"   # solnix-base-x86_64-hipster-20251026-20260904, 21/21 cold launches
ITYPE="${ITYPE:-m5.2xlarge}"
KEY_NAME=solnix-key
SG_ID=sg-07689ce3114d45ec9                      # solnix-sg (:22 from the operator /24 ONLY)
SUBNET=subnet-0bfe4b750cdc33c45                 # us-east-2a (EBS is AZ-bound)
BUILD_VOL_GB="${BUILD_VOL_GB:-100}"
KEY="$HOME/.ssh/id_ed25519"                     # solnix-key
ST=/tmp/dixi.state
PROG=/tmp/dixi-progress.txt
NIX_BOOTSTRAP_URL=https://cache.solnix.io/bootstrap/nix-illumos-2.24.15.tar.zst
NIX_BOOTSTRAP_SHA=ced9cf5e5fed64e3deaa8847f5c70fc1e8cd3541d84bbe64c785d0c00a24ec7f
# gnu-config FODs the by-name flake pins. They are 404 in the binary cache but
# content-addressed, so re-fetching the same commit reproduces the exact paths.
GNUCONFIG_REV=948ae97
CACHE_KEYS='cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8= cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY='
FORK_PATH=/nix/store/qmvlnvf0kk1zkfjpjpxwimg5ym8sfwnk-nixpkgs-patched-1785781297346528064

aws() { command aws --profile bene --region "$REGION" "$@"; }
note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$PROG" >&2; }
kv() { grep "^$1=" "$ST" 2>/dev/null | tail -1 | cut -d= -f2-; }
set_kv() { touch "$ST"; grep -v "^$1=" "$ST" 2>/dev/null > "$ST.tmp" || true; echo "$1=$2" >> "$ST.tmp"; mv "$ST.tmp" "$ST"; }
# Short, hard-bounded, non-interactive ssh; setsid so a stuck remote can never
# hold this shell and KILL beats any ssh-internal blocking.
dssh() { timeout -s KILL "${T:-60}" setsid ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
           -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR -o ConnectTimeout=10 root@"$(kv IP)" "$@"; }
dscp() { timeout -s KILL 180 setsid scp -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
           -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR -o ConnectTimeout=10 "$@"; }

stage_launch() {
  aws sts get-caller-identity --query Arn --output text | grep -q ':user/bene' \
    || { echo "wrong account/profile (expected bene)"; exit 1; }
  if [ -n "$(kv IID)" ] && [ "$(aws ec2 describe-instances --instance-ids "$(kv IID)" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)" = running ]; then
    note "launch: $(kv IID) already running"; return 0
  fi
  local exp run iid
  exp="$(date -d '+90 days' +%Y-%m-%d 2>/dev/null || date -v+90d +%Y-%m-%d)"
  run="$(aws ec2 run-instances --image-id "$BASE_AMI" --instance-type "$ITYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET" \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvdf\",\"Ebs\":{\"VolumeSize\":${BUILD_VOL_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":false}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=solnix-dixi},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dixi},{Key=Expiry,Value=$exp}]" \
                         "ResourceType=volume,Tags=[{Key=Name,Value=solnix-dixi},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dixi}]" \
    --output json)"
  iid="$(echo "$run" | jq -r '.Instances[0].InstanceId')"
  set_kv IID "$iid"
  aws ec2 wait instance-running --instance-ids "$iid"
  set_kv IP "$(aws ec2 describe-instances --instance-ids "$iid" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  set_kv BUILDVOL "$(aws ec2 describe-instances --instance-ids "$iid" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/xvdf`].Ebs.VolumeId' --output text)"
  note "launch: $iid ip=$(kv IP) buildvol=$(kv BUILDVOL) (DeleteOnTermination=false)"
  local i
  for i in $(seq 1 20); do
    T=25 dssh 'uname -sm' >/dev/null 2>&1 && { note "launch: ssh up after ${i} polls"; return 0; }
    sleep 15
  done
  echo "ssh never came up; check: aws ec2 get-console-output --latest --instance-id $iid" >&2; exit 1
}

# The whole on-node provisioning, as one script pushed to the node and nohup'd.
# It is written out here (rather than a pile of ssh calls) so the node does the
# long work unattended and the dev box only polls.
emit_prep() {
cat <<'PREP'
#!/bin/bash
# On-node dixi provisioning. Idempotent; safe to re-run.
exec >>/var/tmp/dixi-prep.log 2>&1
set -x
export PATH=/usr/bin:/usr/sbin:/usr/gnu/bin
step_done() { [ -f "/var/tmp/dixi-prep.$1.done" ]; }
mark()      { touch "/var/tmp/dixi-prep.$1.done"; }

# 1. Build pool on the second whole disk. The root pool is the small slice; never
#    live-grow a mounted root slice, so all build/store data goes here instead.
if ! step_done pool; then
  ROOTDISK=$(zpool status rpool | awk '/c[0-9]+t[0-9]+d[0-9]+/{print $1; exit}')
  for d in $(diskinfo -H 2>/dev/null | awk '{print $2}'); do
    [ "$d" = "$ROOTDISK" ] && continue
    zpool list -v 2>/dev/null | grep -q "$d" && continue
    BFDISK=$d; break
  done
  [ -n "$BFDISK" ] || { echo "PREP_FAILED no spare disk"; exit 1; }
  zpool list -H -o name bfpool >/dev/null 2>&1 || zpool create -f bfpool "$BFDISK"
  zfs list bfpool/pgbf >/dev/null 2>&1 || zfs create -o mountpoint=/pgbf bfpool/pgbf
  # /nix also lives on the big pool: a by-name install must never fill the root
  # pool (a near-full root separately wedged a node's loader).
  zfs list bfpool/nix  >/dev/null 2>&1 || zfs create -o mountpoint=/nix  bfpool/nix
  mark pool
fi

# 2. IPS: the pristine base carries 2025 incorporations while the OI catalog now
#    offers only 2026 packages, so EVERY toolchain install is rejected until a
#    full `pkg update`. That update creates a new BE, so it needs a reboot -- and
#    the new BE's boot_archive must be rebuilt with the solnix DHCP shim and the
#    pit_is_broken tunable inside it, or the reboot loses the reliable-boot
#    property that makes this base 21/21.
if ! step_done update; then
  cp -p /usr/lib/metadata /pgbf/metadata-shim.saved 2>/dev/null || true
  pkg update --accept; rc=$?
  # 4 = "nothing to do" (already current), which is success for our purposes.
  [ $rc -eq 0 ] || [ $rc -eq 4 ] || { echo "PREP_FAILED pkg update rc=$rc"; exit 1; }
  NEWBE=$(beadm list -H | awk -F';' '$3 ~ /R/ && $3 !~ /N/ {print $1}' | head -1)
  if [ -n "$NEWBE" ]; then
    beadm mount "$NEWBE" /mnt
    grep -q 'solnix shim' /mnt/usr/lib/metadata || cp -p /pgbf/metadata-shim.saved /mnt/usr/lib/metadata
    grep -q pit_is_broken /mnt/etc/system || echo 'set pit_is_broken = 1' >> /mnt/etc/system
    bootadm update-archive -R /mnt
    beadm umount "$NEWBE"
    mark update
    echo PREP_REBOOT_NEEDED
    sync; /usr/sbin/reboot
    exit 0
  fi
  mark update
fi

# 3. Toolchain + the buildfarm-specific deps. ipc-run-542 matches the box's perl
#    5.42 ABI (the unversioned ipc-run can resolve to a wrong perl ABI).
#    gnu-diffutils is REQUIRED, not cosmetic: PG's test_json_parser TAP test
#    asserts diff prints NOTHING for identical files, but the illumos
#    /usr/bin/diff prints "No differences encountered" with -u/-c/-U3, which
#    fails 4 subtests and the whole module-test_json_parserCheck stage.
if ! step_done tools; then
  pkg install --accept developer/gcc-14 developer/build/gnu-make \
    developer/parser/bison developer/lexer/flex developer/versioning/git \
    developer/ccache library/perl-5/ipc-run-542 text/gnu-diffutils; rc=$?
  [ $rc -eq 0 ] || [ $rc -eq 4 ] || { echo "PREP_FAILED pkg install rc=$rc"; exit 1; }
  for t in gcc gmake bison flex git ccache; do
    command -v $t >/dev/null || { echo "PREP_FAILED missing $t"; exit 1; }
  done
  perl -MIPC::Run -e 1 || { echo "PREP_FAILED IPC::Run"; exit 1; }
  mark tools
fi

# 4. pgbf user + the buildfarm client. PG's initdb and run_build refuse to run as
#    root, so the animal needs an unprivileged user; its home and the build root
#    live on the big pool so a reboot or a root-pool squeeze cannot lose them.
if ! step_done user; then
  mkdir -p /pgbf/home /pgbf/buildroot /opt/pgbf
  id pgbf >/dev/null 2>&1 || useradd -u 1100 -d /pgbf/home/pgbf -m -s /bin/bash pgbf
  chown pgbf /pgbf /pgbf/home /pgbf/buildroot
  chown -R pgbf /pgbf/home /pgbf/buildroot
  [ -d /opt/pgbf/client-code ] || git clone --depth 1 \
    https://github.com/PGBuildFarm/client-code.git /opt/pgbf/client-code
  chown -R pgbf /opt/pgbf
  # Modern git refuses a tree owned by another user ("dubious ownership"), which
  # breaks run_build.pl's git calls as pgbf.
  su - pgbf -c 'git config --global --add safe.directory /opt/pgbf/client-code'
  mark user
fi

# 5. build-farm.conf: the sample with exactly the knobs solnix needs.
#    --without-icu because the IPS ICU is v4.6 < the 55 modern PG requires;
#    --enable-tap-tests is why IPC::Run is installed.
if ! step_done conf; then
  cd /opt/pgbf/client-code
  [ -f build-farm.conf ] || cp build-farm.conf.sample build-farm.conf
  perl -pi -e "s{^\tmake => 'make',}{\tmake => 'gmake',}; s{^\tbuild_root => undef,}{\tbuild_root => '/pgbf/buildroot',}" build-farm.conf
  perl - build-farm.conf <<'EOP'
my $f = shift; local $/; open my $i, '<', $f or die $!; my $t = <$i>; close $i;
my $new = "\tconfig_opts => [\n\t\tqw(\n\t\t  --enable-cassert\n\t\t  --enable-debug\n\t\t  --enable-tap-tests\n\t\t  --without-icu\n\t\t  ),\n\t],\n";
$t =~ s/\tconfig_opts => \[\n\t\tqw\(\n.*?\t\],\n/$new/s or die "config_opts block not found";
# GNU diff must win over the illumos one for every build/test child process:
# test_json_parser's TAP test asserts an empty diff output.
my $env = "\tbuild_env => {\n\n\t\t# PG TAP tests assert diff prints NOTHING for identical files; the illumos\n\t\t# /usr/bin/diff prints 'No differences encountered' with -u, so put GNU\n\t\t# diffutils (/usr/gnu/bin) ahead of it for the whole build/test run.\n\t\tPATH => '/usr/gnu/bin:/usr/bin:/usr/sbin',\n";
$t =~ s/\tbuild_env => \{\n/$env/ unless $t =~ m{/usr/gnu/bin:/usr/bin};
open my $o, '>', $f or die $!; print $o $t; close $o;
EOP
  perl -c build-farm.conf || { echo "PREP_FAILED build-farm.conf syntax"; exit 1; }
  chown pgbf build-farm.conf
  mark conf
fi

# 6. Nix 2.24 from the banked bootstrap tarball (no compiler needed).
if ! step_done nix; then
  mkdir -p /var/tmp/nixboot /etc/profile.d && cd /var/tmp/nixboot
  [ -f n.tar.zst ] || curl -fsSL -o n.tar.zst "__NIXURL__"
  # illumos has `digest`, not sha256sum (the tarball's own bootstrap-register.sh
  # assumes sha256sum and dies on this platform).
  got=$(digest -a sha256 n.tar.zst)
  [ "$got" = "__NIXSHA__" ] || { echo "PREP_FAILED nix tarball sha $got"; exit 1; }
  [ -d nix-tools224 ] || { zstd -d < n.tar.zst | tar -xf -; }
  [ -d /nix-tools224 ] || cp -R nix-tools224 /nix-tools224
  mkdir -p /nix-tools224/runtime-lib
  # illumos cp has no -P (the tarball's register script uses `cp -Pf`).
  cp -R runtime-lib/. /nix-tools224/runtime-lib/
  cp -f ca-bundle.crt /nix-tools224/ca-bundle.crt
  # The banked tarball only elfedited bin/nix's RUNPATH; its libs and the other
  # bin/* still point at the BUILD host (/usr/gcc/13/lib/amd64,
  # /var/tmp/libgit2-inst/lib), so nix-store cannot find libstdc++/boost/git2/
  # archive. Rewrite every RUNPATH to the install prefix.
  RP='/nix-tools224/lib:/nix-tools224/lib/amd64:/nix-tools224/runtime-lib'
  for f in /nix-tools224/bin/* /nix-tools224/lib/*.so* /nix-tools224/runtime-lib/*.so*; do
    [ -f "$f" ] || continue
    elfdump -d "$f" 2>/dev/null | grep -Eqi 'RUNPATH|RPATH' || continue
    chmod u+w "$f" 2>/dev/null
    /usr/bin/elfedit -e "dyn:runpath $RP" "$f" >/dev/null 2>&1 || echo "runpath fix failed: $f"
  done
  ldd /nix-tools224/bin/nix-store 2>&1 | grep 'not found' && { echo "PREP_FAILED nix libs"; exit 1; }
  mkdir -p /nix/store /nix/var/nix
  printf 'export PATH=/nix-tools224/bin:$PATH\nexport NIX_CONF_DIR=/nix-tools224/etc/nix\n' > /etc/profile.d/nix-illumos.sh
  mkdir -p /nix-tools224/etc/nix
  cat > /nix-tools224/etc/nix/nix.conf <<CONF
build-users-group =
sandbox = false
substituters = https://cache.solnix.io https://cache.nixos.org
trusted-public-keys = __CACHEKEYS__
ssl-cert-file = /nix-tools224/ca-bundle.crt
experimental-features = nix-command flakes
CONF
  export PATH=/nix-tools224/bin:$PATH NIX_CONF_DIR=/nix-tools224/etc/nix
  nix-store --init
  nix --version || { echo "PREP_FAILED nix --version"; exit 1; }
  mark nix
fi

# 7. The by-name flake + its three pinned inputs, so `nix profile install
#    nixpkgs#<pkg>` resolves BY NAME with no --impure.
if ! step_done byname; then
  export PATH=/nix-tools224/bin:$PATH NIX_CONF_DIR=/nix-tools224/etc/nix HOME=/root
  [ -d /root/solnix-pkgs/pkgs/os-specific/illumos/phase3/by-name-flake ] \
    || { echo "PREP_FAILED solnix-pkgs tree missing (dev box must push it)"; exit 1; }
  # The gnu-config FODs are 404 in the cache but content-addressed: re-adding the
  # same upstream commit reproduces the exact store paths flake.lock pins.
  nix-store --add-fixed sha256 /var/tmp/config.guess-__GNUREV__ /var/tmp/config.sub-__GNUREV__
  nix-store --realise __FORKPATH__ --add-root /nix/var/nix/gcroots/solnix-fork -r
  cd /root/solnix-pkgs/pkgs/os-specific/illumos/phase3/by-name-flake
  # The lock's solnixPkgs input pins a narHash of the tree; a freshly pushed tree
  # differs, so re-lock it (this exact stale-lock issue is what blocked by-name
  # installs on the previous animal).
  nix flake update solnixPkgs
  nix registry add nixpkgs "path:$PWD"
  nix eval nixpkgs#coreutils.name || { echo "PREP_FAILED by-name eval"; exit 1; }
  mark byname
fi

echo PREP_DONE
PREP
}

stage_prep() {
  [ -n "$(kv IP)" ] || { echo "run launch first"; exit 1; }
  # Push the solnix-pkgs tree (the by-name flake + the illumos overlay) and the
  # two gnu-config sources the flake pins.
  local tgz=/tmp/dixi-solnix-pkgs.tgz
  tar czf "$tgz" pkgs/illumos pkgs/os-specific
  dscp "$tgz" root@"$(kv IP)":/var/tmp/solnix-pkgs-tree.tgz
  for f in guess sub; do
    curl -fsSL -o "/tmp/config.$f-$GNUCONFIG_REV" \
      "https://git.savannah.gnu.org/cgit/config.git/plain/config.$f?id=$GNUCONFIG_REV"
    dscp "/tmp/config.$f-$GNUCONFIG_REV" root@"$(kv IP)":/var/tmp/
  done
  T=120 dssh 'mkdir -p /root/solnix-pkgs && cd /root/solnix-pkgs && gzip -dc /var/tmp/solnix-pkgs-tree.tgz | tar -xf - && cp -R pkgs/illumos/. pkgs/os-specific/illumos/ && ls pkgs/os-specific/illumos/phase3/by-name-flake'
  emit_prep \
    | sed -e "s|__NIXURL__|$NIX_BOOTSTRAP_URL|" -e "s|__NIXSHA__|$NIX_BOOTSTRAP_SHA|" \
          -e "s|__CACHEKEYS__|$CACHE_KEYS|" -e "s|__GNUREV__|$GNUCONFIG_REV|g" \
          -e "s|__FORKPATH__|$FORK_PATH|" \
    | dssh 'cat > /var/tmp/dixi-prep.sh'
  dssh 'nohup bash /var/tmp/dixi-prep.sh >/dev/null 2>&1 & echo prep-started'
  note "prep: running detached on $(kv IID); poll with: $0 prep-poll"
}

stage_prep_poll() {
  # A pkg-update reboot mid-prep is expected: re-invoke prep after it to resume
  # (every step is marked done, so nothing repeats).
  T=40 dssh 'tail -6 /var/tmp/dixi-prep.log 2>/dev/null; echo ---; ls /var/tmp/dixi-prep.*.done 2>/dev/null | sed "s|.*dixi-prep.||;s|.done||" | tr "\n" " "; echo; grep -qE "^PREP_DONE" /var/tmp/dixi-prep.log 2>/dev/null && echo PREP_DONE || (grep -q PREP_FAILED /var/tmp/dixi-prep.log && echo PREP_FAILED || echo PREP_RUNNING)' \
    2>&1 || echo "SSH_NOT_READY (a pkg-update reboot is expected once; re-poll)"
}

stage_build() {
  dssh 'su - pgbf -c "cd /opt/pgbf/client-code && nohup perl run_build.pl --test --verbose --config=/opt/pgbf/client-code/build-farm.conf HEAD > /pgbf/run-test.log 2>&1 &"; echo build-started'
  note "build: run_build.pl --test HEAD started; poll with: $0 status"
}

stage_nixname() {
  # Goal 2 proof: install BY NAME through the registry mapping. Detached because
  # the solnix cache is missing some NARs, so this may build from source.
  dssh 'export PATH=/nix-tools224/bin:$PATH NIX_CONF_DIR=/nix-tools224/etc/nix HOME=/root; nohup nix profile install nixpkgs#coreutils > /var/tmp/nixname.log 2>&1 & echo nixname-started'
}

stage_status() {
  T=45 dssh 'echo "=== run_build"; tail -4 /pgbf/run-test.log 2>/dev/null; echo "=== nix by-name"; tail -3 /var/tmp/nixname.log 2>/dev/null; echo "=== pools"; zpool list; echo "=== root free"; df -h / | tail -1' 2>&1 || echo SSH_NOT_READY
}

stage_snap() {
  local vol snap
  vol="$(kv BUILDVOL)"; [ -n "$vol" ] || { echo "no BUILDVOL"; exit 1; }
  snap="$(aws ec2 create-snapshot --volume-id "$vol" \
    --description "solnix dixi provisioned build pool (bfpool: /pgbf buildroot + /nix store)" \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=solnix-dixi-buildpool},{Key=Owner,Value=gregburd},{Key=Purpose,Value=solnix-dixi}]' \
    --query SnapshotId --output text)"
  set_kv SNAP "$snap"; note "snap: $snap of $vol"
  echo "$snap"
}

stage_info() {
  cat <<EOF
dixi (solnix x86_64 PostgreSQL build-farm animal)
  instance : $(kv IID)   type $ITYPE   region $REGION
  ip       : $(kv IP)
  login    : ssh -i ~/.ssh/id_ed25519 root@$(kv IP)
  animal   : su - pgbf ; cd /opt/pgbf/client-code
  buildroot: /pgbf/buildroot   (bfpool, vol $(kv BUILDVOL), DeleteOnTermination=false)
  nix      : /nix-tools224/bin/nix (2.24.15), store /nix on bfpool
  snapshot : $(kv SNAP)
If ssh times out later, the operator's egress /24 changed: re-add it with
  bash scripts/sg-guard.sh authorize $REGION $SG_ID tcp 22 \$(curl -s https://checkip.amazonaws.com | cut -d. -f1-3).0/24
EOF
}

case "${1:-}" in
  launch)    stage_launch ;;
  prep)      stage_prep ;;
  prep-poll) stage_prep_poll ;;
  build)     stage_build ;;
  nixname)   stage_nixname ;;
  status)    stage_status ;;
  snap)      stage_snap ;;
  info)      stage_info ;;
  all)       stage_launch; stage_prep; echo "now poll: $0 prep-poll (a reboot mid-prep is expected; then re-run '$0 prep' to resume)" ;;
  *) sed -n '1,45p' "$0"; exit 1 ;;
esac
