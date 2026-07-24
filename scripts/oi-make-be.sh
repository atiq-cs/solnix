#!/usr/bin/env bash
# oi-make-be.sh — assemble a bootable ZFS-root solnix disk image on the illumos
# build host, FROM the Nix-store illumos world (T1.13-T1.15, Phase-1 gate).
#
# Run ON the OpenIndiana build host as root, after a scratch EBS/NVMe disk is
# attached (default c1t1d0; attach the EBS vol then REBOOT so illumos enumerates
# the new NVMe controller — Nitro NVMe hotplug is not detected live).
#
# Produces a self-contained bootable disk mirroring the proven OI rpool layout:
#   GPT: s0 = ESP (pcfs FAT32, 256M, holds the illumos loader as EFI/Boot/bootx64.efi)
#        s1 = the solnix ZFS pool  (tag 4)
#        s8 = reserved             (tag 11)
#   pool  "spool"  (distinct name so it imports next to rpool on the builder)
#   dataset spool/ROOT/solnix-1  = the boot environment
#
# The BE root filesystem IS the Nix-built illumos gate proto (pkgs.illumos.gate,
# our ac45d71fc2 build ingested into the store) — a complete, self-consistent
# illumos root: kernel + drivers + libc + rtld + svc.startd + all SMF method
# scripts + stock manifests + /etc. On top we ADD (design-smf-init §5,
# add-not-replace): solnix-generated SMF manifests + a seeded repository + the
# external libs the SMF stack needs (libxml2/icu/zlib/libstdc++/libgcc_s — NOT
# in the gate proto) + ttya serial console + root console login.
#
# WHY the proto (not the sliced systemPath): the proto is ONE internally
# consistent build (kernel, drivers, genunix, libc, svc.startd all from the SAME
# gate rev) — the safest thing to boot. The RUNPATH-relocated systemPath slices
# (GATE 1, ldd-clean) are the composable form; the proto is the monolithic-root
# form. Both are "our Nix world." The image reuses the proto's own loader +
# boot_archive machinery (bootadm) — kernel/driver concerns matched to this gate.
#
# After this: scripts/oi-be-to-ami.sh snapshots the disk -> registers an AMI.
set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/usr/gnu/bin:/sbin:/nix-tools/bin
DISK="${DISK:-c1t1d0}"                 # scratch disk (whole-disk EFI); NOT the rpool
POOL="${POOL:-spool}"
BE="${BE:-solnix-1}"
BEDS="$POOL/ROOT/$BE"
ALTROOT="${ALTROOT:-/a}"
PROTO="${PROTO:-$(ls -d /nix/store/*illumos-gate-proto | head -1)}"
GCP="${GCP:-/usr/gnu/bin/cp}"          # GNU cp (illumos cp -L differs)
# NON-DEBUG kernel: the gate builds DEBUG-only, which HANGS in early init on EC2
# Nitro (gotcha #4). Build non-DEBUG with `bldenv +d solnix.sh` + `dmake -m serial
# install` in $SRC/uts, then point NDPROTO at the proto that install populated
# (bldenv installs into proto/root_i386, over the DEBUG kernel). If NDPROTO is
# set we swap its kernel trees into the BE after laying down $PROTO.
NDPROTO="${NDPROTO:-/code/illumos-gate/proto/root_i386}"

die()  { echo "FATAL: $*" >&2; exit 1; }
log()  { printf '\n=== %s ===\n' "$*" >&2; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -n "$PROTO" ] && [ -d "$PROTO" ] || die "gate proto not found (PROTO=/nix/store/...-illumos-gate-proto)"
[ "$DISK" != "c2t1d0" ] || die "refusing to use the rpool disk c2t1d0"
[ -e "/dev/rdsk/${DISK}s0" ] || die "scratch disk $DISK not present (attach EBS + reboot)"

log "proto = $PROTO ($(du -sh "$PROTO" | awk '{print $1}'))"

# ---------------------------------------------------------------------------
# 0. tear down any prior attempt
# ---------------------------------------------------------------------------
log "cleaning prior $POOL / $ALTROOT"
umount "$ALTROOT/esp" 2>/dev/null || true
zfs unmount "$BEDS" 2>/dev/null || true
zpool destroy "$POOL" 2>/dev/null || true
zpool export "$POOL" 2>/dev/null || true
mkdir -p "$ALTROOT"

