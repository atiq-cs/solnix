#!/usr/bin/env bash
# test-autoinstall-picker.sh -- self-check for the AUTO-INSTALL target picker in
# oi-make-livecd.sh's solnix-live method. The picker is the one piece of this
# image that can destroy data, so it gets a check that can FAIL.
#
# The block under test is extracted VERBATIM from the script (not retyped) so it
# cannot drift, then run against stub mount/umount/fstyp/format and a fake /dev
# tree. Two knobs model the two guards independently:
#   MOUNT_HSFS -- disks whose p0 accepts `mount -F hsfs -o ro` (guard 1's input)
#   FSTYP_HSFS -- disks whose p0 `fstyp` reports as hsfs      (guard 2's input)
set -u
SCRIPT="${1:-/home/gburd/ws/solnix/scripts/oi-make-livecd.sh}"
W=$(mktemp -d /tmp/pickertest.XXXXXX)
trap 'rm -rf "$W"' EXIT

awk '/IDENTIFY OUR OWN BOOT MEDIUM/,/FAIL no-target-disk/' "$SCRIPT" > "$W/block.sh"
grep -q 'boot medium identified as' "$W/block.sh" || { echo "EXTRACT FAILED: anchors moved"; exit 1; }
printf '    fi\n  fi\n' >> "$W/block.sh"
bash -n "$W/block.sh" || { echo "extracted block is not valid shell"; exit 1; }

mkdir -p "$W/bin"
cat > "$W/bin/stub-mount" <<'EOF'
#!/usr/bin/env bash
node=""; mnt=""
for a in "$@"; do case "$a" in */dev/dsk/*) node=$a;; */.media) mnt=$a;; esac; done
d=$(basename "$node" p0)
case " $MOUNT_HSFS " in *" $d "*) ;; *) exit 1;; esac
mkdir -p "$mnt"
[ -n "${MEDIA_HAS_ARCHIVE:-}" ] && { mkdir -p "$mnt/platform/i86pc/amd64"; : > "$mnt/platform/i86pc/amd64/boot_archive"; }
[ -n "${MEDIA_HAS_MARKER:-}" ] && echo auto > "$mnt/solnix-autoinstall"
exit 0
EOF
cat > "$W/bin/stub-umount" <<'EOF'
#!/usr/bin/env bash
rm -rf "$1/platform" "$1/solnix-autoinstall" 2>/dev/null; exit 0
EOF
cat > "$W/bin/stub-fstyp" <<'EOF'
#!/usr/bin/env bash
d=$(basename "$1" p0)
case " $FSTYP_HSFS " in *" $d "*) echo hsfs; exit 0;; esac
echo unknown_fstyp; exit 1
EOF
cat > "$W/bin/stub-format" <<'EOF'
#!/usr/bin/env bash
echo "       0. c1t0d0 <stub-disk>"; exit 0
EOF
chmod +x "$W/bin"/*

FAILED=
run_case() { # run_case <name> <expected-target>
  local name="$1" want="$2" got rc out
  local R="$W/run.$name"; rm -rf "$R"; mkdir -p "$R/etc" "$R/tmp" "$R/dev/dsk" "$R/dev/rdsk"
  local d
  for d in $DISKS; do
    : > "$R/dev/dsk/${d}p0"; : > "$R/dev/rdsk/${d}p0"; : > "$R/dev/rdsk/${d}s0"
  done
  [ -n "${MARKER:-}" ] && echo "$MARKER" > "$R/etc/solnix-autoinstall"
  # rewrite absolute paths into the sandbox; neuter the countdown and the
  # installer itself -- this test is about SELECTION, not installation.
  sed -e "s#/dev/#$R/dev/#g" -e "s#/etc/solnix-autoinstall#$R/etc/solnix-autoinstall#g" \
      -e "s#/tmp/\.solnix-media-disk#$R/tmp/.solnix-media-disk#g" \
      -e "s#/tmp/\.media#$R/tmp/.media#g" \
      -e "s#/usr/sbin/mount#$W/bin/stub-mount#g" -e "s#/usr/sbin/umount#$W/bin/stub-umount#g" \
      -e "s#/usr/sbin/fstyp#$W/bin/stub-fstyp#g" -e "s#/usr/sbin/format#$W/bin/stub-format#g" \
      -e "s#_i=10#_i=1#" -e "s#sleep 1;#:;#" \
      -e "s#/usr/sbin/solnix-install#echo STUB-INSTALL#" \
      -e "s#/usr/sbin/prtconf#true#g" \
      "$W/block.sh" > "$R/block.sh"
  out=$(MOUNT_HSFS="${MOUNT_HSFS:-}" FSTYP_HSFS="${FSTYP_HSFS:-}" bash "$R/block.sh" 2>&1); rc=$?
  got=$(printf '%s\n' "$out" | sed -n 's/.*AUTO-INSTALL to \([^ ]*\).*/\1/p' | head -1)
  case "$got" in '<none'*) got="";; esac
  if [ "$got" = "$want" ]; then echo "PASS  $name: target='${got:-<none>}'"
  else echo "FAIL  $name: target='$got' want='$want'"; printf '%s\n' "$out" | sed 's/^/      | /'; FAILED=1; fi
}

