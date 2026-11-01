#!/bin/sh
# aa64-ec2-key: fetch the launch keypair from IMDSv2 into root's authorized_keys
# (the solnix-ec2-first-boot.sh pattern, minimal). No IMDS -> no-op. Re-runs per
# instance-id so an AMI-derived launch gets its own key.
exec >>/var/log/aa64-ec2-key.log 2>&1
set -x
date
PATH=/usr/sbin:/usr/bin:/sbin
I=http://169.254.169.254/latest
i=0
while [ $i -lt 30 ]; do
  T=$(curl -s --connect-timeout 2 --max-time 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' $I/api/token)
  [ -n "$T" ] && break
  i=$((i+1)); sleep 2
done
[ -n "$T" ] || { echo "no IMDS"; exit 0; }
IID=$(curl -s -H "X-aws-ec2-metadata-token: $T" $I/meta-data/instance-id)
KEY=$(curl -s -H "X-aws-ec2-metadata-token: $T" $I/meta-data/public-keys/0/openssh-key)
echo "iid=$IID keylen=${#KEY}"
case "$KEY" in ssh-*|ecdsa-*) ;; *) echo "no key"; exit 0;; esac
mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
grep -qF "$KEY" /root/.ssh/authorized_keys || echo "$KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
echo "$IID" > /root/.ssh/.aa64-iid
exit 0
