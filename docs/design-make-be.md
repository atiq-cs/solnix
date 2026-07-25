# Design: make-be — bootable ZFS-root solnix image + EC2 AMI (Phase-1 gate)

Status: **PHASE-1 GATE MET** — the bootable ZFS-root solnix image assembles from
the Nix-store illumos world and boots on EC2 to the **`svc:/milestone/
multi-user-server:default` ONLINE** milestone, with our own `svc.startd`
managing 75 services. Definitive serial-console evidence in
`artifacts/phase1-boot/solnix-multi-user-server-boot.log`. This doc is the
working recipe + every boot gotcha found.

**T2.2 DONE** — `svcs -x` is now CLEAN (0 in maintenance) and **interactive
`ssh root@<solnix-ip>` login works** from a dev box (evidence:
`artifacts/phase2-ssh/gate-a-b-evidence.txt`; AMI `ami-0e94f12f2d0a6d37a`). See
gotchas #11–#16 for the crypto race + OpenSSH + ena/ifconfig fixes.

Maps to roadmap T1.13–T1.16b (make-be + boot to multi-user-server milestone).
Scripts: `scripts/oi-make-be.sh` (assemble the image), `scripts/oi-be-to-ami.sh`
(snapshot → AMI). Built + booted on the EC2 illumos build host (`illumos-960edb1c89`,
gate `ac45d71fc2`, Nix 2.3.16, store `rpool/nix`, `sandbox=false`).

---

## 0. The proven EC2-boot path (NOT nested QEMU)

Assemble a bootable ZFS-root disk on a scratch EBS/NVMe volume attached to the
build host, then snapshot → register-image like `scripts/oi-make-ami.sh`. The
illumos loader boots on EC2 UEFI (Nitro) via an ESP `EFI/Boot/bootx64.efi`.

Reference boot chain (confirmed from the build host's own working serial console,
`aws ec2 get-console-output i-<build-host>`):

```
UEFI firmware
  -> ESP  \EFI\BOOT\BOOTX64.EFI   (= illumos loader64.efi)
  -> loader: "Trying ZFS pool" -> "Setting currdev to zfs:<pool>/ROOT/<be>"
  -> loads /platform/i86pc/kernel/amd64/unix + /platform/i86pc/amd64/boot_archive
  -> unix: "illumos Version ... 64-bit"
  -> genunix, CPU feature probe, mem sizing, TSC calibration
  -> device tree (rootnex), Configuring devices
  -> /sbin/init -> svc.startd -> svc.configd -> manifest-import
  -> milestones: single-user -> multi-user -> multi-user-server
  -> console login
```

---

## 1. Disk layout (mirrors the proven OI rpool disk)

`prtvtoc` of the build host's booting rpool disk is the template:

```
Partition  Tag  Flags   Sector    Count    Last
   0        12    00       256    524288   524543   ESP (pcfs FAT32, 256 MiB)
   1         4    00    524544   <pool>    ...       the ZFS pool (tag 4)
   8        11    00    <end>     16384    ...       reserved (tag 11)
```

GOTCHA (GPT labelling): `fdisk -B` on the whole-disk `p0` node produces a label
that reports the disk in *cylinders*, and `fmthard` then rejects the ESP slice
with "not aligned on cylinder boundary". Fix: create + destroy a throwaway zpool
on the whole disk first (`zpool create -f __tmp cNtNdN; zpool destroy __tmp`) —
that lays a **pure sector-addressed EFI label**, on which `fmthard -s` accepts
the 3-partition spec cleanly. This is the reliable GPT-with-ESP recipe on illumos.

ESP: `mkfs -F pcfs -o fat=32,b=ESP /dev/rdsk/cNtNdNs0`. Loader goes to
`EFI/Boot/bootx64.efi`.

Pool: `zpool create -f -o altroot=/a -o cachefile=none -O compression=on
-O atime=off -m none spool /dev/dsk/cNtNdNs1`. Name it `spool` (not `rpool`) so
it imports next to the builder's own rpool. BE = `spool/ROOT/solnix-1`
(`canmount=noauto mountpoint=/`); `spool/ROOT` is `mountpoint=legacy`.

