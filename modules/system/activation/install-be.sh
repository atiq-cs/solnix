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
# Laid into a staging dir, then merged WITHOUT replacing any file already in the BE:
# the installer writes the machine inputs (etc/path_to_inst, etc/hostid,
# etc/svc/profile/site/solnix-install.xml) before this runs, and a plain tar over
# them restored the stock ones. The X1's first boot from NVMe then hung after cpu5:
# its path_to_inst was the stock "#path_to_inst_bootstrap_1" instead of the 91
# bindings the installer copied (measured on the disk, and in its boot_archive).
_stage=.solnix-stock.$$
if [ ! -e var/svc ] || [ ! -e etc/passwd ]; then
  mkdir -p "$_stage"
  ( cd "$R$STOCK" && tar cf - etc var ) | ( cd "$_stage" && tar xf - ) || die "stage the stock /etc and /var"
  find "$_stage" ! -type l -exec chmod u+w {} + || die "chmod u+w the stock stage"
  for _t in etc var; do
    # files and links not already in the BE move in; directories are created
    # (their owners and modes are set by the ownership pass below).
    ( cd "$_stage" && find "$_t" ! -type d -print ) | while read -r _p; do
      if [ -e "$_p" ] || [ -h "$_p" ]; then continue; fi    # the BE's own file wins
      mkdir -p "$(dirname "$_p")" && mv "$_stage/$_p" "$_p" || { echo "install-be: FATAL: lay /$_p" >&2; exit 1; }
    done || die "merging the stock /$_t"
    ( cd "$_stage" && find "$_t" -type d -print ) | while read -r _p; do mkdir -p "$_p"; done
  done
  find "$_stage" -depth -delete
fi
# the proto ships every dir 0555 (gotcha #7); /var/tmp must be world-writable+sticky
chmod 1777 var/tmp
# NOT chmod -R: illumos chmod -R follows symbolic links, so on a BE that already
# has /etc links into the store it made the store files writable (measured on the
# X1: the cacert bundle /etc/ssl/certs links to was the one 0644 file in its store
# path, changed when solnix-2 was laid).
find etc var ! -type l -exec chmod u+w {} + || die "chmod u+w /etc /var"
# The store hard-links identical files (auto-optimise-store), and tar keeps hard
# links, so the stock tree arrived with e.g. eleven empty files sharing one inode
# (etc/driver_classes, etc/versions/build, etc/mnttab, etc/security/dev/*, ...).
# Writing one then rewrote all of them: the driver database copy below changed
# etc/versions/build, a boot-archive file, so every boot found the archive stale,
# rebuilt it and rebooted, forever (measured on the first KVM-installed disk: 26
# "WARNING: Reboot required" cycles in system-filesystem-usr's log). Mutable
# state must be separate files, so break every link in /etc and /var.
find etc var -type f -links +1 | while read -r f; do
  cp -p "$f" "$f.unlink" && mv -f "$f.unlink" "$f" || die "cannot break the hard link on /$f"
done
[ -z "$(find etc var -type f -links +1 | head -1)" ] || die "/etc or /var still has hard-linked files"
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
# the early tools are real files in the BE; the rest of /sbin resolves after the mount.
for b in init sh zfs mount autopush; do relink "$EARLY/sbin/$b" "sbin/$b"; done
RT=$(grep -- '-rtld$' "$R$TOP/early-paths")
for l in lib/ld.so.1 usr/lib/ld.so.1 lib/amd64/ld.so.1 usr/lib/amd64/ld.so.1; do
  case $l in *amd64*) relink "$RT/lib/amd64/ld.so.1" $l;; *) relink "$RT/lib/ld.so.1" $l;; esac