# ---------------------------------------------------------------------------
# 1. GPT label: pure-EFI base via a throwaway pool, then fmthard the 3-part spec
#    (matches the OI installer's rpool layout: s0 ESP tag12, s1 pool tag4, s8
#    reserved tag11). fmthard on a fdisk-created label complains about cylinder
#    alignment; a zpool-created EFI label is sector-addressed and takes fmthard.
# ---------------------------------------------------------------------------
log "GPT-labelling $DISK (clean EFI label via throwaway pool)"
zpool create -f __solnix_tmp "/dev/dsk/${DISK}" >/dev/null 2>&1 || die "could not create clean EFI label"
zpool destroy __solnix_tmp 2>/dev/null || true

SECTORS="$(prtvtoc -h "/dev/rdsk/${DISK}" 2>/dev/null | awk '$1==8{print $4}')"
# s8 (reserved) start from the EFI label = last usable region; total accessible:
ACCESS="$(prtvtoc "/dev/rdsk/${DISK}" 2>/dev/null | awk '/accessible sectors/{print $2}')"
RESV_START="$(prtvtoc -h "/dev/rdsk/${DISK}" 2>/dev/null | awk '$1==8{print $4}')"
RESV_SIZE="$(prtvtoc -h "/dev/rdsk/${DISK}" 2>/dev/null | awk '$1==8{print $5}')"
ESP_START=256
ESP_SIZE=524288                        # 256 MiB
POOL_START=$((ESP_START + ESP_SIZE))
POOL_SIZE=$((RESV_START - POOL_START))
[ "$POOL_SIZE" -gt 0 ] || die "computed pool size <= 0 (RESV_START=$RESV_START)"

log "fmthard: s0 ESP @${ESP_START}+${ESP_SIZE}, s1 pool @${POOL_START}+${POOL_SIZE}, s8 resv @${RESV_START}+${RESV_SIZE}"
cat > /tmp/solnix.vtoc <<EOF
0 12 00 ${ESP_START} ${ESP_SIZE}
1 4 00 ${POOL_START} ${POOL_SIZE}
8 11 00 ${RESV_START} ${RESV_SIZE}
EOF
fmthard -s /tmp/solnix.vtoc "/dev/rdsk/${DISK}" 2>&1 || die "fmthard failed"
prtvtoc -h "/dev/rdsk/${DISK}"

# ---------------------------------------------------------------------------
# 2. ESP: FAT32 for the loader
# ---------------------------------------------------------------------------
log "mkfs pcfs ESP on ${DISK}s0"
yes | mkfs -F pcfs -o fat=32,b=ESP "/dev/rdsk/${DISK}s0" >/dev/null 2>&1 || true
mkdir -p "$ALTROOT/esp"
mount -F pcfs "/dev/dsk/${DISK}s0" "$ALTROOT/esp" 2>/dev/null && umount "$ALTROOT/esp" || die "ESP unusable"

# ---------------------------------------------------------------------------
# 3. the pool + BE dataset
# ---------------------------------------------------------------------------
log "creating pool $POOL on ${DISK}s1"
zpool create -f -o altroot="$ALTROOT" -o cachefile=none \
  -O compression=on -O atime=off -m none "$POOL" "/dev/dsk/${DISK}s1"
zfs create -o canmount=off -o mountpoint=legacy "$POOL/ROOT"
zfs create -o canmount=noauto -o mountpoint=/ "$BEDS"
zfs mount "$BEDS"
BEROOT="$ALTROOT"
[ -d "$BEROOT/." ] || die "BE root not mounted at $BEROOT"

# ---------------------------------------------------------------------------
# 4. lay down the Nix-built illumos world (the gate proto)
# ---------------------------------------------------------------------------
log "copying proto -> BE root (the Nix-built ac45d71fc2 world)"
( cd "$PROTO" && tar -cf - . ) | ( cd "$BEROOT" && tar -xf - )
for d in proc dev devices system/contract system/object system/volatile \
         etc/svc/volatile var/run var/tmp mnt export export/home root; do mkdir -p "$BEROOT/$d"; done