echo "=== A. marker BAKED IN the ramdisk, media enumerates as a disk (QEMU shape) ==="
DISKS="c1t0d0 c2t0d0" MOUNT_HSFS="c1t0d0" FSTYP_HSFS="c1t0d0" MEDIA_HAS_ARCHIVE=1 MARKER=auto \
  run_case baked-media-visible c2t0d0

echo "=== B. X1 shape: the media does NOT enumerate at all, only the NVMe ==="
DISKS="c1t001B448B485502D1d0" MARKER=auto \
  run_case baked-media-invisible c1t001B448B485502D1d0

echo "=== C. marker on the MEDIA's own filesystem (legacy path), media visible ==="
DISKS="c1t0d0 c2t0d0" MOUNT_HSFS="c1t0d0" FSTYP_HSFS="c1t0d0" MEDIA_HAS_ARCHIVE=1 MEDIA_HAS_MARKER=1 \
  run_case media-marker c2t0d0

echo "=== D. NEGATIVE CONTROL: no marker anywhere -> must select NOTHING ==="
DISKS="c1t0d0 c2t0d0" MOUNT_HSFS="c1t0d0" FSTYP_HSFS="c1t0d0" MEDIA_HAS_ARCHIVE=1 \
  run_case no-marker ""

echo "=== E. guard 2 SABOTAGED (fstyp no longer reports hsfs). Guard 1 (content"
echo "       identification via boot_archive) must still exclude the stick. ==="
DISKS="c1t0d0 c2t0d0" MOUNT_HSFS="c1t0d0" FSTYP_HSFS="" MEDIA_HAS_ARCHIVE=1 MARKER=auto \
  run_case sabotage-guard2 c2t0d0

echo "=== F. guard 1 SABOTAGED (no boot_archive on the medium). Guard 2 must"
echo "       still exclude it. ==="
DISKS="c1t0d0 c2t0d0" MOUNT_HSFS="c1t0d0" FSTYP_HSFS="c1t0d0" MARKER=auto \
  run_case sabotage-guard1 c2t0d0

echo "=== G. BOTH guards sabotaged -> the stick IS selected. This case MUST"
echo "       report c1t0d0; if it does not, the harness is not exercising the"
echo "       guards and A-F prove nothing. ==="
DISKS="c1t0d0 c2t0d0" MARKER=auto \
  run_case both-guards-off c1t0d0

[ -z "$FAILED" ] && echo "ALL PICKER CHECKS PASS" || { echo "PICKER CHECKS FAILED"; exit 1; }
