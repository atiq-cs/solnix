# dixr: a riscv64 solnix build host (plan, measured 2026-10-31)

Track dixr1. Brief: /scratch/solnix/briefs/dixr1.md. Work: /scratch/solnix/dixr1/ (progress.txt has every step).
Bank: /scratch/solnix-bank/dixr1-20261031/ (sha256 read back). Built and booted on an EC2 chef box
(i-085afb21bb983f303, c6i.8xlarge, Ubuntu 24.04, qemu 8.2.2), never on floki or lixr. lixr (192.168.1.179) was
offline the whole session (no ARP from floki or arnold; tailscale lists it offline), so nothing here touched the board.

## The finding that changes the plan

The brief takes our own kernel (`src/riscv/uts`, 30k lines, static-only ET_EXEC, no ZFS, newlib) as the base and
lists what it lacks. A different base already has all of it except nix:
**n-hys/illumos-gate** (Hayashi Naoyuki, CDDL, branch `osport/v2021.07` 3f7cd4cf, 2022-08-25). It is a full
illumos-gate with `uts/riscv64` + `riscv64pf/{virt,unleashed,sun20i}`, libc, `ld.so.1`, ZFS, SMF, the IP stack, and
its own `riscv64-solaris2.11` gcc 11.1.0 + binutils. `docs/prior-art-n-hys-riscv.md` (2026-07-29) recommended
harvesting drivers from it. Nobody had built or booted it. Today it was built and booted:

| check | result | evidence |
|---|---|---|
| build (docker `ghcr.io/n-hys/illumos-build:main`, `make tools MACH=riscv64; make -j32 MACH=riscv64`) | BUILD-RC=0, about 25 min | bank `build3-ok.log.gz`, `build.sh` |
| proto | 29,023 files, 589 in /usr/bin, a tarball of 308 MB | bank `illumos-2026-10-31-riscv64.tar.gz` (ba2c7b94) |
| cross toolchain (x86_64 Linux host) | `riscv64-solaris2.11-{gcc,g++,ld,...}` gcc 11.1.0 | bank `cross-tools-riscv64.tar.gz` (1592c8e0) |
| qemu virt boot, ZFS root | OpenSBI -> inetboot -> `illumos Version SunOS_Development 64-bit` -> SMF 138/138 -> boot-archive reboot -> `console login:` | ec2 `~/w/con-b3.log`, `con-b9.log` |
| userland | `uname`: `SunOS 5.11 riscv64 SUNW,virt`; `zpool status`: rpool ONLINE; `/` = rpool/ROOT/illumos | progress step 14 |
| native compile in the guest | gcc 11.1.0 C hello (dynamic, `/lib/ld.so.1`) runs; g++ iostream/vector runs; GNU make 4.3; perl 5.26.3 | step 14 |
| SMP | 4/4 harts online at `-smp 4`, 8/8 at `-smp 8 -m 8G`, with `-cpu rv64,sv57=off` (below) | steps 16, 22 |
| parallel build | 8 gcc -O2 objects: `make -j1` 4 s, `make -j4` 1 s | step 23 |
| network | `ipadm create-addr -T dhcp platmac0/v4` gives 10.0.2.15; host HTTP fetch 13/13 bytes | step 23 |

## Three things it took to boot (each mechanism observed)

1. **`make tools` needs `MACH=riscv64`.** `usr/src/mk/config.mk` defaults to `MACH=aarch64`, so the cross dtrace is
   built for EM_AARCH64 and libc's `plockstat.o` fails with "incorrect ELF machine type" (dt_link.c:1218). The stale
   objects survive a re-run: `make -C usr/src/cross/src/dtrace clean` first.
2. **The ZFS label path must be the illumos bootpath.** A pool made on Linux records `path=/dev/loop3p1` with no devid,
   and inetboot sets no `zfs-bootpool`, so there is no pre-root device scan. Result: `zfs_domount: error 19`
   (ldi_open_by_name -> resolve_pathname, driver_lyr.c:615). With the bare nexus `/soc/virtio_mmio@10007000` the
   result is error 6 (blkdev bd_open ENXIO on the partition-less default minor), found by walking `zfs_dbgmsgs` over
   qemu's gdbstub (`dbg.gdb`). Fix (`mkdisk.sh`): create the pool through a symlink named
   `/soc/virtio_mmio@10007000/blkdev@0,0:a`, the string inetboot builds (psm/stand/boot/riscv64/virt/machdep.c:272).
   The two failing disks are kept as negative controls.