# --- 4a. swap in the NON-DEBUG kernel (gotcha #4/#5) ---------------------------
# The DEBUG kernel hangs in early init on EC2. Replace ALL kernel module trees
# (platform + kernel + /usr/kernel) with the non-DEBUG build so unix/genunix AND
# every driver (pm/ptm/pts) are consistently non-DEBUG (a mismatch -> mod_load
# 'undefined symbol ptms_logp/pm_debug').
if [ -n "$NDPROTO" ] && [ -d "$NDPROTO" ] && \
   ! strings "$NDPROTO/platform/i86pc/kernel/amd64/unix" 2>/dev/null | grep -qi 'DEBUG enabled'; then
  # crude DEBUG check: a non-DEBUG unix is ~2.3MB, DEBUG ~2.6MB; trust the caller.
  log "swapping NON-DEBUG kernel trees from $NDPROTO"
  for tree in platform/i86pc/kernel platform/i86hvm/kernel platform/i86xpv/kernel kernel usr/kernel; do
    [ -d "$NDPROTO/$tree" ] && ( cd "$NDPROTO" && tar -cf - "$tree" ) | ( cd "$BEROOT" && tar -xf - )
  done
fi

# --- 4b. directory permissions (gotcha #7) ------------------------------------
# The gate proto ships ~3451 directories mode 0555 (no owner-write); every
# service that writes (/var/run, /etc/mail, /var/spool) then fails 'Permission
# denied'. Restore owner-write to all dirs (0555 -> 0755, real-illumos default).
log "restoring directory write permissions (proto ships 0555 dirs)"
find "$BEROOT" -type d -exec chmod u+w {} + 2>/dev/null || true
chmod 1777 "$BEROOT/tmp" "$BEROOT/var/tmp" "$BEROOT/system/volatile" 2>/dev/null || true
[ -d "$BEROOT/var/spool/clientmqueue" ] && chmod 1770 "$BEROOT/var/spool/clientmqueue" 2>/dev/null || true

# --- 4c. essential /dev symlinks (gotcha #6) ----------------------------------
# The proto's on-disk /dev lacks console/msglog/null; init's svc.startd
# >/dev/msglog </dev/console then can't open stdio and hangs silently. Seed the
# persistent symlinks into /devices/pseudo (the devfs auto-mount populates them).
log "seeding essential /dev symlinks"
for n in console msglog null zero tty syscon systty sysmsg random urandom poll; do
  [ -L "/dev/$n" ] && ln -sf "$(/usr/bin/readlink /dev/$n)" "$BEROOT/dev/$n" 2>/dev/null || true
done

# --- 4d. SMF profile symlinks (gotcha #8) -------------------------------------
# generic.xml/platform.xml/name_service.xml are made at install; without them
# `svccfg apply` fails and the standard service profile isn't applied.
log "creating SMF profile symlinks"
( cd "$BEROOT/etc/svc/profile" && \
  ln -sf generic_limited_net.xml generic.xml && \
  ln -sf platform_none.xml platform.xml && \
  ln -sf ns_dns.xml name_service.xml ) 2>/dev/null || true

# --- 4e. missing users/groups (gotcha #9) -------------------------------------
# proto passwd/group lack several accounts (sshd for privsep, etc.). Append the
# ones the host has that the BE lacks.
log "adding missing users/groups from host"
for u in $(comm -23 <(cut -d: -f1 /etc/passwd | sort) <(cut -d: -f1 "$BEROOT/etc/passwd" | sort) 2>/dev/null); do
  grep "^$u:" /etc/passwd >> "$BEROOT/etc/passwd" 2>/dev/null || true
  grep "^$u:" /etc/shadow >> "$BEROOT/etc/shadow" 2>/dev/null || true
done
for g in $(comm -23 <(cut -d: -f1 /etc/group | sort) <(cut -d: -f1 "$BEROOT/etc/group" | sort) 2>/dev/null); do
  grep "^$g:" /etc/group >> "$BEROOT/etc/group" 2>/dev/null || true
done
chmod 1777 "$BEROOT/tmp"

