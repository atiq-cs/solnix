# NixOS minimal ISO ↔ solnix installer media: tool parity (MEASURED)

This doc supersedes the package lists in `docs/design-minimal-iso-parity.md` (2026-08,
written from nixos-25.05 by reading the source, not by evaluating it). Some of its
claims did not hold when measured. See "Corrections" at the end.

## How this was measured

**NixOS** (nixpkgs 26.05 source, `/nix/store/0pci4p12dvimf6d7p4674ykvcjwsaq6a-source`,
`system.nixos.version = 26.11pre1074753.b1b875982b17`). I evaluated the real minimal-ISO module on floki:

```
nix eval --impure --json --expr 'let s = import <src>/nixos/lib/eval-config.nix {
  system = "x86_64-linux"; modules = [ <src>/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix ]; };
  in map (p: p.name) s.config.environment.systemPackages'
```

This gives 161 entries and 110 unique packages. The system path is
`/nix/store/bn1s1xfx34mjpi7dz7y7zjhlsi1w5p7b-system-path`, which is not in
cache.nixos.org. So I listed the `bin/` and `sbin/` of every installed output
(`meta.outputsToInstall`) with `nix store ls --store https://cache.nixos.org`, or
from the local store. That gives 1,503 rows and **1,060 distinct program names**.
The only outputs not listed are the doc-only `nixos-help`/`nixos-manual-html` (not
cached) and `glibc-locales`, `nix-bash-completions` and the configuration-reference
manpage (no `bin/`). Raw data, copied out of the repo:
`/tmp/streamI1.WIP/{nixos-iso-systemPackages.json,nixos-iso-state.json,bins2.txt,nixos-iso-programs.txt}`.

Where the packages come from (file:line in that source):

| Source | What it adds |
|---|---|
| `nixos/modules/profiles/base.nix:14-51` | w3m-nographics testdisk ms-sys efibootmgr efivar parted gptfdisk ddrescue ccrypt cryptsetup vim fuse fuse3 sshfs-fuse socat screen tcpdump sdparm hdparm smartmontools pciutils usbutils nvme-cli unzip zip jq |
| `profiles/base.nix:54-69` | `boot.supportedFilesystems`: ext2/3/4 btrfs cifs f2fs ntfs vfat xfs zfs, which pull in e2fsprogs btrfs-progs cifs-utils f2fs-tools ntfs3g dosfstools mtools xfsprogs zfs-user |
| `installer/cd-dvd/installation-cd-base.nix:50-54` | `defaultPackages = [ rsync ]`, `programs.git.enable` |
| `profiles/installation-device.nix:52-116` | sudo, polkit, openssh, networkmanager + wpa_supplicant + modemmanager, mdadm (`boot.swraid.enable`) |
| `config/system-path.nix` requiredPackages | acl attr bash-interactive bzip2 coreutils-full cpio curl diffutils findutils gawk getent getconf gnugrep gnupatch gnused gnutar gzip xz less libcap ncurses libressl mkpasswd procps shadow time util-linux which zstd glibc |
| `installer/tools/tools.nix` | nixos-install nixos-generate-config nixos-enter nixos-rebuild(-ng) nixos-option nixos-version nixos-build-vms |
| everything else | systemd kmod kexec-tools dbus iptables nixos-firewall-tool lvm2 bcache-tools linux-pam iproute2 iputils bind(dnsutils, host) hostname openresolv kbd man-db nano nix nix-info grub syslinux |

The packages contributing the most program names: util-linux (262), systemd (144),
coreutils-full (108), iptables (90), shadow (60), xfsprogs (50), e2fsprogs (50),
lvm2 (49), glibc (42), procps (36), mtools (33), kbd (33), bind (30), grub (28).
Most of these are Linux-kernel interfaces (systemd, iptables, kmod, lvm2) or
filesystems illumos does not have (xfs, ext4, btrfs, f2fs).

