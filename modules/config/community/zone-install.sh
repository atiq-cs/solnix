#!/usr/bin/ksh93
# zone-install.sh -- the solnix brand's install hook (zone-brand/config.xml.in: `<install>`), run by `zoneadm install`
# as root in the global zone:  zone-install.sh <env-file> <zonename> <zonepath>
# Lays <zonepath>/root from the running generation, the way install-be lays a BE (modules/system/activation/install-be.sh):
#   /usr /lib /sbin /bin  the GZ's link farms, copied as links (cpio -p): they name store paths, which resolve in the
#                         ZONE's own /nix/store. /usr/kernel and /usr/lib/brand stay out (a zone loads no modules).
#   /nix/store            the closure of world + early + sw + the zone's own scripts (nix copy), NOT the toplevel, whose
#                         etc/ would show the zone the GZ's whole config. Same userland, rtld and ld as GZ builds, so a
#                         rebuild here is the GZ's rebuild.
#   /etc /var             the gate's stock tree, then the zone's own files (passwd, shadow, nix.conf, resolv.conf ...).
# Nothing in the zone root is written by the GZ after this, so a zone that turns hostile cannot aim a GZ write at a link.
# exit 254 (ZONE_SUBPROC_NOTCOMPLETE) makes zoneadm clean the zonepath and leave the zone "configured".
set -o pipefail
export PATH=/usr/bin:/usr/sbin:/sbin
. "$1" || exit 254	# ZONE_TOP ZONE_STORE_PATHS ZONE_USER ZONE_UID ZONE_NIXBLD ZONE_NIXCONF ZONE_RESOLV ZONE_HOSTS
Z=$2 R=$3/root
die() { print -u2 "zone-install $Z: $*"; exit 254; }
rl() { ls -ld "$1" | sed -n 's/.* -> //p'; }
[[ -d $3 ]] || die "no zonepath $3"
mkdir -p -m 0755 "$R" || die "mkdir $R"
cd / || die "cd /"
# 1. system code: the link farms (no regular files under usr/bin..sbin except usr/kernel's .conf, which stays out)
find usr lib sbin bin \( -path usr/kernel -o -path usr/lib/brand \) -prune -o -print | cpio -pdm "$R" 2> /dev/null ||
    die "copying the /usr /lib /sbin link farms"
[[ -z $(cd "$R" && find usr lib sbin -type f | head -1) ]] || die "a regular file in the copied farms (expected links only)"
# 2. the store
mkdir -p "$R/nix/store" "$R/nix/var/nix/gcroots" || die "mkdir nix"
nix copy --no-check-sigs --to "local?root=$R" $ZONE_STORE_PATHS > "$3/nix-copy.log" 2>&1 || die "nix copy (log $3/nix-copy.log)"
rm -f "$R/usr/bin" && ln -s "$ZONE_SW/bin" "$R/usr/bin" || die "usr/bin"	# the copied link names the GZ toplevel's sw
# every store path a copied link names must be in the zone's store (else that tool fails only when first run)
( cd "$R" && find usr lib sbin bin -type l -exec ls -ld {} + ) | sed -n 's,.* -> /nix/store/\([^/]*\).*,\1,p' | sort -u |
    while read -r p; do [[ -e $R/nix/store/$p ]] || print -r -- "$p"; done > "$3/missing" || die "checking the links"