# ---------------------------------------------------------------------------
# 5. /etc essentials + ttya serial console (EC2 serial console = ttya)
# ---------------------------------------------------------------------------
log "/etc essentials + ttya console + driver-config files"
# --- driver-config files (gotcha #3): the proto's name_to_major/driver_aliases/
#     driver_classes/minor_perm are near-empty stubs (no rootnex! -> kernel panic
#     'Couldn't find major number for rootnex' in setup_ddi). Copy the host's
#     full set (compatible: same illumos lineage; our drivers are a superset with
#     the same names for all core drivers).
for f in name_to_major driver_aliases driver_classes minor_perm; do
  $GCP "/etc/$f" "$BEROOT/etc/$f" 2>/dev/null || true
done
$GCP /etc/security/device_policy "$BEROOT/etc/security/device_policy" 2>/dev/null || true
cat > "$BEROOT/etc/vfstab" <<'EOF'
#device		device		mount		FS	fsck	mount	mount
#to mount	to fsck		point		type	pass	at boot	options
/devices	-		/devices	devfs	-	no	-
/proc		-		/proc		proc	-	no	-
ctfs		-		/system/contract ctfs	-	no	-
objfs		-		/system/object	objfs	-	no	-
sharefs		-		/etc/dfs/sharetab	sharefs	-	no	-
fd		-		/dev/fd		fd	-	no	-
swap		-		/tmp		tmpfs	-	yes	-
EOF
[ -f "$BEROOT/etc/hostid" ] || printf '0x1b0b57ec\n' > "$BEROOT/etc/hostid"
mkdir -p "$BEROOT/boot/solaris"
cat > "$BEROOT/boot/solaris/bootenv.rc" <<'EOF'
setprop console ttya
setprop os_console ttya
setprop ttya-mode 115200,8,n,1,-
setprop ttya-ignore-cd true
setprop ttya-rts-dtr-off false
EOF
# loader.conf: serial console + verbose boot (so the serial log shows progress)
cat > "$BEROOT/boot/loader.conf" <<'EOF'
console="ttya"
os_console="ttya"
boot-args="-v"
loader_logo="illumos"
EOF

# ---------------------------------------------------------------------------
# 6. external libs the SMF stack NEEDs but the gate proto lacks
#    (svccfg + svc.startd NEED libxml2 -> libz + libicuuc -> libicudata +
#    libstdc++ + libgcc_s). Placed at the standard /usr/lib[/amd64] paths so the
#    proto binaries resolve them via their normal RUNPATH. Provenance: host IPS
#    (libxml2/zlib/icu-78) + gcc-14 runtime (matches externalLibs slice).
#    TODO(P2): build from source / pin an IPS pkg instead of host copies.
# ---------------------------------------------------------------------------
log "adding external libs (libxml2/icu/zlib/libstdc++/libgcc_s), both ABIs"
add_extlibs() {  # $1 = src dir, $2 = dst dir
  local sd=$1 dd=$2
  for l in "$sd/libxml2.so.16" "$sd/libz.so.1" "$sd/libicuuc.so.78" "$sd/libicudata.so.78"; do
    [ -e "$l" ] && $GCP -L "$l" "$dd/$(basename "$l")"
  done
}
add_extlibs /usr/lib            "$BEROOT/usr/lib"
add_extlibs /usr/lib/amd64      "$BEROOT/usr/lib/amd64"
$GCP -L /usr/gcc/14/lib/libstdc++.so.6        "$BEROOT/usr/lib/libstdc++.so.6"
$GCP -L /usr/gcc/14/lib/libgcc_s.so.1         "$BEROOT/usr/lib/libgcc_s.so.1"
$GCP -L /usr/gcc/14/lib/amd64/libstdc++.so.6  "$BEROOT/usr/lib/amd64/libstdc++.so.6"
$GCP -L /usr/gcc/14/lib/amd64/libgcc_s.so.1   "$BEROOT/usr/lib/amd64/libgcc_s.so.1"

# --- sshd (for login evidence): sshd is NOT in the gate proto (separate IPS pkg).
#     Copy it (64-bit) + libcrypto/libssl + ssh-keygen, generate host keys, allow
#     root pubkey login, seed root's authorized_keys with the operator's key.
#     NOTE: sshd needs cryptosvc online (a known peripheral failure), so ssh may
#     not come up until that's fixed; the console svcs dump is the gate evidence.
log "adding sshd + openssl (64-bit) for login"
$GCP /usr/sbin/sshd "$BEROOT/usr/sbin/sshd" 2>/dev/null || true
$GCP /usr/bin/ssh-keygen "$BEROOT/usr/bin/ssh-keygen" 2>/dev/null || true
for l in libcrypto.so.3 libssl.so.3; do
  s=$(ls /usr/lib/amd64/$l 2>/dev/null || ls /lib/amd64/$l 2>/dev/null)
  [ -n "$s" ] && $GCP -L "$s" "$BEROOT/usr/lib/amd64/$l" 2>/dev/null || true