**solnix.** I listed the installer toplevel's `sw/bin`, `sw/sbin` and the world's
`/usr/bin`, `/usr/sbin` and `/sbin` from the store. The world
`/nix/store/73687v4yabr70dckk36ljliq67788558-illumos-userland` is the one in
`usb-image-20261009a-x1`: 516 usr/bin, 364 usr/sbin, 55 sbin, and **no /usr/gnu**.
The toplevel at HEAD 19231fe0 evaluates to
`wmjgnrxfdwkxk08412rsrqpa03zw1hsa-solnix-system-solnix-installer`. dixi carries an
older build, `rfj7169b...`, whose sw/bin has 553 names. I evaluated HEAD's
`environment.systemPackages` directly to get the current list.
Raw data: `/tmp/streamI1.WIP/solnix-media-programs.txt`.

## State of the live system (installer vs user)

| | NixOS minimal ISO (measured) | solnix media | Reason for any difference |
|---|---|---|---|
| root password | empty (`installation-device.nix:49`) | empty (`make-installer-image.sh` 5b) | same |
| unprivileged user | `nixos`, empty password, wheel, passwordless sudo (`:37-58`) | none: you log in as root | NOTE: no `nixos` user. illumos RBAC `pfexec` would be the analog of passwordless sudo. Left as a decision for the maintainer (adding the user changes the login flow every install test drives). |
| console autologin | `services.getty.autologinUser = "nixos"` (`:61`) | login prompt, root, no password | illumos ttymon has no autologin flag. An `-a` equivalent needs a console-login method override. Not changed. |
| help text | `services.getty.helpLine` (`:64-72`): empty passwords, how to ssh, `nmtui` | `solnix-motd` banner, which now points at **/root/README** | same purpose; README is new |
| sshd | enabled, `PermitRootLogin yes` (`:84-87`) | enabled (svc:/network/sshd), `PermitRootLogin yes` (installer.nix) | same. NixOS's empty password cannot be used over ssh either. `solnix-install --ssh` sets a password or key. |
| networking | NetworkManager + wpa_supplicant, `useDHCP=false`, dhcpcd on (eval) | solnix-autonet: first wired NIC by DHCP at boot, in the background | no NetworkManager on illumos. Wifi: `dladm connect-wifi`, but no Intel wifi driver attaches yet. |
| firewall | on, logRefusedConnections off (`:123`) | on (`solnix.firewall`: TCP 22, lo0 trusted; eval) | same |
| trusted-users | root, nixos (`:134`) | root | no `nixos` user |
| hostId | `8425e349` (`base.nix:72`) | none on the media; solnix-install writes `/etc/hostid` on the target | |
| channel / nixpkgs copy | `channel.nix`: nixpkgs on the media | a pinned flake (substituted or built) | solnix installs flakes. NOTE: `solnix-channel-init` exists for the channel form. |
| config skeleton | `nixos-generate-config` | **`solnix-generate-config`** (new) | see docs/installer-contract.md |
| manual | `nixos-help` (w3m) | `/root/README` + `--help` | the world has **no man pages** (`man ls` → "No manual entry", measured) |
| low-memory tweaks | `GC_INITIAL_HEAP_SIZE=1M`, overcommit (`:95-102`) | ARC capped at 512 MB; nix `min-free=0` (installer.nix) | illumos has no overcommit sysctl |

## Tool table: NixOS install-time tool → solnix

Legend: **PRESENT** = the same tool on the media. **EQUIV** = the illumos tool, with
the command. **WRAP** = a Linux-named solnix wrapper over the illumos tool (new).
**ADDED** = newly packaged from source (built outside nix on dixi, see below).
**MISSING** = not on the media. **N/A** = only meaningful on Linux.

### Disks, partitions, wiping

