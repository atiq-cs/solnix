#!/usr/bin/env bash
# image-acceptance-test.sh -- every lesson we have learned building solnix install
# media, captured as a repeatable check that runs against a BUILT image before it
# ships. Add a check here whenever a new class of defect is found on hardware, so
# older fixes cannot silently regress.
#
# Usage:
#   scripts/image-acceptance-test.sh <image-dir> [--boot]
#     <image-dir>  an artifacts/install-media/usb-image-*/ dir (has the .iso/.img,
#                  boot-logs/, SHA256SUMS) OR a raw boot_archive path.
#     --boot       also run the QEMU boot phase (needs qemu + the illumos build
#                  node's tools; the STATIC phase runs anywhere the files are).
#
# Exit 0 = all checks pass. Non-zero = at least one check FAILED (the image must
# NOT ship). Each check prints PASS / FAIL / SKIP with the lesson it guards.
#
# ⚠️ A CHECK THAT CANNOT FAIL PROVES NOTHING. Every check here is paired, where it
# matters, with a negative control (--selftest) proving it fails on the defect it
# guards. Run `scripts/image-acceptance-test.sh --selftest` to prove the suite bites.
set -uo pipefail

DIR="${1:?usage: image-acceptance-test.sh <image-dir|boot_archive> [--boot|--selftest]}"
MODE=""
case "${2:-}" in --boot) MODE=boot ;; --selftest) MODE=selftest ;; esac
[ "$1" = "--selftest" ] && MODE=selftest

PASS=0 FAIL=0 SKIP=0
_ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "  SKIP: $*"; SKIP=$((SKIP+1)); }