3. **qemu >= 7 needs `-cpu rv64,sv57=off`.** qemu 8.2's virt DTB gives every hart `mmu-type = "riscv,sv57"`.
   inetboot's `update_enable_hartmask` (machdep.c:126) counts only sv39/sv48 harts, so only the boot hart came up
   (1/4 in b3). With sv57 off the DTB says sv48 and every hart starts (4/4, 8/8).

## Gap list, re-measured against each base

"ours" = `src/riscv/uts` (rvtty3c 863cc75 and later). "n-hys" = the build above. Sizes are for dixr as a solnix host.

| gap (brief) | ours | n-hys, measured today | what is left for solnix |
|---|---|---|---|
| dynamic linking | ET_EXEC only (`elf.c:108` refuses anything else) | `/usr/bin/ls` and a fresh gcc output are dynamic, INTERP `/lib/ld.so.1`, and run | none |
| syscalls nix needs | ~70, Linux riscv numbers (`syscall.c`); no flock, symlink, MAP_SHARED, fsync; NPROC 16, NOFILE 32 | the illumos syscall table (`uts/common`): fork/exec/pipe/poll/flock(fcntl)/rename/symlink/mmap MAP_SHARED all MI code | none known; run nix's test suite to find out |
| filesystem for /nix/store | ramfs + SNFS (fixed slots, 256 KiB/file) | ZFS root (`zpool status` ONLINE), ufs/tmpfs/lofs in kernel/fs | none |
| C/C++ toolchain targeting riscv64-solaris | gcc 14.3 xgcc on a dead OI node (STATUS R-P17..22), not reproducible | cross gcc/g++ 11.1.0 on x86_64 Linux (banked) + native gcc/g++ 11.1.0 in the proto | gcc 14 for nixpkgs: port the riscv sol2 bits from `extra/gcc` to solnix's gcc-src recipe (aarch64 did the same with richlowe/gcc) |
| nix | none | none | the real work: nix 2.24 via `pkgs/illumos/nix-src.nix` (15 deps), bootstrapped natively in the guest the way aa64nix did aarch64 |
| builder service | none | SMF + OpenSSH 8.6 server ship, but every ssh connection closes right after kex (step 24, open) | fix sshd, then the `solnix-builder-<id>` user and zone (maintainer directive 6) |
| K3 boot (OpenSBI/U-Boot SPI-NOR, DTB, UART, UFS, RTL8153) | uts has K3 drivers that compile; none has run on silicon | virt, HiFive Unleashed and Allwinner D1 only. No K3/K1, no AIA (PLIC only), no UFS, no USB NIC | large. Ours: AIA, k3ufs.c, the K3 DTB facts. n-hys: the DDI/GLDv3 framework the drivers must plug into |

### What the n-hys base does not settle

* **Version.** 2021.07 illumos plus riscv. solnix's x86 gate is current illumos. A rebase is real work, but the arch
  code (uts/riscv64*, libc/riscv64, sgs riscv64) is a separable diff.
* **Upstream status.** Not in illumos-gate. Last push 2022-11-17. We would be its maintainer.
* **ABI.** illumos numbering throughout, which is the ABI `docs/riscv64-packages-2026-10-23.md` §7 recommended moving
  to. Our uts kernel's Linux-numbered syscalls and newlib userland do not carry over. The cost is losing the uts
  packages, not gaining anything.
* **Login over a DNS-configured resolver "hangs"** (dixr1 steps 17-22). RETRACTED by dixr2: it was not a block in
  getaddrinfo. With `hosts: files dns`, every `getent hosts <name>` and `/usr/bin/login` died of SIGSEGV (pc 0) in
  `nss_dns.so.1`, and ttymon re-prompting looked like a hang. Cause and fix: stage 1 below.
* **sshd preauth died with EINVAL** (dixr1 step 26). Fixed by dixr2; the cause was the cross-configured sandbox, not
  LibreSSL: stage 1 below.