done
# kernel trees as REAL files (bootadm builds the boot_archive by walking the
# filelist dirs; a `kernel -> store` link would leave the modules out). Re-copied
# only when the generation's kernel slice changes (marker file).
# A live root (the installer media) holds its own store on the same filesystem:
# there the trees are HARD LINKS to the store's files (real files to bootadm and
# the kernel, no second copy). The copy was 94.5 MB of a ramdisk capped at 700 MiB
# (measured on the installer toplevel). An installed BE's /nix is a separate
# dataset, so it keeps real copies. The store's files are read-only and the trees
# are only read, so sharing the inode cannot change the store.
_ktree() {   # $1 = tree relative to the kernel slice
  if [ -n "${SOLNIX_LIVE:-}" ] && [ "$ROOT" = "$R" ]; then
    ( cd "$R$KERNEL" && find "$1" -print ) | while read -r _e; do
      if [ -d "$R$KERNEL/$_e" ] && [ ! -h "$R$KERNEL/$_e" ]; then mkdir -p "$_e"
      elif [ -h "$R$KERNEL/$_e" ]; then ln -s "$(rl "$R$KERNEL/$_e")" "$_e"
      else ln "$R$KERNEL/$_e" "$_e" || { echo "install-be: FATAL: hard link /$_e" >&2; exit 1; }
      fi
    done || die "linking the kernel tree $1"
  else
    ( cd "$R$KERNEL" && tar cf - "$1" ) | tar xf - || die "copying the kernel tree $1"
  fi
}
if [ "$(cat .solnix-kernel 2>/dev/null)" != "$KERNEL" ]; then
  for t in kernel usr/kernel platform/i86pc/kernel platform/i86pc/amd64; do
    [ -e "$t" ] && find "$t" -depth -delete
    [ -e "$R$KERNEL/$t" ] && { mkdir -p "$(dirname "$t")"; _ktree "$t"; }
  done
  echo "$KERNEL" > .solnix-kernel
fi
[ -e platform/i86pc/kernel/amd64/unix ] || die "no unix after kernel copy"
# /boot: real files (loader64.efi, pmbr, gptzfsboot, forth, fonts, loader.rc) from the kernel slice;
# machine inputs the installer already wrote (loader.conf, bootenv.rc) are preserved.
# /boot from the kernel slice, merging over what is already there (machine inputs).
lay_boot() {
  for e in $(ls "$R$KERNEL/boot"); do
    # boot/solaris: merged entry by entry. A tar copy of the whole directory replaced
    # the installer's bootenv.rc (its console setprop) with the stock one (measured
    # under KVM: solnix-install's machine-input check failed "first line now: #").
    case $e in solaris) mkdir -p boot/solaris
                        for _s in $(ls -A "$R$KERNEL/boot/solaris"); do
                          if [ -e "boot/solaris/$_s" ] || [ -h "boot/solaris/$_s" ]; then continue; fi
                          ( cd "$R$KERNEL/boot/solaris" && tar cf - "$_s" ) | ( cd boot/solaris && tar xf - ) \
                            || die "copy boot/solaris/$_s"
                        done ;;
               *) [ -e "boot/$e" ] || cp -R "$R$KERNEL/boot/$e" boot/ ;; esac
  done
}
lay_boot
# find ! -type l, not chmod -R, which follows links: boot/solaris/bin/root_archive
# -> ../../../usr/sbin/root_archive resolves into the userland store path, and
# chmod -R made that store file 0755 (measured on the X1's live store).
find boot ! -type l -exec chmod u+w {} + 2>/dev/null
# platform/i86pc/amd64 holds bootadm's boot_archive: writable on a real BE. On a live
# root its files are hard links into the store, so a chmod would make the STORE
# writable; the live root builds no boot_archive there (step 8), so leave it.
[ -n "${SOLNIX_LIVE:-}" ] || find platform/i86pc/amd64 ! -type l -exec chmod u+w {} + 2>/dev/null
[ -d boot/fonts ] || die "/boot/fonts missing after copy"