---

## 2. The BE root = the Nix-built gate proto

**Decision: the BE root filesystem IS `pkgs.illumos.gate`'s proto** (our
`ac45d71fc2` build ingested into the Nix store), laid down with
`(cd $proto && tar -cf - .) | (cd /a && tar -xf -)`. Rationale: the proto is ONE
internally consistent illumos build — kernel + drivers + genunix + libc + rtld +
svc.startd + all 102 SMF method scripts + stock manifests + /etc — so the
kernel↔driver↔userland ABI all matches. The RUNPATH-relocated `systemPath` slices
(GATE 1, ldd-clean) are the *composable* form of the same world; the proto is the
*monolithic-root* form. Both are "our Nix world", not stock OI (the running host
is `illumos-960edb1c89`; our kernel banner is `master-0-gac45d71fc2`).

The proto is a near-complete bootable root. It ships `/boot` (loader64.efi,
gptzfsboot, pmbr), `sbin/init`, `bootadm`, `installboot`, `filelist.ramdisk`,
`lib/svc/seed/global.db`, and `ld.so.1` at `/lib` + `/usr/lib` symlink chain.

### Things the proto lacks that a boot needs (the ADD list, design-smf-init §5)

1. **`/etc/name_to_major` + `driver_aliases` + `driver_classes` + `minor_perm`
   are near-EMPTY stubs** (name_to_major has ~4 entries, no `rootnex`!). The gate
   build does not populate them (they're filled at install/first-boot by add_drv).
   **Without `rootnex` the kernel panics `Couldn't find major number for 'rootnex'`
   in setup_ddi().** FIX: copy the build host's full `/etc/name_to_major` (268
   entries incl. rootnex=179, zfs=264, blkdev=28, nvme=139) + `driver_aliases`
   (1339) + `driver_classes` + `minor_perm`. The host's majors are compatible —
   same illumos lineage, and our proto's drivers are a superset with the same
   names for all core drivers.