## Step 3, done: an upstream leaf built natively on riscv64-solaris

In the b11 guest (`-smp 4 -m 8G`): zlib 1.3.1 was fetched from the host over HTTP and its sha256 (9a93b2b7..) checked
in the guest with `digest`. Then `./configure && make -j4 && make check` printed `*** zlib 64-bit test OK ***`, rc 0,
in 121 s. `libz.so.1.3.1` is a riscv64 ELF shared object. Control: a minigzip round trip returns rc 0, and with the
trailer CRC zeroed it reports `incorrect data check`, rc 1.
This is a native build with the proto's gcc, not a Nix derivation and not a `packages.riscv64-solaris` attr. The
recipe side (mk-src-pkg.nix's zlib) runs only once nix runs in the guest.

## Stages 1 and 2, done (dixr2, 2026-10-31)

Work: /scratch/solnix/dixr2/ (progress.txt has every step). Bank: /scratch/solnix-bank/dixr2-20261031/ (sha256 read
back). Same EC2 box. Four fixes to the n-hys tree (`n-hys-dixr2.diff`) and one to its gcc (`n-hys-gcc-dixr2.diff`).
Each fix was A/B-tested in the same guest with the old binary as the negative control.

| problem | mechanism (observed) | fix | control |
|---|---|---|---|
| sshd `Invalid argument [preauth]` | truss: the preauth child's `pollsys(..., 1, ...)` = EINVAL. openssh was configured cross, so configure's run-probes "select works with descriptor rlimit" assumed yes, giving SANDBOX_RLIMIT; with RLIMIT_NOFILE 0, illumos poll rejects nfds > p_fno_ctl (poll.c:393) | `oss/openssh/Makefile`: `--with-solaris-privs --with-sandbox=solaris` (what solnix x86 uses, base-src.nix) | old sshd: "Connection reset" rc 255; new: kex OK, `ssh uname -m` = riscv64 |
| login/getent die with DNS on | `nss_dns` calls `res_*` (all `#pragma weak`) through GOT slots that ld.so.1 binds at load (R_RISCV_64), before `_nss_dns_init` dlopens libresolv, so the call goes to 0 | `lib/nsswitch/dns/Makefile.com`: link `-lresolv` | alternating old,new,old,new: old rc 139 2/2, new resolves 2/2 |
| nix links fail on `qsort_r` | riscv64 libc exports from the hand-kept `port/mapfile-vers.gnu`, which lacked 6 symbols that `mapfile-vers` lists and libc defines | add qsort_r, futimes, lutimes, getgrouplist, upanic, __stack_chk_fail | old libc exports 0 of 6, new 6 |
| libgit2 (-std=c90) fails in `<sys/atomic.h>` | `uts/riscv64/asm/atomic.h` used C99 `static inline` | `static __inline__` | -std=c90 test compiles |
| nix aborts: `created == 123 ... ~AbstractSetting` | GCC PR c++/80431 (fixed in gcc 12, r12-1697): an NSDMI `Setting x{this}` in a class with a virtual base skips the constructor | backport r12-1697 into n-hys `extra/gcc` 11.1; rebuilt the cross and the native cc1plus | the PR's reproducer: old g++ "DESTROY" only, new "CREATE DESTROY"; old nix rc 139 2/2, new rc 0 2/2 |

The image: `mkdisk2.sh` builds a fresh disk from the proto dir with hostname `dixr` + `/etc/inet/hosts`, persistent
DHCP on platmac0 (ipadm.conf), nsswitch.dns (net-svc writes resolv.conf from the lease), sshd enabled by an SMF site
profile (`/etc/svc/profile/site/dixr.xml`) and key-only root login. `NIXBOOT=1` adds /opt/nixboot.

**Stage 1 gate, 8/8 boots** (`boottest.sh`: 8 fresh copies, `-smp 8 -m 6G`, 2 at a time): every boot answered
`ssh -p <fwd> root@127.0.0.1 uname -m` = riscv64 (8 harts, hostname dixr) 475-648 s after qemu start (`bt-r1.tsv`).

**Stage 2: nix in the guest.** Stage0 was CROSS-built on the host, not natively: a native g++ -O2 of one
nix-sized C++ unit takes 101-107 s in the guest against 3.65 s for the host cross g++ (about 28x). openssl 3.4.0
(no-asm, a solaris64-riscv64-gcc target), sqlite, libsodium, zstd, bzip2, editline, nlohmann_json, toml11, curl,
libarchive, brotli, libgit2, boost-context, then nix 2.24.15 with the 9 solnix patches plus 0010 (gcc 11 std::visit)
and `-include optional`. All of it installs to /opt/nixboot. In the guest:
`nix-build -E 'derivation { name="t"; system="riscv64-solaris"; builder="/bin/sh"; args=["-c" "echo ok > $out"]; }'`
gives `/nix/store/7c1hvm66dbi8i0l62w5ijb5h820sn7hk-t` ("ok") in 2.7 s. Controls: a builder that exits 3 fails
with rc 100, and `system = "x86_64-solaris"` is refused ("but I am a 'riscv64-solaris'"). The second gate
(`bt-r2.tsv`) passed 8/8 on the banked nix disk: on every boot, ssh `uname -m` = riscv64 and a fresh nix-build gave the
same out path, 537-699 s from qemu start. The gate's negative control is the same image built with the old rlimit
sandbox sshd (`SSHD=` in mkdisk2.sh): 2/2 reached `dixr console login:` and 2/2 FAILED the ssh check at 900 s (`bt-neg.tsv`).

Stage 3 plan, with what was measured: /scratch/solnix/dixr2/stage3-plan.md.

## Stages to "dixr builds queue rows as riscv64-solaris"

| stage | what runs where | done when | size |
|---|---|---|---|
| 0 (today) | n-hys proto on qemu virt on an EC2 Linux box; serial console | boots to login, native gcc/g++/make, zlib check | done |
| 1 | fix sshd preauth EINVAL; set a hostname and /etc/hosts; persistent DHCP; script the image (mkdisk.sh + an SMF profile) | `ssh dixr uname -m` = riscv64, 8/8 boots | done (dixr2) |
| 2 | nix in the guest: stage0 = proto gcc 11 + nix's 15 C/C++ deps built natively (as aa64nix used braich gcc14), nix 2.24.15 into /opt/nixboot | `nix-build` of a trivial derivation gives riscv64 output | done (dixr2), cross-built in about an hour; the C++ risk was gcc 11's PR 80431, not boost or unwinding |
| 3 | `pkgs/illumos/riscv64/{gate,default}.nix`: ingest this proto like aarch64's gate.nix; gcc from n-hys `extra/gcc`; `lib.systems` already names riscv64-solaris (solnix-pkgs 0007) | `nix build .#...riscv64-solaris.zlib` in the guest, drv + out recorded | weeks |
| 4 | builder: `solnix-builder-<id>` user/zone, claims only riscv64-solaris rows from recipes.tsv, publish gate, 8UNr client check | one queue row done end to end | after infra issues the short id and recipes.tsv has riscv64 rows (0 today) |
| 5 | real hardware: K3 (lixr) or a rented riscv64 server | separate track; see K3 below | months |

## Where the QEMU dixr runs

| | lixr (K3, Bianbu, 16 harts, 31 GB) | EC2 x86 (c6i.8xlarge here) |
|---|---|---|
| emulation | TCG riscv64-on-riscv64 (rvsrv/rvtty3c used qemu 10.2.1 unpacked under ~/scratch). KVM on the K3's `h` harts: not checked | TCG riscv64-on-x86 |
| measured speed | not measured this session (offline) | zlib configure+build+check 121 s at -smp 4; boot to login ~4 min first boot, ~2 min after |
| availability | board offline today; it is also the maintainer's desktop-class board | burner accounts expire in about 7 days; images must be banked (done) |
| cost | none | about $1.4/h for c6i.8xlarge on demand |
| fit | a home build host once it is back; rvtty3c already ran the uts guest there | the AGENTS.md definition of dixr; the first riscv64 builder |

The way to a fast build host is native: either KVM on the K3 (its 8 X100 harts carry `h`), or a riscv64 server.
TCG on x86 is fine for leaves and for proving recipes. It is too slow for gcc or llvm bootstraps at queue scale.

## K3 boot path (unchanged by this session; nothing was flashed or rebooted)

docs/k3-first-boot-runbook.md stays the plan for the uts kernel. For the n-hys kernel the board needs:
1. a `riscv64pf/k3` platform: a DTB-driven ns16550 at 0xd4017000 (n-hys asy_nsuart already reads reg-shift),
   the 24 MHz timebase, 16 harts;
2. AIA (APLIC+IMSIC) in place of PLIC (ours: `src/riscv/uts/aia.c`);
3. UFS (ours: `k3ufs.c`, a register model, never run on silicon) ported to illumos DDI/blkdev;
4. the RTL8153 USB NIC: this tree's USB NIC drivers are axf (ASIX), udmf (DM9601), upf and urf (RTL8150, the
   old 10/100 part), with no RTL8152/8153 driver. Whether the K3's DWC3 can use illumos xhci (uts/common/io/usb/hcd/xhci, built for x86 only) is not checked;