done
if [ -f /etc/ssh/sshd_config ]; then
  mkdir -p "$BEROOT/etc/ssh"
  $GCP /etc/ssh/sshd_config "$BEROOT/etc/ssh/sshd_config"
  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/; s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$BEROOT/etc/ssh/sshd_config" 2>/dev/null || true
  for t in rsa ecdsa ed25519; do
    [ -f "$BEROOT/etc/ssh/ssh_host_${t}_key" ] || /usr/bin/ssh-keygen -q -t $t -f "$BEROOT/etc/ssh/ssh_host_${t}_key" -N "" 2>/dev/null || true
  done
fi
if [ -n "${ROOT_AUTHKEY:-}" ] && [ -f "$ROOT_AUTHKEY" ]; then
  mkdir -p "$BEROOT/root/.ssh"; chmod 700 "$BEROOT/root/.ssh"
  $GCP "$ROOT_AUTHKEY" "$BEROOT/root/.ssh/authorized_keys"; chmod 600 "$BEROOT/root/.ssh/authorized_keys"
fi

# ---------------------------------------------------------------------------
# 7. seed the SMF repository (design-smf-init §3.2 + §5.1): copy the shipped
#    seed/global.db (27 core services incl. all milestones) to repository.db.
#    manifest-import at first boot then ADDS all /lib/svc/manifest/** (incl. our
#    solnix marker) to reach the full service set + the milestone.
# ---------------------------------------------------------------------------
log "seeding SMF repository from seed/global.db"
mkdir -p "$BEROOT/etc/svc"
$GCP "$BEROOT/lib/svc/seed/global.db" "$BEROOT/etc/svc/repository.db"
chmod 0600 "$BEROOT/etc/svc/repository.db"

