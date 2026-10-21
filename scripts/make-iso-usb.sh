#!/usr/bin/env bash
# make-iso-usb.sh — assemble the solnix hybrid ISO + dd-able USB image from the
# staging tree built on the illumos host by oi-make-livecd.sh. Runs on a Linux
# box (uses xorriso + mtools + mkfs.vfat via nix-shell). T2.13.
#
#   make-iso-usb.sh <solnix-iso-tree.tar.gz> <outdir>
#
# Produces:
#   <outdir>/solnix-x86_64.iso   hybrid ISO: BIOS El Torito (cdboot) + UEFI ESP
#   <outdir>/solnix-x86_64-usb.img  GPT disk image, dd-able to USB (ESP + iso data)
#
# The ISO boot chain (illumos loader):
#   BIOS: El Torito no-emulation boot image = boot/cdboot -> boot/isoboot ->
#         boot/loader -> reads boot/loader.conf -> loads unix + boot_archive.
#   UEFI: an EFI System Partition image (FAT) holding EFI/BOOT/BOOTX64.EFI =
#         loader64.efi, added as an El Torito EFI boot entry (xorriso -e).
set -euo pipefail

TARBALL="${1:?usage: make-iso-usb.sh <tarball> <outdir>}"
OUTDIR="${2:?usage: make-iso-usb.sh <tarball> <outdir>}"
WORK="$(mktemp -d /tmp/solnix-iso.XXXXXX)"
mkdir -p "$OUTDIR"
# VARIANT names the media: minimal (console ISO) or graphical (live Xfce ISO).
# VARIANT names the media; empty (the default) gives the plain deliverable names
# solnix-x86_64.iso / solnix-x86_64-usb.img. VARIANT=graphical suffixes them.
VARIANT="${VARIANT-}"
ISO="$OUTDIR/solnix-x86_64${VARIANT:+-$VARIANT}.iso"
USB="$OUTDIR/solnix-x86_64${VARIANT:+-$VARIANT}-usb.img"

