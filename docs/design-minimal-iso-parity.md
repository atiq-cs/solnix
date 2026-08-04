# solnix minimal ISO ↔ NixOS minimal ISO parity

**Directive (maintainer, 2026-08-04):** the solnix minimal ISO must match the
NixOS minimal ISO's level of default functionality, mapping Linux-specific tools
to illumos equivalents where required.

**Authoritative NixOS source (nixos-25.05):** the minimal-ISO package set =
`config/system-path.nix` `requiredPackages` + `defaultPackages` +
`profiles/base.nix` `environment.systemPackages` (installation-cd-minimal pulls
`installation-cd-base` → `installation-device` → `base`; `minimal.nix` only
STRIPS docs/fonts/etc., adds nothing).

Legend: ✅ built (real solnix derivation) · ⏳ portable, not yet built · 🔁 map to
illumos-native · ⛔ N/A on illumos (Linux-kernel-specific).

## 1. requiredPackages (base userland — every NixOS system)

| NixOS pkg | solnix | note |
|---|---|---|
| coreutils-full | ✅ coreutils 9.11 | |
| bashInteractive | ⏳ **build** (have bash via seed; need bash-interactive w/ readline as a pkg) | on the build-host baseline too |
| acl / attr | 🔁 native | illumos ACLs via `ls -v`/`chmod` NFSv4 ACLs + extended attrs (`runat`, `fsattr`); no separate acl/attr pkgs |
| bzip2 ✅ / gzip ✅ / xz ✅ | ✅ | |
| cpio | ✅ 2.15 | (illumos also has native cpio) |
| curl | ✅ 8.21.0 | |
| diffutils ✅ / findutils ✅ / gawk ✅ / gnugrep ✅ / gnused ✅ / gnutar ✅ | ✅ | |
| gnupatch | ✅ patch 2.8 | |
| getent / getconf | 🔁 native | illumos ships `getent(1)`, `getconf(1)` in the base OS |
| less | ✅ 704 | |
| libcap | ⛔ | Linux capabilities; illumos uses **RBAC/privileges** (`ppriv`, `priv(5)`) — native |
| ncurses | ✅ 6.6 | |
| netcat | ⏳ **build** (netcat-openbsd) | portable |
| mkpasswd | ⏳ build (whois/mkpasswd) OR 🔁 native `passwd`/crypt | |
| procps (ps/top/free/...) | 🔁 native | illumos `ps`, `prstat`, `top`(pkg), `vmstat`, `kstat` — native + richer |
| su | 🔁 native | illumos `su(1)` in base OS |
| time | ⏳ build (gnu time) OR 🔁 native `/usr/bin/time`, `timex` | |
| util-linux | 🔁 native | the illumos base OS IS the "util-linux equivalent": `mount`, `fdisk`, `swap`, `dmesg`, `col`, `hexdump`(→`od`), `lsblk`(→`format`/`diskinfo`), `blkid`(→`fstyp`), `nsenter`(→zones) |
| stdenv cc+libc | ✅ pure x86_64-solaris stdenv (seed) | + build-host baseline (docs/design-minimal-build-host.md) |

## 2. defaultPackages

| NixOS | solnix | note |
|---|---|---|
| perl | ✅ 5.42.0 | |
| rsync | ⏳ **build** | portable, high-value |
| strace | 🔁 **truss** (native) | illumos `truss(1)` = strace equivalent, in base OS |

## 3. profiles/base.nix (disk / fs / net / recovery tools)