[[ -s $3/missing ]] && die "the farms name store paths the zone does not have ($3/missing)"
# the brand's initname (at most 32 bytes, INITNAME_SZ): /sbin is a copied farm dir, so the link is the zone's own
[[ -e $R/sbin/zinit || -h $R/sbin/zinit ]] && die "sbin/zinit exists in the copied farm"
ln -s "$ZONE_INIT" "$R/sbin/zinit" || die "sbin/zinit"
# GC roots, or the zone daemon's min-free GC would delete the zone's own userland. Never ln onto a name that exists:
# with a link to an absolute /nix/store dir there, ln -s[f] writes INTO the GLOBAL zone's store path (it did, once:
# illumos-early is in both lists; nix-store --verify-path caught it).
for p in $(print -r -- $ZONE_STORE_PATHS | tr ' ' '\n' | sort -u); do
	g=$R/nix/var/nix/gcroots/zone-${p##*/}
	[[ -e $g || -h $g ]] || ln -s "$p" "$g" || die "gcroot $p"
done
# 3. /etc /var from the stock tree; the BE's hard-linked empties broken as install-be does
S=$(rl "$ZONE_TOP/stock")
( cd "$S" && find etc var -print | cpio -pdm "$R" ) 2> /dev/null || die "copying the stock /etc /var"
cd "$R" || die "cd $R"
find etc var ! -type l -exec chmod u+w {} + || die "chmod u+w"
find etc var -type f -links +1 | while read -r f; do cp -p "$f" "$f.u" && mv -f "$f.u" "$f" || exit 1; done || die "unlinking"
D=$(rl "$ZONE_TOP/drivers")
nawk -F'\t' 'FILENAME=="etc/passwd"{split($0,a,":"); u[a[1]]=a[3]; next} FILENAME=="etc/group"{split($0,a,":"); g[a[1]]=a[3]; next}
    ($3 in u) && ($4 in g) {print $5, u[$3]":"g[$4], $2}' etc/passwd etc/group "$D/etc-var-attrs.tsv" |
    while read -r m o p; do [[ -e $p && ! -h $p ]] && { chown "$o" "$p"; chmod "$m" "$p"; }; done
for d in dev devices proc system/contract system/object tmp var/tmp var/run var/log var/empty home root etc/svc/volatile var/lib/solnix/secrets; do
	mkdir -p "$d" || die "mkdir $d"
done
chmod 1777 tmp var/tmp
# ipmgmtd and dlmgmtd run as netadm/dladm and write these (the GZ's owners)
chown -R netadm:netadm etc/ipadm && chown -R dladm:netadm etc/dladm || die "etc/ipadm, etc/dladm owners"
# 4. accounts. root has an empty password in the stock shadow: lock it (NP); nobody logs in to this zone.
sed 's/^root:[^:]*:/root:NP:/' etc/shadow > etc/shadow.n && mv etc/shadow.n etc/shadow || die "shadow"
print -r -- "nixbld::30000:" >> etc/group
print -r -- "$ZONE_USER::$ZONE_UID:" >> etc/group
print -r -- "$ZONE_USER:x:$ZONE_UID:$ZONE_UID:solnix queue builder:/home/$ZONE_USER:/usr/bin/ksh93" >> etc/passwd
print -r -- "$ZONE_USER:NP:::::::" >> etc/shadow
typeset -i i=1
while (( i <= ZONE_NIXBLD )); do
	print -r -- "nixbld$i:x:$((30100 + i)):30000:Nix build user $i:/var/empty:/bin/false" >> etc/passwd
	print -r -- "nixbld$i:NP:::::::" >> etc/shadow
	(( i++ ))
done
nawk -F: -v n="$ZONE_NIXBLD" '$1=="nixbld" {s=""; for (i = 1; i <= n; i++) s = s (s ? "," : "") "nixbld" i; $4=s} {print}' OFS=: etc/group > etc/group.n &&
    mv etc/group.n etc/group || die "group"
chmod 0400 etc/shadow
mkdir -m 0700 "home/$ZONE_USER" && chown "$ZONE_UID:$ZONE_UID" "home/$ZONE_USER" || die "home"
# 5. the zone's own config
mkdir -p etc/nix && cp "$ZONE_NIXCONF" etc/nix/nix.conf && cp "$ZONE_RESOLV" etc/resolv.conf && cp "$ZONE_HOSTS" etc/hosts || die "etc files"
sed -e 's/^hosts:.*/hosts:      files dns/' -e 's/^ipnodes:.*/ipnodes:    files dns/' etc/nsswitch.files > etc/nsswitch.conf || die "nsswitch"
print -r -- "$Z" > etc/nodename
mkdir -p etc/ssl/certs && rm -f etc/ssl/certs/ca-certificates.crt etc/ssl/certs/ca-bundle.crt &&
    ln -s "$ZONE_CACERT" etc/ssl/certs/ca-certificates.crt && ln -s "$ZONE_CACERT" etc/ssl/certs/ca-bundle.crt || die "ca links"
