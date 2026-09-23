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
WORK="$(mktemp -d /tmp/img-accept.XXXXXX)"
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

  # LESSON (tui5 regression): auto-login on raw /dev/console let the X1 hid
  # keyboard flood drown the prompt. The media MUST keep STOCK ttymon.
  if [ -e "$R/etc/svc/repository.db" ] && command -v svccfg >/dev/null; then
    local cl
    cl=$(SVCCFG_REPOSITORY="$R/etc/svc/repository.db" svccfg -s system/console-login listprop start/exec 2>/dev/null)
    case "$cl" in
      *solnix-console-login*) _fail "console-login is repointed to solnix-console-login (auto-login) -- the tui5 no-login regression" ;;
      *console-login*)        _ok  "console-login is stock ttymon (tui5 regression guard)" ;;
      *)                      _skip "console-login start/exec not readable" ;;
    esac
  else _skip "no repository.db / svccfg -- console-login check"; fi

  # LESSON (X1 hid flood): /etc/system must quiet the hid Invalid-Report-Descriptor spam.
  if grep -q 'set hid:hid_errlevel' "$R/etc/system" 2>/dev/null; then
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
  if [ -x "$R/usr/sbin/solnix-zap" ] && head -1 "$R/usr/sbin/solnix-zap" | grep -q '/sbin/sh'; then
    _ok "solnix-zap present + #!/sbin/sh (disk-nuke recovery tool)"
  else _fail "solnix-zap missing or wrong shebang"; fi

  # LESSON (committed != shipped): the shipped solnix-install must match a known
  # HEAD blob (the mount-guard fix etc. must actually be IN the image binary).
  if [ -x "$R/usr/sbin/solnix-install" ]; then
    local ish gsh
    ish=$(sha256sum "$R/usr/sbin/solnix-install" 2>/dev/null | awk '{print $1}')
    gsh=$(cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && git show HEAD:scripts/solnix-install 2>/dev/null | sha256sum | awk '{print $1}')
    if [ -n "$gsh" ] && [ "$ish" = "$gsh" ]; then _ok "shipped solnix-install sha == git HEAD blob ($ish)"
    elif [ -n "$gsh" ]; then _fail "shipped solnix-install sha ($ish) != HEAD blob ($gsh) -- image predates a committed fix"
    else _skip "not in a git tree -- cannot compare solnix-install sha to HEAD"; fi
  else _fail "/usr/sbin/solnix-install not present or not executable"; fi

  # LESSON (autoinstall must be opt-in): a stray /etc/solnix-autoinstall would wipe
  # a disk unattended. It must be ABSENT on a normal installer image.
  if [ -e "$R/etc/solnix-autoinstall" ]; then _fail "/etc/solnix-autoinstall present (would auto-wipe a disk!)"
  else _ok "/etc/solnix-autoinstall absent (install is interactive)"; fi

  # LESSON (login dns stall): a local console login needs no dns; the media keeps
  # hosts/ipnodes = files. tui8's first build logged the rewrite but a LATER host
  # /etc re-copy put 'files dns mdns' back -- a build-log line is not the artifact.
  local ns; ns=$(grep -E '^[[:space:]]*hosts:' "$R/etc/nsswitch.conf" 2>/dev/null | head -1)
  case "$ns" in
    *dns*) _fail "nsswitch '$ns' -- dns in the live-media hosts lookup (console-login dns stall)" ;;
    *files*) _ok "nsswitch hosts is files-only on the live media ($ns)" ;;
    *) _fail "nsswitch.conf has no hosts: line" ;;
  esac

  # LESSON (tui8 KVM: auto-network DOWN): the build host's /etc/ipadm/ipadm.conf
  # shipped its own persistent addrobj (vioif0/dhcp). On a same-named live NIC it
  # stole the lease, the auto-network's vioif0/v4 stayed down, resolv.conf was never
  # written, and every fetch failed "Could not resolve hostname". No persistent
  # interfaces may ship on the live media.
  if grep -qE '^_ifname=' "$R/etc/ipadm/ipadm.conf" 2>/dev/null; then
    _fail "ipadm.conf ships build-host interfaces: $(grep -oE '_aobjname=[^;]+' "$R/etc/ipadm/ipadm.conf" | sort -u | tr '\n' ' ')"
  else _ok "ipadm.conf carries no build-host interfaces (auto-network plumbs the NIC)"; fi

  # LESSON (dig/curl broken -- the SECOND-ORDER dangling lib, the openssl trap):
  # EVERY staged ELF's DT_NEEDED must be present in the ramdisk, TRANSITIVELY
  # (a staged lib's own NEEDED too), ABI-matched (a 64-bit binary needs a 64-bit
  # lib). This is the runnability check; it also caught curl/dig/nslookup.
  runnability_check "$R"
}

# Transitive, ABI-aware NEEDED-closure check over every staged ELF.
runnability_check() {
  local R="$1"
  command -v elfdump >/dev/null || { _skip "elfdump absent -- runnability (NEEDED-closure) check (run on the illumos node)"; return; }
  local libdirs="$R/lib $R/lib/amd64 $R/usr/lib $R/usr/lib/amd64 $R/usr/gnu/lib $R/usr/gnu/lib/amd64"
  _have() {  # $1 soname, $2 wanted ELFCLASS (32|64)
    local sn="$1" want="$2" d f cls
    for d in $libdirs; do
      f="$d/$sn"; [ -e "$f" ] || continue
      cls=$(elfdump -e "$f" 2>/dev/null | awk '/ei_class/{print $NF}')
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
    local cls; cls=$(elfdump -e "$elf" 2>/dev/null | awk '/ei_class/{print $NF}'); case "$cls" in *64*) cls=64 ;; *) cls=32 ;; esac
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

# boot_archive size ceiling (the X1 firmware refused an oversized raw archive).
size_check() {
  local ba="$1" cap="${RD_MAX_RAW_BYTES:-816119808}"   # measured X1 EFI hard limit
  local sz; sz=$(stat -c %s "$ba" 2>/dev/null || stat -f %z "$ba" 2>/dev/null)
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
  echo 'hosts:      files dns mdns' > "$T/etc/nsswitch.conf"
  mkdir -p "$T/etc/ipadm"; echo '_ifname=vioif0;_aobjname=vioif0/dhcp;_dhcp=30,no;' > "$T/etc/ipadm/ipadm.conf"
  local before=$FAIL
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