# ---------------------------------------------------------------------------
# Locate + mount the boot_archive (the live root UFS image inside the media).
# The static checks inspect the ROOT FILESYSTEM the machine actually boots.
# ---------------------------------------------------------------------------
# the inflated boot_archive is ~700 MB: on the build host /tmp is swap-backed, so honour TMPDIR
WORK="$(mktemp -d "${TMPDIR:-/tmp}/img-accept.XXXXXX")"
RDMNT="$WORK/rd"
LOFI_RD="" LOFI_ISO="" ISOMNT=""
cleanup() {
  [ -n "$ISOMNT" ] && umount "$ISOMNT" 2>/dev/null
  [ -n "$RDMNT" ] && umount "$RDMNT" 2>/dev/null
  [ -n "$LOFI_RD" ] && lofiadm -d "$LOFI_RD" 2>/dev/null
  [ -n "$LOFI_ISO" ] && lofiadm -d "$LOFI_ISO" 2>/dev/null
  rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

find_boot_archive() {
  # Mount the image's boot_archive root at $RDMNT. Sets FOUND_RD on success.
  # Runs in the PARENT shell (not $(...)) so LOFI_*/ISOMNT reach the cleanup trap.
  # Returns 2 when this host cannot mount illumos filesystems (no lofiadm).
  FOUND_RD="" BA_PATH=""
  local ba=""
  if [ -f "$DIR" ]; then
    ba="$DIR"                              # a raw or gzipped boot_archive path
  elif [ -d "$DIR" ]; then
    local iso; iso=$(ls "$DIR"/*.iso 2>/dev/null | head -1)
    [ -n "$iso" ] || { echo "no .iso in $DIR" >&2; return 1; }
    command -v lofiadm >/dev/null || { echo "lofiadm absent (run the static phase on the illumos build node)" >&2; return 2; }
    LOFI_ISO=$(lofiadm -a "$iso") || return 1
    ISOMNT="$WORK/iso"; mkdir -p "$ISOMNT"
    mount -F hsfs -o ro "$LOFI_ISO" "$ISOMNT" 2>/dev/null || { ISOMNT=""; return 1; }
    ba=$(ls "$ISOMNT"/platform/i86pc/amd64/boot_archive 2>/dev/null | head -1)
    [ -n "$ba" ] || { echo "no boot_archive in the iso" >&2; return 1; }
  fi
  [ -n "$ba" ] || return 1
  command -v lofiadm >/dev/null || return 2
  # The media ships the boot_archive GZIPPED (the loader auto-inflates). lofiadm
  # refuses a file whose size is not a multiple of 512, so inflate FIRST; a raw
  # UFS archive is used as-is. (The first on-illumos run of this suite FAILED to
  # mount every image because it tried lofiadm on the gzipped file first.)
  if gzip -t "$ba" 2>/dev/null; then
    gzip -dc "$ba" > "$WORK/ba.ufs" 2>/dev/null || return 1
    BA_PATH="$WORK/ba.ufs"
  else
    BA_PATH="$ba"
  fi
  LOFI_RD=$(lofiadm -a "$BA_PATH") || return 1
  mkdir -p "$RDMNT"
  mount -F ufs -o ro "$LOFI_RD" "$RDMNT" 2>/dev/null || return 1
  FOUND_RD="$RDMNT"
}

# =====================================================================
# STATIC CHECKS -- each guards a specific lesson (incident cited).
# Take a mounted-ramdisk root ($1) and inspect files. No boot needed.
# =====================================================================
static_checks() {
  local R="$1"

  # LESSON (tui5 regression + its resolution): auto-login on raw /dev/console let the
  # X1 hid keyboard flood drown the prompt. Auto-login is now the DEFAULT again, but
  # it is SAFE ONLY BECAUSE the flood is quieted (hid:hid_errlevel=0). So the rule is
  # a COUPLING: if console-login is repointed to the auto-login method, hid_errlevel
  # MUST also be set. Stock ttymon is also acceptable (SOLNIX_AUTOLOGIN=0).
  if [ -e "$R/etc/svc/repository.db" ] && command -v svccfg >/dev/null; then
    local cl hidq=0
    cat "$R/etc/system" "$R"/etc/system.d/* 2>/dev/null | grep -q 'set hid:hid_errlevel' && hidq=1
    cl=$(SVCCFG_REPOSITORY="$R/etc/svc/repository.db" svccfg -s system/console-login listprop start/exec 2>/dev/null)
    case "$cl" in
      *solnix-console-login*)
        if [ "$hidq" = 1 ]; then _ok "console-login is auto-login AND hid_errlevel is set (safe -- flood quieted)"
        else _fail "console-login is auto-login BUT hid_errlevel is NOT set -- the tui5 no-login regression (flood would drown the raw shell)"; fi ;;
      *console-login*)        _ok  "console-login is stock ttymon (auto-login off; also fine)" ;;
      *)                      _skip "console-login start/exec not readable" ;;
    esac
  else _skip "no repository.db / svccfg -- console-login check"; fi

  # LESSON (X1 hid flood): /etc/system must quiet the hid Invalid-Report-Descriptor spam.
  # bootadm assembles /etc/system.d/* into the kernel's view of /etc/system
  # (.self-assembly), so a tunable set in a system.d fragment counts.
  if cat "$R/etc/system" "$R"/etc/system.d/* 2>/dev/null | grep -q 'set hid:hid_errlevel'; then
    _ok "/etc/system sets hid:hid_errlevel (X1 hid console-flood guard)"
  else _fail "/etc/system missing 'set hid:hid_errlevel' (X1 hid flood would drown the console)"; fi

  # LESSON (EC2 resolv.conf poisoned DNS on a home network): the media must NOT
  # ship the build host's resolver -- resolv.conf must be empty.
  if [ -s "$R/etc/resolv.conf" ] && grep -q '^[[:space:]]*nameserver' "$R/etc/resolv.conf" 2>/dev/null; then
    _fail "/etc/resolv.conf ships a nameserver (stale EC2 resolver -- poisons DNS off-EC2): $(grep -m1 nameserver "$R/etc/resolv.conf")"
  else _ok "/etc/resolv.conf is empty (no stale EC2 resolver)"; fi

  # LESSON (2/9 SSL CA cert failure, reproduced under local KVM on tui7): nix's
  # HTTPS flake fetch needs a real CA bundle at EVERY ssl-cert-file any nix.conf
  # names. tui7 shipped TWO nix.conf files and BOTH named a file absent from the
  # image (/nix-tools224/ca-bundle.crt, and a /nix/store/...-nix-2.24.15 path) ->
  # curl 77 "Problem with the SSL CA cert". Checking only the first conf would
  # miss a dangling second one, so check them all.
  local conf caf n any=0
  for conf in "$R"/nix-tools224/etc/nix/nix.conf "$R"/etc/nix/nix.conf; do
    [ -f "$conf" ] || continue
    caf=$(grep -h '^[[:space:]]*ssl-cert-file' "$conf" 2>/dev/null | tail -1 | sed 's/.*= *//')
    [ -n "$caf" ] || continue
    any=1
    if [ -f "$R$caf" ]; then
      n=$(grep -c 'BEGIN CERTIFICATE' "$R$caf" 2>/dev/null || echo 0)
      if [ "${n:-0}" -ge 20 ]; then _ok "${conf#$R}: ssl-cert-file $caf present ($n certs) (2/9 SSL-CA guard)"
      else _fail "${conf#$R}: ssl-cert-file $caf has only ${n:-0} certs (flake fetch would fail SSL CA)"; fi
    else _fail "${conf#$R}: ssl-cert-file $caf is ABSENT from the image (nix HTTPS fetch dies at 2/9 with curl 77)"; fi
  done
  [ "$any" = 1 ] || _fail "no nix.conf in the image sets ssl-cert-file (nix HTTPS fetch has no CA)"

  # LESSON (this session): solnix-zap disk-nuke tool must be staged + runnable.
  local ZAP INST AUTONET; ZAP=$(_tool "$R" solnix-zap); INST=$(_tool "$R" solnix-install); AUTONET=$(_tool "$R" solnix-autonet)
  if [ -n "$ZAP" ] && head -1 "$ZAP" | grep -q '/sbin/sh'; then
    _ok "solnix-zap present + #!/sbin/sh (disk-nuke recovery tool)"
  else _fail "solnix-zap missing or wrong shebang"; fi

  # LESSON (committed != shipped): the shipped solnix-install must match a known
  # HEAD blob (the mount-guard fix etc. must actually be IN the image binary).
  if [ -n "$INST" ]; then
    local ish gsh
    ish=$(sha256sum "$INST" 2>/dev/null | awk '{print $1}')
    gsh=$(cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && git show HEAD:scripts/solnix-install 2>/dev/null | sha256sum | awk '{print $1}')
    if [ -n "$gsh" ] && [ "$ish" = "$gsh" ]; then _ok "shipped solnix-install sha == git HEAD blob ($ish)"
    elif [ -n "$gsh" ]; then _fail "shipped solnix-install sha ($ish) != HEAD blob ($gsh) -- image predates a committed fix"
    else _skip "not in a git tree -- cannot compare solnix-install sha to HEAD"; fi
  else _fail "/usr/sbin/solnix-install not present or not executable"; fi

  # LESSON (autoinstall must be opt-in): a stray /etc/solnix-autoinstall would wipe
  # a disk unattended. It must be ABSENT on a normal installer image.
  if [ -e "$R/etc/solnix-autoinstall" ]; then _fail "/etc/solnix-autoinstall present (would auto-wipe a disk!)"
  else _ok "/etc/solnix-autoinstall absent (install is interactive)"; fi

  # LESSON (login dns stall, measured): the live hostname must be in /etc/hosts, or
  # every login-path lookup goes to DNS at ~3.5s per NXDOMAIN. And nsswitch MUST keep
  # dns -- removing it cut the delay but broke nix's flake fetch ("Could not resolve
  # hostname") while dig still worked. Both conditions are checked.
  local nn; nn=$(cat "$R/etc/nodename" 2>/dev/null || echo solnix)
  # Guard the ordering bug too: an entry for the BUILD host's name ("unknown") does
  # not help the live system, whose nodename is solnix.
  if [ "$nn" = unknown ]; then
    _fail "/etc/nodename is 'unknown' (build-host name shipped) -- the live hostname was never set"
  elif grep -qw "$nn" "$R/etc/hosts" 2>/dev/null; then _ok "/etc/hosts answers for the live hostname '$nn' (no dns stall at login)"
  else _fail "/etc/hosts has no entry for '$nn' -- every login-path lookup hits DNS (~3.5s per NXDOMAIN)"; fi
  local ns; ns=$(grep -E '^[[:space:]]*hosts:' "$R/etc/nsswitch.conf" 2>/dev/null | head -1)
  case "$ns" in
    *dns*) _ok "nsswitch keeps dns for real resolution ($ns)" ;;
    *) _fail "nsswitch '$ns' has no dns -- name resolution breaks (nix flake fetch fails to resolve)" ;;
  esac

  # LESSON (tui8 KVM: auto-network DOWN): the build host's /etc/ipadm/ipadm.conf
  # shipped its own persistent addrobj (vioif0/dhcp). On a same-named live NIC it
  # stole the lease, the auto-network's vioif0/v4 stayed down, resolv.conf was never
  # written, and every fetch failed "Could not resolve hostname". No persistent
  # interfaces may ship on the live media.
  # Check ADDRESS entries only: stripping the INTERFACE (_ifname=) entries breaks
  # ipmgmtd entirely (measured on tui8 v3 -- `ipadm create-if` fails outright).
  if grep -q '_aobjname=' "$R/etc/ipadm/ipadm.conf" 2>/dev/null; then
    _fail "ipadm.conf ships build-host addresses: $(grep -oE '_aobjname=[^;]+' "$R/etc/ipadm/ipadm.conf" | sort -u | tr '\n' ' ')"
  else _ok "ipadm.conf carries no build-host address objects (auto-network plumbs the NIC)"; fi

  # LESSON (tui8 v3/v4 under KVM): the live media cannot create a PERSISTENT dhcp
  # addrobj -- `ipadm create-addr -T dhcp` fails "Operation failed" on the ramdisk's
  # persistent DB, so the auto-network left no lease and every fetch failed to
  # resolve. The temporary form (-t) gets the lease. Both the boot-time autonet
  # method and solnix-install must use -t.
  local an="$AUTONET"
  if [ -n "$an" ] && [ -f "$an" ]; then
    if grep -q 'create-addr -t -T dhcp' "$an"; then _ok "solnix-autonet creates a TEMPORARY dhcp addrobj (-t)"
    else _fail "solnix-autonet uses a persistent create-addr -- fails on the live media's persistent DB (no lease)"; fi
  else _fail "/lib/svc/method/solnix-autonet missing"; fi
  if [ -n "$INST" ]; then
    if grep -q 'create-addr -t -T dhcp' "$INST"; then _ok "solnix-install creates a TEMPORARY dhcp addrobj (-t)"
    else _fail "solnix-install uses a persistent create-addr (no lease on the live media)"; fi
  fi

  # LESSON (X1 tiny console): the installed BE is copied from this root, and its loader
  # picks the largest /boot/fonts font that fits 80x34. No fonts.dir = builtin 8x16 =
  # 478x134 cells on a 4K panel. efi-max-resolution is not a loader variable at all.
  if [ -s "$R/boot/fonts/fonts.dir" ] && [ -s "$R/boot/fonts/16x32.fnt" ]; then
    _ok "/boot/fonts (fonts.dir + 16x32) present -- installed console gets a readable font"
  else _fail "/boot/fonts/fonts.dir or 16x32.fnt missing -- installed console falls back to the builtin 8x16"; fi
  if grep -qs '^efi-max-resolution' "$R/boot/loader.conf"; then
    _fail "loader.conf sets efi-max-resolution (not a loader variable; does nothing)"
  else _ok "loader.conf has no inert efi-max-resolution"; fi

  closure_contract_checks "$R"

  # LESSON (dig/curl broken -- the SECOND-ORDER dangling lib, the openssl trap):
  # EVERY staged ELF's DT_NEEDED must be present in the ramdisk, TRANSITIVELY
  # (a staged lib's own NEEDED too), ABI-matched (a 64-bit binary needs a 64-bit
  # lib). This is the runnability check; it also caught curl/dig/nslookup.
  runnability_check "$R"
}

