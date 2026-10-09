# Installing solnix on the X1 Carbon from the USB stick

This is the procedure for the maintainer's Lenovo X1 Carbon ("dixi"). The media is
generic: it carries no personal users, keys or flakes. The machine's identity comes
from the nix-config flake you name at install time.

Status (2026-10-09): the X1 was installed from usb-image-20261008a and runs
generation 3 (BE solnix-3) built from github nix-config. The current media is
`artifacts/install-media/usb-image-20261009b-x1` (sha256 7a6f6bb0..., README there
has the measurements): under KVM it installs `examples/minimal-flake#example` end
to end and the installed disk boots clean (svcs -x empty, DHCP, DNS, nix-env -iA
solnix.htop). Log in on the media as root with no password (an accepted deviation
from NixOS: no `nixos` user, docs/installer-contract.md); /root/README lists the
install tools (lsblk, lspci, nvmeadm, smartctl, nano, rsync, ...).

## 0. Before you start: nix-config

nix-config's `solnixConfigurations.dixi` (nixos/solnix/dixi.nix via mkSolnixHost
on `solnix.lib.mkPkgs`) is what the installer builds. It is in nix-config main
(3b840e5 and later): base.nix, `profiles = [ "Primary Administrator" ]`, git, curl
and home-manager from `pkgs.solnix`, the NIC `e1000g0`, DNS from the LAN's DHCP.
Keep its `solnix` input current with `nix flake update solnix`: the installer
runs the TARGET generation's own install-be (as nixos-install does), so fixes to
install-be reach the install only through that lock.

## 1. Write the stick (on the Linux box)

```sh
IMG=artifacts/install-media/<dir>/solnix-x86_64-usb.img
sha256sum "$IMG"                      # compare with SHA256SUMS next to it
lsblk -o NAME,SIZE,MODEL,TRAN         # find the stick: TRAN=usb, the size you expect
sudo dd if="$IMG" of=/dev/sdX bs=4M conv=fsync status=progress   # sdX = the WHOLE stick, not sdX1
sync
```

`dd` overwrites the whole device. Check the name twice.

## 2. Boot it

1. Plug in the stick and the wired network. The working wired path on this X1 has
   been an ASIX AX88772 USB dongle, which appeared as `e1000g0`. `dladm
   show-phys` on the media shows the name your adapter gets.
2. Power on, press **F12** for the boot menu, and pick the USB stick (UEFI). Secure
   Boot must be off (F1 -> Security -> Secure Boot).
3. The loader menu boots by default after 5 s. The kernel loads the whole system
   into RAM; the stick is not used after that.
4. At `solnix-installer console login:` log in as `root`. On the media, root has
   no password.

## 3. Network, and optionally a remote session

```sh
solnix-install --ssh
```

Measured result under KVM:

- `e1000g0 got <addr> via DHCP`
- `internet OK`
- `sshd is up`
- a root password for this session, printed in the banner

From another machine, `ssh root@<address>` with that password. A wrong
password is refused. To use a key instead, export `SOLNIX_SSH_PUBKEY='ssh-ed25519 ...'`
before running it.

If the check fails, the installer prints curl's own error. A TLS or certificate
error (curl rc 60/77) is not a network outage.

## 4. Install dixi

Find the internal disk:

```sh
format </dev/null        # lists disks; the NVMe is the internal one
```

Then:

```sh
SOLNIX_ADMIN_USER=gburd solnix-install --disk <nvme-disk> \
  --flake 'git+https://github.com/gburd/nix-config.git?ref=main#dixi'
```

- `--disk` is the WHOLE internal disk, and it is erased.
- The installer does the following:
  1. Evaluates `solnixConfigurations.dixi`.
  2. Copies the media's store into the new pool's `/nix`.
  3. Builds the rest of the toplevel on the target, substituting from
     cache.solnix.io and cache.nixos.org.
  4. Lays boot environment 1 from it.
  5. Installs the UEFI loader.

  Under KVM it took about 25 minutes.
- It asks for a root password, then for gburd's. gburd is declared by dixi.nix;
  the installer sets only the password, the home on `<pool>/home` and the RBAC
  entry.
- For key login on first boot, add `SOLNIX_ADMIN_SSHKEY='ssh-ed25519 ...'` to the
  same command line.
- For an unattended install, add `SOLNIX_ROOT_PW=...` and `SOLNIX_ADMIN_PW=...`
  (avoid that on a shared terminal).

When it reports `DONE`, reboot and remove the stick.

## 5. After first boot (all measured on the KVM-installed dixi)

```sh
ssh gburd@<address>       # key or password; root cannot ssh in (PermitRootLogin no)
pfexec id                 # uid=0: Primary Administrator
su                        # works too (the setuid su from /run/wrappers/bin)
beadm list                # solnix-1, active now and on reboot
ls -l /run/current-system # the dixi toplevel in /nix/store
git --version; curl --version
nix-build -E '...'        # an ordinary user builds through nix-daemon
```

### A new generation

Edit nix-config, then on the X1:

```sh
nix build --out-link ~/new '<flake>#solnixConfigurations.dixi.config.system.build.toplevel'
pfexec nix-env -p /nix/var/nix/profiles/system --set ~/new
pfexec ~/new/bin/switch-to-configuration boot   # makes BE solnix-2, the next default
pfexec reboot
```

Under KVM, generation 2 booted. In the loader menu, option 6 ("Select Boot
Environment") listed `solnix-2` and `solnix-1`, and choosing `solnix-1` booted
generation 1 while `solnix-2` stayed the default.

`reboot` uses illumos fast reboot, which skips the loader menu. To reach the
menu, power-cycle instead, or run `reboot -p`.

## Known open items

- **Wifi** (Intel AX2xx, iwx) does not work yet; use wired.
- **COSMIC** is off (`solnix.desktop.cosmic.enable = false`).
- **Seven gate tools don't run**: cdrw, rmmount, rmumount, volcheck,
  volrmmount, latencytop and tpmadm need dbus, glib or trousers, which nothing
  builds yet. Nothing on the install or boot path uses them.
- **No kmdb** (`misc/kmdbmod`).
- **First-boot labelclear stall.** Under KVM, a `zpool labelclear` on the target
  stalled about 25 minutes after the scratch pool on the same disk was destroyed.
  The install then completed.
