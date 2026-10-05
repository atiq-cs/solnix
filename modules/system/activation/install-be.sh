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
farm() {   # $1 = dir relative to /, mirrors $WORLD/$1
  mkdir -p "$1"
  for e in $(ls -A "$R$WORLD/$1"); do
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
  for t in kernel usr/kernel platform/i86pc/kernel; do
    [ -e "$t" ] && find "$t" -depth -delete
    [ -e "$R$KERNEL/$t" ] && { mkdir -p "$(dirname "$t")"; ( cd "$R$KERNEL" && tar cf - "$t" ) | tar xf -; }
  done
  echo "$KERNEL" > .solnix-kernel
fi
[ -e platform/i86pc/kernel/amd64/unix ] || die "no unix after kernel copy"
# /boot: real files (loader64.efi, pmbr, gptzfsboot, forth, fonts, loader.rc) from the kernel slice;
# machine inputs the installer already wrote (loader.conf, bootenv.rc) are preserved.
for e in $(ls "$R$KERNEL/boot"); do
  case $e in solaris) mkdir -p boot/solaris; cp -R "$R$KERNEL/boot/solaris/." boot/solaris/ ;;
             *) [ -e "boot/$e" ] || cp -R "$R$KERNEL/boot/$e" boot/ ;; esac
done
chmod -R u+w boot platform/i86pc/amd64 2>/dev/null
[ -d boot/fonts ] || die "/boot/fonts missing after copy"

# 3. /etc from the toplevel over the stock tree.
( cd "$R$ETC" && find . -type f -o -type l ) | while read -r f; do
  f=${f#./}; mkdir -p "etc/$(dirname "$f")"
  case $f in passwd|shadow|group) continue;; esac
  rm -f "etc/$f"; cp "$R$ETC/$f" "etc/$f"
done
# accounts: stock lines stay; the toplevel's users (users.users) replace same-named ones.
for f in passwd shadow group; do
  [ -e "$R$ETC/$f" ] || continue
  awk -F: 'NR==FNR{own[$1]=$0; next} ($1 in own){print own[$1]; delete own[$1]; next} {print}
           END{for(u in own) print own[u]}' "$R$ETC/$f" "etc/$f" > "etc/$f.new" && mv "etc/$f.new" "etc/$f"
done
chmod 0400 etc/shadow
# driver database rendered from the gate's pkg manifests (pkgs/illumos/data/drivers).
for f in name_to_major driver_aliases minor_perm driver_classes; do cp "$R$DRV/$f" "etc/$f"; done
grep -q '^# solnix drivers' etc/security/device_policy || \
  { echo '# solnix drivers'; cat "$R$DRV/device_policy.add"; } >> etc/security/device_policy
# /etc/system fragments, each applied once.
for f in "$R$ETC"/system.d/*; do
  [ -e "$f" ] || continue
  tag="* solnix: $(basename "$f")"
  grep -qF "$tag" etc/system || { echo "$tag"; cat "$f"; } >> etc/system
done
[ -e etc/path_to_inst ] || : > etc/path_to_inst
[ -e etc/hostid ] || printf '0x1b0b57ec\n' > etc/hostid

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
         urandom:random@0:urandom poll:poll@0:poll conslog:log@0:conslog log:log@0:log zfs:zfs@0:zfs; do
  relink "../devices/pseudo/${n#*:}" "dev/${n%%:*}"
done
for i in 0 1 2; do relink "./fd/$i" "dev/$(echo stdin stdout stderr | cut -d' ' -f$((i+1)))"; done

# 7. this BE is one generation: /run/{current,booted}-system are fixed for it.
relink "$TOP" run/current-system; relink "$TOP" run/booted-system

# 8. console + boot archive.
[ -e boot/loader.conf ] || printf 'console="%s"\nos_console="%s"\n' "$CONS" "$CONS" > boot/loader.conf
[ -e boot/solaris/bootenv.rc ] || printf 'setprop console %s\nsetprop ttya-mode 115200,8,n,1,-\n' "$CONS" > boot/solaris/bootenv.rc
bootadm update-archive -f -R "$ROOT" >&2 || die "bootadm update-archive failed"
[ -s platform/i86pc/amd64/boot_archive ] || die "no boot_archive"
say "BE $POOL/ROOT/$BE populated from $TOP"