2. **External libs the SMF stack NEEDs are absent** (third-party, not gate-built):
   `libxml2.so.16` (svccfg + svc.startd NEED it) → `libz.so.1` + `libicuuc.so.78`
   → `libicudata.so.78` + `libstdc++.so.6` + `libgcc_s.so.1`. Copy (deref'd) into
   `/usr/lib` + `/usr/lib/amd64` from host IPS + gcc-14 runtime (same provenance as
   the `externalLibs` slice). Without libxml2, manifest-import (svccfg) fails.

3. **`/etc/svc/repository.db`** — copy the shipped `lib/svc/seed/global.db` (27
   core services incl. all milestones). svc.configd opens it; manifest-import then
   ADDS all `/lib/svc/manifest/**` (incl. our solnix manifests) at first boot.

4. **ttya serial console** — `boot/solaris/bootenv.rc`: `setprop console ttya;
   setprop os_console ttya; setprop ttya-mode 115200,8,n,1,-`. Plus
   `boot/loader.conf`: `console="ttya"` so the LOADER emits to serial too. EC2's
   serial console (`get-console-output`) captures COM1 = ttya. GOTCHA: an earlier
   `setprop console text` sent kernel console to the EFI framebuffer (invisible to
   AWS) — must be `ttya`, not `text`.

5. **root console login** — the proto's root shell is `/usr/bin/bash` which the
   proto does NOT ship; point root's shell at `/usr/bin/ksh93` (present). Root
   password is already empty; allow empty-password console login
   (`/etc/default/login`: `#CONSOLE=`, `PASSREQ=NO`).

6. **ena NIC on Nitro** — the proto ships the `ena` driver binary but its
   `driver_aliases` lacks the ena PCI aliases and `name_to_major` lacks ena. The
   host `driver_aliases`/`name_to_major` we copy in (fix #1) already include them
   (`ena "pciex1d0f,{ec2,1ec2,ec20,ec21}"`, `ena 152`). A `solnix-netcfg` oneshot
   does DHCP on the first phys NIC (mirrors `metadata-shim.sh` networking).

7. **solnix SMF marker** (add-not-replace) — `/lib/svc/manifest/solnix/
   solnix-hello.xml` (transient, depends on multi-user, prints a banner + `svcs
   -x`) proves our generated manifest imports and reaches online. DTD-validated
   at build with `xmllint --dtdvalid`.

---

## 3. boot_archive (the ramdisk that mounts ZFS root)

`bootadm update-archive -f -R /a`. GOTCHAS:

- The build host has **no `mkisofs`** (cdrtools), so bootadm's compressed-hsfs
  path prints `gzip: stdout: No space left on device` warnings and initially falls
  back to a **UFS** boot_archive. Once all files are in place it produces the
  proper **gzip-compressed CPIO** archive (matching the distro format — verify
  with `file`: "gzip compressed data"). Both formats are loader-bootable; the
  gzip-CPIO one is the distro standard.
- The archive must contain the ZFS + disk drivers to mount root: verified
  `kernel/drv/amd64/{zfs,blkdev,nvme}`, `kernel/fs/amd64/zfs`,
  `platform/i86pc/kernel/amd64/unix`, `kernel/amd64/genunix` — all our build.
- `name_to_major`/`driver_aliases` are IN the ramdisk (filelist.ramdisk lists
  `etc/name_to_major` etc.) — so fix #1 above must be applied BEFORE building the
  archive, and the archive rebuilt after any change to those files.

Loader install: copy `boot/loader64.efi` → ESP `EFI/Boot/bootx64.efi`. `zpool set
bootfs=spool/ROOT/solnix-1 spool`. (`installboot -m` on the ESP slice warns
"Booting pcfs from EFI labeled disks requires the boot partition" — expected/
non-fatal; UEFI boots via the ESP loader, not the gptzfsboot stage.)

---

## 4. AMI (Phase 2)

Export the pool (`zpool export spool`), then snapshot the scratch EBS vol →
`register-image` with `--boot-mode uefi --ena-support --architecture x86_64`.

GOTCHAS:
- **UEFI AMIs require a Nitro instance type** (m5/m6i/c5...). m4/Xen reject a
  UEFI-boot-mode AMI ("does not support an AMI with a boot mode of UEFI").
- The numa account **enforces IMDSv2** — `run-instances` needs
  `--metadata-options HttpTokens=required,HttpEndpoint=enabled` or it errors
  `UnsupportedOperation ... httpTokensEnforced`.

Capture the serial console: `aws ec2 get-console-output --instance-id <iid>
--latest` (the `--latest` flag returns fresh output; without it the output lags).
Strip ANSI: `sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g'`.

---

## 5. Boot progress + gotchas (chronological, the iteration log)

| # | Symptom (serial console) | Root cause | Fix |
|---|---|---|---|
| 1 | No console output at all | loader console defaulted to framebuffer / `console text` in bootenv.rc | `console ttya` in bootenv.rc + loader.conf; use `get-console-output --latest` |
| 2 | Hang right after `illumos Version ... 64-bit / DEBUG enabled` | (was actually a later panic, hidden without `-v`) | boot `-v` (verbose) to reveal it |
| 3 | `panic: Couldn't find major number for 'rootnex'` in `setup_ddi()` | gate proto `/etc/name_to_major` is a 4-entry stub (no rootnex) | copy host's full name_to_major/driver_aliases/driver_classes/minor_perm |
| 4 | Hang after `TSC calibrated using VMware` (100% with DEBUG kernel) | the gate builds DEBUG-only (`NIGHTLY_OPTIONS='-FnCDAmprt'`, the `-D`). The DEBUG kernel hangs in early init (`startup_smap`/`startup_modules`) on EC2 Nitro; the stock kernel is non-DEBUG. | build a **non-DEBUG** kernel: `bldenv +d solnix.sh` then `dmake -m serial install` in `$SRC/uts` (build `uts/intel` before `uts/i86pc` or CTF-uniquify fails). Swap `platform/*/kernel`, `kernel`, **AND `/usr/kernel`** into the BE. |
| 5 | `mod_load: cannot load module 'pm'/'ptm'/'pts': undefined symbol 'ptms_logp'/'pm_debug'` | DEBUG/non-DEBUG **mismatch**: swapped non-DEBUG unix/genunix but left DEBUG `/usr/kernel/*` drivers that reference debug-only symbols | swap `/usr/kernel` too — ALL kernel module trees must be the same DEBUG-ness |
| 6 | init hangs at kernel→userland handoff, no `Configuring devices` | the proto's on-disk `/dev` lacks the persistent `console`/`msglog`/`null` symlinks, so init's `svc.startd >/dev/msglog </dev/console` can't open stdio | seed `/dev/{console,msglog,null,zero,tty,syscon,systty,sysmsg,random,urandom,poll}` symlinks into `/devices/pseudo/...` |
| 7 | pervasive `Permission denied` (rpcbind /var/run, sendmail 'unsafe map file', 'dangerous permissions=40555') | **the gate proto ships ALL directories mode 0555** (no owner-write) — 3451 of them | `find $BE -type d -exec chmod u+w {} +`; then `chmod 1777 /tmp /var/tmp`, `1770 /var/spool/clientmqueue` |
| 8 | `svccfg apply /etc/svc/profile/generic.xml failed` | the standard profile symlinks (`generic.xml`, `platform.xml`, `name_service.xml`) are missing from the proto (made at install) | `ln -s generic_limited_net.xml generic.xml`, `platform_none.xml platform.xml`, `ns_dns.xml name_service.xml` in `/etc/svc/profile` |
| 9 | `sendmail: unknown user smmsp`; `sshd` privsep needs its user | proto passwd/group missing several users | append missing users/groups (incl. `sshd`) from the host passwd/group/shadow; disable sendmail via a site profile (it's non-essential + floods the console) |
| 10 | intermittent hang at `TSC calibrated` (~50% of boots) even non-DEBUG | **RESOLVED (T2.1).** After a hypervisor TSC-freq source ("VMware", which via `get_hwenv() & HW_SUPPORTS_FREQ` also covers **KVM**/VirtualBox/ACRN — EC2 Nitro is KVM) wins TSC calibration, `tsc_calibrate()` calls `tsc_pit_also()` (timestamp.c) which runs a **diagnostic** PIT (legacy 8254) calibration purely to record what the PIT *would* have measured (for the APIC code). That run does port I/O to the emulated 8254 (`freq_tsc_pit` in locore.S + `pit_sanity_check` in tscc_pit.c); on EC2 Nitro/KVM the emulated PIT is unreliable and the calibration loop's refine-and-retry spins pathologically long, presenting as a boot hang. It is single-CPU (a **1-vCPU** batch still hung ~75% — rules out an MP/AP race) and the hypervisor detect is correct (VMware/KVM source is right). It runs in `startup_tsc()` which precedes `startup_modules()` — so it is BEFORE `/etc/system` is read, and `pit_is_broken` is not a boot property, so the ONLY early knob is a source default. | **FIX:** default `int pit_is_broken = 1;` in `usr/src/uts/i86pc/os/tscc_pit.c` (the file already documents this global as the "avoid the PIT entirely" switch). On a cloud VM the PIT diagnostic is worthless (the hypervisor freq source always wins), so this loses nothing. Applied by `scripts/oi-gate-build.sh` (also `scripts/patches/0001-tscc_pit-default-pit_is_broken.patch`), baked into the non-DEBUG kernel that `oi-make-be.sh` swaps in via NDPROTO. **Batch-measured on m6i.large: 4/10 (40%) BEFORE → 20/20 (100%) AFTER** (two 10-boot batches). Runtime confirmed via `mdb -k`: `pit_is_broken=1`, `pit_tsc_hz=0` (PIT never ran), `tsc_calibration_source="VMware"`. |
| 11 | (T2.2) `cryptosvc` → maintenance: `/sbin/cryptoadm start` exits 1 (can't open `/dev/cryptoadm`) → blocks `network/ssh` (require_all dep on cryptosvc) | **RACE, not missing driver.** The crypto/cryptoadm/kcf drivers, `.conf`, `/kernel/crypto/*` providers, `libcryptoutil.so.1`, `/etc/crypto/*` are ALL in the proto and load fine. The `/dev/cryptoadm` pseudo node IS created — but by `svc:/system/device/local` (devfsadm), which runs LATE on our image (~device milestone). Stock `cryptosvc` depends only on `svc:/system/filesystem/root`, so it starts BEFORE devfsadm makes the node and loses the race. (On real hw the crypto node exists early in the device tree.) FIX: inject a `require_all` dependency on `svc:/milestone/devices` into the stock `cryptosvc.xml` (awk, DTD-revalidated) so cryptosvc waits for devfsadm. Confirmed by a diag marker: at +45s `ls /dev/cryptoadm` succeeds and `cryptoadm start` returns 0. |
| 12 | (T2.2) `network/ssh` → maintenance "exited $SMF_EXIT_ERR_FATAL" AFTER crypto fixed | The gate proto ships the OLD Sun_SSH `ssh.xml`+method that runs `/usr/lib/ssh/sshd`; the reference OI host runs MODERN OpenSSH at `/usr/sbin/sshd` with a different manifest/method. Copying only the binary left the proto method calling the wrong path. FIX: copy the reference host's WHOLE OpenSSH — `ssh.xml` manifest + `sshd` method + `sshd`/`ssh-keygen`/`ssh` binaries. |
| 13 | (T2.2) ssh still fatal: `/usr/libexec/sshd-session does not exist or is not executable` (status 95) | Modern OpenSSH (9.8+) splits sshd into a listener + per-connection helper binaries in `/usr/libexec`. Copying `sshd` alone is insufficient. FIX: copy `/usr/libexec/{sshd-session,sshd-auth,sftp-server,ssh-keysign,ssh-pkcs11-helper,ssh-sk-helper}`. |
| 14 | (T2.2) ssh online + listening 0.0.0.0:22 but SSH from dev box **times out** (not refused) | The privsep chroot dir `/var/empty` is NOT in the proto; without it sshd's privsep FAILS. (Actually two problems stacked — see #15 for the real timeout cause; `/var/empty` fixed a separate fatal.) FIX: `mkdir /var/empty; chown root:sys; chmod 0755`. |
| 15 | (T2.2) THE SSH timeout root cause: instance had **only loopback**, no NIC address, no default route | The gate ena driver leaves the datalink STATE `unknown` (never posts link-up), and **`ipadm create-if ena0` REFUSES to plumb an unknown-state link** ("Operation failed") → DHCP never runs → no IP → SSH times out. The original `solnix-netcfg` silenced all errors and exited OK, masking a no-network boot (Phase-1 "passed" with NO network — evidence was console-only). FIX: legacy `ifconfig ena0 plumb` + `ifconfig ena0 dhcp start wait 60` DOES NOT care about link STATE and works — yields a real DHCP addr + default route. netcfg now tries ipadm, falls back to ifconfig. |
| 16 | (T2.2) `svcs -x` not empty: `dns/client` offline, hal/ipsecalgs "1 dependent not running" | `network/dns/client` (a `:true` marker svc) is driven online by `network/location` via an `optional_all/refresh` dep — but `network/location` ships DISABLED, so dns/client stays offline. hal/ipsecalgs disabled-by-admin still show in `svcs -x` because each has a dependent (`rmvolmgr`/`ipsec/policy`) not running. FIX (site profile + netcfg): enable `network/location`; disable the dependents `system/filesystem/rmvolmgr` + `network/ipsec/policy`; netcfg backgrounds a `svcadm refresh + enable dns/client` after location is up (its refresh-dep may miss the boot-time state change). |

### Boot milestones reached (Nitro m6i.large, UEFI) — ALL PASS

- loader → **PASS** (finds ESP, ZFS pool `spool/ROOT/solnix-1`, loads unix + boot_archive)
- unix + genunix → **PASS** (`illumos Version master-0-gac45d71fc2 64-bit`, OUR non-DEBUG build)
- CPU feature probe + mem sizing + TSC calibration → **PASS** (T2.1 fix: `pit_is_broken=1` in the non-DEBUG kernel makes this reliable, no more ~50% hang after "TSC calibrated using VMware")
- device tree / `setup_ddi` (rootnex) → **PASS** (fix #3)
- `blkdev0`/`nvme0` attach + **VFS ZFS root mount** (`root on spool/ROOT/solnix-1 fstype zfs`) → **PASS**
- both vCPUs online → **PASS**
- `/sbin/init` → `svc.startd` → `svc.configd` → `manifest-import` (176 manifests) → **PASS**
- `svc:/milestone/single-user` → `multi-user` → **`multi-user-server`** ONLINE → **PASS (THE GATE)**
- `console login:` prompt + `site/solnix-{netcfg,hello}` online → **PASS**
- (T2.2) `svc:/system/cryptosvc` ONLINE → crypto framework up → **PASS**
- (T2.2) `svc:/network/ssh` ONLINE + listening + **interactive `ssh root@<ip>` shell** → **PASS (GATE B)**
- (T2.2) `svcs -x` EMPTY (0 maintenance, 0 offline) → **PASS (GATE A)**

### Definitive gate evidence (serial console, `svcs`)

```
SunOS solnix 5.11 master-0-gac45d71fc2 i86pc i386 i86pc
online  16:11:29 svc:/milestone/multi-user:default
online  16:11:30 svc:/milestone/multi-user-server:default   <- THE GATE
online service count: 75
```
`svcs -x` shows 5 peripheral services in maintenance/offline (cryptosvc, hal,
keymap, intrd, ipmp) — none are milestone dependencies, so multi-user-server
reached online regardless. **T2.2 UPDATE: all now resolved — `svcs -x` is CLEAN
(empty) and interactive SSH login works.** cryptosvc was a device-node race
(gotcha #11, fixed with a `milestone/devices` dependency); hal/keymap/intrd/ipmp
(+ipsecalgs) are peripheral/desktop and cleanly DISABLED in the site profile;
`network/ssh` needed the modern-OpenSSH layout + `sshd-session` helper +
`/var/empty` + a working NIC (ena needs legacy `ifconfig` — gotchas #12–#16).

---

## 6. TODO / open (post-gate polish)

- ~~**Intermittent early-kernel TSC hang (~50%)**~~ **RESOLVED (T2.1):** the
  diagnostic PIT run (`tsc_pit_also` → `freq_tsc_pit`) spun on the KVM-emulated
  8254; fixed by defaulting `pit_is_broken=1` in `tscc_pit.c` (gotcha #10).
  Batch-measured 40% → 100% on m6i.large. AMI `ami-0e215d9b018112964`.
  Boot-hang batch-test helper: `scripts/oi-boot-batch.sh` (launch N, parse
  console for the multi-user-server milestone, report N/M, terminate).
- ~~Clean up the 5 peripheral maintenance services~~ **DONE (T2.2):** `svcs -x`
  is clean. cryptosvc = `milestone/devices` dep (gotcha #11); hal/keymap/intrd/
  ipmp/ipsecalgs = disabled in the site profile (+ their dependents rmvolmgr/
  ipsec-policy); dns/client driven online via `network/location`.
- ~~Get `network/ssh` online + a login~~ **DONE (T2.2):** modern-OpenSSH layout
  (`/usr/sbin/sshd` + `/usr/libexec/sshd-session` et al) + `/var/empty` privsep
  dir + reference `ssh.xml`/method + `PermitRootLogin yes` + root authorized_keys
  (gotchas #12–#14). ena NIC needs legacy `ifconfig` DHCP, not ipadm (gotcha #15).
- Nixify make-be (`lib/make-be.nix`) — the script recipe (`scripts/oi-make-be.sh`
  + the manual fixes here) is proven; fold the fixes into it, then nixify.
- External libs + non-DEBUG kernel: fold into `pkgs.illumos.gate` (build
  non-DEBUG proto; the gate FOD should use `bldenv +d`).
- Build the external libs + libcrypto from source / pinned IPS pkg (P2).