5. a load address for inetboot or unix above 0x102000000 (the K3's DRAM base; the same issue the uts payload solved).
Booting would be U-Boot `booti` from /boot (sda2), with SPI-NOR untouched (runbook §4). No flash is needed.

## What this means for src/riscv/uts

The uts kernel has real value: K3 facts measured off the board, AIA, the K3 drivers, and 11 recorded QEMU-vs-metal
divergences. As a base for a nix build host it would need ET_DYN + ld.so, an illumos-numbered syscall ABI, ZFS,
libc, gcc and SMF. That is the whole of what n-hys already has. The cheaper path is to carry the n-hys tree
forward (rebase onto solnix's gate pin) and move the K3-specific uts work into a `riscv64pf/k3` platform there.
That is a recommendation, and the maintainer decides it (ASK 1).

## ASK MAINTAINER

1. **Base for riscv64 solnix: n-hys illumos-gate (booted today) or our uts kernel?** Recommendation: n-hys for
   dixr, and port the uts K3 work into it. Carrying a 2021.07-based fork has a cost; rebasing it onto the solnix gate
   pin is the first big task.
2. **An EC2 host for the QEMU dixr.** Today's box was a burner c6i.8xlarge (terminated after this track). A standing
   dixr needs a host in the permanent account or on arnold/lixi. Which one? Note: arnold (Fedora 44, 12 threads,
   62 GB, /dev/kvm) can run it under TCG too. It has no qemu-system-riscv64 installed today.
3. **lixr is offline** (no ARP from floki or arnold since at least 16:56Z; tailscale offline). Is that expected?
   The board was not touched.
4. **The K3 itself: keep Bianbu, or flash?** Nothing in this plan needs a flash: the runbook's `booti` from /boot
   leaves SPI-NOR alone. Running the QEMU dixr on the K3 under Bianbu (or KVM, if Bianbu's kernel has it for the
   `h` harts) also keeps Bianbu. No change is requested now.
5. **Infra:** the riscv64-solaris builder needs a `solnix-builder-<id>` short id, and recipes.tsv has 0 riscv64 rows
   (measured). Ask the infra team when stage 4 is near, not now.
6. **Upstream:** n-hys's author (Hayashi Naoyuki) was last active 2022-11. Contact him before we fork in earnest?

## Reproduce (on any x86_64 Linux with docker + qemu-system-misc; never floki)

```sh
git clone -b osport/v2021.07 --recursive https://github.com/n-hys/illumos-gate.git   # 3f7cd4cf, 3.6 GB
docker run --rm -u $(id -u):$(id -g) -e HOME=$HOME -v $PWD/illumos-gate:$HOME/illumos-gate -v $PWD/data:/data \
  -v $PWD/tmpsol:/tmp/solaris -v $PWD/build.sh:/build.sh:ro ghcr.io/n-hys/illumos-build:main /build.sh  # bank build.sh
sudo sh mkdisk.sh      # GPT + ZFS rpool, label path = the illumos bootpath (needs zfsutils-linux)
sh boot.sh b1 4 8G     # first boot imports SMF and reboots itself; second boot reaches login
python3 con.py ~/w/con-b1.sock script.txt   # drive the serial console (send/expect)
```
Or skip the build: `zstd -d disk-rv64-pristine.img.zst` from the bank plus `inetboot.bin` from the proto tarball
(`platform/SUNW,virt/inetboot.bin`).