| NixOS program | nixpkgs pkg | use at install | solnix | how |
|---|---|---|---|---|
| lsblk | util-linux | list disks | **WRAP** `lsblk` | diskinfo -Hp + prtvtoc -h + fstyp + zpool status (tested on dixi: disk, 3 slices, fstype, `pool=rpool`) |
| blkid | util-linux | fs type of a partition | EQUIV | `fstyp /dev/rdsk/<d>s<n>` |
| fdisk, sfdisk, cfdisk | util-linux | MBR/GPT edit | EQUIV | `fdisk /dev/rdsk/<d>p0` (MBR), `format -e` (EFI) |
| parted | parted | the manual's partitioner | EQUIV | `format -e`. solnix-install partitions for you. |
| sgdisk, gdisk | gptfdisk | GPT edit | EQUIV | `format -e`, or `zpool create` (whole-disk EFI label) |
| partx, partprobe | util-linux, parted | re-read the table | EQUIV | `devfsadm` |
| sfdisk -d | util-linux | dump/restore a table | EQUIV | `prtvtoc` / `fmthard -s` |
| wipefs | util-linux | wipe signatures | EQUIV | `solnix-zap <disk>` (pool labels + front/back GPT), `zpool labelclear -f` |
| blkdiscard | util-linux | TRIM a device | EQUIV | `zpool trim <pool>`. For a whole NVMe: `nvmeadm format <ctl>/<ns>`. |
| shred | coreutils | overwrite | **ADDED** (GNU name) | GNU `shred` from coreutils-9.7, already in the closure. On a whole SSD: `nvmeadm secure-erase`. |
| wipe | (not in NixOS) | | EQUIV | `nvmeadm secure-erase`, `dd if=/dev/zero` |
| dd | coreutils | raw copy | PRESENT | illumos dd (no `status=progress`, measured) |
| ddrescue | ddrescue | recover a failing disk | MISSING | GPL-3, separate program, licence-fine. Upstream ships only `.tar.lz`, and there is no lzip in the world: needs an lzip derivation first. |
| testdisk | testdisk | partition/boot repair | MISSING | portable but needs ncurses + libuuid/ext2fs shims. Not attempted. |
| ms-sys | ms-sys | write Windows MBRs | N/A | |
| hdparm | hdparm | ATA identify/params | EQUIV | `iostat -En` (model, serial, size, errors), `diskinfo -c` |
| sdparm | sdparm | SCSI mode pages | EQUIV | `iostat -En`; mode pages: `format` → `inquiry` |
| smartctl | smartmontools | SMART health | **ADDED** | smartmontools 7.4. os_solaris speaks ATA/SCSI only: on the X1's NVMe it says "Unable to detect device type" (measured). Use `nvmeadm`. |
| nvme | nvme-cli | NVMe admin | EQUIV | `nvmeadm list`, `get-logpage <ctl> health`, `format`, `secure-erase` (measured help) |
| mdadm, lvm, bcache | mdadm, lvm2, bcache-tools | RAID / volumes | EQUIV | ZFS vdevs (`zpool create p mirror d1 d2`), zvols |
| cryptsetup | cryptsetup | LUKS | EQUIV | `zfs create -o encryption=on` |
| ccrypt | ccrypt | file crypto | EQUIV | `openssl enc` |

### Filesystems

| NixOS | pkg | solnix | how |
|---|---|---|---|
| mkfs.fat / mkfs.vfat | dosfstools | EQUIV | `mkfs -F pcfs -o fat=32 /dev/rdsk/<d>s0` (what solnix-install runs) |
| mkfs.ext4, mkfs.xfs, mkfs.btrfs, mkfs.f2fs, ntfs-3g | e2fsprogs, xfsprogs, btrfs-progs, f2fs-tools, ntfs3g | N/A | Linux filesystems. Native: ZFS root, UFS `newfs`, pcfs, hsfs. |
| mkswap / swapon | util-linux | EQUIV | `zfs create -V`; `swap -a /dev/zvol/dsk/...` |
| mount / umount / losetup | util-linux | PRESENT / EQUIV | `mount -F <fs>`; `lofiadm` for loop devices |
| zpool / zfs | zfs-user 2.4.4 | PRESENT | the illumos (gate) zfs |
| mount.cifs | cifs-utils | EQUIV | `mount -F smbfs` |
| sshfs, fusermount | sshfs-fuse, fuse | MISSING | illumos has no FUSE in the base |

### Network and wifi

