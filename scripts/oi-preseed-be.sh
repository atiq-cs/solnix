#!/usr/bin/env bash
# oi-preseed-be.sh — run ON the Ubuntu ZFS helper. Pre-seeds the mounted
# OpenIndiana boot environment at $BE so the resulting AMI is loginnable on EC2
# WITHOUT IMDS (this account enforces IMDSv2, which the OI metadata-agent — an
# IMDSv1 client — can't use).
#
# Seeds: (1) root SSH authorized_keys + PermitRootLogin, (2) root password,
# (3) a first-boot SMF service that brings up DHCP on the first NIC the way the
# metadata-agent's run_amazon() would (ipadm create-if + create-addr -T dhcp).
set -euo pipefail
BE=/mnt/be
PUBKEY="$(cat /tmp/my_pubkey)"
ROOT_HASH="$(cat /tmp/root_hash)"

echo "=== 1. root SSH key ==="
mkdir -p "$BE/root/.ssh"; chmod 700 "$BE/root/.ssh"
echo "$PUBKEY" > "$BE/root/.ssh/authorized_keys"
chmod 600 "$BE/root/.ssh/authorized_keys"

echo "=== 2. allow root SSH ==="
sed -i 's/^PermitRootLogin .*/PermitRootLogin yes/' "$BE/etc/ssh/sshd_config"
grep -q '^PermitRootLogin yes' "$BE/etc/ssh/sshd_config"

echo "=== 3. root password (console fallback) ==="
# replace field 2 of the root: line in /etc/shadow
awk -v h="$ROOT_HASH" 'BEGIN{FS=OFS=":"} /^root:/{$2=h} {print}' "$BE/etc/shadow" > /tmp/shadow.new
cp /tmp/shadow.new "$BE/etc/shadow"; chmod 400 "$BE/etc/shadow"
grep '^root:' "$BE/etc/shadow"

echo "=== 3b. AMD-safe base libc (breaks the GPU/AMD circular blocker) ==="
# solnix's base 32-bit /lib/libc.so.1 is the SYSENTER variant (tags hwcap AV_386_SEP
# + emits sysenter). The illumos amd64 kernel removes X86FSET_SEP on ALL AMD (no
# sysenter in long mode) -> ld.so.1 rejects libc -> SIGKILL (the 936x init loop) on
# any AMD box (g4ad, AMD workstations). FIX (upstream illumos does this): install
# the int/syscall variant (libc_hwcap3.so.1: int $0x91 + syscall, hwcap 0x861, no
# SEP -- the kernel supports both on AMD) as the base. Done here IN-PLACE on the
# mounted BE (no zpool-import-of-the-target -> no DHCP poison), so every solnix AMI
# is AMD-safe out of the box + Intel is unaffected (int/syscall works on both).
# See pkgs/illumos/patches/libc-amd-int-syscall-base.README.md.
if [ -f "$BE/usr/lib/libc/libc_hwcap3.so.1" ]; then
  cp -p "$BE/lib/libc.so.1" "$BE/lib/libc.so.1.sysenterbak" 2>/dev/null || true
  cp "$BE/usr/lib/libc/libc_hwcap3.so.1" "$BE/lib/libc.so.1"
  echo "  base /lib/libc.so.1 <- libc_hwcap3 (int/syscall, AMD-safe)"
else
  echo "  NOTE: $BE/usr/lib/libc/libc_hwcap3.so.1 absent -- base libc NOT swapped (AMD boxes will init-loop)"
fi

echo "=== 3c. ena plain-PCI aliases (g4ad/Nitro enumerates ENA as pci1d0f,* not pciex1d0f,*) ==="
# On g4ad the npe nexus presents the ENA NIC as a legacy-PCI compatible name
# (path_to_inst: /pci@0,0/pci1d0f,ec20@5 -> ena), but the stock driver_aliases
# only list the PCIe-express form (pciex1d0f,*). Without a pci1d0f,* alias the
# device enumerates but ena never binds -> no NIC -> no DHCP -> no SSH. NVMe is
# unaffected (it binds by class: pciclass,010802). Add both forms.
if [ -f "$BE/etc/driver_aliases" ]; then
  for a in pci1d0f,ec2 pci1d0f,1ec2 pci1d0f,ec20 pci1d0f,ec21; do
    grep -q "^ena \"$a\"" "$BE/etc/driver_aliases" || echo "ena \"$a\"" >> "$BE/etc/driver_aliases"
  done
  echo "  added pci1d0f,* ena aliases"
fi

echo "=== 4. first-boot DHCP+ssh SMF service (IMDS-independent) ==="
install -d "$BE/opt/solnix"
cat > "$BE/opt/solnix/firstboot.sh" <<'EOS'
#!/bin/sh
# solnix first-boot: bring up DHCP on the first physical NIC, enable ssh.
# Mirrors the metadata-agent run_amazon() networking, minus IMDS.
set -x
exec >/var/log/solnix-firstboot.log 2>&1
NIC=$(dladm show-phys -p -o LINK | head -1)
[ -n "$NIC" ] || NIC=$(dladm show-link -p -o LINK | head -1)
ipadm create-if "$NIC" 2>/dev/null || true
# Single DHCP addrobj only (the ena cold-boot fix): a dual ena0/dhcp + ena0/v4
# races the lease -> "configure_v4_lease: cannot set IP address ... Cannot assign
# requested address". Strip any stale ena0/v4, use ONE addrobj.
ipadm delete-addr "$NIC/v4" 2>/dev/null || true
ipadm create-addr -T dhcp -w 30 "$NIC/dhcp" 2>/dev/null || true
svcadm enable -s svc:/network/ssh:default 2>/dev/null || true
# best-effort hostname
hostname solnix-builder-build 2>/dev/null || true
EOS
chmod +x "$BE/opt/solnix/firstboot.sh"

cat > "$BE/lib/svc/manifest/site/solnix-firstboot.xml" <<'EOX'
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type='manifest' name='solnix-firstboot'>
  <service name='site/solnix-firstboot' type='service' version='1'>
    <create_default_instance enabled='true' />
    <single_instance />
    <dependency name='net' grouping='require_all' restart_on='none' type='service'>
      <service_fmri value='svc:/network/physical:default' />
    </dependency>
    <dependency name='multi-user' grouping='require_all' restart_on='none' type='service'>
      <service_fmri value='svc:/milestone/multi-user' />
    </dependency>
    <exec_method type='method' name='start' exec='/opt/solnix/firstboot.sh' timeout_seconds='120' />
    <exec_method type='method' name='stop' exec=':true' timeout_seconds='10' />
    <property_group name='startd' type='framework'>
      <propval name='duration' type='astring' value='transient' />
    </property_group>
  </service>
</service_bundle>
EOX
echo "manifest written; it will be auto-imported by svc:/system/manifest-import on boot"

echo "=== done seeding BE ==="
