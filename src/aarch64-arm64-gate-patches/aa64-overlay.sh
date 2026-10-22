#!/bin/bash
# aa64-overlay.sh <imgroot> : EC2 login overlay on the banked proto world.
# braich (OmniOS bloody aarch64) OpenSSH + libs + curl, DHCP on ena0, IMDS key.
R=$1; B=/build/braich-root; [ -d "$R/etc" ] || exit 2
set -x
# sshd/ssh/keygen + helpers + their non-world libs (libcrypto/libz/libgcc_s/curl+deps)
for f in usr/sbin/sshd usr/bin/ssh usr/bin/ssh-keygen usr/bin/scp usr/bin/curl \
         usr/libexec/sshd-session usr/libexec/sshd-auth usr/libexec/sftp-server \
         usr/libexec/ssh-keysign etc/ssh/moduli etc/ssh/ssh_config \
         lib/svc/method/sshd lib/svc/manifest/network/ssh.xml; do
  mkdir -p "$R/$(dirname $f)"; cp -p "$B/$f" "$R/$f" || echo "MISSING $f"
done
# libs: copy every braich lib the world lacks (by soname), never overwrite world libs
for d in lib usr/lib; do
  for l in $B/$d/*.so.*; do
    n=$(basename $l); [ -e "$R/$d/$n" ] || [ -L "$R/$d/$n" ] || cp -P "$l" "$R/$d/$n"
  done
done
[ -e $R/lib/libgcc_s.so.1 ] || cp -p $B/usr/lib/libgcc_s.so.1 $R/lib/libgcc_s.so.1
cp -rp $B/usr/gcc $R/usr/ 2>/dev/null
cat > $R/etc/ssh/sshd_config <<'S'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
Subsystem sftp /usr/libexec/sftp-server
S
mkdir -p $R/var/empty $R/root/.ssh; chmod 700 $R/root/.ssh
# IMDS key service
mkdir -p $R/usr/lib/aa64 $R/lib/svc/manifest/site
cp /build/patches/aa64-ec2-key.sh $R/usr/lib/aa64/; chmod 0555 $R/usr/lib/aa64/aa64-ec2-key.sh
cp /build/patches/aa64-ec2-key.xml $R/lib/svc/manifest/site/
# network: DHCP on ena0 (persistent ipadm conf, the x86 AMI shape)
mkdir -p $R/etc/ipadm $R/etc/dladm
cat > $R/etc/ipadm/ipadm.conf <<'I'
_ifname=ena0;_family=2;
_ifname=ena0;_family=26;
_ifname=ena0;_aobjname=ena0/dhcp;_dhcp=-1,no;
I
cp $R/etc/nsswitch.dns $R/etc/nsswitch.conf 2>/dev/null
echo "OVERLAY_DONE"