# =====================================================================
# THE CLOSURE CONTRACT (media built FROM A TOPLEVEL, scripts/make-installer-image.sh).
# NixOS's iso-image.nix: storeContents = [ toplevel ]. These hold for that media and
# fail on media made by copying a host root (oi-make-livecd.sh), by design.
# =====================================================================
_rl() { ls -ld "$1" 2>/dev/null | sed -n 's/.* -> //p'; }
# _inr <root> <path>: resolve <path> INSIDE <root> (absolute link targets re-rooted),
# print the real file. A plain [ -e "$R/usr/bin/x" ] on closure media follows
# /nix/store/... through the BUILD host's store, which proves nothing about the image.
_inr() {
  local p="$1/$2" n=0 t
  while [ -h "$p" ] && [ $n -lt 32 ]; do
    t=$(_rl "$p"); case "$t" in /*) p="$1$t" ;; *) p="$(dirname "$p")/$t" ;; esac; n=$((n+1))
  done
  [ -e "$p" ] && [ ! -h "$p" ] && echo "$p"
}
# _tool <root> <name>: an installer tool, wherever this media kind puts it
# (closure media: the system profile's sw/bin; host-copied media: /usr/sbin).
_tool() { _inr "$1" "run/current-system/sw/bin/$2" || _inr "$1" "usr/sbin/$2" || _inr "$1" "lib/svc/method/$2"; }
closure_contract_checks() {
  local R="$1" top cs
  # 1. /run/current-system is a toplevel IN the media's own store, and the system
  #    profile points at it (generation 1).
  top=$(_rl "$R/run/current-system")
  case "$top" in
    /nix/store/*-solnix-system-*)
      if [ -d "$R$top" ] && [ -e "$R$top/bin/install-be" ]; then _ok "/run/current-system -> $top, present in the media store"
      else _fail "/run/current-system -> $top, but that toplevel is not in the media's store"; fi ;;
    *) _fail "/run/current-system is '${top:-absent}', not a solnix toplevel in /nix/store (media not built from a closure)" ;;
  esac
  local sp; sp=$(_rl "$R/nix/var/nix/profiles/system")
  if [ -n "$top" ] && [ "$(_rl "$R/nix/var/nix/profiles/$sp")" = "$top" ]; then _ok "system profile -> $sp -> the toplevel"
  else _fail "system profile does not resolve to /run/current-system ($sp)"; fi
  # 2. the media's store is a registered store: every closure path valid in its own DB.
  if [ -f "$R/nix/var/nix/db/db.sqlite" ]; then
    if command -v nix-store >/dev/null && [ -n "$top" ]; then
      # nix opens <root>/nix/var/nix/db/big-lock even to read, so a read-only mount
      # of the image cannot answer this (measured: "opening lock file ... Read-only
      # file system", which made this check fail on a correct image). Read a COPY of
      # the DB instead, against the image's store, without writing the image.
      local _dbc; _dbc=$(mktemp -d /tmp/img-accept-db.XXXXXX)
      mkdir -p "$_dbc/nix/var/nix" && cp -R "$R/nix/var/nix/db" "$_dbc/nix/var/nix/db" 2>/dev/null
      # nix refuses a store dir that is a symlink ("is a symlink; this is not
      # allowed for the Nix store"), which made this check fail on every image;
      # loopback-mount the image's store there instead (read-only).
      mkdir -p "$_dbc/nix/store"
      local _lofs=0; mount -F lofs -o ro "$R/nix/store" "$_dbc/nix/store" 2>/dev/null && _lofs=1
      # Verify every path PRESENT in the image's store, plus the toplevel's closure.
      # The DB's own closure alone cannot fail: a deleted ValidPaths row also drops
      # that path's Refs, so -qR silently omits it (measured: 55 -> 54, rc 0).
      local _cl; _cl=$( { nix-store --store "local?root=$_dbc" -qR "$top" 2>/dev/null
                          ls "$R/nix/store" | grep -v '^\.' | sed 's,^,/nix/store/,'; } | sort -u)
      if [ "$_lofs" = 0 ]; then _skip "cannot lofs-mount the image store -- store DB validity"
      elif [ -n "$_cl" ] && nix-store --store "local?root=$_dbc" --verify-path $_cl >/dev/null 2>&1
      then _ok "every store path on the media is VALID in its store DB ($(echo "$_cl" | wc -l | tr -d ' ') paths, toplevel closure included)"
      else _fail "the media's store DB does not register the whole toplevel closure"; fi
      [ "$_lofs" = 1 ] && umount "$_dbc/nix/store"
      find "$_dbc" -depth -delete 2>/dev/null
    else _skip "nix-store absent -- store DB validity"; fi
  else _fail "no /nix/var/nix/db/db.sqlite -- the media store is unregistered"; fi
  # 3. the userland resolves INTO the store: /usr/bin and /usr/sbin are links into a
  #    store path, not host directories.
  local d t
  for d in usr/bin usr/sbin; do
    t=$(_rl "$R/$d")
    case "$t" in /nix/store/*) _ok "/$d -> $t (resolves into the store)" ;;
      *) _fail "/$d is ${t:-a real directory}, not a link into /nix/store (copied from a host root)" ;; esac
  done
  # 4. nothing outside the store, the generated root skeleton and mutable state is
  #    an ELF: binaries copied from a host land as real files in /usr, /lib, /sbin.
  local stray
  # (/usr/kernel is excluded: install-be copies kernel modules as real files on purpose,
  #  because bootadm walks real dirs to build the boot_archive)
  stray=$(find "$R/usr" "$R/lib" "$R/sbin" "$R/opt" -path "$R/usr/kernel" -prune -o -type f -print 2>/dev/null | while read -r f; do
            LC_ALL=C od -An -N4 -tx1 "$f" 2>/dev/null | grep -q '7f 45 4c 46' && echo "${f#$R}"; done | head -5)
  if [ -z "$stray" ]; then _ok "no ELF outside /nix/store under /usr /lib /sbin /opt (no host-copied binaries)"
  else _fail "ELF files outside the store (host copies): $(echo $stray)"; fi
  # 5. no live-root-copy step left in the shipped installer.
  if [ -n "$top" ] && [ -f "$R$top/bin/solnix-install" ] || [ -h "$R$top/bin/solnix-install" ]; then
    local si; si="$R$(_rl "$R$top/bin/solnix-install")"; [ -f "$si" ] || si="$R$top/bin/solnix-install"
    if grep -qE 'tar cEfX|SELF_INSTALL=|copy the running root FS' "$si" 2>/dev/null; then _fail "shipped solnix-install still has the live-root copy step"
    elif grep -q 'install-be' "$si" 2>/dev/null; then _ok "shipped solnix-install populates the BE through install-be (no live-root copy)"
    else _fail "shipped solnix-install has neither install-be nor a copy step -- unrecognised installer"; fi
  else _fail "toplevel carries no bin/solnix-install"; fi
  # 6. the media's nix.conf: cache.solnix.io trusted ONLY by the 8UNr key (+ cache.nixos.org).
  local nc="$R/etc/nix/nix.conf" keys
  if [ -f "$nc" ]; then
    # strip only up to the FIRST '=': base64 keys end in '=', so a greedy s/.*=// eats them all.
    keys=$(grep -E '^[[:space:]]*trusted-public-keys' "$nc" | sed 's/^[^=]*= *//')
    case " $keys " in
      *" cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8= "*)
        if echo "$keys" | tr ' ' '\n' | grep -v -e '^cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=$' -e '^cache.nixos.org-1:' -e '^$' | grep -q .
        then _fail "nix.conf trusts keys other than 8UNr/cache.nixos.org: $keys"
        else _ok "nix.conf trusts only cache.solnix.io-1:8UNr... (+ cache.nixos.org-1)"; fi ;;
      *) _fail "nix.conf does not trust cache.solnix.io-1:8UNr... ($keys)" ;;
    esac
    grep -qE '^[[:space:]]*substituters.*https://cache\.solnix\.io' "$nc" && _ok "nix.conf substitutes from https://cache.solnix.io"       || _fail "nix.conf has no https://cache.solnix.io substituter"
  else _fail "no /etc/nix/nix.conf on the media"; fi
  # 7. generic media: no personal identity baked in.
  local who
  who=$(awk -F: '$3>=100 && $3<60000 {print $1}' "$R/etc/passwd" 2>/dev/null | grep -v -E '^(nobody|noaccess|nobody4|nixbld[0-9]+|sshd|dladm|netadm|netcfg|pkg5srv|upnp|smmsp|svctag|zfssnap|unknown)$' | head -3)
  if [ -z "$who" ]; then _ok "no personal login accounts on the media"
  else _fail "personal account(s) baked into the media: $(echo $who)"; fi
  if find "$R/root" "$R/etc/ssh" -name 'authorized_keys*' -size +0 2>/dev/null | grep -q .; then
    _fail "an authorized_keys file is baked into the media"
  else _ok "no authorized_keys baked into the media"; fi
  # 8. a TLS trust store at the names curl/git/openssl look for (NixOS security/ca.nix),
  #    resolving into the media's store. Without it the media's curl failed every HTTPS
  #    fetch with rc 77 and the installer reported "network is NOT up" (X1, closure1).
  local ca; ca=$(_inr "$R" etc/ssl/certs/ca-certificates.crt)
  case "$(_rl "$R/etc/ssl/certs/ca-certificates.crt")" in
    /nix/store/*) if [ -n "$ca" ] && grep -q 'BEGIN CERTIFICATE' "$ca" 2>/dev/null
                  then _ok "/etc/ssl/certs/ca-certificates.crt -> a CA bundle in the media's store"
                  else _fail "/etc/ssl/certs/ca-certificates.crt names a store path the media does not hold"; fi ;;
    *) _fail "no /etc/ssl/certs/ca-certificates.crt link into the store (curl/git HTTPS fail with rc 77)" ;;
  esac
  # 9. state the gate gives to a non-root owner is owned by it (pkg(5) ownership,
  #    applied by install-be from pkgs/illumos/data/drivers/etc-var-attrs.tsv).
  #    Root-owned /etc/dladm: dlmgmtd (dladm) cannot record a new link and the NIC
  #    never shows in `dladm show-phys` (X1 and KVM media, 20261007).
  local own
  for own in etc/dladm/datalink.conf:dladm etc/dladm:dladm etc/ipadm:netadm; do
    local p=${own%%:*} u=${own##*:} uid got
    uid=$(awk -F: -v u="$u" '$1==u{print $3}' "$R/etc/passwd" 2>/dev/null)
    got=$(ls -lnd "$R/$p" 2>/dev/null | awk '{print $3}')
    if [ -z "$got" ]; then _fail "/$p is missing"
    elif [ -n "$uid" ] && [ "$got" = "$uid" ]; then _ok "/$p is owned by $u (uid $uid), as the gate's manifests give it"
    else _fail "/$p is owned by uid $got, not $u (${uid:-no such account}): $u's daemon cannot write it"; fi
  done
  # 11. no boot service can write into a store path through a link (measured on the
  #     media: fs-root's libc_mount lofs-mounted over the libc store path via
  #     /usr/lib/libc, and update-man-index rewrote usr/has/man/whatis in the world).
  if [ -e "$R/usr/lib/libc" ] || [ -h "$R/usr/lib/libc" ]; then
    _fail "/usr/lib/libc exists: fs-root's libc_mount would lofs-mount over the libc store path"
  else _ok "no /usr/lib/libc (fs-root mounts no hwcap libc over the store)"; fi
  if grep -q "system/update-man-index.*enabled=.false" "$R/etc/svc/profile/site/solnix.xml" 2>/dev/null; then
    _ok "update-man-index is preset off (it rewrites usr/has/man/whatis in the store)"
  else _fail "update-man-index is not preset off: it rewrites usr/has/man/whatis inside the world's store path"; fi
  # 10. /dev/sad/admin exists before devfsadm: inittab's autopush opens it to push
  #     ldterm onto the console; without it every boot line is a bare line feed.
  case "$(_rl "$R/dev/sad/admin")" in
    *devices/pseudo/sad@0:admin) _ok "/dev/sad/admin exists for inittab's autopush (console line discipline)" ;;
    *) _fail "no /dev/sad/admin: autopush configures nothing and the boot console staircases" ;;
  esac
  [ "${MODE:-}" = selftest ] || https_check "$R"
}

# The media's own curl, chrooted, fetches over HTTPS with NO CA environment, and the
# same fetch with a bogus CA file fails (negative control: the check can fail). The
# media's resolv.conf is empty by design, so the name is pinned with --resolve; this
# tests TLS trust, not DNS.
https_check() {
  local R="$1" url="${ACCEPT_HTTPS_URL:-https://cache.solnix.io/nix-cache-info}" h ip body rc
  command -v chroot >/dev/null && [ -n "$(_inr "$R" run/current-system/sw/bin/curl)" ] \
    || { _skip "no chroot or no curl on the media profile -- HTTPS fetch check"; return; }
  h=$(echo "$url" | sed -e 's,^https://,,' -e 's,/.*,,')
  ip=$(getent hosts "$h" 2>/dev/null | awk '{print $1; exit}')
  [ -n "$ip" ] || { _skip "build host cannot resolve $h -- HTTPS fetch check"; return; }
  body=$(chroot "$R" /usr/bin/env -i PATH=/run/current-system/sw/bin:/usr/bin \
           /run/current-system/sw/bin/curl -fsS --max-time 30 --resolve "$h:443:$ip" "$url" 2>&1); rc=$?
  case "$rc:$body" in
    0:*StoreDir*) _ok "media curl (chroot, no CA env) fetched $url" ;;
    *) _fail "media curl (chroot, no CA env) could not fetch $url: rc=$rc $(echo "$body" | head -1)"; return ;;
  esac
  chroot "$R" /usr/bin/env -i PATH=/run/current-system/sw/bin:/usr/bin CURL_CA_BUNDLE=/etc/nonexistent.pem \
    /run/current-system/sw/bin/curl -fsS --max-time 30 --resolve "$h:443:$ip" "$url" >/dev/null 2>&1 \
    && _fail "negative control: media curl fetched $url with a bogus CA bundle (check is vacuous)" \
    || _ok "negative control: the same fetch with a bogus CA bundle fails"
}

# Transitive, ABI-aware NEEDED-closure check over every staged ELF.
runnability_check() {
  local R="$1"
  if [ -n "$(_rl "$R/run/current-system")" ]; then runnability_check_closure "$R"; return; fi
  command -v elfdump >/dev/null || { _skip "elfdump absent -- runnability (NEEDED-closure) check (run on the illumos node)"; return; }
  local libdirs="$R/lib $R/lib/amd64 $R/usr/lib $R/usr/lib/amd64 $R/usr/gnu/lib $R/usr/gnu/lib/amd64"
  _have() {  # $1 soname, $2 wanted ELFCLASS (32|64)
    local sn="$1" want="$2" d f cls
    for d in $libdirs; do
      f="$d/$sn"; [ -e "$f" ] || continue
      cls=$(elfdump -e "$f" 2>/dev/null | grep -oE 'ELFCLASS(32|64)' | head -1)
      case "$cls" in *64*) cls=64 ;; *32*) cls=32 ;; *) cls="?" ;; esac
      [ "$cls" = "$want" ] || [ "$cls" = "?" ] && return 0
    done
    find "$R/usr/lib" "$R/lib" -name "$sn" 2>/dev/null | grep -q . && return 0
    return 1
  }
  local missing=0 checked=0
  local seen="$WORK/seen"; : > "$seen"
  # worklist: start with binaries, add staged libs, fixed-point over NEEDED.
  local worklist="$WORK/worklist"; : > "$worklist"
  for b in "$R"/usr/bin/* "$R"/usr/sbin/* "$R"/sbin/* "$R"/usr/gnu/bin/* \
           "$R"/usr/has/bin/* "$R"/usr/libexec/* "$R"/usr/libexec/git-core/* \
           "$R"/usr/openssl/*/bin/* $libdirs/*.so* ; do
    [ -f "$b" ] || continue
    LC_ALL=C od -An -N4 -tx1 "$b" 2>/dev/null | grep -q '7f 45 4c 46' || continue
    echo "$b" >> "$worklist"
  done
  while [ -s "$worklist" ]; do
    local elf; elf=$(head -1 "$worklist"); sed -i '1d' "$worklist" 2>/dev/null || { tail -n +2 "$worklist" > "$worklist.n"; mv "$worklist.n" "$worklist"; }
    grep -qxF "$elf" "$seen" 2>/dev/null && continue
    echo "$elf" >> "$seen"
    # elfdump -e prints "ei_class: ELFCLASS64  ei_data: ELFDATA2LSB" on ONE line; taking
    # the last field ($NF) read ELFDATA2LSB and classified every ELF as 32-bit.
    local cls; cls=$(elfdump -e "$elf" 2>/dev/null | grep -oE 'ELFCLASS(32|64)' | head -1); case "$cls" in *64*) cls=64 ;; *) cls=32 ;; esac
    checked=$((checked+1))
    local need
    for need in $(elfdump -d "$elf" 2>/dev/null | awk '$2=="NEEDED"{print $NF}'); do
      local sn; sn=$(basename "$need")
      if ! _have "$sn" "$cls"; then
        _fail "runnability: ${elf#$R} NEEDs $sn ($cls-bit) -- NOT staged (the dig/curl/openssl second-order class)"
        missing=$((missing+1))
      fi
    done
  done
  [ "$missing" = 0 ] && _ok "runnability: all $checked staged ELFs' NEEDED libs present, ABI-matched, transitive (dig/curl/openssl guard)"
}

# Closure media: every binary on the system profile's PATH resolves its libraries
# INSIDE the image. ldd runs under chroot so absolute store paths resolve against the
# image, not this host. ldd only loads the object; it never runs it (unlike the
# svc.configd exec-test incident, docs/working-with-subagents.md).
runnability_check_closure() {
  local R="$1" b n=0 bad=0 out
  command -v chroot >/dev/null && [ -n "$(_inr "$R" usr/bin/ldd)" ] || { _skip "no chroot/ldd in the image -- closure runnability"; return; }
  for b in "$R"/run/current-system/sw/bin/* "$R"/usr/sbin/zpool "$R"/usr/sbin/zfs "$R"/usr/sbin/svccfg; do
    local rel="/${b#$R/}" real; real=$(_inr "$R" "${rel#/}") || continue
    LC_ALL=C od -An -N4 -tx1 "$real" 2>/dev/null | grep -q '7f 45 4c 46' || continue
    n=$((n+1))
    out=$(chroot "$R" /usr/bin/ldd "$rel" 2>&1 | grep -E 'not found|open failed|wrong ELF class')
    [ -z "$out" ] || { _fail "runnability: $rel -- $(echo "$out" | head -2 | tr '\n' ' ')"; bad=$((bad+1)); }
  done
  [ "$n" -gt 0 ] || { _fail "runnability: no ELF binaries found on the system profile PATH"; return; }
  [ "$bad" = 0 ] && _ok "runnability (closure): all $n profile/core binaries resolve every library inside the image (chroot ldd)"
}

# boot_archive size ceiling (the X1 firmware refused an oversized raw archive).
size_check() {
  local ba="$1" cap="${RD_MAX_RAW_BYTES:-816119808}"   # measured X1 EFI hard limit
  # wc -c, not stat: illumos has no stat(1) at all, so a stat-based size read was
  # empty on the one platform this runs on (STATIC phase) and the check only SKIPped.
  local sz; sz=$(wc -c < "$ba" 2>/dev/null | tr -d ' ')
  if [ -n "$sz" ] && [ "$sz" -lt "$cap" ]; then _ok "boot_archive raw size $sz < $cap (X1 EFI ceiling)"
  elif [ -n "$sz" ]; then _fail "boot_archive raw size $sz >= $cap -- the X1 firmware will refuse it"
  else _skip "could not stat boot_archive size"; fi
}

# =====================================================================
# BOOT PHASE (QEMU) -- prove the media actually boots + tools RUN.
# =====================================================================
boot_checks() {
  command -v qemu-system-x86_64 >/dev/null || { _skip "qemu absent -- boot phase"; return; }
  local img; img=$(ls "$DIR"/*-usb.img "$DIR"/*.img 2>/dev/null | head -1)
  [ -n "$img" ] || { _skip "no .img for the boot phase"; return; }
  local log="$WORK/boot.log"
  if scripts/qemu-boot-test.sh disk "$img" 240 uefi "$log" 2>/dev/null; then :; fi
  # LESSON (tui5): a stock login prompt must appear (QEMU has a PS/2 kbd, no hid flood).
  if grep -qiE 'solnix console login:|login:' "$log" 2>/dev/null; then
    _ok "QEMU boot reached a login prompt (stock ttymon)"
  else _fail "QEMU boot did NOT reach a login prompt (see $log)"; fi
  # NOTE: curl/dig/nix RUN checks require an interactive/expect login; the static
  # runnability_check already proves their NEEDED closure. A full exec check is a
  # future addition (expect-driven), tracked as a KNOWN GAP here rather than faked.
  _skip "curl/dig/nix exec-RUN check (needs expect login) -- covered statically by runnability_check; expect-driven exec is a KNOWN GAP"
}

# =====================================================================
# SELF-TEST -- prove the suite's checks CAN fail (negative controls).
# =====================================================================
selftest() {
  echo "=== SELF-TEST: proving the checks fail on the defects they guard ==="
  local T="$WORK/fake"; mkdir -p "$T/etc" "$T/usr/sbin" "$T/nix-tools224/etc/nix"
  # a deliberately-DEFECTIVE fake root: EC2 resolv.conf, no hid_errlevel, no zap,
  # and the tui7 defect -- a nix.conf naming a CA bundle that is not in the image.
  echo 'nameserver 10.0.0.2' > "$T/etc/resolv.conf"
  : > "$T/etc/system"
  mkdir -p "$T/etc/nix"
  echo 'ssl-cert-file = /nix/store/jxn55a9725j8ba9hkqila89s66abszhr-nix-2.24.15/etc/ssl/certs/ca-bundle.crt' > "$T/etc/nix/nix.conf"
  echo 'hosts:      files' > "$T/etc/nsswitch.conf"   # no dns -> resolution breaks
  echo '::1 unknown localhost' > "$T/etc/hosts"; echo solnix > "$T/etc/nodename"
  mkdir -p "$T/etc/ipadm"; echo '_ifname=vioif0;_aobjname=vioif0/dhcp;_dhcp=30,no;' > "$T/etc/ipadm/ipadm.conf"
  # closure-contract defects: a host-copied /usr/bin with an ELF in it, no
  # /run/current-system, a nix.conf trusting the retired 5HAV key, a personal user.
  mkdir -p "$T/usr/bin"; printf '\177ELF\002\001\001' > "$T/usr/bin/ls"
  printf 'trusted-public-keys = cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=\nsubstituters = https://cache.nixos.org\n' >> "$T/etc/nix/nix.conf"
  echo 'jdoe:x:1000:10::/home/jdoe:/bin/sh' > "$T/etc/passwd"
  local before=$FAIL cbefore
  cbefore=$FAIL; closure_contract_checks "$T" >/dev/null 2>&1 || true
  echo "  closure-contract checks fired on the defective root: $((FAIL-cbefore)) (expect >= 9)"
  [ $((FAIL-cbefore)) -ge 9 ] || { echo "  FAIL: closure-contract checks are vacuous"; return 1; }
  # the CA-store check alone, on the defective root (no /etc/ssl) and on a dangling link
  cbefore=$FAIL; ( closure_contract_checks "$T" 2>&1 ) | grep -q 'no /etc/ssl/certs/ca-certificates.crt link' \
    && echo "  CA-store check fires on a root with no /etc/ssl/certs/ca-certificates.crt" \
    || { echo "  FAIL: CA-store check did not fire on a root without the bundle"; return 1; }
  FAIL=$cbefore
  # and a GOOD closure root passes them all (positive control).
  local G="$WORK/good" TL=/nix/store/00000000000000000000000000000000-solnix-system-x
  mkdir -p "$G$TL/bin" "$G/nix/store/11111111111111111111111111111111-w/bin" "$G/run" "$G/nix/var/nix/profiles" "$G/usr" "$G/etc/nix" "$G/nix/var/nix/db"
  echo 'install-be' > "$G$TL/bin/solnix-install"; : > "$G$TL/bin/install-be"; : > "$G/nix/var/nix/db/db.sqlite"
  ln -s "$TL" "$G/run/current-system"; ln -s "$TL" "$G/nix/var/nix/profiles/system-1-link"; ln -s system-1-link "$G/nix/var/nix/profiles/system"
  ln -s /nix/store/11111111111111111111111111111111-w/bin "$G/usr/bin"; ln -s /nix/store/11111111111111111111111111111111-w/bin "$G/usr/sbin"
  printf 'substituters = https://cache.solnix.io https://cache.nixos.org\ntrusted-public-keys = cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=\n' > "$G/etc/nix/nix.conf"
  echo 'root:x:0:0::/root:/bin/sh' > "$G/etc/passwd"
  mkdir -p "$G/etc/ssl/certs" "$G/nix/store/22222222222222222222222222222222-cacert/etc/ssl/certs"
  echo '-----BEGIN CERTIFICATE-----' > "$G/nix/store/22222222222222222222222222222222-cacert/etc/ssl/certs/ca-bundle.crt"
  ln -s /nix/store/22222222222222222222222222222222-cacert/etc/ssl/certs/ca-bundle.crt "$G/etc/ssl/certs/ca-certificates.crt"
  local gb=$FAIL; closure_contract_checks "$G" > "$WORK/good.out" 2>&1 || true
  # the store-DB validity check needs a real store; on a fake root it may only SKIP or FAIL that one line
  local gfails; gfails=$(grep -c 'FAIL:' "$WORK/good.out"); grep 'FAIL:' "$WORK/good.out" | grep -v 'store DB' | sed 's/^/    good-root /'
  if [ "$(grep 'FAIL:' "$WORK/good.out" | grep -vc 'store DB')" != 0 ]; then echo "  FAIL: a GOOD closure root fails the contract (checks are wrong)"; return 1; fi
  FAIL=$gb
  echo "  positive control: a good closure root passes the contract (store-DB line aside: $gfails)"
  before=$FAIL
  static_checks "$T" >/dev/null 2>&1 || true
  if [ "$FAIL" -gt "$before" ]; then
    echo "  PASS: the suite FAILED on a deliberately-defective root ($((FAIL-before)) checks fired)"
    echo "  => the checks can fail; they are not vacuous."
    FAIL=$before   # reset -- the selftest EXPECTS failures
    return 0
  fi
  echo "  FAIL: the suite PASSED a defective root -- the checks are vacuous (fix them!)"
  return 1
}

# ---------------------------------------------------------------------------
main() {
  if [ "$MODE" = selftest ]; then selftest; exit $?; fi
  echo "=== solnix image acceptance test: $DIR ==="
  local rc=0; find_boot_archive || rc=$?
  local R="$FOUND_RD"
  if [ "$rc" = 2 ]; then
    echo "STATIC checks need the illumos build node (lofiadm/mount -F ufs). Skipping mount-based checks." >&2
    _skip "boot_archive mount (not on an illumos host)"
  elif [ -z "$R" ]; then
    _fail "could not locate/mount a boot_archive in $DIR"
  else
    echo "-- static checks (mounted boot_archive: $R) --"
    static_checks "$R"
    # size gate applies to the UNCOMPRESSED archive (what the EFI loader stages).
    [ -n "$BA_PATH" ] && size_check "$BA_PATH"
  fi
  if [ "$MODE" = boot ]; then echo "-- boot phase (QEMU) --"; boot_checks; fi
  echo ""
  echo "=== RESULT: $PASS pass, $FAIL fail, $SKIP skip ==="
  [ "$FAIL" = 0 ]
}
main
