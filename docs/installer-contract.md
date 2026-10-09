# The installer contract: what the media does, what the user does

NixOS's minimal ISO splits an install between the media, `nixos-install`, and the
user, who follows the manual (`nixos/doc/manual/installation/installing.chapter.md`
in nixpkgs `/nix/store/0pci4p12dvimf6d7p4674ykvcjwsaq6a-source`). The table below
takes each step in the manual's order. For each one it gives who does it on NixOS,
who does it on solnix, and the reason wherever the two differ. The tool-by-tool
mapping is in `docs/nixos-iso-tool-parity.md`.

The rule (AGENTS.md): use NixOS's answer, except where illumos cannot do the same
thing, and write down why.

| # | Step | NixOS: who / how | solnix: who / how | Why it differs |
|---|---|---|---|---|
| 0 | Boot, log in | media: autologin as `nixos` (`profiles/installation-device.nix:61`); root and nixos have empty passwords (`:46,:49`) | media: login prompt, `root` with an empty password (`make-installer-image.sh` 5b, `/etc/default/login` PASSREQ=NO) | illumos ttymon has no autologin flag, and the media has no unprivileged user. Root needs no sudo step (manual:137). |
| 1 | Become root | user: `sudo -i` (manual:137) | already root | same as above |
| 2 | Read the help | media: getty helpLine (`:64-72`); user: `nixos-help` | media: `solnix-motd` at login points at **/root/README** (welcome, steps, tools) | no HTML manual on the media; the world ships no man pages |
| 3 | Keyboard layout | user: `loadkeys` (manual:140) | user: `loadkeys` / `kbd -s` | same |
| 4 | Network up | media: NetworkManager + dhcpcd at boot; user: `nmtui` for wifi (manual:150-162) | media: `solnix-autonet` (first wired NIC, DHCP) at boot; user: `solnix-install --net`, or `ipadm` | no NetworkManager. Wifi needs a wifi driver that attaches, and Intel AX2xx/AC9560 do not yet. |
| 5 | Remote install | media: sshd on, PermitRootLogin yes (`:84-87`); user: `passwd` or an authorized_keys file (manual:164-171) | media: sshd on, PermitRootLogin yes (installer.nix); user: `solnix-install --ssh`, which sets a random printed password or `SOLNIX_SSH_PUBKEY` | same contract. `--ssh` sets the credential for you, because `passwd` on the live ramdisk works but is easy to forget. |
| 6 | Partition | user: `parted` (manual:173-283) | **installer**: `solnix-install` writes the GPT (ESP s0, ZFS s1, reserved s8). The user picks the disk (`--disk`; it auto-detects otherwise, never the boot medium). | The solnix layout is fixed: a ZFS root pool with boot environments, `<pool>/nix` and `<pool>/home` outside the BE. A free-form layout would break `beadm` and the loader. Same reason NixOS-on-ZFS guides script this step. |
| 7 | Format | user: `mkfs.ext4`, `mkswap`, `mkfs.fat` (manual:285-319) | **installer**: `mkfs -F pcfs` on the ESP, `zpool create`, the datasets | as above. Swap is a zvol if wanted, after install. |
| 8 | Mount the target | user: `mount ... /mnt`, `/mnt/boot` (manual:321-348) | **installer**: BE mounted at `/a`, ESP at `/a/esp` | as above |
| 9 | Generate a config | user: `nixos-generate-config --root /mnt` writes `configuration.nix` + `hardware-configuration.nix` (+ `flake.nix` with `--flake`) (manual:350-367) | user: **`solnix-generate-config --dir /var/tmp/cfg --host NAME`** writes `flake.nix` + `configuration.nix` + `hardware-configuration.nix` (wired NICs → `networking.interfaces.<n>.dhcp`; Intel wifi noted by PCI id) | Generated before install, not after mounting: solnix-install does the mounting and building in one run, so the config has to exist first. Not in hardware-configuration.nix: fileSystems (fixed layout), initrd modules (illumos copies `/etc/path_to_inst`, and the media carries the whole driver DB), boot.loader (one loader), hostId (installer writes `/etc/hostid`). |
| 10 | Edit the config | user: `nano /mnt/etc/nixos/configuration.nix` (manual:370-430) | user: `nano /var/tmp/cfg/configuration.nix` (nano is now on the media) | same |
| 11 | Install | user runs `nixos-install [--flake ...]`: builds the toplevel into `/mnt/nix/store`, sets the system profile, installs the bootloader through `switch-to-configuration boot`, copies the channel (nixos-install.sh:249-322) | user runs `solnix-install --flake '/var/tmp/cfg#NAME'` (or `github:...`, or no flake for the base system). It does steps 6-8, seeds the target store from the media, builds the toplevel there, sets profile generation 1, runs the toplevel's own `switch-to-configuration install-be`, installs the loader (ESP + BIOS stage2) and sets bootfs. | one command for 6-8 + 11, for the layout reason in 6 |
| 12 | Config lands on the target | user wrote it into `/mnt/etc/nixos` | **installer**: a local `--flake` directory is copied to `/etc/nixos` on the target (new), so `solnix-rebuild switch` finds `/etc/nixos/flake.nix` with no arguments, as nixos-rebuild does. A remote ref is not copied: the remote is the source of truth. | NixOS gets this for free because the user edits the config in place |
| 13 | Root password | installer: `nixos-install` prompts (nixos-install.sh:328-340); `--no-root-passwd` skips | installer: solnix-install prompts. It can also lock root (`*LK*`, never blank), and takes `SOLNIX_ROOT_PW` unattended. | same, plus a lock choice |
| 14 | User account password | user: `nixos-enter --root /mnt -c 'passwd alice'` (manual:472-476) | installer: offers to create an admin user (staff + sysadmin + Primary Administrator, home on `<pool>/home`) and sets its password. Config-declared users keep the hash the installer set (install-be's mutableUsers merge). | no `nixos-enter`; prompting is the friendlier form of the same step |
| 15 | home-manager | not part of nixos-install | installer: optional (`--home`), builds the activation package for first boot | solnix addition |
| 16 | Reboot | user: `reboot` (manual:487) | installer offers reboot or power off; user: `init 6`, remove the media | same |
| 17 | First boot | GRUB menu, one generation (manual:491-497) | illumos loader menu, generation 1 = BE `solnix-1` | same model: each generation is a menu entry (a BE) |

## Accepted deviations (maintainer decisions)

- **Log in as root with no password; no `nixos` user, no console autologin.**
  NixOS's media autologins as an unprivileged `nixos` user with passwordless sudo
  (profiles/installation-device.nix:46-61). The solnix media shows a login prompt;
  the user logs in as `root` with an empty password and runs the install from
  there. Decided by the maintainer (2026-10-09): no `nixos` user is required.
  The empty password is media-only: solnix-install sets or locks root on the
  target, and the installed system's root has no declared password
  (modules/config/users.nix), so a switch keeps whatever the installer set.

## Departures from NixOS that have no illumos reason (open)

These are recorded here rather than silently kept.

- **No `nixos-enter` analog.** `chroot /a /usr/bin/bash` covers `passwd`, but there
  are no `/dev`, `/proc` or `/run` bind mounts the way nixos-enter sets them up.
  Low priority: step 14 is done by the installer.
- **`efibootmgr`.** No NVRAM boot entry is written; the loader sits at the removable
  path `EFI/Boot/bootx64.efi`. This works everywhere it has been tried. NixOS's
  systemd-boot writes an entry (`canTouchEfiVariables`). An illumos efibootmgr
  equivalent would be new work.
- **Channel on the media.** NixOS copies nixpkgs onto the media so nixos-install
  works offline (`channel.nix`). solnix installs flakes and seeds the target store
  from the media's own closure, so the base system installs offline. A flake whose
  pin differs needs the network.

## Where each piece lives

| Piece | File |
|---|---|
| media system (the analog of installation-device.nix) | `configurations/installer.nix` |
| image builder (iso-image.nix analog), /root/README copy | `scripts/make-installer-image.sh` |
| login banner (helpLine analog) | `scripts/live/solnix-motd` |
| /root/README | `scripts/live/README` |
| Linux-named wrappers | `scripts/live/compat/{lsblk,lspci,lsusb,ip}` |
| nixos-generate-config analog | `scripts/solnix-generate-config` |
| nixos-install analog | `scripts/solnix-install` |
| image checks for all of the above | `scripts/image-acceptance-test.sh` (`install_tools_check`) |
