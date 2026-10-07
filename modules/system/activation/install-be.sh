#!/sbin/sh
# install-be -- populate a boot environment from a solnix toplevel, and nothing else.
#
# The single step shared by lib/make-be.nix (image), scripts/solnix-install
# (installer) and `switch-to-configuration boot` (new generation), so the three
# cannot drift. NixOS analog: nixos-install runs the toplevel's own
# switch-to-configuration boot. Interface (IFACE-1):
#
#   SOLNIX_ROOT=<mounted BE root>  SOLNIX_STORE_ROOT=<R: R/nix/store holds the closure; "" = live /nix>
#   SOLNIX_POOL=<pool> SOLNIX_BE=<be> [SOLNIX_CONSOLE=text|ttya] [SOLNIX_LIVE=1]
#   <toplevel>/bin/switch-to-configuration install-be <toplevel>
#
# Layout (docs/design-nix-managed-base.md): one shared <pool>/nix holds the store.
# Per generation, the early set (what runs before that dataset is mounted, plus the
# kernel the loader reads) is copied as REAL files to the same store paths inside
# the BE's own /nix; inittab mounts <pool>/nix over it with `zfs mount -O` (M4)
# before svc.startd. /usr/bin, /usr/sbin link into the toplevel's sw; /sbin into the
# early set; /lib, /usr/lib are real dirs of per-entry links into the userland so
# the ld.so.1 interpreter paths resolve before the mount. Every toplevel path is
# read through SOLNIX_STORE_ROOT (an absolute /nix/store link would otherwise
# resolve against the running system), and every link written into the BE is
# either relative or a /nix/store path, never a path on the running system.
set -u
TOP=$1
R=${SOLNIX_STORE_ROOT:-}
ROOT=${SOLNIX_ROOT:?SOLNIX_ROOT unset}
POOL=${SOLNIX_POOL:?SOLNIX_POOL unset}
BE=${SOLNIX_BE:?SOLNIX_BE unset}
CONS=${SOLNIX_CONSOLE:-ttya}
PATH=/usr/sbin:/usr/bin:/sbin
die() { echo "install-be: FATAL: $*" >&2; exit 1; }
say() { echo "install-be: $*" >&2; }
# no readlink(1) on illumos: derive the target from ls -l.
rl() { ls -ld "$1" 2>/dev/null | sed -n 's/.* -> //p'; }
# resolve a toplevel attribute link (absolute /nix/store target) through R.
attr() { t=$(rl "$R$TOP/$1"); [ -n "$t" ] || die "toplevel has no $1"; echo "$t"; }

[ -d "$ROOT" ] || die "SOLNIX_ROOT $ROOT is not a directory"
[ -e "$R$TOP/early-paths" ] || die "$TOP has no early-paths (not an install-be toplevel)"
WORLD=$(attr world); KERNEL=$(attr kernel-slice); EARLY=$(attr early)
DRV=$(attr drivers); ETC=$(attr etc); STOCK=$(attr stock)

# 1. early set + kernel as real files at their store paths inside the BE.
mkdir -p "$ROOT/nix/store"
for p in $(cat "$R$TOP/early-paths"); do
  [ -e "$ROOT$p" ] && continue
  [ -e "$R$p" ] || die "early path $p missing under store root '$R'"
  ( cd "$R/nix/store" && tar cf - "$(basename "$p")" ) | ( cd "$ROOT/nix/store" && tar xf - ) || die "copy $p"
done
say "early set: $(wc -l < "$R$TOP/early-paths" | tr -d ' ') store paths copied into $ROOT/nix/store"

# 2. root skeleton (state dirs are real; system code is linked).
cd "$ROOT" || die "cd $ROOT"
for d in dev devices proc system/contract system/object system/boot system/volatile tmp \
         var etc export/home root mnt run boot platform/i86pc usr var/empty; do mkdir -p "$d"; done