| NixOS pkg | purpose | solnix |
|---|---|---|
| vim | editor | ✅ 9.2 |
| parted / gptfdisk | partitioning | 🔁 native `format(1M)`, `fdisk`, `gpart`; GPT via `format -e`; ZFS whole-disk `zpool create` |
| efibootmgr / efivar | EFI boot vars | 🔁 native `bootadm`, `beadm`; illumos loader (not GRUB/efibootmgr) |
| ms-sys | MS boot sectors | ⛔ N/A |
| ddrescue | disk recovery | ⏳ build (gddrescue) — portable |
| testdisk | partition repair | ⏳ build — portable (may need patches) |
| ccrypt | file crypto | ⏳ build OR 🔁 use `openssl enc` (✅ openssl) |
| cryptsetup (dm-crypt) | disk encryption | 🔁 **ZFS native encryption** (`zfs create -o encryption=on`) — the illumos idiom; no dm-crypt |
| fuse / fuse3 / sshfs-fuse | userspace fs | 🔁 illumos has no FUSE in-base; sshfs via `sshfs` pkg if libfuse ports (⏳/⛔ — defer) |
| socat | socket relay | ⏳ **build** — portable |
| screen | terminal mux | ⏳ **build** (or tmux) — portable |
| tcpdump | packet capture | 🔁 native **`snoop(1M)`** = tcpdump equivalent; tcpdump also ⏳ buildable |
| sdparm / hdparm | SCSI/ATA params | 🔁 native `format`, `cfgadm`, `iostat -E`; hdparm→ N/A (use `format`) |
| smartmontools | SMART diag | ⏳ build — portable (smartctl works on illumos) |
| pciutils (lspci) | PCI enum | 🔁 native **`prtconf -v`**, `scanpci`, `pcieadm` |
| usbutils (lsusb) | USB enum | 🔁 native `cfgadm -al`, `prtconf` |
| nvme-cli | NVMe admin | 🔁 native **`nvmeadm(1M)`** |
| unzip ✅ / zip | archive | unzip ✅ 6.0; zip ⏳ build |
| w3m-nographics | text browser (manual) | ⏳ build OR 🔁 `man`/`col` for the manual (✅ mandoc); w3m portable |
| boot.supportedFilesystems (btrfs/xfs/f2fs/ntfs/cifs/vfat/zfs) | fs support | 🔁 **ZFS is the native root**; illumos supports UFS/pcfs(vfat)/hsfs(iso)/smbfs(cifs); btrfs/xfs/f2fs/ntfs ⛔ (Linux fs) |

## 4. Net-new solnix packages to BUILD for parity (portable, high-value)
`bashInteractive`, `rsync`, `netcat`, `socat`, `screen` (or tmux), `zip`,
`smartmontools`, `ddrescue`, `w3m`, `time`, `mkpasswd`. (+ testdisk, ccrypt best-effort.)

## 5. illumos-native tools that ALREADY satisfy NixOS-minimal functions (no pkg needed)
`truss`(strace), `snoop`(tcpdump), `prtconf`/`pcieadm`(lspci), `cfgadm`(lsusb),
`nvmeadm`(nvme-cli), `format`/`fdisk`/`zpool`(parted/gptfdisk), ZFS-encryption
(cryptsetup), `ppriv`(libcap), `ps`/`prstat`/`vmstat`/`kstat`(procps),
`getent`/`getconf`/`su`/`mount`/`swap`/`dmesg`(util-linux), `bootadm`/`beadm`(efibootmgr).
These are in the illumos base OS shipped in every solnix image — so the *functional*
parity is largely already there; the gap is the portable net-new list in §4.

## 6. Plan
1. Add the illumos-native equivalents to the minimal profile's PATH/docs (they're in
   the base OS — ensure they're exposed + documented as the mapped tool).
2. Build the §4 net-new portable packages as real hermetic derivations.
3. Fold both into `configurations/base.nix` `environment.systemPackages` (the minimal
   profile) alongside the build-host baseline (docs/design-minimal-build-host.md).
4. Applies to AMI + ISO + IMG, x86_64 first, then per-arch as each reaches parity.

## Default editor (update): vi = nvi (github.com/lichray/nvi2)
solnix's default `vi` is **nvi** (lichray/nvi2 — modernized Berkeley nvi: small, C++,
wide-char, NO vim dependency), packaged as `nvi`. `/usr/bin/{vi,ex,view}` link to `nvi`
(NOT vim — that avoids the dangling vi->vim symlink class + keeps the base small). vim
remains available as a separately-installable package (`vim`) but is not the default vi.
Wired: pkgs/illumos/nvi2.nix, base.nix systemPackages, oi-make-livecd.sh vi/ex/view links.