# ---------------------------------------------------------------------------
# 8. solnix-generated SMF manifest + method (add-not-replace, design-smf-init §5)
# ---------------------------------------------------------------------------
log "installing solnix SMF marker manifest + method"
mkdir -p "$BEROOT/lib/svc/manifest/solnix" "$BEROOT/lib/svc/method"
if [ -n "${SMF_MANIFESTS:-}" ] && [ -d "$SMF_MANIFESTS/manifest/solnix" ]; then
  cp "$SMF_MANIFESTS"/manifest/solnix/*.xml "$BEROOT/lib/svc/manifest/solnix/" 2>/dev/null || true
fi
cat > "$BEROOT/lib/svc/manifest/solnix/solnix-hello.xml" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type="manifest" name="solnix:hello">
  <service name="site/solnix-hello" type="service" version="1">
    <single_instance/>
    <dependency name="fs" grouping="require_all" restart_on="none" type="service">
      <service_fmri value="svc:/system/filesystem/local:default"/>
    </dependency>
    <exec_method type="method" name="start" exec="/lib/svc/method/solnix-hello" timeout_seconds="120">
      <method_context><method_credential user="root"/></method_context>
    </exec_method>
    <exec_method type="method" name="stop" exec=":true" timeout_seconds="60">
      <method_context><method_credential user="root"/></method_context>
    </exec_method>
    <property_group name="startd" type="framework">
      <propval name="duration" type="astring" value="transient"/>
    </property_group>
    <instance name="default" enabled="true"/>
    <template>
      <common_name><loctext xml:lang="C">solnix Phase-1 gate marker</loctext></common_name>
    </template>
  </service>
</service_bundle>
EOF
# The marker runs EARLY (on filesystem/local, not multi-user) and, after a 45s
# settle, dumps full gate evidence (uname, milestone state, svcs -x, online list)
# to /dev/console so it lands in the EC2 serial console log (the gate evidence).
cat > "$BEROOT/lib/svc/method/solnix-hello" <<'EOF'
#!/sbin/sh
. /lib/svc/share/smf_include.sh
( sleep 45
  {
    echo ""
    echo "########## SOLNIX PHASE-1 GATE EVIDENCE ##########"
    echo "## uname -a:"; /usr/bin/uname -a
    echo "## solnix-release:"; cat /etc/solnix-release 2>/dev/null
    echo "## current milestone:"; /usr/bin/svcs -H milestone/multi-user-server milestone/multi-user 2>&1
    echo "## svcs -x (should be clean if healthy):"; /usr/bin/svcs -x 2>&1
    echo "## online service count:"; /usr/bin/svcs -a 2>/dev/null | grep -c online
    echo "## svcs -a (online only):"; /usr/bin/svcs -a 2>/dev/null | grep online | head -60
    echo "########## END SOLNIX GATE EVIDENCE ##########"
    echo ""
  } > /dev/console 2>&1
) &
exit $SMF_EXIT_OK
EOF
chmod 0755 "$BEROOT/lib/svc/method/solnix-hello"

# solnix-netcfg oneshot: DHCP on the first phys NIC (mirrors metadata-shim.sh)
cat > "$BEROOT/lib/svc/method/solnix-netcfg" <<'EOF'
#!/sbin/sh
. /lib/svc/share/smf_include.sh
NIC=$(/usr/sbin/dladm show-phys -p -o LINK 2>/dev/null | head -1)
if [ -n "$NIC" ]; then
  /usr/sbin/ipadm create-if "$NIC" 2>/dev/null || true
  /usr/sbin/ipadm create-addr -T dhcp -w 30 "$NIC/dhcp" 2>/dev/null || \
    /usr/sbin/ipadm create-addr -T dhcp "$NIC/v4" 2>/dev/null || true
fi
[ -s /etc/resolv.conf ] || printf 'nameserver 169.254.169.253\nnameserver 8.8.8.8\n' > /etc/resolv.conf
/usr/bin/hostname solnix 2>/dev/null || true
exit $SMF_EXIT_OK
EOF
chmod 0755 "$BEROOT/lib/svc/method/solnix-netcfg"
cat > "$BEROOT/lib/svc/manifest/solnix/solnix-netcfg.xml" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type="manifest" name="solnix:netcfg">
  <service name="site/solnix-netcfg" type="service" version="1">
    <single_instance/>
    <dependency name="devices" grouping="require_all" restart_on="none" type="service">
      <service_fmri value="svc:/milestone/devices:default"/>
    </dependency>
    <exec_method type="method" name="start" exec="/lib/svc/method/solnix-netcfg" timeout_seconds="60">
      <method_context><method_credential user="root"/></method_context>
    </exec_method>
    <exec_method type="method" name="stop" exec=":true" timeout_seconds="60">
      <method_context><method_credential user="root"/></method_context>
    </exec_method>
    <property_group name="startd" type="framework">
      <propval name="duration" type="astring" value="transient"/>
    </property_group>
    <instance name="default" enabled="true"/>
    <template><common_name><loctext xml:lang="C">solnix DHCP bringup</loctext></common_name></template>
  </service>
</service_bundle>
EOF
# site profile: enable our services (manifests default disabled) + disable the
# noisy non-essential sendmail (floods the console, blocks nothing).
mkdir -p "$BEROOT/etc/svc/profile/site"
cat > "$BEROOT/etc/svc/profile/site/solnix.xml" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type="profile" name="solnix">
  <service name="network/ssh" version="1" type="service"><instance name="default" enabled="true"/></service>
  <service name="site/solnix-netcfg" version="1" type="service"><instance name="default" enabled="true"/></service>
  <service name="site/solnix-hello" version="1" type="service"><instance name="default" enabled="true"/></service>
  <service name="network/smtp" version="1" type="service"><instance name="sendmail" enabled="false"/></service>
  <service name="network/sendmail-client" version="1" type="service"><instance name="default" enabled="false"/></service>
</service_bundle>
EOF
# validate against the DTD (build-time gate, design-smf-init §2.6)
for m in "$BEROOT/lib/svc/manifest/solnix/solnix-hello.xml" \
         "$BEROOT/lib/svc/manifest/solnix/solnix-netcfg.xml" \
         "$BEROOT/etc/svc/profile/site/solnix.xml"; do
  xmllint --noout --dtdvalid "$BEROOT/usr/share/lib/xml/dtd/service_bundle.dtd.1" "$m" 2>&1 && echo "DTD-valid: $(basename $m)"
done

# ---------------------------------------------------------------------------
# 9. root console login (serial console is the only EC2 access for the gate)
#    proto root already has an empty password; ensure the shell EXISTS (proto's
#    default /usr/bin/bash is absent -> point at /usr/bin/ksh93) and allow
#    empty-password console login.
# ---------------------------------------------------------------------------
log "root console login"
if [ -e "$BEROOT/usr/bin/ksh93" ]; then RSH=/usr/bin/ksh93; else RSH=/sbin/sh; fi
awk -F: -v sh="$RSH" 'BEGIN{OFS=":"} $1=="root"{$7=sh} {print}' \
  "$BEROOT/etc/passwd" > "$BEROOT/etc/passwd.new" && mv "$BEROOT/etc/passwd.new" "$BEROOT/etc/passwd"
awk -F: 'BEGIN{OFS=":"} $1=="root"{$2=""} {print}' \
  "$BEROOT/etc/shadow" > "$BEROOT/etc/shadow.new" && mv "$BEROOT/etc/shadow.new" "$BEROOT/etc/shadow"
chmod 0400 "$BEROOT/etc/shadow"
[ -f "$BEROOT/etc/default/login" ] && sed -i 's/^CONSOLE=/#CONSOLE=/; s/^PASSREQ=YES/PASSREQ=NO/' "$BEROOT/etc/default/login" || true

# ---------------------------------------------------------------------------
# 10. boot_archive (gzip-CPIO ramdisk with kernel + zfs/blkdev/nvme drivers)
# ---------------------------------------------------------------------------
log "building boot_archive (bootadm update-archive -R $BEROOT)"
[ -f "$BEROOT/etc/path_to_inst" ] || : > "$BEROOT/etc/path_to_inst"
bootadm update-archive -f -R "$BEROOT" 2>&1 | grep -vE '^gzip:|cannot find' | tail -6 || true
[ -f "$BEROOT/platform/i86pc/amd64/boot_archive" ] || die "boot_archive not built"
log "boot_archive: $(file "$BEROOT/platform/i86pc/amd64/boot_archive")"

# ---------------------------------------------------------------------------
# 11. install the loader on the ESP + bootfs + menu.lst
# ---------------------------------------------------------------------------
log "installing loader on ESP + setting bootfs"
mount -F pcfs "/dev/dsk/${DISK}s0" "$BEROOT/esp"
mkdir -p "$BEROOT/esp/EFI/Boot"
cp "$BEROOT/boot/loader64.efi" "$BEROOT/esp/EFI/Boot/bootx64.efi"
umount "$BEROOT/esp"
# gptzfsboot for legacy/BIOS (UEFI boots via the ESP loader; non-fatal warning)
installboot -fm "$BEROOT/boot/pmbr" "$BEROOT/boot/gptzfsboot" "/dev/rdsk/${DISK}s0" 2>&1 || \
  echo "NOTE: installboot -m warning is expected on EFI-labelled disks (UEFI uses the ESP loader)"
zpool set bootfs="$BEDS" "$POOL"
cat > "$BEROOT/boot/menu.lst" <<EOF
title solnix-1
bootfs $BEDS
EOF

# ---------------------------------------------------------------------------
# 12. finalize
# ---------------------------------------------------------------------------
log "finalizing"
cat > "$BEROOT/etc/solnix-release" <<EOF
solnix Phase-1 image
built: $(date -u +%FT%TZ)
proto: $PROTO
host:  $(uname -a)
EOF
sync
zfs set canmount=noauto "$BEDS"
umount "$BEROOT/esp" 2>/dev/null || true
zfs unmount "$BEDS" 2>/dev/null || zfs unmount -f "$BEDS" 2>/dev/null || true
zpool export "$POOL" || die "zpool export failed"

log "DONE: bootable solnix image on $DISK (pool $POOL, BE $BEDS)"
echo "Next: scripts/oi-be-to-ami.sh (snapshot the EBS vol -> register AMI)."
echo "DISK=$DISK POOL=$POOL BE=$BEDS"