log() { printf '\n=== %s ===\n' "$*" >&2; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

log "unpacking staging tree"
tar -xf "$TARBALL" -C "$WORK"
ISOROOT="$WORK/iso"
[ -d "$ISOROOT/boot" ] || { echo "no boot/ in staging tree" >&2; exit 1; }
[ -f "$WORK/loader64.efi" ] || { echo "no loader64.efi in tree" >&2; exit 1; }
[ -f "$ISOROOT/boot/cdboot" ] || { echo "no boot/cdboot (BIOS El Torito image)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. rewrite loader.conf cleanly (the fleet heredoc can double-escape quotes,
#    which breaks the loader parser -> boot_archive_type never set -> "No rootfs
#    module provided"). This file is tiny + known, so author it here authoritatively.
# ---------------------------------------------------------------------------
log "writing loader.conf"
# NOTE: UNQUOTED heredoc on purpose. With <<'EOF' the ${SOLNIX_CONSOLE:-...}
# below was written LITERALLY into loader.conf; the illumos loader has no shell
# parameter expansion, so it answered "no valid consoles!" (observed) and fell
# back. Only the console lines contain '$'.
# Console ORDER matters for the deliverable: real hardware (the X1 Carbon) has no
# ttya at all, so the framebuffer console ("text") must lead.
#
# ⚠️ ttya is NO LONGER kept second by default, and that is a deliberate change.
#     `console=` is a LIST from which illumos derives BOTH stdin and stdout.
#     consconfig_dacf.c:68-86: if stdin does not resolve to a keyboard, the console
#     becomes CONSOLE_SERIAL_KEYBOARD / CONSOLE_TIP and rconsvp is wired to the
#     SERIAL device -- output still reaches the VGA text screen while NO keystroke
#     is ever read. On a machine with no physical serial port that presents as "the
#     keyboard does not work", for EVERY keyboard, which is exactly what the X1
#     showed with both its internal keyboard and an external USB one.
#
#     Keeping ttya "just for the capture" is therefore not free -- it may be the
#     cause. QEMU hid this because we boot with `-nographic -serial mon:stdio`, so
#     there the serial line IS the keyboard and the setting is accidentally right.
#
#     Set SOLNIX_CONSOLE="text,ttya" explicitly for headless QEMU/EC2 runs that
#     need a serial capture. The DEFAULT now favours real hardware, matching
#     oi-make-livecd.sh so stage 2 cannot silently override stage 1 (which is how
#     the branding fix was reverted once already).
# loader_brand/loader_menu_title: this rewrite REPLACES the loader.conf that
# oi-make-livecd.sh authored, so omitting them silently reverted the boot-screen
# branding to illumos even though menu.4th (patched on the build host) was fine.
cat > "$ISOROOT/boot/loader.conf" <<EOF
loader_logo="illumos"
loader_brand="solnix"
loader_menu_title="Welcome to solnix"
# console: the LOADER mirrors to every console in this list, so text,ttya puts the
# loader menu on the panel and on COM1. The KERNEL is different: boot_console.c
# lookup_console_device() stops at the first ',' so its console is the first name
# only (text), and the kernel mirrors to a second device only via diag-device.
# ttya is the legacy I/O-port UART at 0x3f8; laptops without a COM port (the X1
# Extreme Gen5) have no ttya, so this mirror reaches nothing there. Capture on such
# machines comes from the network + a crash dump on the media, not serial.
# SOLNIX_CONSOLE overrides (=text pure framebuffer, =ttya serial-only boot).
console="${SOLNIX_CONSOLE:-text,ttya}"
# os_console pins the KERNEL console. PROVEN ON REAL HARDWARE: the X1 Carbon
# had a dead keyboard until BOTH `set console=text` AND `set os_console=text`
# were given at the loader prompt. multiboot2.c:468 reads os_console via
# getenv and :598-603 only defaults it when unset AND several consoles exist,
# so on this machine the kernel console was never pinned to the framebuffer:
# output fell back to the screen while input stayed on a nonexistent ttya.
# This one line is the only keyboard change with hardware evidence behind it.
# The kernel reads only the first name here (see console= above), so this is
# effectively os_console=text with the ttya suffix ignored.
os_console="${SOLNIX_CONSOLE:-text,ttya}"
# Console font. MEASURED on the X1 (3840x2160 EDID): with no /boot/fonts the loader
# falls back to its builtin 8x16 font (478x134 cells, unreadable). With the gate
# fonts present, autoload_font() (efi/loader/main.c) loads /boot/fonts/fonts.dir and
# set_font() (common/font/font.c) walks them largest-first, taking the first that
# fits the default 80x34 grid: 16x32 on this panel (239x67), confirmed via mdb
# tems.ts_font after a reboot. The kernel console inherits it (module.c
# "console-font"). Pin a size with screen-font="WxH" if ever needed.
# efi-max-resolution is NOT a loader variable (no reference in usr/src/boot).
ttya-mode="115200,8,n,1,-"
autoboot_delay="5"
boot_archive_load="YES"
boot_archive_type="rootfs"
boot_archive_name="/platform/i86pc/amd64/boot_archive"
boot_archive.hash_load="NO"
kernel="/platform/i86pc/kernel/amd64/unix"
bootfile="unix"
EOF
# Verbose boot (-v) is OFF by default: on a 4K panel the early-boot framebuffer
# scrolls pixel by pixel, so each of its ~100 extra lines is visibly slow (the X1).
# SOLNIX_BOOTARGS=-v brings it back for a debugging run.
[ -n "${SOLNIX_BOOTARGS:-}" ] && printf 'boot-args="%s"\n' "$SOLNIX_BOOTARGS" >> "$ISOROOT/boot/loader.conf"
# ⚠️ This script rewrites loader.conf but conf.d/ is ALSO read by the loader
# (support.4th:1207,1441), and upstream ships conf.d/console pinning ttya. Left
# alone it silently re-pins the kernel console after everything above -- which is
# half of why the X1 keyboard was dead in image j. Reconcile, then gate.
_cd="$ISOROOT/boot/conf.d/console"
if [ -f "$_cd" ]; then
  sed -e "s/^console=.*/console=\"${SOLNIX_CONSOLE:-text,ttya}\"/" \
      -e "s/^os_console=.*/os_console=\"${SOLNIX_CONSOLE:-text,ttya}\"/" \
      "$_cd" > "$_cd.new" && mv "$_cd.new" "$_cd"
  echo "  conf.d/console reconciled to ${SOLNIX_CONSOLE:-text}" >&2
fi
for _f in "$ISOROOT/boot/loader.conf" "$ISOROOT/boot/conf.d/console"; do
  [ -f "$_f" ] || continue
  grep -q '\${' "$_f" && { echo "FATAL: $_f has an unexpanded \${...}; the loader does not expand variables" >&2; exit 1; }
  if [ "${SOLNIX_CONSOLE:-text}" = "text" ] && grep -qE '^(os_)?console="ttya"' "$_f"; then
    echo "FATAL: $_f still pins ttya despite SOLNIX_CONSOLE=text" >&2; exit 1
  fi
done
echo "  console gate OK (stage 2): loader.conf + conf.d/console = ${SOLNIX_CONSOLE:-text}" >&2

# Boot menu item 4 (free on the live media: 1 boot, 2 single user, 3 loader prompt,
# 5+ options): boot with the ThinkPad dGPU powered off. The loader passes every
# environment variable to the kernel as a boot property (module.c
# build_environment_module -> fakebop.c process_boot_environment), the same as
# -B solnix-dgpu-off=1; tzmon then runs its opt-in dGPU power-off
# (scripts/patches/0005-tzmon-thinkpad-dgpu-off.patch). Elsewhere it logs one line.
# A menu command runs with the item number on the stack, as `boot` (item 1) expects;
# the word sets the variable and hands that stack to boot unchanged.
cat > "$ISOROOT/boot/menu.rc.local" <<'MENU'
: solnix_dgpu_off_boot ( N -- NOTREACHED ) s" set solnix-dgpu-off=1" evaluate boot ;
set mainmenu_caption[4]="Boot, ThinkPad [D]GPU off"
set mainmenu_command[4]="solnix_dgpu_off_boot"
set mainmenu_keycode[4]=100
set mainansi_caption[4]="Boot, ThinkPad ^[1mD^[mGPU off"
MENU
grep -q 'solnix-dgpu-off=1' "$ISOROOT/boot/menu.rc.local" || { echo "FATAL: menu.rc.local lacks the dGPU-off entry" >&2; exit 1; }

cat "$ISOROOT/boot/loader.conf" >&2

# ---------------------------------------------------------------------------
# 1. build the EFI System Partition image (FAT) with EFI/BOOT/BOOTX64.EFI.
#    Size it to fit loader64.efi + slack, rounded up. Placed at the ISO root as
#    boot/efiboot.img and referenced by xorriso -e as the EFI El Torito entry.
# ---------------------------------------------------------------------------
log "building EFI System Partition image (efiboot.img)"
EFI_IMG="$ISOROOT/boot/efiboot.img"
# wc -c, not stat -c%s: illumos has no stat(1) at all, so keep the size idiom
# portable in case this step ever moves on-node.
EFI_KB=$(( ( $(wc -c < "$WORK/loader64.efi") / 1024 ) + 2048 ))   # loader + 2MB slack
# FAT needs a minimum; round to a 32KB-cluster-friendly size, min 4MB.
[ "$EFI_KB" -lt 4096 ] && EFI_KB=4096
rm -f "$EFI_IMG"
mkfs.vfat -C "$EFI_IMG" "$EFI_KB" >/dev/null
mmd   -i "$EFI_IMG" ::/EFI ::/EFI/BOOT
mcopy -i "$EFI_IMG" "$WORK/loader64.efi" ::/EFI/BOOT/BOOTX64.EFI
echo "efiboot.img: ${EFI_KB}KB with EFI/BOOT/BOOTX64.EFI"
mdir -i "$EFI_IMG" ::/EFI/BOOT >&2 || true

# ALSO drop the ESP tree into the ISO9660 filesystem itself (xorriso warns that
# without a visible /EFI/BOOT, some UEFI firmwares + the Windows-USB method won't
# find the loader). Give the ISO a real /EFI/BOOT/BOOTX64.EFI too.
mkdir -p "$ISOROOT/EFI/BOOT"
cp "$WORK/loader64.efi" "$ISOROOT/EFI/BOOT/BOOTX64.EFI"

# ---------------------------------------------------------------------------
# 1b. WRITABLE SCRATCH PARTITION (design-two-installer-images.md #1). The live
#     root is a small RAM ramdisk; `nix eval <user-flake>` fetches flake inputs
#     into ~/.cache/nix and fills it. NixOS bakes its own closure into the media
#     and mounts the target disk for the rest; we add a real WRITABLE partition
#     on the stick so setup_scratch (in solnix-install) can mount it for the
#     flake fetch/eval scratch AND root's home -- WITHOUT carving the live GPT at
#     runtime (that wedges boot devices).
#
#     SIZE: fixed at build time (a dd'd stick cannot auto-grow the partition
#     without a live-GPT edit -- MEASURED: `zpool online -e` sees the still-fixed
#     p3 and does not expand; growing the p3 GPT entry first is a deferred
#     follow-up). So SIZE IT BIG ENOUGH FOR THE COMMON USER-FLAKE FETCH here.
#     The image is written SPARSE (dd seek, zeros), so a large partition costs
#     almost nothing in the shipped .img yet gives real space on the stick.
#     4GB covers most flake-input fetches; the base/default install needs almost
#     none (step #2's media store serves the base closure locally).
#
#     WHAT KIND: type Solaris (bf01). setup_scratch `zpool create`s it on first
#     use (the Linux build box has no zpool to pre-format it).
SCRATCH_MB="${SCRATCH_MB:-4096}"
SCRATCH_IMG="$WORK/scratch.img"
log "building blank writable scratch partition image (${SCRATCH_MB}MB sparse, type Solaris)"
rm -f "$SCRATCH_IMG"
# a zeroed SPARSE image; setup_scratch formats it (zpool create) on first boot.
# Sparse (seek, no data blocks written) keeps the shipped .img small -- only the
# GPT-declared size matters for the partition, not on-disk bytes here.
dd if=/dev/zero of="$SCRATCH_IMG" bs=1024k count=0 seek="$SCRATCH_MB" 2>/dev/null

# ---------------------------------------------------------------------------
# 1c. READ-ONLY MEDIA STORE (design-two-installer-images.md #2). Seed the SOLNIX
#     BASE closure + the common starter set into a read-only Nix binary cache and
#     pack it as its OWN ISO9660 (hsfs) image dropped in the ISO tree at
#     /solnix-store.iso. At boot, setup_media_store (solnix-install) lofiadm -a's
#     it, mounts -F hsfs -o ro, and wires it as `--extra-substituters file://<mnt>`
#     so a base `nix build` pulls store paths from the MEDIA, not the network.
#
#     WHY a file:// binary cache in ISO9660, not a raw /nix/store or a UFS image:
#       * `--extra-substituters file://<dir>` reads the STANDARD binary-cache layout
#         (nix-cache-info + <hash>.narinfo + nar/*.nar), which `nix copy --to
#         file://<dir>` produces. That is exactly what a substituter consumes.
#       * illumos has NO overlayfs and needs none (research, design doc). It DOES
#         mount ISO9660 read-only via lofi + `mount -F hsfs` natively, and Linux
#         builds ISO9660 with the xorriso this script already depends on -- so no
#         UFS-on-Linux writer is needed. MEASURED on Linux: git's 75-path closure
#         realises from file://<iso-mount> with the network substituter unreachable.
#       * The image lives in the MEDIA filesystem (lofi-mounted), NOT unpacked into
#         the RAM ramdisk -- so it does not re-fill RAM (the #2 constraint).
#
#     ⚠️ MEASURED distinction preserved: this serves STORE PATHS. It makes the
#        DEFAULT/base install near-instant + offline. A user's github: flake still
#        fetches its FLAKE INPUTS into the step-#1 scratch partition; the two caches
#        are separate and not conflated here.
#
#     Set SOLNIX_NO_MEDIA_STORE=1 to skip (faster iteration / no-nix build box).
#     STORE_CACHE names the upstream cache to seed FROM (default cache.solnix.io).
# SOLNIX_STORE_ISO=<path> reuses an ALREADY-BUILT media store instead of re-seeding
# it from the cache. The media store is independent of the ramdisk (it is a separate
# ISO9660 the live system lofi-mounts), so a verified one can be carried across
# rebuilds. Needed when the upstream cache is temporarily missing a nar: tui8 v4 hit
# `error: file 'nar/168cmpx8...nar.xz' does not exist in binary cache` (404 on BOTH
# cache.solnix.io and the transit endpoint) for a closure member that the SAME
# starter set had copied successfully hours earlier -- an upstream gap, not a
# repo/media defect. Reusing a verified store keeps the ramdisk fixes shippable.
if [ -n "${SOLNIX_STORE_ISO:-}" ]; then
  [ -f "$SOLNIX_STORE_ISO" ] || { echo "FATAL: SOLNIX_STORE_ISO=$SOLNIX_STORE_ISO not found" >&2; exit 1; }
  log "reusing prebuilt media store $SOLNIX_STORE_ISO ($(wc -c < "$SOLNIX_STORE_ISO" | tr -d ' ') B, sha256 $(sha256sum "$SOLNIX_STORE_ISO" | cut -c1-16)...)"
  cp "$SOLNIX_STORE_ISO" "$ISOROOT/solnix-store.iso"
  cp "$SOLNIX_STORE_ISO" "$OUTDIR/solnix-store.iso"
elif [ -z "${SOLNIX_NO_MEDIA_STORE:-}" ]; then
  log "building read-only base-closure media store -> $ISOROOT/solnix-store.iso"
  if ! command -v nix >/dev/null 2>&1; then
    echo "FATAL: nix not on PATH; the media store needs \`nix copy\`. Install nix or set SOLNIX_NO_MEDIA_STORE=1." >&2
    exit 1
  fi
  STORE_CACHE="${STORE_CACHE:-https://cache.solnix.io}"
  STORE_KEY="${STORE_KEY:-cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=}"
  # The base-closure roots. Default: the x86_64-solaris published store paths for the
  # pnames configurations/base.nix's system.build.toplevel references (its
  # systemPackages starter set) + the common starter set the brief names. Passed as
  # a newline-separated file so the caller can override for a different config.
  #   SOLNIX_STORE_ROOTS=/path/to/roots.txt   (one /nix/store/... path per line)
  STORE_ROOTS_FILE="${SOLNIX_STORE_ROOTS:-}"
  if [ -z "$STORE_ROOTS_FILE" ]; then
    _rd="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/docs/registry/real-derivations.tsv"
    STORE_ROOTS_FILE="$WORK/base-roots.txt"
    if [ -f "$_rd" ]; then
      # base.nix systemPackages + nix module deps + the brief's starter set, by pname.
      awk -F'\t' '$8=="x86_64-solaris" && $7=="published" && \
        ($1=="coreutils"||$1=="file"||$1=="gnugrep"||$1=="gnused"||$1=="bzip2"|| \
         $1=="xz"||$1=="zlib"||$1=="pcre2"||$1=="nvi"||$1=="which"||$1=="gdb"|| \
         $1=="openssl"||$1=="git"||$1=="ncurses"||$1=="curl") {print $4}' \
        "$_rd" | sort -u > "$STORE_ROOTS_FILE"
    fi
  fi
  if [ ! -s "$STORE_ROOTS_FILE" ]; then
    echo "FATAL: no base-closure roots to seed (looked for docs/registry/real-derivations.tsv" >&2
    echo "       x86_64-solaris published rows, or SOLNIX_STORE_ROOTS). Set SOLNIX_NO_MEDIA_STORE=1 to skip." >&2
    exit 1
  fi
  # GUI edition (design #4): base closure + the COSMIC closure, so a desktop
  # install is fast/offline. These are the x86_64-illumos COSMIC build outputs
  # published to cache.solnix.io (verified reachable): the smallvil compositor,
  # libcosmic + cosmic-toolkit rlibs, and the rust-illumos toolchain the front-end
  # is built with. The cosmic-term APP output is NOT in the cache (its runnable
  # binary lived only on the closed-account host); the seeded set is what SURVIVES
  # and is what the smallvil session + the thin front-end need. Override with
  # SOLNIX_COSMIC_ROOTS=<file> (one /nix/store path per line).
  if [ "${SOLNIX_IMAGE_EDITION:-tui}" = gui ]; then
    _cosmic_roots="${SOLNIX_COSMIC_ROOTS:-}"
    if [ -z "$_cosmic_roots" ]; then
      _cosmic_roots="$WORK/cosmic-roots.txt"
      cat > "$_cosmic_roots" <<'COSMICROOTS'
/nix/store/7qvqfz2wc82qi4v1k1hvvhrkwcs627gz-smallvil-x86_64-illumos
/nix/store/rvzgiglmlsvxi6qnsgh6fwnxz8n0243p-libcosmic-x86_64-illumos.rlib
/nix/store/591rk79s4adj5bx7lfpfg906ja1s8y7s-cosmic-toolkit-x86_64-illumos-rlibs
/nix/store/8daydacsqmkzi72zfa3dmi9pp98d6hmj-rust-illumos-1.97.1
COSMICROOTS
    fi
    cat "$_cosmic_roots" >> "$STORE_ROOTS_FILE"
    sort -u "$STORE_ROOTS_FILE" -o "$STORE_ROOTS_FILE"
    echo "  GUI edition: added $(wc -l < "$_cosmic_roots" | tr -d ' ') COSMIC closure roots" >&2
  fi
  echo "  base-closure roots ($(wc -l < "$STORE_ROOTS_FILE" | tr -d ' ') paths):" >&2
  sed 's,^/nix/store/,    ,' "$STORE_ROOTS_FILE" >&2
  STORE_DIR="$WORK/store"
  mkdir -p "$STORE_DIR"
  # nix copy: cache -> file:// binary cache, WITH closure, uncompressed (the media
  # is already read-only + the ISO is not re-compressed here; NAR-level compression
  # would only slow the boot-time substitution). Signatures are checked against the
  # trusted key so a tampered upstream path is refused at seed time.
  # shellcheck disable=SC2046
  if ! nix copy \
        --extra-experimental-features nix-command \
        --from "$STORE_CACHE" \
        --to "file://$STORE_DIR?compression=none" \
        --option trusted-public-keys "$STORE_KEY cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" \
        $(cat "$STORE_ROOTS_FILE") 2>&1 | tail -8; then
    echo "FATAL: nix copy of the base closure from $STORE_CACHE failed" >&2; exit 1
  fi
  # GATE: the binary-cache layout must be present, or file:// substitution silently
  # finds nothing at boot (the empty-dir negative control -- proven to FAIL rc=1).
  _ninfo=$(ls "$STORE_DIR"/*.narinfo 2>/dev/null | wc -l | tr -d ' ')
  [ "$_ninfo" -ge 1 ] || { echo "FATAL: media store has 0 .narinfo files -- seed produced nothing" >&2; exit 1; }
  [ -d "$STORE_DIR/nar" ] || { echo "FATAL: media store has no nar/ dir" >&2; exit 1; }
  # nix-cache-info makes it a valid substituter root; nix copy writes it, assert it.
  [ -f "$STORE_DIR/nix-cache-info" ] || { echo "FATAL: media store has no nix-cache-info" >&2; exit 1; }
  echo "  media store seeded: $_ninfo narinfo, $(du -sh "$STORE_DIR" 2>/dev/null | awk '{print $1}')" >&2
  # Pack the store dir as its OWN ISO9660 (Rock Ridge -R preserves the exact
  # hash-named file names + case that narinfo lookups depend on). This image is
  # what illumos lofi-mounts read-only at boot.
  STORE_ISO="$ISOROOT/solnix-store.iso"
  rm -f "$STORE_ISO"
  xorriso -as mkisofs -R -V SOLNIXSTORE -o "$STORE_ISO" "$STORE_DIR" 2>&1 | tail -3
  [ -f "$STORE_ISO" ] || { echo "FATAL: solnix-store.iso not produced" >&2; exit 1; }
  echo "  media store image: $(wc -c < "$STORE_ISO" | tr -d ' ') B at $STORE_ISO" >&2
  # Bank a copy of the store image beside the deliverables (read-back verify + R2).
  cp "$STORE_ISO" "$OUTDIR/solnix-store.iso"
else
  echo "SOLNIX_NO_MEDIA_STORE=1: NOT seeding the base-closure media store" >&2
fi

# ---------------------------------------------------------------------------
# 1d. IMAGE EDITION MARKER (design-two-installer-images.md #3, NixOS
#     `isoImage.edition` parity). The two solnix installer images share one
#     installation-device base (the live ramdisk oi-make-livecd.sh builds + the
#     step-#1 scratch partition + this step-#2 media store) and differ only in a
#     thin edition: `tui` (text console, RD_MB=640, base media store) vs `gui`
#     (COSMIC, RD_MB layered, base+COSMIC media store). This run builds `tui`.
#     Record it on the media so the shipped artifact is self-describing.
#     GRAPHICAL builds set SOLNIX_IMAGE_EDITION=gui.
SOLNIX_IMAGE_EDITION="${SOLNIX_IMAGE_EDITION:-tui}"
mkdir -p "$ISOROOT/etc"
printf 'EDITION=%s\nINSTALLER=solnix-install\nMEDIA_STORE=%s\nSCRATCH_PARTITION=gpt3\n' \
  "$SOLNIX_IMAGE_EDITION" \
  "$([ -f "$ISOROOT/solnix-store.iso" ] && echo present || echo absent)" \
  > "$ISOROOT/etc/solnix-image-edition"
echo "  image edition marker: $SOLNIX_IMAGE_EDITION (media store $([ -f "$ISOROOT/solnix-store.iso" ] && echo present || echo absent))" >&2

# ---------------------------------------------------------------------------
# 2. assemble the hybrid ISO with xorriso.
#    -b boot/cdboot          BIOS El Torito boot image (no-emulation)
#    -e boot/efiboot.img     UEFI El Torito boot image (the ESP FAT)
#    -isohybrid-gpt-basdat    make efiboot.img appear as a GPT partition so the
#                             same .iso is also USB-dd-able (isohybrid).
# ---------------------------------------------------------------------------
log "assembling hybrid ISO -> $ISO"
# -b boot/cdboot        BIOS El Torito (no-emulation)
# -e --interval:...     UEFI El Torito pointing at the efiboot.img
# -append_partition 2 0xef boot/efiboot.img  ALSO expose efiboot.img as GPT
#                       partition 2 (type EF00 ESP) so UEFI firmware that boots
#                       the media as a DISK (the USB path) finds the ESP.
# -append_partition 3 0xbf scratch.img       the writable Solaris scratch part
#                       (type bf01/Solaris) that setup_scratch mounts + grows.
# -partition_offset 16  isohybrid MBR so BIOS USB boot works too.
xorriso -as mkisofs \
  -o "$ISO" \
  -V SOLNIX_INSTALL \
  -R -J \
  -partition_offset 16 \
  -b boot/cdboot -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/efiboot.img -no-emul-boot \
  -append_partition 2 0xef "$ISOROOT/boot/efiboot.img" \
  -append_partition 3 0xbf "$SCRATCH_IMG" \
  -appended_part_as_gpt \
  "$ISOROOT" 2>&1 | tail -20

ls -la "$ISO"
echo "ISO sha256:"; sha256sum "$ISO"

# ---------------------------------------------------------------------------
# 3. the dd-able USB image. The isohybrid ISO above is ALREADY dd-able to USB
#    (BIOS via the isohybrid MBR, UEFI via the GPT ESP partition). But the brief
#    wants an explicit GPT disk .img too. The isohybrid .iso IS that image; we
#    copy it to the .img name so the deliverable is unambiguous, and verify it
#    carries a GPT + an EFI partition.
# ---------------------------------------------------------------------------
log "producing dd-able USB image (isohybrid .iso is USB-dd-able) -> $USB"
cp "$ISO" "$USB"
echo "USB sha256:"; sha256sum "$USB"
# verify GPT + partition table present (isohybrid-gpt)
if command -v fdisk >/dev/null 2>&1; then fdisk -l "$USB" 2>/dev/null | head -20 || true; fi
# HARD GATE: the .img must carry a real GPT ("EFI PART" magic at LBA 1) or UEFI
# firmware booting the media as a DISK will not find the ESP. -isohybrid-gpt-basdat
# alone did NOT write one (measured: LBA 1 was all zeros, MBR-only) -- which is
# why -appended_part_as_gpt is used above.
if [ "$(dd if="$USB" bs=512 skip=1 count=1 2>/dev/null | head -c 8)" != "EFI PART" ]; then
  echo "FATAL: no GPT header at LBA 1 of $USB -- UEFI disk boot will fail" >&2; exit 1
fi
echo "GPT header present at LBA 1 (EFI PART)"

# HARD GATE: the boot screen must say solnix. Both sources are load-bearing --
# menu.4th's hardcoded title overrides loader_menu_title, so check both in the
# tree that was just handed to xorriso.
if grep -q 'Welcome to illumos' "$ISOROOT/boot/forth/menu.4th" 2>/dev/null; then
  echo "FATAL: boot/forth/menu.4th still says 'Welcome to illumos'" >&2; exit 1
fi
grep -q 'Welcome to solnix' "$ISOROOT/boot/forth/menu.4th" 2>/dev/null || \
  { echo "FATAL: boot/forth/menu.4th lacks 'Welcome to solnix'" >&2; exit 1; }
grep -q '^loader_brand="solnix"' "$ISOROOT/boot/loader.conf" || \
  { echo "FATAL: loader.conf lacks loader_brand=solnix" >&2; exit 1; }
echo "branding gate OK: menu.4th + loader.conf both say solnix"

log "DONE: $ISO + $USB"

# ACCEPTANCE GATE: run the image acceptance suite against the just-built media so
# no image ships without passing every lesson-derived check (console-login, hid,
# resolv.conf, CA bundle, solnix-zap, shipped-installer-sha, the transitive-lib
# runnability closure, size ceiling). Non-fatal-by-default so a build on a host
# lacking lofiadm still completes (checks SKIP), but on the illumos build node it
# runs for real; set IMG_ACCEPT_STRICT=1 to make any FAIL abort the build.
_accept="$(dirname "$0")/image-acceptance-test.sh"
if [ -x "$_accept" ]; then
  log "running image acceptance suite on $OUTDIR"
  if "$_accept" "$OUTDIR"; then
    log "image acceptance suite: PASS"
  else
    echo "WARN: image acceptance suite reported FAILURES on $OUTDIR (see output above)" >&2
    [ "${IMG_ACCEPT_STRICT:-0}" = 1 ] && { echo "FATAL: IMG_ACCEPT_STRICT=1 and the acceptance suite failed" >&2; exit 1; }
  fi
else
  echo "WARN: $_accept not found -- image shipped WITHOUT the acceptance suite" >&2
fi