# 3. /etc from the toplevel over the stock tree, as NixOS's setup-etc.pl lays it:
#    etc/static is the generation's etc store path, and each managed file is a
#    link into it, so the generation owns the file and the next one replaces it.
#    The links are relative (etc/ssh/sshd_config -> ../static/ssh/sshd_config;
#    NixOS writes /etc/static/...) so they also resolve under an altroot.
#    etc/static itself names the store path; nothing reads a managed file before
#    inittab's first sysinit line mounts <pool>/nix (step 4).
# etc_copy: the files that stay REAL copies, NixOS's environment.etc.<n>.mode.
#    The store is writable by root here (no read-only bind mount on illumos), and a
#    root write THROUGH a link rewrites the store file (measured: `cp` and `>>` onto
#    a link to a 0444 file), so anything written in place must be a copy.
etc_copy() {
  case $1 in
    # replaced from the DHCP lease (solnix-net, net-svc, dns-install).
    resolv.conf) return 0 ;;
    # net-loc and dns-install `cp` a template over it in place.
    nsswitch.conf) return 0 ;;
    # solnix-install edits it on the target (PermitRootLogin, UsePAM).
    ssh/sshd_config) return 0 ;;
    # init reads it before inittab mounts <pool>/nix.
    default/init) return 0 ;;
    # boot-archive inputs: the kernel reads them from the archive, where a link
    # into /nix would dangle.
    system|system.d/*) return 0 ;;
    # read by the kernel (usba_devdb.c kobj_open_file) when USB hubs attach,
    # which can precede the /nix mount -- same reason as system.d.
    usb/config_map.conf) return 0 ;;
    # boot -a alternate system files are assembled from these below.
    system.alt/*) return 0 ;;
    # `coreadm -U` imports it into SMF and renames it to coreadm.conf.old.
    coreadm.conf) return 0 ;;
    # dumpadm(8) rewrites /etc/dumpadm.conf (and svc:/system/dumpadm reads it).
    dumpadm.conf) return 0 ;;
    # svc:/system/power's method appends a statefile line to it in place.
    power.conf) return 0 ;;
    # install-be filters pkcs11.conf below; cryptoadm rewrites it.
    crypto/*) return 0 ;;
  esac
  return 1
}
relink "$ETC" etc/static
( cd "$R$ETC" && find . -type f -o -type l ) | while read -r f; do
  f=${f#./}; mkdir -p "etc/$(dirname "$f")"
  case $f in passwd|shadow|group|user_attr) continue;; esac   # merged below
  rm -f "etc/$f"
  if etc_copy "$f"; then
    if [ -h "$R$ETC/$f" ]; then ln -s "$(rl "$R$ETC/$f")" "etc/$f"; else cp "$R$ETC/$f" "etc/$f"; fi
  else
    ln -s "$(echo "$f" | sed 's,[^/]*/,../,g; s,[^/]*$,,')static/$f" "etc/$f"
  fi || { echo "install-be: FATAL: lay /etc/$f" >&2; exit 1; }
done || die "laying the managed /etc"
# links into etc/static that this generation no longer has (a file a previous
# generation managed): removed, as setup-etc.pl's cleanup does.
find etc -type l ! -name static | while read -r l; do
  case "$(rl "$l")" in *static/"${l#etc/}") [ -e "$R$ETC/${l#etc/}" ] || [ -h "$R$ETC/${l#etc/}" ] || rm -f "$l" ;; esac
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
    chown "$o" "$p" && chmod "$m" "$p" || { echo "install-be: FATAL: cannot set $o $m on /$p" >&2; exit 1; }
  done || die "ownership pass failed"   # the loop runs in a pipeline subshell: its exit status is the only signal
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

# 4. inittab: mount the shared store right AFTER autopush (ap::, from the early set)
#    and before soconfig, which lives in the shared store, and svc.startd
#    (measured ctB4 + M4). Not before ap::: autopush applies only to streams built
#    after it runs, and these lines' msglog/console redirects open the console, so
#    ahead of ap:: the console never gets ldterm and every boot message is a bare
#    line feed (the staircase console). Stock illumos keeps ap:: first for this.
# 4a. right after it, the shared /var state (docs/design-var-state.md): every
#    canmount=noauto dataset under <pool>/var is mounted with -O over the BE's own
#    directory, so logs, /var/tmp, /var/lib and the spools are one copy for every
#    generation and a rollback does not revert them (NixOS: /var is not part of a
#    generation). Here, not in filesystem/local: svc.startd writes /var/svc/log and
#    utmpx/wtmpx as soon as filesystem/minimal is online, before `zfs mount -a`, and
#    noauto keeps `zfs mount -a` from trying a non-empty BE directory. A pool
#    without <pool>/var mounts nothing and the BE keeps its own /var.
# A BE laid by an older install-be has nx:: and vr:: ahead of ap::; both are moved.
if [ -z "${SOLNIX_LIVE:-}" ]; then
  grep -q '^ap::sysinit' etc/inittab || die "inittab has no ap::sysinit (autopush) line to mount the store after"
  _nx="nx::sysinit:/sbin/zfs mount -O $POOL/nix >/dev/msglog 2<>/dev/msglog </dev/console"
  _vr="vr::sysinit:/sbin/sh -c '/sbin/zfs list -H -o canmount,name -r -t filesystem $POOL/var 2>/dev/null | while read c n; do [ \"\$c\" = noauto ] && /sbin/zfs mount -O \"\$n\"; done; exit 0' >/dev/msglog 2<>/dev/msglog </dev/console"
  awk -v n="$_nx" -v v="$_vr" '/^(nx|vr)::sysinit/ {next} {print} /^ap::sysinit/ && !d {print n; print v; d=1}' \
    etc/inittab > etc/inittab.new && mv etc/inittab.new etc/inittab
  [ "$(grep -E '^[^#:]*:[^:]*:sysinit:' etc/inittab | head -3 | cut -d: -f1 | tr '\n' ' ')" = "ap nx vr " ] \
    || die "inittab sysinit order is not ap, nx, vr"