| NixOS | pkg | solnix | how |
|---|---|---|---|
| ip (a, link, route) | iproute2 | **WRAP** `ip` (read-only: a, link, route, neigh) | ipadm show-addr, dladm show-phys/show-link, netstat -rn, arp -an (tested on dixi) |
| nmtui, nmcli | networkmanager | EQUIV | `solnix-install --net` (DHCP), `ipadm create-addr -T dhcp` |
| wpa_cli, wpa_supplicant | wpa_supplicant | EQUIV in principle | `dladm scan-wifi`/`connect-wifi` (measured in `dladm help`). No Intel wifi driver attaches yet (X1 = 8086:a370, iwm). |
| ping | iputils | PRESENT | |
| traceroute | (not in NixOS minimal) | PRESENT | |
| dig, host, nslookup | bind | MISSING | `getent hosts <name>`. BIND/ldns not packaged. |
| tcpdump | tcpdump | EQUIV | `snoop -d <nic>` |
| curl | curl | PRESENT | curl 8.10.1 |
| wget | (not in NixOS minimal) | n/a | curl |
| ssh, scp, sftp | openssh | PRESENT | openssh 10.2p1 |
| rsync | rsync | **ADDED** | rsync 3.4.1 (bundled popt and zlib, no openssl/xxhash/zstd/lz4) |
| socat | socat | MISSING | `nc` is present. socat is buildable (GPL-2) if wanted. |
| iptables | iptables | N/A | ipf (`solnix.firewall`) |

### Hardware info

| NixOS | pkg | solnix | how |
|---|---|---|---|
| lspci | pciutils | **WRAP** `lspci` (`-n` adds ids) | `/usr/lib/pci/pcieadm show-devs` (off PATH, measured), `prtconf -D` |
| lsusb | usbutils | **WRAP** `lsusb` (`-t` tree) | `cfgadm -l -s select=type(usb-device)`, `prtconf -D` |
| lscpu | util-linux | EQUIV | `psrinfo -vp` |
| free | procps | EQUIV | `prtconf \| grep Memory`, `vmstat`, `kstat` |
| dmesg | util-linux | PRESENT | |
| dmidecode | (not in NixOS minimal) | EQUIV | `smbios` |
| lsmod, modprobe | kmod | EQUIV | `modinfo`, `modload`, `add_drv` |
| efibootmgr, efivar | efibootmgr, efivar | MISSING | illumos loader on the ESP as `EFI/Boot/bootx64.efi` (the removable path), so no NVRAM entry is needed. No EFI variable editor in the world. |
| grub-install, syslinux | grub, syslinux | EQUIV | `installboot`, `bootadm`, `beadm` |
| loadkeys, setfont | kbd | PRESENT / EQUIV | `loadkeys` present, `kbd -s`; console font from `/boot/fonts` |

### Editors, shell, files

