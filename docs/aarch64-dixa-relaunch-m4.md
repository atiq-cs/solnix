# Relaunching dixa from the aa64rb m4 AMI (first-reboot DL_BADPPA fixed)

Written 2026-10-29 by aa64rb2. Evidence: /scratch/solnix/aa64rb/progress.txt, verify.log. Supersedes the aa64h/aa64tls
AMIs in docs/aarch64-dixa-recreate.md, which still applies for type, capacity, timing and the instance store.

## The AMI: aa64rb m4 (owner solnix-ami 788352824872, private)
m4 = aa64tls m2 + `site/aa64-archive-sync`. Every boot where `bootadm update-archive -vn` reports a change, the service
runs `bootadm update-archive`, ordered after device/local and boot-archive-update and before network/ssh. Kernel, userland,
nix and the toplevel are m2's (the static-TLS rtld/libc/ld, the rebuilt store set, the man fix).
Raw sha256 `1af907363c2332fbb7a59bf9672d449622e68029338d395959043a1e0d6f3a3f`. Banked at floki
`~/solnix-bank/ami/aarch64-6cd2521c1e-aa64rb-20261029/aa64rb-m4.img.gz` (gz a53e9f80, read back == raw).

| region | AMI | snapshot | boot-tested |
|---|---|---|---|
| us-east-1 | `ami-0b544e93ac70551d6` | `snap-055a1eeed30713aa3` | c6gd.metal x1 (ue1, us-east-1c, 2026-10-29) via a temporary kiwi share (removed): launch + 1 API reboot, ena0 up, 0 BADPPA, REGISTRY_FETCH_OK |
| us-west-2 | `ami-0c58280779782f854` | `snap-0f39566de9350f63b` | same image as kiwi ami-0db4448441e41d58c: 3/3 c6gd.metal |

- The kiwi image went through 3 fresh c6gd.metal launches (v1-v3, us-west-2a). Each was followed by one EC2 API reboot,
  and each came back with ena0 up, ssh OK, 0 DL_BADPPA, and no "Using default device instance data".
- The control was the m2 image: its first API reboot after launch gave DL_BADPPA 5/5.
- Attributes match m2's: arm64, UEFI, ENA, `/dev/sda1` 10 GiB gp3.
- m2 (us-west-2 ami-00234e6fbe02f6734, us-east-1 ami-0e7962165a7e60513) is tagged `Status=superseded-by-...`. Don't use it.

- Open item (1 of 4 m4 launches: ue1 only): the launch's second boot put `svc:/network/rpc/bind` into maintenance
  (`rpcbind failed with 1` x3, 3 dependents down) and logged `sendmail: unknown user smmsp`. The site profile disables
  rpc/bind, and on the next boot it was `disabled` again. No other launch boot whose console reaches login showed it: aa64h o1-o4, aa64tls v1, aa64rb b and v1-v3 (9 boots).
  Mechanism not measured. The dependents that stopped were ktkt_warn, autofs and smserver, and ssh, ena0 and nix were unaffected.
  If `svcs -x` shows it on the new dixa, run `svcadm disable rpc/bind`, which is the image's intended state.

## 1. Share it with the work account (solnix-ami can do this)
    AWS_PROFILE=solnix-ami aws ec2 modify-image-attribute --region us-east-1 --image-id ami-0b544e93ac70551d6 \
      --launch-permission 'Add=[{UserId=399683337502}]'
A shared AMI's snapshot need not be shared for a launch. (kiwi snap-03ec7f20db2ea487f already carries a
createVolumePermission for 399683337502. It is not needed for this and dies with kiwi on 10-30.)

## 2. Launch (work account, us-east-1)
Use the run-instances line in docs/aarch64-dixa-recreate.md with `--image-id ami-0b544e93ac70551d6`, c6gd.metal, root
`/dev/sda1` 10 GiB gp3 (more is fine; the pool does not grow). The key comes from IMDS (site/aa64-ec2-key), so any EC2
keypair works. ssh as root answers about 20 min after launch, on the second cycle (the first is the boot-archive
self-reboot). Watch with `aws ec2 get-console-output --latest` for `console login:`.
Reboots are now safe both ways: `reboot-instances` (a hard reset on aarch64) and in-guest `reboot`.

