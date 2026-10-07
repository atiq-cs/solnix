# Installing solnix on the X1 Carbon from the USB stick

This is the procedure for the maintainer's Lenovo X1 Carbon ("dixi"). The media is
generic (no personal users, keys or flakes); the machine's identity comes from the
nix-config flake you name at install time.

Status: DRAFT. Under KVM the image boots to the installer login; steps 3-5 have NOT yet been run there
(blocked: `solnix-install --net` did not finish under KVM). Nothing here has been run on the X1.
Measurements: /tmp/x1-installer-progress.txt.

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

1. Plug in the stick and the wired network (the X1's onboard NIC is `e1000g0`).
2. Power on and press **F12** for the boot menu, then pick the USB stick (UEFI).
   Secure Boot must be off (F1 -> Security -> Secure Boot).
3. The illumos loader menu appears and boots by default after 10 s. The kernel
   loads the whole system into RAM (the stick is not used after that).
4. At `solnix-installer console login:` log in as `root`. The media's root has no password.

## 3. Check the network first

```sh
solnix-install --ssh
```

This brings up DHCP on the first wired NIC, checks that an HTTPS fetch of
`https://cache.nixos.org/nix-cache-info` works, and starts sshd so you can continue
from another machine (`ssh root@<the address it prints>`; set a root password with
`passwd` first, or export `SOLNIX_SSH_PUBKEY='ssh-ed25519 ...'` before running it).
If it fails it now prints curl's own error. A TLS or certificate error (curl rc 60/77) is
not a network outage.

## 4. Install dixi

Prerequisite: nix-config carries the change in `/tmp/nix-config-dixi-changes.md`
(mkSolnixHost on `solnix.lib.mkPkgs`, dixi.nix importing solnix's base.nix,
`e1000g0`, `profiles = [ "Primary Administrator" ]`) and its flake.lock points at a
solnix revision that has them.

Find the internal disk (NVMe on the X1):

```sh
format </dev/null        # lists disks, e.g. c2t0d0 (the NVMe); the USB stick is not in RAM-root use
```

Then:

```sh
SOLNIX_ADMIN_USER=gburd solnix-install --disk c2t0d0 \
  --flake 'git+https://github.com/gburd/nix-config.git#dixi'
```

- `--disk` is the WHOLE internal disk. It is erased.
- The installer evaluates `solnixConfigurations.dixi`, realises its closure into the
  new pool's `/nix` (copying what the media already holds, substituting from
  cache.solnix.io, building the rest), lays boot environment 1 from it, and installs
  the UEFI loader.
- It asks for a root password, then for gburd's password (gburd is declared by
  dixi.nix; the installer sets only the password, the home on `<pool>/home`, and the
  RBAC entry). Put an SSH key in with `SOLNIX_ADMIN_SSHKEY='ssh-ed25519 ...'` on
  the same command line, or declare `users.users.gburd.openssh.authorizedKeys.keys`.
- Unattended: add `SOLNIX_ADMIN_PW=...` (avoid it on a shared terminal).

When it reports done: `reboot`, remove the stick.

## 5. After first boot

```sh
ssh gburd@dixi            # or log in on the console
pfexec id                 # uid=0: Primary Administrator
beadm list                # solnix-1, active now and on reboot
nix build nixpkgs#hello   # goes through nix-daemon (nixbld users)
```

A new generation: edit nix-config, then on the X1

```sh
pfexec nix build --out-link /tmp/new '<flake>#solnixConfigurations.dixi.config.system.build.toplevel'
pfexec /tmp/new/bin/switch-to-configuration boot      # makes BE solnix-2, the next default
pfexec reboot
```

Both generations are in the loader's boot-environment menu (option 6 in the loader menu).

## Known open items

- Wifi (Intel AX2xx, iwx) does not work yet; use the onboard wired NIC.
- COSMIC is off (`solnix.desktop.cosmic.enable = false`).
- Console text misaligned on the X1 (maintainer report): REPRODUCED under KVM as a staircase in the
  boot-time console output (each line starts where the previous one ended: LF without CR). The
  interactive login shell after it is aligned. Cause not yet proven: on the media, `autopush -g` shows
  no ldterm configured on the console device, although inittab runs `autopush -f /etc/iu.ap`.
- A flake install evaluates the solnix package set, which downloads the pinned
  sources at evaluation time (`builtins.fetchurl`/`fetchTarball`), about 1 GB,
  even when every output is already in the media's store or the cache. It needs
  a working network and time. Moving the sources to fixed-output derivations
  (NixOS's fetchurl) removes this and is planned.