| NixOS | pkg | solnix | how |
|---|---|---|---|
| vim | vim | EQUIV | `vi` (illumos vi). vim not packaged. |
| nano | nano | **ADDED** | nano 8.4 (against the from-source ncurses) |
| less | less | PRESENT | less 679 |
| screen | screen | EQUIV | **tmux** 3.5a, now on PATH (it was built but not shipped) |
| htop / top | (not in NixOS minimal) / procps | PRESENT | htop, top (= htop), prstat |
| strace | (not in NixOS minimal) | EQUIV | `truss` |
| jq | jq | **ADDED** to PATH | jq 1.7.1, already in the closure (home-manager) |
| gzip, gunzip, zcat | gzip | **ADDED** | gzip 1.13. The world had **no gzip at all**, yet solnix-install calls `gzip -t` on a gzip boot_archive. |
| xz, unxz | xz | **ADDED** to PATH | xz 5.6.3, already in the closure (nix's dependency) |
| zstd, bzip2 | zstd, bzip2 | MISSING on PATH | the store copies on dixi have no `bin/` (library-only builds) |
| unzip, zip | unzip, zip | MISSING | buildable (Info-ZIP licence), not attempted |
| tar, cpio | gnutar, cpio | PRESENT | illumos tar/cpio |
| stat, readlink, realpath, timeout, sha256sum, … | coreutils-full | **ADDED** (18 names) | GNU coreutils-9.7, only names absent from the world (measured: 35 absent, 73 collide). ls/cp/dd/df stay illumos. |
| git | git | PRESENT | git 2.54.0 |
| sudo | sudo | PRESENT | solnix-sudo; root needs none |
| w3m | w3m-nographics | MISSING | only for the HTML manual, which is not on the media |

### Nix

| NixOS | solnix |
|---|---|
| nix, nix-build, nix-env, nix-store, nix-shell | PRESENT (nix 2.24.15) |
| nixos-install | `solnix-install` |
| nixos-generate-config | **`solnix-generate-config`** (new) |
| nixos-rebuild | `solnix-rebuild` (+ `nixos-rebuild` alias) |
| nixos-version | `solnix-version` |
| nixos-enter | MISSING. There is no chroot+bind analog. `chroot /a /usr/bin/bash` works for passwd on the target. |
| nixos-option | MISSING (`nix eval`) |
| home-manager | PRESENT |

## What was added, and what it costs

All the additions are on the installer only, in `configurations/installer.nix`.

| Addition | Kind | New closure bytes |
|---|---|---|
| lsblk, lspci, lsusb, ip | wrapper scripts (`scripts/live/compat/`) | ~6 KB |
| solnix-generate-config | script | ~7 KB |
| 18 GNU coreutils names | links into coreutils-9.7 (already in the closure) | 0 |
| jq, xz | already in the closure | 0 |
| tmux + libevent | from source (already built) | 2,666,624 (`nix-store -q --size`) |
| gzip, nano, rsync, smartmontools | from source, `pkgs/illumos/base-src.nix` | 3,838,844 (file bytes of the replayed outputs; NAR within a few %) |
| /root/README | text | ~9 KB |

That totals about **6.5 MB**. The headroom against `RD_MAX_RAW` 734,003,200 B was
~73 MB (20261009a needed 660,813,227 B), so ×1.12 UFS overhead leaves ~66 MB. The
orchestrator's `make-installer-image.sh` closure gate is the check that counts.

### Build evidence (REAL vs PLANNED)

- dixi cannot run `nix build` on any mkSrcPkg recipe. The builder's PATH is
  `/usr/gnu/bin:/usr/bin:/usr/sbin`, dixi has no /usr/gnu, and `sha256sum` is
  missing (measured: `bash: line 5: sha256sum: command not found`). The strip step
  calls `/usr/bin/gstrip ... || true`, which silently does nothing there, and the
  build-time-path gate then fails. The fix is pending:
  `docs/pending/builders-need-store-tools.md`.
- **REAL (outside nix):** each recipe's own builder script, taken from
  `nix derivation show`, ran on dixi with the PATH and gstrip rewritten to store
  GNU tools and `$out` in `/var/tmp/streamI1/out-<p>`. Harness:
  `/tmp/streamI1.WIP/replay.sh`. All four exit 0, including mk-src-pkg's own ldd
  closure gate ("every ELF resolves inside /nix/store"):
  `gzip 1.13`, `GNU nano, version 8.4`, `rsync version 3.4.1 protocol version 32`,
  `smartctl 7.4 2023-08-01 r5530 [x86_64-pc-solaris2.11]`.
- The first smartmontools run built, but smartctl would not load:
  `ld.so.1: smartctl: fatal: libssp.so.0: open failed`. configure adds
  `-fstack-protector-strong`, and gcc.lib does not ship libssp. Fixed in the recipe
  with `CXXFLAGS=-fno-stack-protector`, and proven by the second replay.
- **PLANNED:** the real `nix build` on bhost:
  `.#packages.x86_64-solaris.{gzip,nano,rsync,smartmontools}` and the installer
  toplevel.

## Corrections to docs/design-minimal-iso-parity.md

- "`scanpci`" for lspci: not in the world. `pcieadm` is, but in `/usr/lib/pci`, off PATH.
- "unzip ✅ 6.0", "bzip2 ✅ / gzip ✅ / xz ✅", "less ✅ 704", "vim ✅ 9.2",
  "curl ✅ 8.21.0", "coreutils ✅ 9.11": not on the installer media as of 20261009a.
  gzip, unzip and vim were absent everywhere. xz and coreutils were in the closure
  but not on PATH. Versions differ (curl 8.10.1, less 679).
- "`gpart`": not an illumos tool.
- "illumos `man`/mandoc for the manual": `man` is present but the world ships no
  manual pages (`man ls` → "No manual entry for ls", measured on dixi).