## 3. Restore dixa's host key before anything trusts the new sshd
dixa is enrolled at tier 1 as a builder, and its identity is `/etc/ssh/ssh_host_ed25519_key`. The image generates a
new key at first boot, so connect the first time with `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`.
Then, from floki:

    H=dixa; N=<new-ip>; cd ~/ws/nix-config
    SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d --extract "[\"${H}_ssh_host_ed25519_key\"]" nixos/solnix/secrets.yaml |
      ssh root@$N 'umask 077; cat > /etc/ssh/ssh_host_ed25519_key.new && ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key.new'
    # compare with: sops -d --extract '["dixa_ssh_host_ed25519_key_pub"]' nixos/solnix/secrets.yaml ; if equal:
    ssh root@$N 'mv /etc/ssh/ssh_host_ed25519_key.new /etc/ssh/ssh_host_ed25519_key &&
      ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key > /etc/ssh/ssh_host_ed25519_key.pub && svcadm restart network/ssh'

- The aarch64 image's sshd is braich's `svc:/network/ssh:default`, not the x86 `network/sshd`.
- The old pin in floki `~/.ssh/known_hosts.dixa` (3.94.113.224) holds the restored key. After an IP change, edit only the address.
- Do NOT `enroll` again (docs/community-features.md "Host identity").

## 4. The aa64tls store set is already in the image
Old dixa got these by hand (path A, 12:40Z). m4 ships them, so path A and path B both become unnecessary:
- `/lib/{libc.so.1,ld.so.1,libld.so.4}` come from the aa64tls proto.
- `system-2-link` -> `/nix/store/yzfqpfw9nzimai0zmda540bnc3d0qgrh-solnix-system-aarch64`: nix n537qp9h, libc slice
  m0w5yd5w, the man fix.
- The gburd@dixa home generation (`/nix/store/1d93bmvpp8d89c78xyypz8j4i2bzm277-home-manager-generation`) is NOT in
  the image. Copy it from the floki bank file:// cache, then activate it as gburd:
  `nix copy --no-check-sigs --from file:///home/gburd/solnix-bank/aa64tls-20261029/store <path>`.
  From floki, run that over `ssh-ng`, or scp the cache over first.

## 5. Redo what dixa1 did by hand (the image has root only, single-user nix)
The scripts and their originals are in `/scratch/solnix/dixa1/`, and the change list is `dixa-changes.md`:
- `pool.sh`: the `data` stripe on c2t1d0 + c3t1d0, plus ws/src/scratch/var-tmp. `vartmp.sh` puts /var/tmp on data.
- `useradd -m -s /run/current-system/sw/bin/bash gburd`: uid 1000 and Primary Administrator, as nixos/solnix/dixa.nix.
  Then his authorized_keys.
- `smf/multiuser.sh`: nixbld1..32, nix.conf, store root:nixbld 1775, svc:/system/nix-daemon. Re-render the start method
  with `nixOut = n537qp9h` (dixa1 render-nixd.nix), not j9mcnrx5. Use `nix-daemon.final.xml`
  (ignore_error=core,signal, TMPDIR=/var/tmp/big).
- `devroot.sh`: only if dixa builds bootstrap/gate sources (braich-dev + /opt/nixboot).
- /etc/profile: put ~/.nix-profile/bin first (dixa-changes.md "gburd's home").

## 6. Census and the builder: not on aarch64 yet
- `site/solnix-census`, the cache proxy and site/solnix-builder are nix-config `community.nix` module services. dixa.nix
  does not import community.nix (only dixi.nix does). The aarch64 image has no module-system toplevel
  (pkgs/illumos/aarch64/system.nix), so `solnix-rebuild switch --flake .#dixa` cannot install them.
- m4's only site services are aa64-ec2-key and aa64-archive-sync. So dixa sends no census, which is the private
  default (`solnix.privacy.enable = true`). A hand-run census like dixi's first ping (community1) is possible, but it is
  a maintainer choice, so it is not in this note.
- To build queue rows on dixa, place the bearer as dixi does (`/var/lib/solnix/build-queue-bearer`, 0600 root, 64 B,
  from `secrets/build-queue-bearer.yaml`). The builder loop itself has to be run by hand until aarch64 has module support.

## 7. Verify
- The console of each boot shows no `DL_BADPPA` and no "Using default device instance data" (on the boot after launch).
- `svcs -x` is empty, and `svcs aa64-archive-sync` is online. Its log `/var/svc/log/site-aa64-archive-sync:default.log`
  ends "in sync after N updates", and `bootadm update-archive -vn` shows only `cannot find:` lines.
- `ssh root@<ip> sh -s < ~/ws/solnix/scripts/ami-registry-check.sh` prints REGISTRY_FETCH_OK.
- `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` matches the sops `_pub` value.
- One `aws ec2 reboot-instances`, then ssh again. This is the case m4 fixes.
- Then terminate the old dixa and its root volume. The old dixa needs `bootadm update-archive` before any reboot
  (/scratch/solnix/aa64rb/dixa-archive-note.md) if anything is to be copied off it first.