# the BE's own /nix is only the mountpoint + the early set; the shared dataset covers it at boot.
mkdir -p nix/var
chmod 1777 tmp
# /var and /etc start from the gate's stock tree (mutable state, as on a pkg install).
[ -e var/svc ] || ( cd "$R$STOCK" && tar cf - var ) | tar xf -
# the proto ships every dir 0555 (gotcha #7); /var/tmp must be world-writable+sticky
chmod 1777 var/tmp
[ -e etc/passwd ] || ( cd "$R$STOCK" && tar cf - etc ) | tar xf -
chmod -R u+w etc var
relink() { rm -f "$2"; ln -s "$1" "$2"; }
relink "$TOP/sw/bin" usr/bin;  relink "$WORLD/usr/sbin" usr/sbin;  relink usr/bin bin
# the rest of /usr and /opt: links into the userland; the gate's own relative
# links (usr/adm -> ../var/adm, ...) are reproduced as they are.
for d in usr opt; do
  [ -d "$R$WORLD/$d" ] || continue; mkdir -p "$d"
  for e in $(ls -A "$R$WORLD/$d"); do
    case $d/$e in usr/bin|usr/sbin|usr/lib|usr/kernel) continue;; esac
    [ -d "$d/$e" ] && [ ! -h "$d/$e" ] && continue
    rm -f "$d/$e"
    if [ -h "$R$WORLD/$d/$e" ]; then ln -s "$(rl "$R$WORLD/$d/$e")" "$d/$e"; else ln -s "$WORLD/$d/$e" "$d/$e"; fi
  done
done
# per-entry farms for lib dirs whose ld.so.1 must resolve before /nix is mounted.
# usr/lib/libc is left out: fs-root's libc_mount lofs-mounts the
# hardware-capability libc found there (32-bit libc_hwcapN.so.1, -xtarget
# pentium_pro builds) over /lib/libc.so.1, which here is a link into the libc
# store path, so the mount landed ON the store path and changed it (measured on
# the media: nix-store --verify-path failed on libc until the lofs mount was
# removed; seeding a target store from it failed "hash mismatch importing
# path"). Without the directory `moe` finds no variant and nothing is mounted;
# 32-bit processes use the plain libc, 64-bit ones never had a variant.
farm() {   # $1 = dir relative to /, mirrors $WORLD/$1
  mkdir -p "$1"
  for e in $(ls -A "$R$WORLD/$1"); do
    [ "$1/$e" = usr/lib/libc ] && { rm -f usr/lib/libc; continue; }
    if [ "$e" = amd64 ] && [ -d "$R$WORLD/$1/amd64" ]; then farm "$1/amd64"; continue; fi
    relink "$WORLD/$1/$e" "$1/$e"   # relink, not skip: a cloned BE points at the old generation
  done
}
farm lib; farm usr/lib; farm sbin
# the four early tools are real files in the BE; the rest of /sbin resolves after the mount.
for b in init sh zfs mount; do relink "$EARLY/sbin/$b" "sbin/$b"; done
RT=$(grep -- '-rtld$' "$R$TOP/early-paths")
for l in lib/ld.so.1 usr/lib/ld.so.1 lib/amd64/ld.so.1 usr/lib/amd64/ld.so.1; do
  case $l in *amd64*) relink "$RT/lib/amd64/ld.so.1" $l;; *) relink "$RT/lib/ld.so.1" $l;; esac
done
# kernel trees as REAL files (bootadm builds the boot_archive by walking the
# filelist dirs; a `kernel -> store` link would leave the modules out). Re-copied
# only when the generation's kernel slice changes (marker file).
if [ "$(cat .solnix-kernel 2>/dev/null)" != "$KERNEL" ]; then
  for t in kernel usr/kernel platform/i86pc/kernel platform/i86pc/amd64; do
    [ -e "$t" ] && find "$t" -depth -delete
    [ -e "$R$KERNEL/$t" ] && { mkdir -p "$(dirname "$t")"; ( cd "$R$KERNEL" && tar cf - "$t" ) | tar xf -; }
  done
  echo "$KERNEL" > .solnix-kernel
fi
[ -e platform/i86pc/kernel/amd64/unix ] || die "no unix after kernel copy"
# /boot: real files (loader64.efi, pmbr, gptzfsboot, forth, fonts, loader.rc) from the kernel slice;
# machine inputs the installer already wrote (loader.conf, bootenv.rc) are preserved.
for e in $(ls "$R$KERNEL/boot"); do
  case $e in solaris) mkdir -p boot/solaris; ( cd "$R$KERNEL/boot" && tar cf - solaris ) | ( cd boot && tar xf - ) ;;
             *) [ -e "boot/$e" ] || cp -R "$R$KERNEL/boot/$e" boot/ ;; esac