fi
# their mountpoints exist in the BE (zfs mount creates a missing one, which a BE
# cloned before the dataset existed may lack); the dataset name is the path.
[ -n "${SOLNIX_LIVE:-}" ] || zfs list -H -o name -r -t filesystem "$POOL/var" 2>/dev/null \
  | while read -r _n; do mkdir -p "${_n#"$POOL"/}"; done

# 5. SMF: fresh seed repository + solnix manifests (site dir, real files) + site profile.
[ -e etc/svc/repository.db ] || { cp "$R$WORLD/lib/svc/seed/global.db" etc/svc/repository.db; chmod 0600 etc/svc/repository.db; }
# The manifests are REAL copies in a real /var/svc/manifest/site/solnix holding
# exactly this generation's set. svccfg records a manifest by its realpath, and
# `svccfg cleanup` (manifest-import's last step) deletes a service only when
# every recorded manifest is gone AND under lib/svc/manifest or var/svc/manifest
# (svccfg_libscf.c lscf_service_cleanup); a store path makes it skip the service.
# Measured with a private repository: a manifest dir that is a link into the
# store kept a removed service forever; real copies here dropped it at cleanup.
# NOT /lib/svc/manifest/solnix: /lib/svc links into the userland store path, so a
# write there lands in the store.
_sm=var/svc/manifest/site/solnix
[ -h "$_sm" ] && rm -f "$_sm"
mkdir -p "$_sm" etc/svc/profile/site
for _m in "$_sm"/*.xml; do
  [ -e "$_m" ] || continue
  [ -e "$R$TOP/manifest/solnix/${_m##*/}" ] || rm -f "$_m"   # a service this generation dropped