done
chmod -R u+w boot platform/i86pc/amd64 2>/dev/null
[ -d boot/fonts ] || die "/boot/fonts missing after copy"

# 3. /etc from the toplevel over the stock tree.
( cd "$R$ETC" && find . -type f -o -type l ) | while read -r f; do
  f=${f#./}; mkdir -p "etc/$(dirname "$f")"
  case $f in passwd|shadow|group|user_attr) continue;; esac
  rm -f "etc/$f"
  # links stay links (etc/ssl/certs/* -> the cacert store path, as NixOS's /etc does)
  if [ -h "$R$ETC/$f" ]; then ln -s "$(ls -ld "$R$ETC/$f" | sed -n 's/.* -> //p')" "etc/$f"
  else cp "$R$ETC/$f" "etc/$f"; fi
done
# accounts: stock lines stay; the toplevel's users (users.users) replace same-named ones.
# A declared user with no hashedPassword (shadow "NP") keeps the password already
# set on this BE (NixOS users.mutableUsers: the installer or `passwd` owns it), so a
# new generation does not lock out the user the installer gave a password.
for f in passwd shadow group user_attr; do
  [ -e "$R$ETC/$f" ] || continue
  [ -e "etc/$f" ] || : > "etc/$f"
  awk -F: -v f="$f" 'NR==FNR{own[$1]=$0; np[$1]=($2=="NP"); next}
           ($1 in own){ if (f=="shadow" && np[$1] && $2!="NP" && $2!="") print; else print own[$1]; delete own[$1]; next}
           {print}
           END{for(u in own) if (own[u]!="") print own[u]}' "$R$ETC/$f" "etc/$f" > "etc/$f.new" && mv "etc/$f.new" "etc/$f"
done
chmod 0400 etc/shadow
# Ownership and modes of the stock /etc and /var, from the gate's pkg(5) manifests
# (pkgs/illumos/data/drivers/etc-var-attrs.tsv). The store keeps no owners, so without this
# the whole tree is root-owned, and daemons that drop privilege cannot write their
# own state: dlmgmtd (dladm:netadm) failed to persist a new link to a root-owned
# /etc/dladm/datalink.conf, so the NIC never appeared in `dladm show-phys` and the
# installer found no network (measured on the media; the same steps with the gate's
# owners list e1000g0). Only entries present in the BE are touched, so a config that
# replaced a file keeps it. Names resolve through this BE's own passwd/group.
if [ -e "$R$DRV/etc-var-attrs.tsv" ]; then
  awk -F'\t' 'FILENAME=="etc/passwd"{split($0,a,":"); u[a[1]]=a[3]; next}
       FILENAME=="etc/group"{split($0,a,":"); g[a[1]]=a[3]; next}
       { if (!($3 in u) || !($4 in g)) { miss[$3":"$4]++; next }
         print $5, u[$3]":"g[$4], $2 }
       END { for (k in miss) printf "install-be: no account for %s (%d entries left root-owned)\n", k, miss[k] > "/dev/stderr" }' \
    etc/passwd etc/group "$R$DRV/etc-var-attrs.tsv" |
  while read -r m o p; do
    [ -e "$p" ] && [ ! -h "$p" ] || continue
    chown "$o" "$p" && chmod "$m" "$p" || die "cannot set $o $m on /$p"
  done
else
  die "$DRV has no etc-var-attrs.tsv (drivers db older than this install-be)"
fi
# driver database rendered from the gate's pkg manifests (pkgs/illumos/data/drivers).
for f in name_to_major driver_aliases minor_perm driver_classes; do cp "$R$DRV/$f" "etc/$f"; done
grep -q '^# solnix drivers' etc/security/device_policy || \
  { echo '# solnix drivers'; cat "$R$DRV/device_policy.add"; } >> etc/security/device_policy
[ -e etc/path_to_inst ] || : > etc/path_to_inst
# pkcs11_tpm.so NEEDs libtspi (trousers), which is not built: every libpkcs11
# consumer that loads it dies in ld.so.1 (measured: `digest -a sha1` killed, so
# bootadm writes an empty boot_archive.hash). Drop the provider that cannot load.
grep -v 'pkcs11_tpm' etc/crypto/pkcs11.conf > etc/crypto/pkcs11.conf.new && mv etc/crypto/pkcs11.conf.new etc/crypto/pkcs11.conf
# no /etc/hostid (NixOS writes one only when networking.hostId is set): the kernel
# then derives the hostid from the SMBIOS UUID and system/hostid (svc-hostid)
# persists it in the rot47-quoted form the kernel's reader expects.

# declared users' authorized_keys (users.users.<n>.openssh.authorizedKeys).
[ -e "$R$TOP/seed-authorized-keys" ] && ROOT="$ROOT" /usr/bin/bash "$R$TOP/seed-authorized-keys" >&2

# 4. inittab: mount the shared store FIRST (before autopush/soconfig, which live in
#    the shared store, and before svc.startd; measured ctB4 + M4).
if [ -z "${SOLNIX_LIVE:-}" ] && ! grep -q '^nx::sysinit' etc/inittab; then
  awk -v p="$POOL" '/::sysinit:/ && !d {print "nx::sysinit:/sbin/zfs mount -O " p "/nix >/dev/msglog 2<>/dev/msglog </dev/console"; d=1} {print}' \
    etc/inittab > etc/inittab.new && mv etc/inittab.new etc/inittab
fi

# 5. SMF: fresh seed repository + solnix manifests (site dir, real files) + site profile.
[ -e etc/svc/repository.db ] || { cp "$R$WORLD/lib/svc/seed/global.db" etc/svc/repository.db; chmod 0600 etc/svc/repository.db; }
mkdir -p var/svc/manifest/site/solnix etc/svc/profile/site
cp "$R$TOP"/manifest/solnix/*.xml var/svc/manifest/site/solnix/ 2>/dev/null
cp "$R$TOP/site-profile.xml" etc/svc/profile/site/solnix.xml
( cd etc/svc/profile && relink generic_limited_net.xml generic.xml && relink platform_none.xml platform.xml && relink ns_files.xml name_service.xml )

# 6. /dev: the nodes needed before devfsadm runs, generated (never copied from the running /dev).
for n in console:cn@0:console msglog:sysmsg@0:msglog null:mm@0:null zero:mm@0:zero tty:sy@0:tty \
         syscon:cn@0:syscon systty:cn@0:systty sysmsg:sysmsg@0:sysmsg random:random@0:random \
         urandom:random@0:urandom poll:poll@0:poll conslog:log@0:conslog log:log@0:log zfs:zfs@0:zfs \
         ticotsord:tl@0:ticotsord ticots:tl@0:ticots ticlts:tl@0:ticlts keysock:keysock@0:keysock \
         spdsock:spdsock@0:spdsock cryptoadm:cryptoadm@0:cryptoadm crypto:crypto@0:crypto pm:pm@0:pm \
         tcp:tcp@0:tcp tcp6:tcp6@0:tcp6 udp:udp@0:udp udp6:udp6@0:udp6 icmp:icmp@0:icmp icmp6:icmp6@0:icmp6 \
         rawip:icmp@0:icmp rawip6:icmp6@0:icmp6 ip:ip@0:ip ip6:ip6@0:ip6 arp:arp@0:arp; do
  relink "../devices/pseudo/${n#*:}" "dev/${n%%:*}"
done
for i in 0 1 2; do relink "./fd/$i" "dev/$(echo stdin stdout stderr | cut -d' ' -f$((i+1)))"; done
# The tl/keysock/spdsock links are the /dev paths sock2path.d maps AF_UNIX and
# PF_KEY/PF_POLICY to, and tcp/udp/icmp are the TPI fallback devices sockfs opens
# for a STREAMS ioctl on an AF_INET socket ("Failed to convert socket to TPI
# (err=2)" when absent) -- inittab's soconfig runs before devfsadmd makes them;
# measured: AF_UNIX unmapped -> nix-daemon cannot listen); cryptoadm/crypto/pm
# are opened by cryptosvc and pmconfig before devfsadmd catches up (gotcha #11).
# NOTE: a hand list of early pseudo nodes; a full first-boot `devfsadm` would
# replace it, at the price of the forced reconfigure check (f) forbids.
# the rest of the gate pkg manifests' dev/ actions (system-kernel.p5m, SUNWcsd.p5m).
# Without dev/dld, dlmgmtd exits 1 -> datalink-management fails -> system/device/local
# (devfsadm, then the soconfig rerun that maps AF_UNIX to /dev/ticotsord) never runs.
relink ../devices/pseudo/dld@0:ctl dev/dld
for d in dsk fd ipnet net pts rdsk rmt sad swap term vt zcons; do mkdir -p "dev/$d"; done
# inittab's `autopush -f /etc/iu.ap` runs before devfsadm and opens /dev/sad/admin;
# without the link it configures nothing, ldterm is never pushed on the console,
# and every boot message is a line feed with no carriage return (the staircase
# console seen on the X1 and under KVM; running autopush by hand fixed it).
relink ../../devices/pseudo/sad@0:admin dev/sad/admin
relink ../../devices/pseudo/sad@0:user dev/sad/user

# 7. this BE is one generation: /run/{current,booted}-system are fixed for it.
relink "$TOP" run/current-system; relink "$TOP" run/booted-system
# GC roots in the shared store, as NixOS has them: gcroots/profiles names the
# store's own profiles dir (nix creates it as <store root>/nix/var/nix/profiles
# when the store is first opened under a chroot root, which is wrong once booted),
# and the running/booted generation are indirect roots (nix-daemon.nix,
# activation-script.nix).
G="$R/nix/var/nix/gcroots"; mkdir -p "$G"
relink /nix/var/nix/profiles "$G/profiles"
# `nix-env --store local?root=<staging> -p <staging>/nix/var/nix/profiles/system`
# records an INDIRECT root in gcroots/auto naming the staging path (measured:
# auto/a15k9a7j... -> /var/tmp/ii/media/rd/nix/var/nix/profiles/system-1-link),
# which dangles once the store is mounted at /nix. gcroots/profiles above already
# keeps every system-N-link, as on NixOS, so drop auto roots that point outside
# this system's own /nix.
if [ -d "$G/auto" ]; then
  for a in "$G"/auto/*; do
    [ -h "$a" ] || continue
    case "$(rl "$a")" in /nix/*|/run/*) : ;; *) rm -f "$a" ;; esac
  done
fi
relink /run/current-system "$G/current-system"; relink /run/booted-system "$G/booted-system"

# 7b. /etc/system.d: the kernel reads only /etc/system.d/.self-assembly (modsysfile.c),
#     which `bootadm update-archive` assembles from the directory. A live root skips
#     bootadm, so its system.d tunables never applied (measured in a crash dump of the
#     media: zfs_arc_max 0 and hid_errlevel unset despite system.d/solnix-live-arc and
#     solnix-hid-quiet; the uncapped ARC starved the installer until the ZFS deadman
#     panicked "I/O to pool 'rpool' appears to be hung"). Assemble it here for every
#     root, the way bootadm's build_etc_system_dir does (sorted, dot files skipped).
if [ -d etc/system.d ]; then
  : > etc/system.d/.self-assembly.new
  for f in $(ls etc/system.d | LC_ALL=C sort); do
    case $f in .*) continue ;; esac
    cat "etc/system.d/$f" >> etc/system.d/.self-assembly.new
  done
  if [ -s etc/system.d/.self-assembly.new ]; then mv etc/system.d/.self-assembly.new etc/system.d/.self-assembly
  else rm -f etc/system.d/.self-assembly.new etc/system.d/.self-assembly; fi
fi

# 8. console + boot archive.
[ -e boot/loader.conf ] || printf 'console="%s"\nos_console="%s"\n' "$CONS" "$CONS" > boot/loader.conf
[ -e boot/solaris/bootenv.rc ] || printf 'setprop console %s\nsetprop ttya-mode 115200,8,n,1,-\n' "$CONS" > boot/solaris/bootenv.rc
# A live root (SOLNIX_LIVE=1, the installer media) IS the boot_archive: the image
# builder turns this whole tree into it. An inner archive would be a ~150 MB copy
# of the same files inside the ramdisk, which does not fit (measured: cpio "End of
# medium on output" filled the 654 MB ramdisk) and is deleted right after anyway.
if [ -z "${SOLNIX_LIVE:-}" ]; then
  bootadm update-archive -f -R "$ROOT" >&2 || die "bootadm update-archive failed"
  [ -s platform/i86pc/amd64/boot_archive ] || die "no boot_archive"
fi
say "BE $POOL/ROOT/$BE populated from $TOP"