done
for _m in "$R$TOP"/manifest/solnix/*.xml; do
  [ -e "$_m" ] || continue
  rm -f "$_sm/${_m##*/}"; cp "$_m" "$_sm/" || die "copy the manifest ${_m##*/}"
done
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
# setuid/setgid programs (NixOS security.wrappers, /run/wrappers/bin). The store
# keeps no setuid bits, so the world's copies of the gate's setuid programs
# (pkgs/illumos/data/drivers/setuid.tsv, from the pkg(5) manifests) ran
# unprivileged: `w`/`uptime` "failed to enable privilege bracketing", `ping`
# "socket Permission denied", passwd/su/crontab/at not setuid (measured on the
# first installed disk; a setuid copy of each worked). Each one is copied out of
# the world with the manifest's owner, group and mode. Its RUNPATH already pins its
# libraries into the store, so the copy is the program itself. /run is a per-BE
# directory, so the copies belong to this generation.
WR=run/wrappers/bin
[ -d run/wrappers ] && find run/wrappers -depth -delete
mkdir -p "$WR"; chmod 0755 run/wrappers "$WR"
[ -e "$R$DRV/setuid.tsv" ] || die "$DRV has no setuid.tsv (drivers db older than this install-be)"
# owner and group by NUMBER from this BE's passwd/group: chown by name resolves
# against the running system's databases, which on a build host or the media need
# not have the BE's accounts (measured: "chown: unknown group id smmsp").
awk -F'\t' 'FILENAME=="etc/passwd"{split($0,a,":"); u[a[1]]=a[3]; next}
     FILENAME=="etc/group"{split($0,a,":"); g[a[1]]=a[3]; next}
     { if (!($2 in u) || !($3 in g)) { printf "install-be: setuid: no account for %s:%s, skipping /%s\n", $2, $3, $4 > "/dev/stderr"; next }
       print $1, u[$2]":"g[$3], $4 }' etc/passwd etc/group "$R$DRV/setuid.tsv" |
while read -r m o p; do
  src="$R$WORLD/$p"; [ -f "$src" ] || continue        # not built into this world
  b=$(basename "$p")
  [ -e "$WR/$b" ] && { say "setuid: $p and an earlier entry share the name $b; keeping the first"; continue; }
  cp "$src" "$WR/$b" && chmod 0000 "$WR/$b" && chown "$o" "$WR/$b" && chmod "$m" "$WR/$b" \
    || { echo "install-be: FATAL: cannot install the setuid copy of /$p" >&2; exit 1; }
done || die "setuid pass failed"   # pipeline subshell: die inside it would not stop install-be
say "setuid: $(ls "$WR" | wc -l | tr -d ' ') privileged programs in /$WR"
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
# keeps every system-N-link, as on NixOS, so drop the auto roots that point INTO
# the staging root. Only those, and only when there is one: with the live store
# (R="", switch-to-configuration boot) every auto root is a real user's
# (nix-build's ./result, home-manager's generations), and dropping the ones outside
# /nix lets the next GC delete their closures (measured on the X1: 17 of 49).
drop_staging_roots() {   # $1 = gcroots dir, $2 = staging store root ("" = none)
  [ -n "$2" ] && [ -d "$1/auto" ] || return 0
  for a in "$1"/auto/*; do
    [ -h "$a" ] || continue
    case "$(rl "$a")" in "$2"/*) rm -f "$a" ;; esac
  done
}
drop_staging_roots "$G" "$R"
relink /run/current-system "$G/current-system"; relink /run/booted-system "$G/booted-system"
# per-user core directories (modules/config/coreadm.nix developerUsers): the
# per-process core pattern writes /var/cores/<uid>/core.* with the crashing
# process's credentials, so each listed user needs a directory they own there.
# Created when absent; a user's existing cores are left alone. /var/cores is a
# shared dataset on <pool>/var systems, so this persists across generations.
if [ -s "$R$ETC/solnix/core-users" ]; then
  mkdir -p var/cores && chmod 0755 var/cores
  while read -r _cu; do
    [ -n "$_cu" ] || continue
    _cg=$(awk -F: -v u="$_cu" '$3==u{print $4; exit}' etc/passwd)
    [ -n "$_cg" ] || die "core-users: uid $_cu is not in this BE's passwd"
    [ -d "var/cores/$_cu" ] || mkdir -p "var/cores/$_cu"
    chown "$_cu:$_cg" "var/cores/$_cu" && chmod 0700 "var/cores/$_cu" \
      || die "core-users: chown var/cores/$_cu"
  done < "$R$ETC/solnix/core-users"
fi
# root's channel subscription, as NixOS's tmpfiles rule `f /root/.nix-channels`:
# written when absent, never overwritten (the admin's nix-channel --add wins).
# /root lives in the BE, so a new BE starts from the previous one's copy.
if [ -e "$R$ETC/solnix/root-nix-channels" ] && [ ! -e root/.nix-channels ]; then
  mkdir -p root && cp "$R$ETC/solnix/root-nix-channels" root/.nix-channels && chmod 0644 root/.nix-channels \
    || die "writing /root/.nix-channels"
fi

# 7a. the initial PATH. sshd (read_etc_default_login, for sessions that never source
#     /etc/profile: `ssh host cmd`), su and login all start a session with PATH
#     (SUPATH for root) from /etc/default/login. The stock value has neither the
#     setuid copies nor the system profile, so `ssh dixi uptime` ran the store's
#     non-setuid uptime: "failed to enable privilege bracketing" (measured on the
#     X1). Same order as /etc/profile.d/solnix-env.sh: wrappers first, then sw.
if [ -f etc/default/login ]; then
  _p=/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/usr/sbin:/sbin:/usr/gnu/bin
  _sp=/run/wrappers/bin:/run/current-system/sw/bin:/usr/sbin:/sbin:/usr/bin:/usr/gnu/bin
  sed -e "s,^#*PATH=.*,PATH=$_p," -e "s,^#*SUPATH=.*,SUPATH=$_sp," etc/default/login > etc/default/login.new \
    && mv etc/default/login.new etc/default/login || die "setting PATH in /etc/default/login"
  grep -q "^PATH=$_p\$" etc/default/login && grep -q "^SUPATH=$_sp\$" etc/default/login \
    || die "/etc/default/login has no PATH=/SUPATH= line to set"
fi

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
# Alternate system files for `boot -a` ("Name of system file"). Naming one replaces
# BOTH /etc/system and the self-assembly (modctl.c mod_askparams), so each is the
# full normal configuration plus its extra lines: etc/system.alt/<name>.extra ->
# etc/system.alt/<name>. Real files: the kernel opens them before /nix is reachable.
if [ -d etc/system.alt ]; then
  for _x in etc/system.alt/*.extra; do
    [ -e "$_x" ] || continue
    _alt=${_x%.extra}
    { cat etc/system 2>/dev/null; cat etc/system.d/.self-assembly 2>/dev/null
      echo "* --- $(basename "$_alt") (boot -a alternate) ---"; cat "$_x"; } > "$_alt.new" \
      && rm -f "$_alt" && mv "$_alt.new" "$_alt" || die "assembling $_alt"
  done
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
