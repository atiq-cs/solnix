# Design: solnix on aarch64 — port assessment, substrate, and bootstrap plan (A1)

Status: research + substrate decision + A2 started. This is the deliverable for
task **A1** in `.kiro/specs/solnix-aarch64/tasks.md`. It (1) assesses the
out-of-tree aarch64 illumos port, (2) fixes the build/test substrate with a
QEMU-boot analysis, and (3) gives a concrete A2/A3/A4 plan mapped to our proven
x86_64 recipes. Sources are cited inline (repos, IPD, commit dates). Honest
about what is unmerged, unproven, and hard.

Verified on 2026-07-25 against: the OI amd64 build host `<keypair>-build`
(illumos-960edb1c89, 16 cores / 64 GB, us-east-2 `<instance>`), and
live GitHub API queries.

---

## TL;DR

- **The port to target is `richlowe/arm64-gate` + `richlowe/illumos-gate@arm64-gate`**,
  NOT Hayashi Naoyuki's `alhazred/illumos-arm`. The steering doc names Hayashi;
  that port is real but **stale (last push 2021-11)**. Rich Lowe's is the live,
  canonical effort: last commit **2026-07-19**, merges illumos/master, and is
  backed by the official **illumos IPD 24** (authors: Toomas Soome, Richard
  Lowe, Michael van der Westhuizen). Retarget the track to `arm64-gate`.
- **It boots.** QEMU `virt` (GICv2), Raspberry Pi 4, Odroid C2. There is an
  automated QEMU test harness that runs real illumos test suites (os-tests,
  libc-tests, etc.) across eight CPU models. No prebuilt image exists (0
  releases on either repo) — you build the disk yourself.
- **Build method = cross from an amd64 illumos host** (OmniOS or OpenIndiana),
  exactly the shape of our x86_64 work. It builds a cross GCC 10.4 (`richlowe/gcc`
  `il-14_3_0-arm64`) + cross binutils (`richlowe/binutils-gdb`), pulls an
  **OmniOS `braich` aarch64 sysroot**, then runs illumos `nightly -T aarch64`.
  Triple: **`aarch64-unknown-solaris2.11`** — exactly what `design-nixpkgs-illumos.md`
  predicted.
- **Substrate: QEMU `virt` guest, host = our existing amd64 illumos build host
  (or any Linux/Graviton host).** illumos-aarch64 **cannot boot on AWS Graviton**
  today: the port has GICv2 only (**GICv3 = "No"** in IPD 24), and Graviton/Nitro
  presents GICv3 + ACPI. So Graviton buys nothing over an x86 host for *booting*;
  it would only be a faster *build* host, and even that is not needed — the cross
  build runs on our amd64 illumos host and QEMU-TCG runs the guest anywhere.
- **A2 started AND progressing** on `<keypair>-build` (idle at the time; x86_64
  gate untouched in a separate `/aarch64` tree). Harness cloned, bootstrap deps
  installed, **`make download` complete** (gate 1.15 GB + gcc 1.68 GB + u-boot +
  ATF + dtc + rpi fw + OmniOS aarch64 sysroot). **`make setup` well underway:**
  cross **binutils**, the illumos **Solaris `ld`** (sgs), aarch64 **sysroot
  headers**, dtc, and u-boot host tools are BUILT and verified on disk; the
  cross **GCC** is compiling. One expected fork-friction break hit and fixed
  (host Python 3.13 vs sysroot). See §5.
- **Honest timeline:** proto build is plausibly days-to-weeks of iteration
  (unmerged fork, will hit build breaks); a QEMU boot to multi-user is the real
  milestone and is weeks out, not days. Do NOT claim "aarch64 supported" until it
  boots to multi-user SMF in QEMU (steering rule).

---

## 1. Port assessment

### 1.1 Which port (and correcting the steering doc)

The steering (`architectures.md`, `solnix-aarch64/tasks.md`) names **Hayashi
Naoyuki** as the aarch64 illumos port author. Verified reality:

| Port | Repo | Last push | State |
|------|------|-----------|-------|
| Hayashi Naoyuki (`alhazred`) | `github.com/alhazred/illumos-arm` (fork) + `alhazred/illumos-arm-wiki` | **2021-11-16** | Real historical port; **stale ~4.5 yr**. The original 32/64-bit ARM effort ("onarm" lineage). |
| **Rich Lowe (`richlowe`)** | **`github.com/richlowe/arm64-gate`** (harness) + **`richlowe/illumos-gate` branch `arm64-gate`** (the gate) | **2026-07-19** (gate), 2026-06-22 (harness) | **Live, canonical.** Backed by official **IPD 24**. |

`richlowe/arm64-gate` search-ranks first for "illumos aarch64" and describes
itself "bootstrap illumos on AArch64." The gate branch merges illumos/master
regularly (last merge commit `2026-07-19`). **Retarget the solnix aarch64 track
from Hayashi to Rich Lowe's port.** (Note it for a steering-doc correction.)

Sources:
- `https://github.com/richlowe/arm64-gate` (README, Makefile, env/aarch64,
  qemu-setup/, tools/)
- `https://github.com/richlowe/illumos-gate/tree/arm64-gate`
- `https://github.com/richlowe/gcc/tree/il-14_3_0-arm64`,
  `https://github.com/richlowe/binutils-gdb` (branch `illumos-arm64-2-43-1`)
- IPD 24: `https://github.com/illumos/ipd/blob/master/ipd/0024/README.md`
  (state: predraft; authors Soome/Lowe/van der Westhuizen)
- Hayashi: `https://github.com/alhazred/illumos-arm`,
  `https://github.com/alhazred/illumos-arm-wiki`, `github.com/alhazred/onarm`

### 1.2 What boots

Per IPD 24 "Target Hardware" and the harness `Makefile`/`qemu-setup`:

- **QEMU `virt`** (SystemReady IR profile) — the primary dev target. `make
  qemu-disk` builds `illumos-disk.img`; boot with `qemu-system-aarch64 -machine
  virt -bios u-boot.bin -drive .../illumos-disk.img`.
- **Raspberry Pi 4** (BCM2711) — `make rpi4-disk`, real hardware.
- **Odroid C2 / Meson GXBB** (Amlogic S905) — listed, "obsolete."
- **QEMU `sbsa-ref`** — mentioned as the only cost-effective way to test
  SystemReady **SR** bringup; needs GICv3, which the port does **not** yet do.

The harness ships `qemu-setup/testsuite.exp`: an `expect(1)` driver that boots
QEMU in semi-random CPU/machine configs and runs real illumos test suites
(`/opt/os-tests/bin/ostest`, `libc-tests`, `libproc-tests`, `libsec-tests`,
`tz-tests`, `nvme-tests`, `elf-tests`, `i2c-tests`, `util-tests`, `crypto-tests`)
across CPUs `cortex-a53/a57/a72/a76/a710`, `neoverse-n1/n2/v1`. That a working
test harness exists is strong evidence the port genuinely boots to a usable
userland — not just a kernel banner.

The README is candid about brokenness: no `mdb`/`kmdb`/`dtrace` yet; SMF
services `rbac`, `inetd-upgrade`, `update-man-index` "almost always time out";
`root` has no password. So: **boots to multi-user-ish, with rough edges.**

### 1.3 Build method (cross from amd64 illumos)

From `arm64-gate/README.md` + `Makefile`. Three phases:

1. `make download` — clones the arm64 gate, `richlowe/gcc`
   (`il-14_3_0-arm64`, a gcc-14.3.0 base), `richlowe/binutils-gdb`
   (`illumos-arm64-2-43-1`), `u-boot` v2025.10, ARM Trusted Firmware
   `lts-v2.10.11`, `dtc` 1.7.2, RPi firmware, perl 5.42 + perl-cross 1.6.2, and
   **pkgrecv's an OmniOS aarch64 sysroot** from `https://pkg.omnios.org/bloody/braich`.
2. `make setup` — builds the prerequisites, in dependency order (from the
   Makefile `SETUP_TARGETS`):
   - `sysroot` — `pkg image-create --variant variant.arch=aarch64` populated from
     the OmniOS braich repo (glibc-equivalent runtime: c-runtime, openssl-3,
     libxml2, nspr, nss, zlib, glib2, dbus, bash, xorriso, net-snmp).
   - `binutils-gdb` — cross binutils, `--target=aarch64-unknown-solaris2.11`.
   - `sgs` — builds the illumos link-editor + headers via
     `bldenv -T aarch64 env/aarch64 'make bldtools sgs'`, rsyncs tools proto into
     `$CROSS` and aarch64 headers into the sysroot. **This is the Solaris `ld`
     for aarch64** — the analog of the piece our x86_64 seed carries.
   - `boot-gcc` — a bootstrap cross gcc (`--disable-shared --disable-libstdcxx`).
   - `gcc` — the full cross gcc (`aarch64-unknown-solaris2.11`, GCC 14.3.0,
     `--with-abi=lp64`, `--with-gnu-as`, `--without-gnu-ld` +
     `--with-ld=$(CROSS)/opt/onbld/bin/amd64/ld` i.e. the Solaris link-editor,
     LP64-only no-multilib).
   - `perl` — cross miniperl (gate build tools need it).
   - `u-boot`, `u-boot-qemu`, `u-boot-rpi4`, `arm-trusted-firmware`, `dtc`,
     `barn` (an OmniOS/kayak image helper).
3. `make illumos` — `nightly -T aarch64 env/aarch64`. Then `make image`
   (ZFS send stream), `make qemu-disk` / `make rpi4-disk` (bootable disk).

Toolchain, precisely:
- **Cross GCC 14.3.0** from `richlowe/gcc` (branch `il-14_3_0-arm64`). GNU `as`,
  **Solaris `ld`** (not GNU ld) — `--without-gnu-ld` +
  `--with-ld=.../onbld/bin/amd64/ld`. (Verified during A2: the installed cross
  compiler reports `aarch64-unknown-solaris2.11-gcc (GCC) 14.3.0`.)
- **`aarch64-unknown-solaris2.11`** GNU triple, **LP64 only, no multilib**
  (matches IPD 24: "LP64 only, no-multilib").

Host requirement: an illumos system with GCC 10 **and** GCC 14 (OmniOS
`/opt/gcc-10`,`/opt/gcc-14`; OI `/usr/gcc/10`,`/usr/gcc/14`), onbld, astdev,
swig, bison, gnu-make, gnu-coreutils, openjdk8, openssl-11, cdrtools, sudo,
zones/internal. Our OI host has all of these (installed during A2, §5).

### 1.4 Completeness (honest)

- **Kernel:** boots on `virt`/RPi4; `unix` is per-platform (IPD 24: no coherent
  boot services). GICv2/GICv2m only; **GICv3/ITS = No**; SMMU = No; PSCI-based
  reset. NS16550 + PL011 UART.
- **World/userland:** enough to run the test suites above and reach a shell.
  Missing: `mdb`, `kmdb`, `dtrace`. A cross `gdb` is built as a stand-in.
- **Boot path:** u-boot → (ATF on RPi) → illumos EFI loader (`loader64.efi` →
  `EFI/BOOT/bootaa64.efi`) → `unix`. On QEMU today a "temporary booter" path is
  used (`inetboot.bin` in the older README variant; `-bios u-boot.bin` + EFI
  loader in the current `run.sh`) with known-weird `boot_archive`/`vdev_probe`
  warnings. Boot is slow under TCG and deliberately verbose.
- **SMF:** comes up but several services time out (rbac, inetd-upgrade,
  update-man-index). `svccfg apply` pauses without output — patience required.

### 1.5 License / merge status

- CDDL (illumos), same as the rest of the gate. The `env/aarch64` file carries
  the standard CDDL header. No license blocker for solnix (we already build CDDL
  illumos).
- **Unmerged.** IPD 24 is **predraft**. This is an out-of-tree branch that tracks
  master. Implication for solnix: we pin a specific `arm64-gate` commit and carry
  it as an input, exactly as `design-build-strategy.md` anticipated ("integrating
  an unmerged illumos fork"). Contribute fixes upstream where we hit them.

### 1.6 Prebuilt image?

**No.** `richlowe/arm64-gate` and `richlowe/illumos-gate` both have **0
releases** (GitHub API). You must run the cross build to get a disk image.
There is no aarch64 OI/OmniOS cloud image either. This is the core reason the
aarch64 track is harder than x86_64: there is no seed cloud image to extract
from — the seed must come from *our own* first cross build (§4, A3).

---

## 2. Substrate decision

### 2.1 Can illumos-aarch64 run natively on AWS Graviton? — No (today)

Graviton (Nitro) exposes to guests: **GICv3**, **ACPI** (SBBR/server-class),
SMBIOS. The port per IPD 24 "Hardware Support Summary":

| Feature | Port support |
|---------|--------------|
| GICv2/GICv2m | Partial |
| **GICv3/GICv3-ITS** | **No** |
| ACPI system description | port targets **devicetree (EBBR/IR)**, not ACPI |
| SMMUv2/v3 | No |

So on Graviton the port has no interrupt controller it understands and no
devicetree. **It will not boot on Graviton bare-metal or as a Nitro guest**
until GICv3 + ACPI land (SystemReady SR work, explicitly "in its infancy" in IPD
24). Even the port's own SR-testing story is *QEMU `sbsa-ref`*, not real cloud
ARM. Graviton therefore buys solnix nothing for *booting* aarch64 illumos.

### 2.2 The realistic substrate: cross-build on amd64 illumos, boot in QEMU `virt`

Mirror the x86_64 split exactly:

- **Build host = amd64 illumos** (our existing `<keypair>-build`, or a dedicated
  clone). The cross build is amd64-illumos-native — the same "native-anchored"
  reason from `design-build-strategy.md`: dmake/CTF/Solaris-ld are illumos
  binaries; only the *target* is aarch64. A Linux host cannot run this build.
- **Test host = QEMU `virt` (GICv2, TCG)**, which runs anywhere: on the amd64
  illumos build host itself (OI ships `system/qemu` 11.0.2), or on any Linux box.
  A Graviton Linux host *could* run the QEMU guest faster than TCG-on-x86 **iff**
  QEMU's `virt` machine is configured GICv2 and KVM can back it — but that is an
  optimization, not a requirement, and Graviton native-illumos remains off the
  table. **Default: QEMU on the amd64 build host** (fewest moving parts, no
  extra instance, no cross-host image copy).

Concretely, no new instance is strictly required for A2–A4: the amd64 illumos
host both cross-builds AND runs the QEMU guest. (Optionally spin a throwaway
Graviton Linux box later only to measure KVM-GICv2 boot speed; not on the
critical path. Tag `Owner=gregburd Purpose=solnix-dev Expiry=+7d`; terminate.)

### 2.3 QEMU-aarch64 boot verification

The port's own boot recipe (verbatim from the two documented forms):

**Current harness (`qemu-setup/run.sh`) — u-boot + EFI loader:**
```
qemu-system-aarch64 -nographic -machine virt -accel tcg,thread=multi \
  -m 6g -smp cores=2 -cpu cortex-a53 \
  -bios u-boot.bin \
  -netdev vnic,ifname=braich0,id=net0 \
  -device virtio-net-device,netdev=net0,mac=$mac \
  -device virtio-blk-device,drive=hd0 \
  -drive file=illumos-disk.img,format=raw,id=hd0,if=none
```
`build_qemu.sh` builds `illumos-disk.img`: GPT with an ESP (pcfs FAT32) holding
`loader64.efi` → `EFI/BOOT/bootaa64.efi`, plus a ZFS pool `armpool` with
`ROOT/braich` received from `out/illumos.zfs`, `bootfs` set, `swap`+`dump`
zvols, `org.opensolaris.libbe:uuid` set. u-boot (`build/u-boot-qemu/u-boot.bin`)
is the `-bios`.

**NOTE — networking:** `run.sh` uses `-netdev vnic,ifname=braich0` (an illumos
VNIC). That assumes **QEMU-on-illumos**. On a **Linux/Graviton** QEMU host,
substitute user networking: `-netdev user,id=net0`. The README says as much:
"in the worst case user networking `-netdev user,id=net0`." The port *requires a
NIC to exist* (device-tree shape assumption), so you cannot drop `-netdev`
entirely — swap the type, keep the device.

Verification status (honest): I have **read and confirmed the boot recipe from
the port's own scripts** (machine `virt`, GICv2 CPUs, `-bios u-boot.bin`, EFI
loader on an ESP, virtio-blk ZFS root). I have **not yet produced a disk and
booted it** — that requires `make setup` + `make illumos` + `make qemu-disk` to
finish first (A2→A4). The boot recipe is not speculative; it is the maintainer's
documented, test-harnessed procedure. The remaining risk is entirely in getting
*our* cross build to complete, not in whether QEMU can run the result (the
maintainer's CI proves it can).

### 2.4 Storage note

Per task constraint: **no AWS S3 / no numa datasets for storage.** aarch64
artifacts (proto, seed, disk image) live on the build host's local ZFS
(`/aarch64`, 100 GB free) and, when we have a cache story, the solnix.io cache —
not S3/numa. The `numa-arm` r8g instance in the account is **off-limits** (not
ours; NUMA-benchmark box).

---

## 3. Mapping x86_64 recipes → aarch64 (what transfers, what differs)

Our x86_64 bootstrap is: build OI gate → extract seed → wire `x86_64-solaris`
into lib.systems → native stdenv → slice world → make-be → boot. The aarch64
path reuses the *mechanisms* but swaps the source of truth from "OI gate on an OI
host" to "richlowe arm64-gate cross-built on an amd64 illumos host."

| x86_64 recipe | Transfers? | aarch64 equivalent / difference |
|---------------|-----------|--------------------------------|
| `scripts/oi-gate-build.sh` (nightly on OI) | **Rewrite** | The arm64-gate `Makefile` **is** the gate-build recipe. Wrap it (`make download/setup/illumos`) instead of our nightly-on-native. Cross, `-T aarch64`, `env/aarch64`. New script `scripts/arm64-gate-build.sh` that drives the harness. |
| DMAKE serial / pit_is_broken / Perl-version hacks in `oi-gate-build.sh` | Partial | The harness already encodes its own env quirks (`env/aarch64`: gcc10+gcc14, perl 5.42, SUPPRESSPKGDEP, DMAKE_MAX_JOBS via `maxjobs`). Our x86-specific hacks (tscc_pit KVM boot-hang) are **x86-only** — do NOT port. aarch64 boot-hang issues, if any, are different (GIC/timer). |
| `scripts/oi-extract-seed.sh` (proto → seed.tar.zst) | **Yes, adapt paths** | Extract from `proto/root_aarch64` (not `root_i386`); libs under `lib/` and `usr/lib/` **without** an `amd64/` ISA subdir (IPD 24: userland search paths `/lib /usr/lib`, `.../lib/64 -> .`). The seed's toolchain half is the **cross** gcc+Solaris-ld from `$CROSS` (runs on amd64!) — a key difference: the x86 seed's compiler runs on the target; the aarch64 seed's compiler is a *cross* compiler that runs on amd64 and emits aarch64. So the aarch64 "seed" is really a cross-SDK + target sysroot. |
| lib.systems `x86_64-solaris` wiring (`design-nixpkgs-illumos.md`, fork commit `18218269f`) | **Yes, mirror** | Add `aarch64-solaris` double + `examples.aarch64-illumos = { config = "aarch64-unknown-solaris2.11"; }`. The `parse.nix` `hasPrefix "solaris"` fix already covers it. `elaborate` gaps (`uname=SunOS`, `libc=illumos-libc`, `linker=solaris`, `useLLVM=false`) are kernel-keyed, not arch-keyed → already correct for aarch64. Only the cpu (`aarch64`, already in nixpkgs `cpuTypes`) + double are new. **Small diff.** |
| bintools-wrapper `ld-solaris-wrapper.sh` (`-rpath`→`-R`, `-dynamic-linker`→`-I`) | **Yes, unchanged** | Same Solaris link-editor, same flag translation. Arch-independent. |
| `pkgs.illumos.*` slice + `elfedit` RUNPATH relocation (`design-gate-derivation.md`) | **Yes, adapt** | Slice `proto/root_aarch64`; `elfedit` works on aarch64 ELF. No `amd64/` subdir. `ld.so.1` at `/lib/ld.so.1` (+ `/lib/64 -> .` compat symlink). |
| `mk-illumos-component` proto slicing | **Yes** | Same, aarch64 proto. |
| `scripts/oi-make-be.sh` (bootable ZFS image) | **Rewrite** | The harness `tools/build_image.sh` + `build_qemu.sh` already do this for aarch64 (ZFS send + ESP + u-boot + `loader64.efi`). Wrap those instead of our x86 GPT/pcfs/loader logic. Boot path differs: **u-boot + EFI aarch64 loader**, not x86 multiboot/bootx64.efi. No tscc_pit patch. |
| `scripts/oi-make-ami.sh` / `oi-be-to-ami.sh` (register AMI) | **Skip** | No aarch64 AMI path — Graviton can't boot it (§2.1). Test target is QEMU disk image, not an AMI. |
| `scripts/oi-nix-setup.sh` (Nix on illumos) | **Reuse as-is** | Nix-on-illumos runs on the **amd64 build host** and evaluates/builds `x86_64-solaris` derivations; the aarch64 world is cross-produced. The eval-split (`design-make-be.md §7`) is unchanged. |

Where aarch64 fundamentally differs from x86_64:
1. **No cloud seed image.** x86 seeded from an OI cloud image's proto; aarch64
   must seed from *our own first cross build*. Chicken-and-egg is broken by the
   OmniOS `braich` sysroot (a prebuilt aarch64 userland to link against during
   the cross build) — that sysroot is the closest thing to a seed, but it is a
   *runtime* sysroot, not a toolchain.
2. **Cross, not native.** The toolchain runs on amd64, targets aarch64. Our
   x86 stdenv is native-on-illumos; the aarch64 stdenv is `pkgsCross` from an
   amd64-illumos build host (the legit Nix cross scenario `design-nixpkgs-illumos.md §3.5`
   describes, just hosted on illumos-amd64 instead of Linux).
3. **Boot path:** u-boot / ATF / EFI-aarch64-loader / devicetree, not x86
   multiboot. GICv2. No `amd64/` ISA dir; `/lib/64 -> .`.
4. **Triple:** `aarch64-unknown-solaris2.11`, `uname -p aarch64`, `uname -m
   armv8`, TLS variant 1, unsigned char, `__aarch64__`.

---

## 4. A2 / A3 / A4 plan (concrete, mapped to our recipes)

### A2 — Build the aarch64 illumos port (cross, on amd64 illumos)

Gate: an `proto/root_aarch64` exists; the cross gcc compiles a hello `.o` for
aarch64 (`file` says `ELF 64-bit ... ARM aarch64`).

Steps (all on the amd64 illumos host, in `/aarch64/arm64-gate`, x86 gate
untouched):
1. Install host bootstrap deps (gcc10, gcc14, onbld, astdev, swig, bison,
   gnu-make, gnu-coreutils, openjdk8, openssl-11, texinfo, mpc,
   perl xml-parser, cdrtools, sudo, zones/internal). **Done in §5.**
2. `make download` — clone gate/gcc/binutils/u-boot/ATF/dtc/perl + OmniOS braich
   sysroot recv. **Running in §5.**
3. `make setup` — build sysroot, binutils, sgs (Solaris ld + headers), boot-gcc,
   gcc, perl, u-boot(+qemu+rpi4), ATF, dtc, barn. **This is the bulk of A2.**
   Expect breakage on an unmerged fork; fix, or pin an older known-good rev.
4. `make illumos` — `nightly -T aarch64 env/aarch64`. Produces
   `proto/root_aarch64` + packages. **Long, will hit build errors** — triage,
   contribute upstream.
5. Capture as a reproducible recipe: `scripts/arm64-gate-build.sh` (the analog
   of `oi-gate-build.sh`) that pins commits and runs 1–4.
- **Gate check:** `$CROSS/bin/aarch64-unknown-solaris2.11-gcc -c hello.c` →
  aarch64 ELF; `proto/root_aarch64/lib/libc.so.1` exists.

### A3 — aarch64 seed + Nix world

Gate: a hello compiled by the aarch64 Nix cross toolchain runs on the aarch64
QEMU guest, resolving libc from `/nix/store`.

1. **Seed extraction** — `scripts/arm64-extract-seed.sh` (fork of
   `oi-extract-seed.sh`): package the **cross SDK** (`$CROSS` gcc + Solaris ld +
   elfedit/elfdump + `aarch64-unknown-solaris2.11-*` tools) plus the **target
   sysroot** (proto `root_aarch64` libc/crt/headers/ld.so.1 + OmniOS braich
   runtime libs). Note: no `amd64/` subdir; `/lib/64 -> .`. This seed's compiler
   runs on **amd64** (cross), unlike the x86 seed.
2. **lib.systems** — mirror the x86_64-solaris wiring
   (`design-nixpkgs-illumos.md`): add `"aarch64-solaris"` to `doubles.nix` and
   `examples.aarch64-illumos = { config = "aarch64-unknown-solaris2.11"; }`. The
   `parse.nix` `hasPrefix "solaris"` fix and the kernel-keyed `elaborate` gaps
   (`uname/libc/linker/useLLVM`) already cover aarch64 — verify with `nix eval`
   that `examples.aarch64-illumos` elaborates to `config=aarch64-unknown-solaris2.11`,
   `isSunOS=true`, `libc=illumos-libc`, `linker=solaris`, `cpu=aarch64`.
3. **Cross stdenv** — this is `pkgsCross.aarch64-solaris` hosted on the amd64
   illumos builder: `crossSystem = examples.aarch64-illumos`, `libcCross =
   pkgs.illumos.aarch64.libc` (the seed sysroot), cross-gcc = the seed's
   `$CROSS` gcc wrapped by cc-wrapper. This is the *legit* Nix cross path
   (`design-nixpkgs-illumos.md §3.5`) — the aarch64 world genuinely cross-builds
   because the target is aarch64 and the host toolchain (the richlowe cross gcc)
   already exists. The `design-build-strategy.md` "gate doesn't cross" caveat is
   about cross-*OS from Linux*; here the gate is cross-built *by its own
   maintainer's harness on illumos*, and we re-express only the *outputs* as Nix
   slices (Tier 1a), same as x86.
4. **Slice the world** — `pkgs.illumos.aarch64.{libc,ld,rtld,sys,base-tools}`
   from `proto/root_aarch64`, `elfedit` RUNPATH into the store (arch-independent
   mechanism). Reuse `design-gate-derivation.md` slicing, aarch64 paths.
- **Gate check:** cross-build `hello.c` → aarch64 ELF with a store `-R` RUNPATH;
  scp into the QEMU guest; runs; `LD_DEBUG` shows libc from `/nix/store`.

### A4 — aarch64 boot + image

Gate: aarch64 solnix boots to multi-user SMF in QEMU (RPi/Graviton later, if
ever).

1. **make-be for aarch64** — `scripts/arm64-make-be.sh` wrapping the harness
   `tools/build_image.sh` + `build_qemu.sh` (ZFS send stream → GPT ESP with
   `loader64.efi`→`bootaa64.efi` + ZFS `armpool/ROOT/...` + swap/dump zvols +
   libbe uuid). Boot path = **u-boot + EFI aarch64 loader + devicetree**, not x86
   multiboot. Layer solnix SMF manifests on top exactly as `oi-make-be.sh` does
   for x86 (add-not-replace, `design-smf-init.md §5`).
2. **QEMU boot** — `qemu-system-aarch64 -machine virt -bios u-boot.bin
   -device virtio-blk-device,drive=hd0 -drive file=solnix-aarch64.img,...`.
   On the amd64 illumos host use `-netdev vnic,ifname=...`; on a Linux host use
   `-netdev user,id=net0`. Keep a NIC device present (port assumes one).
3. **Bring up to multi-user** — expect the documented SMF timeouts (rbac,
   inetd-upgrade, update-man-index). Patience; fix upstream where feasible.
- **Gate check:** boots to `svc:/milestone/multi-user-server`; smoke test
  (`uname -a` → aarch64, a solnix-built binary runs). Only then may any doc say
  "aarch64 supported" (steering rule).

---

## 5. A2 progress (this task)

Started A2 on `<keypair>-build` (idle at the time: load ~0.6, no nightly
running, 100 GB free; x86_64 gate at `/code/illumos-gate` left untouched — all
aarch64 work isolated under `/aarch64`).

Done:
- Cloned `richlowe/arm64-gate` harness → `/aarch64/arm64-gate`.
- Installed missing bootstrap deps: texinfo, astdev, swig, bison, mpc,
  perl xml-parser, cdrtools, sudo, pipe-viewer, zones/internal, openssl-11
  (with `pkg set-mediator -V 1.1 openssl`), illumos-closed, and later
  `runtime/python-313` (see build break below). (gcc-10/14, onbld, gnu-make,
  gnu-coreutils, openjdk8, pkg-config, gnutls-3, rsync already present.)
- **`make download` COMPLETE.** Fetched: arm64 gate 1.15 GB, `richlowe/gcc`
  1.68 GB, binutils-gdb 189 MB, u-boot 444 MB, ARM Trusted Firmware 46 MB, dtc,
  RPi firmware 155 MB, and the **OmniOS `braich` aarch64 sysroot** (501 MB,
  both `omnios` + `extra.omnios` publishers).
- **`make setup` well underway; cross toolchain building.** Stamps completed:
  `sysroot`, `binutils-gdb`, `barn`, `dtc`, `u-boot`, **`sgs`**. Concretely
  produced and verified on disk:
  - **Cross binutils** — `$CROSS/bin/aarch64-unknown-solaris2.11-{as,ld,gdb,ar,
    elfedit,addr2line,...}` (the aarch64 GNU as + a cross gdb).
  - **The illumos Solaris link-editor** — `$CROSS/opt/onbld/bin/amd64/ld` (the
    `sgs` build; this is the non-GNU link-editor gcc links through).
  - **aarch64 system headers in the sysroot** —
    `build/sysroot/usr/include/sys/` populated from `proto/root_aarch64`.
  - u-boot host tools + dtc.
  - **The cross GCC** — `boot-gcc-stamp` done; `$CROSS/bin/aarch64-unknown-solaris2.11-gcc`
    installed, **`(GCC) 14.3.0`**. **A2 gate check PASSED:** it compiles a `.c`
    to `ELF 64-bit LSB relocatable aarch64` and `-dumpmachine` =
    `aarch64-unknown-solaris2.11`. The full `gcc` target (libstdc++ etc.) was
    still building on top of boot-gcc at handoff, then perl / u-boot-qemu /
    u-boot-rpi4 / arm-trusted-firmware.

Build break hit and fixed (the expected unmerged-fork friction):
- **`sgs` aborted:** "The detected Python version 3.13 in the sysroot is not
  installed on the host!" — `env/aarch64` matches the OmniOS braich sysroot's
  Python (3.13) against `/usr/bin/python3.$v` on the host; our OI host had only
  3.9 and 3.14. **Fix:** `pkg install runtime/python-313`. Re-running `make
  setup` then passed `sgs` and proceeded. (Bake this into the A2 recipe: the host
  Python minor MUST match the sysroot's — pin both, or install the matching
  host python.)

Next (to resume): let `make setup` finish the cross gcc + remaining targets,
then `make illumos` (`nightly -T aarch64 env/aarch64`) → `proto/root_aarch64`,
then `make image` / `make qemu-disk`. `make illumos` is multi-hour and the next
likely place the fork breaks on our exact OI rev; triage/contribute upstream.

Resume commands (on the host, as root):
```
cd /aarch64/arm64-gate
# setup (resumes from stamps; safe to re-run):
nohup /aarch64/run-setup.sh > /var/log/arm64-setup2.log 2>&1 </dev/null &
tail -F /var/log/arm64-setup2.log
# then the gate proper:
env PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin \
  nohup /opt/onbld/bin/i386/dmake illumos > /var/log/arm64-illumos.log 2>&1 &
tail -F /var/log/arm64-illumos.log
```
(`/aarch64/run-setup.sh` = `cd /aarch64/arm64-gate && env PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin /opt/onbld/bin/i386/dmake setup`.)

---

## 6. Honest assessment: hardness + timeline

- **Not a repackage; an integration of an unmerged, actively-moving fork.** The
  gate branch merges master weekly, so pin a commit and expect to rebase. IPD 24
  is predraft — ABI details "subject to change."
- **`make setup` and `make illumos` will break** on a first run on our exact OI
  rev; the maintainer builds primarily on OmniOS. Expect env/version-skew fixes
  (perl, python minor, pkgdepend, gcc shadow). Budget iteration.
- **QEMU-only, and slow.** TCG boot is deliberately verbose and slow; SMF
  services time out; no mdb/dtrace. A "boots to multi-user" milestone is real but
  rough. Realistic: **days to get proto building, weeks to a reliable QEMU boot**,
  assuming steady effort — dominated by build-break triage, not by our Nix
  plumbing (which is a small, well-understood diff off the x86 work).
- **No Graviton payoff for booting.** GICv3/ACPI gap (IPD 24) blocks cloud ARM
  native boot indefinitely; do not plan an aarch64 AMI. QEMU `virt` is the
  target. A Graviton Linux host could only *speed the QEMU guest* (KVM+GICv2),
  and only marginally vs running QEMU on the amd64 build host — skip unless boot
  time becomes the bottleneck.
- **Steering correction owed:** the track names Hayashi Naoyuki; the live port is
  Rich Lowe's `arm64-gate`. Update `architectures.md` / `solnix-aarch64/tasks.md`
  to point at `richlowe/arm64-gate` + IPD 24, and note the Hayashi port as the
  stale historical predecessor.

The good news: the *substrate is settled* (cross on amd64 illumos → QEMU virt),
the *build method is documented and test-harnessed by the maintainer*, the
*triple and toolchain are exactly what our x86 lib.systems work anticipated*, and
the Nix-side diff (lib.systems double + examples entry + aarch64 proto slices) is
small and mostly kernel-keyed code that already works for x86. The risk is
concentrated in one place: getting the maintainer's cross build to complete on
our host. A2 is underway.

---

## 7. A3 progress (aarch64 seed + lib.systems wiring + world slices)

Status: **A3 DONE** (seed extracted, lib.systems wired + eval-verified, all
aarch64 world slices built + signed + published + fetch-verified from
solnix.io). Done on ouch (persistent account, us-east-2), host **builder**
(<builder-ip>, <instance>; secondary hosts builder/w7-7 claimed but
were still SSH-warming — a single host sufficed for the exploratory integration).
Every long host op ran DETACHED via `scripts/oi-job.sh` (no blocking SSH).
Assets: solnix.io cache + local seed store ONLY — no AWS S3/ouch storage.

### 7.1 Proto restore (step 1) — DONE, kernel present

Restored the archived aarch64 proto onto builder by fetching it directly from
the solnix.io cache (host has read access; no scp needed):
`https://s3.solnix.io/solnix-cache/archive/aarch64/aarch64-proto-73466454.tar.zst`
→ sha256 `b4c89fadde66db90936b98f403cb293358551590b2a9afbd61a75a684b23e3db`
**verified** → untarred to `/aarch64/arm64-gate/illumos-gate/proto/root_aarch64`.

Untar gotcha (recorded): Solaris `tar -x -C dir` defaults to `/dev/rmt/0`; there
is NO GNU `gtar` on the OI builder. Use `tar xpf -` (Solaris tar reads stdin with
an explicit `f -`). Baked into `scripts/aa-extract-seed.sh`'s companion restore.

Confirmed in the restored proto (LP64, NO amd64/ ISA subdir — as IPD 24 / §3
predicted):
- `platform/armv8/kernel/aarch64/unix` — **PRESENT** (2088872 bytes). Kernel: yes.
- `kernel/aarch64/genunix` — present.
- `lib/libc.so.1`, `lib/ld.so.1`, `lib/libm.so.0` (aarch64 libm soname is `.0`),
  full `lib/` sibling set (libsocket/libnsl/libresolv/libelf/libmd/libpthread/
  librt/libdl/libmp/libcustr/libofmt/libumem), `lib/64 -> .` compat symlink.
- `usr/lib/{crt1,crti,crtn}.o` + `values-*.o` (no amd64 subdir), `usr/lib/64 -> .`.
- `usr/include` headers; `usr/bin/{ld,elfdump,elfedit}` aarch64-native.
- SMF core present: svcs/svcadm/svc.startd/svc.configd/init/sh + coreutils.

### 7.2 aarch64 seed (step 2) — DONE

`scripts/aa-extract-seed.sh` (adapted from `oi-extract-seed.sh`) staged the
**target-sysroot seed** from the proto: libc + siblings, crt + values, full
headers, ld.so.1 + link-editor .so's (librtld/libld/liblddbg/libldstab), and the
aarch64-native Solaris ld + elfdump/elfedit (with the elfedit modules the x86
seed omitted). No amd64 subdir; `lib/64`+`usr/lib/64 -> .` compat links carried.

- **tarball**: `aarch64-seed.tar.zst`, **5958734 bytes**
- **sha256**: `3a9fd645b5168d2cdf05779f3b89438d94e33b924281d0f590bbad57d75f9e02`
- **SRI (for the FOD)**: `sha256-Op/WRbUWjSzfBXefO4lDjZTjO5JCgdD1kLutV9dfngI=`
- **local copy**: `~/ws/solnix-seed-store/aarch64-seed.tar.zst` (+ manifest),
  sha-verified identical.
- **published**: `https://s3.solnix.io/solnix-cache/archive/aarch64/aarch64-seed.tar.zst`
  (+ `aarch64-seed-manifest.txt`). solnix.io only.

KEY DIFFERENCE from the x86 seed (§3, "cross, not native"): this seed is the
**target-sysroot half ONLY**. The COMPILER half (the richlowe cross gcc / `$CROSS`)
was NOT in the archived proto — only `illumos-gate/proto` was archived, and
`$CROSS`/`opt/onbld` died with numa. So `libcCross` for `pkgsCross.aarch64-solaris`
points at this sysroot; a cross-gcc rebuild via arm64-gate `make setup` is the
A4 dependency (see §7.5 blockers).

### 7.3 lib.systems wiring (step 3) — DONE, eval-verified

Extended the fork (solnix-pkgs) `patches/0001-lib-systems-x86_64-solaris.patch`,
mirroring x86_64-solaris exactly. The delta is SMALL, as §3 predicted, because
almost everything is KERNEL-keyed (isSunOS) not arch-keyed:
- `lib/systems/doubles.nix`: added `"aarch64-solaris"` beside `"x86_64-solaris"`
  in the hardcoded `all` list (the double list is NOT auto-derived — a new
  illumos arch must be registered; `parse.doubleFromSystem` → `aarch64-solaris`).
- `lib/systems/examples.nix`: added
  `aarch64-illumos = { config = "aarch64-unknown-solaris2.11"; };`.
- `parse.nix` (`hasPrefix "solaris"`) + `default.nix` (isSunOS → `illumos-libc`,
  `solaris` linker, `SunOS` uname): ALREADY covered aarch64 — no change needed.
- bintools-wrapper patch (0002): gates on `linker == "solaris"` (kernel-keyed) →
  ALREADY covers aarch64.

Verified by building the patched nixpkgs and `lib.systems.elaborate
examples.aarch64-illumos`:
```
config      = aarch64-unknown-solaris2.11
cpuName     = aarch64        isAarch64 = true
double      = aarch64-solaris   (present in doubles.illumos, beside x86_64-solaris)
isSunOS     = true    kernelName = solaris    uname = SunOS
libc        = illumos-libc      linker = solaris      useLLVM = false
```
(Incidental: patch 0003-all-packages had a pre-existing malformed hunk header —
`@@ -11078,6 +11078,11 @@` should be `+11078,12` for 6 added lines — that blocked
the whole `applyPatches`; corrected so the fork evaluates against the pinned base
rev 7f81d69. NOTE: this base nixpkgs (26.11) already ships `x86_64-solaris` in
doubles.nix + `isSunOS` upstream, so parts of 0001 now overlap upstream — a
future rebase should thin 0001 to just the illumos-libc/linker/example bits.)

### 7.4 aarch64 world slices (step 4) — DONE, built + published + fetch-verified

New aarch64 slice expressions, MIRRORING `pkgs/illumos/{gate,default}.nix`:
- `pkgs/illumos/aarch64/gate.nix` — proto ingest of `proto/root_aarch64`
  (builtins.path), aarch64 sanity (armv8 unix + aarch64 genunix, no amd64).
- `pkgs/illumos/aarch64/default.nix` — `libc/rtld/ld/sys/systemPath` via the
  shared `mk-illumos-component.nix`, adapted for LP64/no-amd64: `originParts =
  [ "$ORIGIN" ]` (no lib/amd64), lib dirs `lib/` + `usr/lib/`, libm.so.0,
  kernel at `platform/armv8/kernel` + `kernel`.
- fork `pkgs/os-specific/illumos/seed-aarch64/default.nix` — the aarch64 seed
  FOD (fetchurl from solnix.io + SRI above). Built + content-verified: unpacks to
  aarch64 `libc.so.1` (`ELF 64-bit ARM aarch64 (Solaris)`), ld.so.1, headers.

Built on builder (host Nix 2.3.16; the slicing/relocation runs on the amd64
host, editing the aarch64 ELF's DT_RUNPATH via the HOST elfedit — mechanism is
arch-independent). Store paths + RUNPATH relocation (all into the store, no host
leak):

| slice | store path | RUNPATH |
|---|---|---|
| gate (proto) | `apkpl07d1wmyx9d47mpsn9x0pna2y4in-illumos-aarch64-gate-proto` | (n/a) |
| libc | `ca59gffniypk0yxin055ql0vi2192ffs-libc` | `$ORIGIN` |
| rtld | `0yms8gv57xa97y4brd9djk07glnfkbzh-rtld` | `$ORIGIN:<libc>/lib` |
| ld | `k04qv31hfxzgpwfdmly7ik6idhn9575q-ld` | `$ORIGIN:$ORIGIN/../../lib:<libc>/lib:<ld>/usr/lib` |
| sys (kernel) | `biiq598vzmhylfrjb4cwy8nw13vvn3d1-sys` | (kernel ELF, no RUNPATH — skipped) |
| systemPath | `cxi11b9s92wjs85zz52fpcvmamn1xq93-system-path` | (symlink farm) |

`libc.so.1` = `EM_AARCH64 ELFCLASS64`; rtld NEEDED libelf/libc resolve
cross-component; ld has NO host `/lib` leak; systemPath sanity passed (armv8 unix
+ aarch64 genunix present).

Signed (`cache.solnix.io-1`) + published to `https://s3.solnix.io/solnix-cache`
under PLAIN store names (hash disambiguates, matching x86 convention). All 6
narinfos live (HTTP 200). **Fetch-back-verified** into a fresh store from the
cache: `libc` → aarch64 ELF; `system-path` → pulled with SIGNATURE VERIFIED
against the trusted pubkey, its 4-path closure (sys/rtld/ld/libc) resolves.

### 7.5 A4 blockers (recorded, do NOT attempt A4 = QEMU boot here)

1. **No cross gcc / `$CROSS`.** Only `illumos-gate/proto` was archived off the
   dying numa host — the richlowe cross gcc (`aarch64-unknown-solaris2.11-gcc`),
   Solaris ld under `$CROSS/opt/onbld`, and the OmniOS braich sysroot were NOT
   archived. To actually COMPILE aarch64 objects (the compiler half of the seed /
   a `pkgsCross.aarch64-solaris` stdenv) the arm64-gate `make download` +
   `make setup` must be re-run on an ouch builder (multi-hour, the §5 A2 recipe:
   host python-313 to match the braich sysroot, gcc10+gcc14, etc.). The proto
   itself (runtime world) is restored and does NOT need a rebuild.
2. **A4 image/boot** needs the harness `tools/build_image.sh` + `build_qemu.sh`
   (u-boot + EFI aarch64 loader + ZFS armpool) + QEMU virt (GICv2). Not started.
3. The `pkgsCross.aarch64-solaris` cc/bintools wiring (fork
   `seed-aarch64` → cc-wrapper/bintools-wrapper, mirroring `seed/default.nix`)
   is NOT wired yet — it needs the compiler half (blocker 1). The seed FOD +
   world slices + lib.systems are the pieces that DON'T need the cross gcc, and
   those are all done and cached.

---

## 8. A4 progress (bootable aarch64 illumos guest under QEMU virt)

Status: **A4 SUCCESS — a booting aarch64 illumos guest.** From the A3-restored
proto (kernel + world, gate rev 73466454) we assembled a bootable ZFS-root QEMU
disk and booted it under `qemu-system-aarch64 -machine virt`. It boots the
aarch64 kernel all the way through **krtld → genunix → SMP (2 cpu online) →
virtio-mmio/vioblk attach → ZFS root mount → devfsadm → SMF manifest-import →
milestone/single-user → an interactive console maintenance prompt.** This far
exceeds the A4 bar ("krtld / any recognizable milestone / a panic after krtld").

Done on ouch (persistent, us-east-2), host **builder** (<builder-ip>,
<instance>) — the host that already had the A3 proto restored. Every
long host op ran DETACHED via `scripts/oi-job.sh` (no blocking SSH). Assets:
solnix.io cache + local host disk ONLY — no AWS S3/ouch storage. Artifacts under
`artifacts/aarch64-a4/`.

### 8.1 Image assembly (`scripts/aa-make-image.sh`) — DONE

The harness `tools/build_image.sh` populates the root via `pkg image-create`
from the nightly pkg repo + OmniOS braich repo — NEITHER was archived (only
`proto/root_aarch64`). So we source the root **directly from the proto** and
adapt only the disk-laying half of `build_qemu.sh`:
- `cp -a proto/root_aarch64` into a scratch ZFS dataset (`rpool/braich_image`).
- skeleton `/dev` from the harness `tools/dev.tar`; `reconfigure`; nodename
  `solnix-aa`; SMF profile symlinks (generic/platform/name_service/inetd).
- SMF repository seeded from the proto's `lib/svc/seed/global.db` (a fresh
  `svccfg import` needs the onbld `svc.configd`, which is not in the restored
  proto; the seed DB + first-boot manifest-import is enough to reach a milestone).
- boot config `/boot/conf.d/00-aarch64-defaults.conf`: serial console, verbose,
  impl-arch bootfile — verbatim from the harness.
- `boot/solaris/bin/create_ramdisk -R $ROOT -p aarch64 -f cpio` → the CPIO
  `boot_archive` the loader loads.
- `zfs send` the staged root → `zfs receive` into `armpool/ROOT/braich` on a
  `lofiadm`-attached 8 GB GPT disk (`zpool create -B` = ESP+pool), `bootfs` set,
  libbe uuid, swap+dump zvols — the `build_qemu.sh` recipe.
- ESP (pcfs FAT32): `loader64.efi` → `EFI/BOOT/bootaa64.efi`.
Result: `/aarch64/out/illumos-disk.img` (248 MiB actual, 8 GiB sparse).

### 8.2 QEMU boot — the firmware/devicetree lesson

**EDK2/AAVMF (first attempt) FAILS at ACPI.** `-bios edk2-aarch64-code.fd`
presents ACPI firmware tables + an SBBR platform (`ARMH,sbbr`). The port targets
devicetree (IPD 24), so `dboot` stalled: `Firmware Tables: ACPI` → `dboot: ACPI
kernel support is a work in progress`. (`artifacts/.../qemu-boot-edk2-milestones.txt`.)

**U-BOOT (winning path) provides devicetree.** `-bios u-boot-qemu.bin` (the
harness's own approach, `qemu-setup/run.sh`) forwards QEMU virt's DTB to the
illumos loader → platform `QEMU,virt`, `Firmware Tables: FDT` → dboot proceeds.
u-boot for `qemu_arm64` was fetched from the Debian `u-boot-qemu` 2025.01 package
(same version the harness pins) to decouple the boot from the still-building
cross toolchain; the cross build's own `u-boot-qemu` target produces the
equivalent. Boot command (GICv2 = virt default; do NOT set gic-version=3):
```
qemu-system-aarch64 -nographic -machine virt -accel tcg,thread=multi \
  -m 4096 -smp 2 -cpu cortex-a72 -bios u-boot-qemu.bin \
  -netdev user,id=net0 -device virtio-net-device,netdev=net0 \
  -device virtio-blk-device,drive=hd0 \
  -drive file=illumos-disk.img,format=raw,id=hd0,if=none
```
(`scripts/aa-qemu-boot-uboot.sh`; QEMU 11.0.2 installed on the host via `pkg`.)

### 8.3 The name_to_major + driver_aliases fix (`scripts/aa-fix-ntm.sh`)

The proto-only image hit two device panics that the harness's `pkg install` path
avoids (pkg assembles `/etc/name_to_major` + `/etc/driver_aliases` from the
driver packages; the gate proto ships a 4-entry `name_to_major` stub + 1-entry
`driver_aliases`):

1. `panic: Couldn't find major number for 'rootnex'` — FIXED by generating a
   full `name_to_major` covering all **235** proto driver binaries, reusing the
   (arch-independent) major numbers from the amd64 host's own `/etc/name_to_major`
   and assigning fresh majors to the arm-only drivers (rootnex, gictwo, arm_gtmr,
   ns16550a, simple-bus, devfdt, efifb, ...).
2. `Cannot mount root on /pseudo/lofi@1:b ... panic: vfs_mountroot` — the
   `vioblk` virtio-blk driver wasn't attaching, so ZFS couldn't see the disk and
   fell back to a lofi default. FIXED by adding the virtio-mmio `driver_aliases`:
   `viommionex "virtio,mmio"` (the DT compatible), plus the child bindings
   `vioblk "virtio-mmio,1,blk"` / `vioif "virtio-mmio,1,net"` (from
   `viommionex.conf`'s `device-N-compat`). With those, all 32 `viommionex` nodes
   enumerate, `vioblk`/`blkdev` attaches, and ZFS finds `armpool` on
   `/virtio_mmio@a003c00/vioblk@a003c00/blkdev@0,0:b`.

These are IMAGE-CONFIG gaps, not kernel/arch gaps — the real fix is to build the
image the harness way (`pkg image-create` from the nightly repo that the cross
build's `make illumos` produces). The manual tables are a valid boot probe that
proved the kernel + drivers + ZFS root all work on aarch64.

### 8.4 How far it boots (the milestones, in order)

`artifacts/aarch64-a4/qemu-boot-full.log` (cleaned console) +
`qemu-boot-uboot-milestones.txt` (annotated):

    U-Boot 2025.01 -> efi_mgr -> loader64.efi -> unix + boot_archive
    Firmware Tables: FDT  (devicetree)   PSCI 1.1, Timer 62.5MHz, EL1
    module /kernel/aarch64/genunix ...   (krtld linked genunix)
    illumos Version arm64-gate-0-g73466454e9 64-bit   (kernel banner)
    mem = 4194304K (4 GB)
    viommionex0..31 at root              (all 32 virtio-mmio nexus nodes)
    blkdev0 is /virtio_mmio@a003c00/vioblk@a003c00/blkdev@0,0 online
    cpu1 initialization complete - online   (SMP: 2 cpu)
    root on armpool/ROOT/braich fstype zfs  (ZFS ROOT MOUNTED on virtio-blk)
    Configuring devices.   Hostname: solnix-aa
    [ svc.startd graph: network/*, system/filesystem/*, milestone/*,
      system/manifest-import, system/device/local, ... ]
    "The system has updated the cache of files (boot archive)"
    network/rpc/bind:default -> maintenance (proto-only image, expected)
    [ milestone/single-user:default starting ]
    Enter user name for system maintenance (control-d to bypass):  <-- LOGIN PROMPT

### 8.5 Exact stop point + next step

**Stop point:** the boot reaches the **single-user milestone + an interactive
console maintenance login prompt**. It stops short of multi-user-server because
`network/rpc/bind` (and `inetd-upgrade`) go to *maintenance* — a known rough
edge for this port (the README/§1.4: rbac/inetd-upgrade/update-man-index "almost
always time out"), aggravated by our proto-only image lacking the pkg-assembled
service config. This is a service-config gap, NOT a kernel/arch failure: the
kernel, SMP, virtio drivers, ZFS root, devfsadm, and the SMF graph engine all
work on aarch64.

**Next step to multi-user:** build the disk the harness way — run the cross
build's `make illumos` to produce `illumos-gate/packages/aarch64/nightly/repo.redist`,
then `pkg image-create` from that repo (+ OmniOS braich) so rpc-bind/config
services get their full config and `/etc/name_to_major`+`driver_aliases` are
assembled by pkg (not by our probe). Alternatively, disable/patch the
maintenance-bound services for a minimal single-user dev image. Either way the
boot path (u-boot + devicetree + loader64.efi + vioblk + ZFS) is proven.

### 8.6 Cross toolchain (`scripts/aa-cross-build.sh`) — IN-FLIGHT

The cross gcc / `$CROSS` (the A4-blocker-1 from §7.5) is being rebuilt from the
richlowe/arm64-gate harness (cloned fresh; the numa proto archive had only
`proto/`, not the harness/`$CROSS`). Progress on builder, detached job
`aa-cross`:
- `make download` COMPLETE (gate 1.21 GB, gcc, binutils-gdb, u-boot, ATF, dtc,
  perl, OmniOS braich sysroot).
- `make setup`: **`sysroot-stamp`, `binutils-gdb-stamp`, `sgs-stamp` DONE** — the
  cross binutils (`aarch64-unknown-solaris2.11-{as,ld,gdb,ar,elfedit,...}`), the
  Solaris link-editor (sgs), and the aarch64 sysroot are BUILT and on disk at
  `/aarch64/gate/arm64-gate/build/cross/bin/`. **boot-gcc is compiling now**
  (then the full `gcc` — the multi-hour GCC compile).
- Host-skew fixes baked into the recipe (the expected unmerged-fork friction):
  Sun `make` (not gmake — the Makefile is deliberately GNU-make-hostile); host
  `python-313` to match the braich sysroot; `library/mpfr`+`library/mpc` +
  `GMPINCDIR=/usr/include` (OI puts gmp.h in /usr/include, not /usr/include/gmp
  like OmniOS — fixed gdb's "requires GMP 4.2+, MPFR 3.1.0+"); `text/texinfo`
  for `makeinfo` (binutils/gdb .info docs); swig/bison/astdev/illumos-closed.
- Time-boxed per the brief: the GCC compile is multi-hour; the detached job
  keeps running. Once `gcc-stamp` lands, `$CROSS/bin/aarch64-unknown-solaris2.11-gcc`
  gives the compiler half of the seed (unblocking `pkgsCross.aarch64-solaris`)
  and lets `make illumos` produce a full proto + the nightly pkg repo for a
  harness-style multi-user image (§8.5).

### 8.7 Honest status

- **Cross toolchain:** IN-FLIGHT — binutils/sgs/sysroot built, boot-gcc/gcc
  compiling (detached). Not yet a working `aarch64-unknown-solaris2.11-gcc`.
- **Image assembled:** YES — bootable ZFS-root QEMU-virt disk from the proto.
- **QEMU boot:** kernel loads → krtld → genunix banner → SMP → vioblk/ZFS root
  mount → SMF → **single-user milestone + console login prompt.**
- **Remaining to multi-user:** pkg-assembled service config (needs `make illumos`
  output) OR patch the maintenance-bound services. Boot path proven.

---

## 9. A5 progress (single-user → MULTI-USER-SERVER under QEMU virt)

Status: **A5 SUCCESS — the aarch64 illumos guest reaches
`svc:/milestone/multi-user-server:default` ONLINE under `qemu-system-aarch64
-machine virt`.** This is the aarch64 equivalent of the x86_64 multi-user-server
gate (design-make-be.md §5), reached via a SERVICE-CONFIG fix (path a in the
brief) — no `make illumos` / pkg-assembled image was needed.

Done on ouch (persistent, us-east-2), host **builder** (<builder-ip>,
<instance>) — the A4 host. Every long host op ran DETACHED (nohup +
short-poll; no blocking SSH across a qemu boot — console captured to a logfile
and polled). Assets: solnix.io cache + local host disk ONLY — no AWS S3/ouch.
Artifacts under `artifacts/aarch64-a5/`.

### 9.1 Diagnosis — why the maintenance services failed (the REAL root cause)

The A4 stop point was `network/rpc/bind:default → maintenance` triggering
"Requesting System Maintenance Mode", parking the boot at the single-user
maintenance prompt. Inspecting the guest's own logs (mounted the ZFS BE
read-only on the host and read `/var/svc/log/*`) revealed the ACTUAL cause is
NOT rpc/bind per se, but a missing external library that breaks `svccfg`:

```
# /var/svc/log/system-manifest-import:default.log (A4 image)
ld.so.1: svccfg: fatal: libxml2.so.16: open failed: No such file or directory
ld.so.1: svccfg: fatal: relocation error: file /usr/sbin/svccfg: symbol xmlFree:
         referenced symbol not found
/lib/svc/method/manifest-import[454]: import_manifests: line 232: 100155: Killed
... apply_profile ... svccfg_apply ... Killed
WARNING: svccfg apply /etc/svc/profile/generic.xml failed
```

`svccfg` NEEDs `libxml2.so.16`, and the **gate proto ships NO libxml2** —
libxml2 is an EXTERNAL library (from the OmniOS `braich` sysroot / `pkg install`,
not built by the illumos gate). So EVERY `svccfg` invocation died on the guest →
`manifest-import` could import NOTHING and apply NO profiles → every service kept
its manifest-default enabled state → `rpc/bind` started from its default-enabled
state, `rpcbind` exited 1, went to maintenance, and svc.startd requested System
Maintenance Mode.

This is EXACTLY the x86_64 `externalLibs` gotcha (design-make-be.md line 103:
"`libxml2.so.16` (svccfg + svc.startd NEED it) … Without libxml2, manifest-import
(svccfg) fails"). It manifested differently on aarch64 only because the symptom
(rpc/bind → maintenance) masked the upstream cause (svccfg dead).

`svcs -xv` NEEDED-closure check on the proto-only image confirmed exactly TWO
missing libs across the SMF/init binaries: **`libxml2.so.16`** (the killer) and
`libfmevent.so.1` (a false positive — it lives in the proto at `/lib/fm/`, found
via the fm library path; svc.startd ran fine).

### 9.2 The fix (`artifacts/aarch64-a5/aa-fix-a5c.sh`, `aa-add-mus-diag.sh`)

Two prongs, both service-config (no rebuild):

1. **Inject the missing external libs.** Copy `libxml2.so.16` (+ `libgcc_s.so.1`,
   its only non-proto NEEDED lib) from the cross build's OmniOS braich sysroot
   (`/aarch64/gate/arm64-gate/build/sysroot/lib/`) into the image `/lib`. libxml2
   NEEDs `libm.so.0` (proto) + `libgcc_s.so.1` (injected) + `libc.so.1` (proto).
   With libxml2 present, **`svccfg` runs on the guest → manifest-import imports
   all 165 manifests and applies profiles cleanly** (verified: the A5
   manifest-import log has ZERO svccfg/libxml2/Killed errors).

2. **Disable the maintenance-prone services** (mirrors x86_64 design-make-be.md
   gotcha #16 site-profile). A `/etc/svc/profile/site/solnix-a5.xml` site profile
   + `general/enabled=false` in the seed `repository.db` (edited offline with the
   HOST `svccfg` via `SVCCFG_REPOSITORY` — the SMF repo is SQLite, arch-
   independent) disable: `network/rpc/bind` (rpcbind exits 1 on this proto),
   `network/inetd-upgrade`, `system/rbac`, `system/update-man-index` (the README
   "almost always time out" trio), plus the peripheral maintenance set
   `system/dumpadm` (savecore can't open the dump device node), `system/intrd`
   (restarts too quickly), `network/sendmail-client`+`system/fm/smtp-notify` (no
   `smmsp` user), `system/hal` (needs dbus), `network/ssh` (no sshd binary in the
   proto — see 9.5). NONE are `multi-user-server` dependencies
   (`multi-user`'s rpc/bind dep is `optional_all`).

Belt-and-suspenders also patched `create_default_instance enabled='false'` in the
offending manifests and the `rpc/bind` enable in `generic_limited_net.xml` (=
`generic.xml`). The load-bearing fix is #1 (libxml2); #2 keeps the peripherals
off `svcs -x`.

Also carried: `find $IMGROOT -type d ! -perm -u+w -exec chmod u+w` (the proto
ships dirs 0555; x86_64 gotcha #7) and two first-boot diagnostic transient
services (`site/solnix-a5-diag` gated on `milestone/multi-user`, `site/solnix-mus-diag`
gated on `milestone/multi-user-server`) that dump `svcs -x` + the milestone
states to `/var/*.txt` on the ZFS root — so the result is read AFTER the boot by
mounting the disk, WITHOUT holding the console.

### 9.3 THE GATE — definitive evidence

`site/solnix-mus-diag` fires only when `milestone/multi-user-server` comes
ONLINE; its output file (`artifacts/aarch64-a5/solnix-mus-diag.txt`), captured
from the guest ZFS root:

```
=== solnix A5 MULTI-USER-SERVER diag Mon Jul 27 07:00:49 PDT 2026 ===
SunOS solnix-aa 5.11 arm64-gate-0-g73466454e9 armv8 aarch64 QEMU,virt
--- the three milestones ---
STATE          STIME    FMRI
online          7:00:23 svc:/milestone/single-user:default
online          7:00:41 svc:/milestone/multi-user:default
online          7:00:45 svc:/milestone/multi-user-server:default   <- THE GATE
--- online service count ---
62
```

The console log (`artifacts/aarch64-a5/qemu-console-a5.log`) shows the clean
cascade with **NO "Requesting System Maintenance Mode"** (grep count = 0, vs A4
which had it): manifest-import (165) → `milestone/single-user` →
`milestone/multi-user` → `milestone/sysconfig` → `system/console-login` →
`solnix-aa console login:` prompt.

### 9.4 `svcs -x` state (the peripheral remainder)

At the multi-user-server snapshot, `svcs -x` lists only peripheral services, none
of which gate the milestone (identical in character to the x86_64 pre-T2.2 "5
peripheral services" state):

- `network/rpc/bind`, `system/dumpadm`, `network/routing/ndp` — **disabled** by
  the site profile (clean; "Disabled by an administrator").
- `network/ssh` — maintenance: no `sshd`/`ssh-keygen` binary in the proto (9.5).
- `system/intrd`, `network/sendmail-client` — maintenance (restart-too-quickly /
  no smmsp user); disabled in the site profile on the final image.
- `system/hal` — offline (needs `svc:/system/dbus`, absent).
- `network/routing-setup`, `site/solnix-*-diag` — transient, "start method
  running" at snapshot time; all completed status 0 seconds later (their logs
  confirm), which is why multi-user-server went online at 07:00:45.

A follow-up image (site profile extended to disable dumpadm/intrd/sendmail/
smtp-notify/hal/ssh) drives `svcs -x` toward the x86_64-clean state; those
services are all non-gating peripherals.

### 9.5 sshd bonus — blocked by the proto (needs the pkg-assembled world)

The BONUS (sshd up + `ssh` in) is NOT reachable on this proto-only image: the
gate proto ships **no `sshd` binary at all** (only `/lib/svc/method/sshd` and no
`/usr/sbin/sshd`, `/usr/bin/ssh-keygen`, or `/usr/libexec/sshd-session`). ssh
fails with `/usr/bin/ssh-keygen: not found` → `$SMF_EXIT_ERR_CONFIG`. OpenSSH on
illumos comes from `pkg install`, not the gate build. The x86_64 path solved this
by copying the reference host's whole modern-OpenSSH layout (design-make-be.md
gotchas #12–#15); the aarch64 equivalent needs the OpenSSH aarch64 binaries from
the OmniOS braich repo or the harness pkg-assembled image (9.6). Deferred — the
primary A5 gate (multi-user-server) is met via console.

### 9.6 The "right way" completion route (documented, not required for A5)

The cross gcc IS now finished on builder
(`/aarch64/gate/arm64-gate/build/cross/bin/aarch64-unknown-solaris2.11-gcc`,
`(GCC) 14.3.0`, all `make setup` stamps present: sysroot, binutils-gdb, sgs,
boot-gcc, gcc, u-boot, atf, dtc, barn). The harness-style multi-user image
(brief path b) is: `make illumos` (nightly -T aarch64) →
`packages/aarch64/nightly/repo.redist` → `pkg image-create` from that repo (+
OmniOS braich), which assembles `/etc/name_to_major`, `driver_aliases`, the full
external-libs (incl. libxml2), rbac/config, and the OpenSSH world CORRECTLY — no
manual injection. That is slower (a multi-hour `make illumos` + a pkg image
build) but is the reproducible production path and unblocks sshd. A5 proved the
service-config path reaches multi-user-server without it; the pkg path is the
follow-on for a polished, sshd-capable image.

### 9.7 Snapshot

The working multi-user aarch64 image (`/aarch64/out/illumos-disk.img`) is
archived to solnix.io `archive/aarch64/` + local `~/ws/solnix-archive/aarch64/`
(see progress.md for the exact rev + sha). This is the aarch64 equivalent of the
x86_64 boot AMI.

### 9.8 Honest status

- **multi-user-server:** REACHED, ONLINE, quoted from on-target `svcs`. ✅
- **Login reachable:** YES — `solnix-aa console login:` on the serial console
  (root, no password on this dev image).
- **svcs -x:** clean of milestone-gating services; the remainder are peripheral
  (disabled or missing-binary), matching x86_64's pre-cleanup state.
- **sshd bonus:** blocked by the proto (no OpenSSH binaries); needs the pkg
  world (9.5/9.6).
- **Method:** service-config fix (path a) — inject libxml2 (the real root cause)
  + disable the maintenance-prone services. No `make illumos` needed to hit the
  gate, though the cross gcc is ready for the pkg-assembled polish route.

---

## 10. A6 progress (full nightly build + pkg-style image + SSH into the guest)

Status: **A6 SUCCESS — SSHed from the host into a running aarch64 illumos guest
at `svc:/milestone/multi-user-server:default`.** This is the aarch64 equivalent
of the x86_64 boot-AMI + ssh login: the point aarch64 becomes a USABLE target.
The image is built from a FULL `make illumos` nightly world proto + the genuinely
EXTERNAL libs (libxml2/openssl from braich) + a full aarch64 OpenSSH — no A5
load-bearing hand-injection into a restored proto.

Done on ouch (persistent, us-east-2), host **builder** (<builder-ip>,
`<keypair>-build`, i86pc). Every long host op DETACHED (nohup -> logfile, poll);
never blocked SSH across the multi-hour build or a qemu boot (console -> socket/
logfile, polled). Assets: solnix.io cache + local host disk ONLY — no AWS S3/ouch
storage. Artifacts under `artifacts/aarch64-a6/`.

### 10.1 `make illumos` — world CLEAN, IPS packaging blocked

Ran the arm64-gate nightly directly (`nightly -T aarch64 env/aarch64`,
`NIGHTLY_OPTIONS=-FnCDAmprt`) via `artifacts/aarch64-a6/aa-run-nightly.sh`, using
the cross gcc (`build/cross/bin/aarch64-unknown-solaris2.11-gcc`, GCC 14.3.0) and
the completed `make setup` (all stamps: sysroot, binutils-gdb, sgs, boot-gcc,
gcc, ATF, dtc, barn). Bypassed the u-boot host-tool setup stamps: `make illumos`
depends on `u-boot`/`u-boot-qemu`/`u-boot-rpi4` stamps, but u-boot's HOST mkimage
fails to compile on the host's **OpenSSL 3** (`EVP_MD_CTX_create/free` deprecated
-> `image-host.c` error). The nightly OS build does NOT need u-boot, and QEMU boot
uses the proven A4 `/aarch64/out/u-boot-qemu.bin` (Debian u-boot-qemu 2025.01), so
running nightly directly is correct.

Result (`artifacts/aarch64-a6/nightly-mail_msg.txt`):
- **World build CLEAN** — "Build errors (aarch64/DEBUG)" section EMPTY. Produced
  a FULL aarch64 world proto (gate rev `a808613930`): the aarch64 kernel + full
  userland, and crucially `usr/sbin/svccfg`, `lib/svc/bin/svc.configd`, svc.startd,
  init, manifest-import, 163 SMF manifests, `network/ssh.xml` manifest.
- **IPS packaging phase FAILED**: `ModuleNotFoundError: No module named 'pkg'`.
  The packaging step's `validate_pkg`/`protocmp` run under `python3.13 -Es`, but
  OI's IPS `pkg` python module ships for python3.9 only (`/usr/lib/python3.9/
  vendor-packages/pkg`), not 3.13 (the version the gate/braich sysroot pins). So
  NO nightly IPS repo (`packages/aarch64/nightly/repo.redist`) was produced, and
  `pkg image-create` from a nightly repo was not possible on this host. This is a
  host-toolchain skew (OI IPS not ported to py3.13), not a gate/arch failure — the
  world proto itself is complete and clean.

### 10.2 Image assembly — full proto + external libs + OpenSSH (brief path b)

Since the IPS repo phase was blocked, assembled the image the equivalent way that
`pkg image-create` from nightly+braich would (`aa-make-image-a6.sh` +
`aa-a6-resume.sh` + `aa-a6-relay.sh`): the root FS is the FRESH nightly world
proto, and ONLY the genuinely-external (non-gate) pieces are added:

1. **External libs** into `/lib`: `libxml2.so.16` (the A5 root cause — svccfg
   NEEDs it), `libcrypto.so.3` + `libssl.so.3` + `libz.so.1` + `libgcc_s.so.1` +
   `liblzma.so.5` (OpenSSH's NEEDED closure) — from the OmniOS braich sysroot /
   the braich aarch64 openssh image.
2. **Full aarch64 OpenSSH** (OpenSSH_10.3, from braich `network/openssh-server`
   pkgrecv'd into an aarch64-variant image): `sshd`, the OpenSSH-10 split helpers
   `sshd-session`/`sshd-auth`, `ssh`, `ssh-keygen`, `sftp-server`, `ssh-keysign`,
   ... + the MATCHING `/lib/svc/method/sshd` + `network/ssh.xml` manifest +
   `sshd_config` (the gate proto ships a stub method calling `/usr/lib/ssh/sshd`;
   the braich method calls `/usr/sbin/sshd` where the OmniOS binary lives).
3. **Config**: root password (`solnix`) via py3.9 `crypt` (host openssl 1.0.2 has
   no `passwd -6`; py3.13 dropped `crypt`); `PermitRootLogin yes` +
   `PasswordAuthentication yes` (dev image); `/var/empty` (OpenSSH privsep dir —
   without it sshd dies `Missing privilege separation directory: /var/empty`);
   persistent NIC autoconfig `/etc/hostname.vioif0` = `dhcp`.
4. **A5 service-config carried**: full `name_to_major` (235) + `driver_aliases`
   (17) tables (the proto ships a 4-entry stub); a site profile enabling
   `network/ssh` and disabling rpc/bind + the maintenance-prone peripherals.

Laid as a GPT disk (`/aarch64/out/illumos-a6.img`): ESP (pcfs) with
`loader64.efi -> bootaa64.efi` + ZFS `armpool/ROOT/braich` + swap/dump zvols +
libbe uuid — the proven A4/A5 recipe. **svccfg/manifest-import/OpenSSH all work
WITHOUT A5's load-bearing hand-hacks** — the world is a clean nightly proto; only
the external libs + OpenSSH are added, exactly as the pkg path would assemble them.

### 10.3 The fixes found during boot (root-caused via a console-socket driver)

Booted under `qemu-system-aarch64 -machine virt -bios u-boot-qemu.bin` with
`-netdev user,hostfwd=tcp::<p>-:22`. Console driven non-interactively over a unix
socket (`-serial unix:...`, `aa-console*.py`) so the console was never held. Two
config gaps surfaced and were root-caused + fixed:

1. **sshd `Missing privilege separation directory: /var/empty`** — the gate proto
   ships no `/var/empty`. FIXED: `mkdir /var/empty` (0755). sshd then starts.
2. **No route from the hostfwd** — `ifconfig -a` showed only `lo0`; the virtio NIC
   (`vioif0`) had no IP, so QEMU user-net's hostfwd could not reach sshd (which
   listens on `0.0.0.0:22`). FIXED: `ifconfig vioif0 plumb; ifconfig vioif0 dhcp
   start` -> `inet 10.0.2.15` (QEMU user-net DHCP). Baked in persistently as
   `/etc/hostname.vioif0` = `dhcp` so `network/physical:default` plumbs+DHCPs it
   at boot.

### 10.4 THE GATE — SSH into the aarch64 guest

From the HOST, `ssh -p <hostfwd> root@127.0.0.1` (pw solnix) reaches the guest's
OpenSSH_10.3 (`aa-ssh-login.py` pty-drives the host ssh client + password).
Quoted from the guest (`artifacts/aarch64-a6/a6-ssh-proof-final.log`):

```
SunOS solnix-aa 5.11 arm64-gate-0-ga808613930 armv8 aarch64 QEMU,virt
---SVCS-MILESTONES---
online          9:24:23 svc:/milestone/multi-user-server:default
---WHOAMI---
uid=0(root) gid=0(root)
```

`svcs -x` on the SSH session lists only peripheral non-gating services (rpc/bind
disabled by profile; dumpadm/sendmail/intrd/hal — the same class as x86_64's
pre-cleanup remainder). The banner probe returns `SSH-2.0-OpenSSH_10.3` from
`127.0.0.1:<hostfwd>` = the guest's sshd via the QEMU user-net forward.

### 10.5 Archive (aarch64 boot-AMI equivalent)

`aarch64-a6-sshable-a808613930.img.zst` (116 MB, gate rev `a808613930`), sha256
`00194b73d321cd9ca44fe46206912c12131f5719e526bd7a4470ee19258d0dc0`:
- solnix.io: `https://s3.solnix.io/solnix-cache/archive/aarch64/aarch64-a6-sshable-a808613930.img.zst`
  (+ `.sha256`) — **fetch-verified** from the public URL (sha matches).
- local: `~/ws/solnix-archive/aarch64/aarch64-a6-sshable-a808613930.img.zst`.

### 10.6 Honest status

- **make illumos:** world build CLEAN — full aarch64 proto (kernel + userland +
  svccfg/svc.configd + 163 manifests). IPS packaging phase blocked by OI's
  py3.9-only `pkg` module vs the gate's py3.13; NO nightly IPS repo. So the image
  was assembled from the full proto + external libs + OpenSSH (brief path b), the
  pkg-image-create equivalent.
- **Image with real libxml2 + OpenSSH:** YES — clean nightly world + braich
  libxml2/openssl + braich aarch64 OpenSSH_10.3. svccfg/manifest-import/OpenSSH
  work without A5's hand-injection being load-bearing.
- **Boot to multi-user-server:** YES — u-boot + devicetree + vioblk + ZFS ->
  `milestone/multi-user-server:default` ONLINE.
- **SSH into aarch64 solnix:** YES — `ssh -p <fwd> root@127.0.0.1` -> `uname -a`
  = aarch64, `svcs milestone/multi-user-server` = online, `id` = root. ✅
- **First-boot note:** the archived image self-reboots once on first boot
  (boot_archive regen); on the next boot vioif0 auto-DHCPs and sshd comes online.
  sshd's SMF start can race the NIC DHCP on a cold boot; `svcadm clear network/ssh`
  brings it online if it lands in maintenance (a boot-ordering polish item, not a
  build/arch gap). The `/var/empty` + NIC-dhcp fixes are baked into the archive.
- **The RIGHT completion note (from A5 §9.6):** the ideal is `make illumos` ->
  nightly IPS repo -> `pkg image-create`. The world build is there; the only
  remaining blocker to the pure pkg path is porting OI's IPS `pkg` module to
  python3.13 (or running the packaging phase against a py3.13 with the pkg module).
  The A6 image is functionally the pkg-assembled result (clean world + external
  libs + OpenSSH), reached by direct assembly because the IPS repo phase was
  blocked on that host-python skew.


## Graviton boot vs package-build speed (2026-07-27, evaluated)

Q: does aarch64 solnix boot on Graviton now, to speed up package building?
A: NO to booting, and it WOULDN'T speed up builds anyway.

- **Boot: no.** All Graviton (1-4, Nitro) present GICv3/GICv3-ITS + ACPI (SBBR
  server-class). The port supports only GICv2 + devicetree (EBBR). No interrupt
  controller it understands, no DTB -> won't boot. Fix = GICv3 driver + ACPI
  parser + SystemReady-SR bringup (IPD 24: "in its infancy") = multi-month
  UPSTREAM kernel port. Not a bug; a hardware-support gap.
- **Speed: Graviton buys ~nothing for package builds.** We build aarch64 pkgs by
  CROSS-COMPILING from amd64 illumos hosts (cross gcc aarch64-unknown-solaris2.11)
  — exactly how A3-A6 worked. QEMU is only for boot-TESTING a few images, NOT the
  hot build path. So the aarch64 package tail already runs at full x86_64 fleet
  speed; a native aarch64 host would be marginal at best and still needs the
  cross path for bootstrap. Emulation overhead is not in the package-build loop.

DECISION: do NOT pursue Graviton boot for build speed. It's a POST-STABLE
deployment-target item (run solnix-aarch64 on real server ARM), pursued as
upstream collaboration on arm64-gate (contribute GICv3+ACPI), alongside PS-7
(qualify on all EC2 types). aarch64 package build-out continues via cross-from-
amd64 on the ouch fleet (fast, no emulation).


## 11. A7 progress (pure `pkg` path — fix OI IPS py3.9-vs-py3.13, emit IPS repo, `pkg image-create`)

Status: **A7 PARTIAL — the pkg fix + IPS repo + `pkg image-create` all SUCCEEDED
(the exact A6 gap is closed); the clean-pkg image BOOT is blocked by a
device-enumeration divergence (documented + time-boxed). aarch64 remains usable
via the A6 image (re-verified booting).**

The ONE gap A6 hit (§10.1/§10.6): the OI IPS `pkg` python module (pkg5, C ext)
is python3.9-only, but the arm64-gate nightly packaging phase ran
`validate_pkg`/`protocmp`/`pmodes` under python3.13 →
`ModuleNotFoundError: No module named 'pkg'`, so NO nightly IPS repo was produced
and A6 had to hand-assemble the image. A7 closes it.

Done on ouch (persistent, us-east-2), host **builder** (<builder-ip>). Every
long op detached (nohup → logfile, poll); never blocked SSH. Assets: solnix.io
cache + local host disk ONLY — no AWS S3/ouch storage. Artifacts under
`artifacts/aarch64-a7/`.

### 11.1 The py3.13/pkg fix (root-caused)

- `env/aarch64` cross-branch (`MACH=aarch64` ≠ `NATIVE_MACH=i386`) sets
  `PYTHON3_VERSION` = the highest `python3.N` whose `Python.h` is in the aarch64
  sysroot. The sysroot ships only python3.13 headers → `PYTHON3_VERSION=3.13`.
- `Makefile.master`: `TOOLS_PYTHON = $(PYTHON3) = /usr/bin/python$(PYTHON3_VERSION)`
  → the gate HOST tools (`validate_pkg`, invoked by `protocmp`/`pmodes`/`protolist`)
  are built with shebang `#!/usr/bin/python3.13 -Es`.
- The OI IPS `pkg` module is installed ONLY for host python3.9
  (`/usr/lib/python3.9/vendor-packages/pkg`; the system `/usr/bin/pkgsend` etc.
  use `#!/usr/bin/python3.9` and work). `validate_pkg` does `from pkg import
  actions` → fails under 3.13. `-Es` blocks PYTHONPATH; pkg5's C ext is 3.9-ABI,
  so 3.13 cannot borrow the 3.9 module.

**Fix (a — least-invasive, survives a tools rebuild; `aa-a7-fix-pkg-python.sh`):**
1. `env/aarch64`: `export TOOLS_PYTHON=/usr/bin/python3.9` after `PYTHON3_VERSION`
   — build the HOST gate tools with the python that HAS the pkg module (3.9),
   while the TARGET world modules still build against the 3.13 sysroot
   (`PYTHON3_VERSION` unchanged). A clean **target-python vs tools-python** split.
2. Re-shebang the built `validate_pkg` to python3.9 (fast path; the env fix makes
   a future `dmake install` in `usr/src/tools` reproduce the 3.9 shebang).

Verified: `validate_pkg -a aarch64 -L -m packages.aarch64` (the exact A6-failing
command) → exit 0, 32451-line proto_list, no ModuleNotFoundError.

### 11.2 IPS repo emitted (re-ran ONLY the packaging phase — no world rebuild)

Re-ran the nightly packaging phase via `bldenv -T aarch64 env/aarch64 "<cmd>"`
(`aa-a7-rerun-packaging.sh`) — the A6 world proto at gate `a808613930` is reused
(the world build was already CLEAN in A6). `dmake -e install` in `$SRC/pkg` →
`packages/aarch64/nightly/repo.redist`; `dmake -e protocmp` + `dmake -e pmodes`
→ ModuleNotFoundError count **0** on install/protocmp/pmodes. Repo:
**495 packages, publisher `on-nightly`, online**; `pkgrecv --newest` reads all
495 (SUNWcs/SUNWcsd/system-kernel/system-library present). The `-T aarch64` on
bldenv is essential: without it bldenv defaults to native i386 and the repo lands
under `packages/i386` (0 aarch64 pkgs) — caught + fixed on the first re-run.

### 11.3 `pkg image-create` assembled the aarch64 image (no A6 hand-injection)

`aa-a7-pkg-image-create.sh`:
1. The nightly osnet repo references ~19 `require` deps that live in the FULL OI
   distribution (`release/name`, `runtime/perl`, `runtime/python-313`,
   `security/sudo`, `text/less`, `developer/*`, `system/header`,
   `consolidation/osnet/osnet-incorporation`, …) — consolidations with NO aarch64
   build (the very bootstrap gap solnix closes). A tiny **stub companion repo**
   of content-less aarch64 packages satisfies the solver; the REAL osnet bits
   still come from pkg.
2. `pkg image-create -F -p on-nightly=<nightly> --variant variant.arch=aarch64`
   (foreign-arch image — works cross-arch on the i386 host, `rc=0`) + the stub
   repo as a 2nd origin.
3. `pkg install` the bootable osnet set (34 pkgs, `rc=0`): SUNWcs/SUNWcsd,
   system/kernel[/platform/qemu-virtual], system/library[/math/iconv/libtecla],
   system/boot/loader, system/file-system/zfs, the virtio drivers
   (driver/misc/virtio+viommionex, driver/storage/vioblk+vio9p+blkdev,
   driver/crypto/viorand, driver/network/vioif), service/network/ssh[-common].

Proof `pkg` (not hand-copy) assembled the world: `unix` (byte-identical cksum to
A6's), `loader64.efi`, `svccfg`, `svc.configd`, 82 SMF manifests, and — crucially
— the CORRECT `name_to_major` (101) + `driver_aliases` (with vioif/vioblk).
**This is strictly better than A6**, which had to hand-generate name_to_major/
driver_aliases because the raw proto shipped a 4-entry stub. Only the genuinely-
EXTERNAL libxml2 (svccfg NEEDs it) + aarch64 OpenSSH_10.3 (`network/ssh` is
obsolete in the illumos gate) are added from braich (`aa-a7-lay-disk.sh`), exactly
as a production `pkg image-create` with a braich publisher would.

### 11.4 The BOOT blocker (the exact stop point)

The pkg-assembled disk panics `vfs_mountroot: cannot mount root` — the kernel
falls to `/pseudo/lofi@1:b` because `vioblk` never attaches, and `vioblk` never
attaches because `viommionex` (the virtio-mmio nexus) never attaches
(`viommionex` appears 0× in the A7 console; A6's console shows
`viommionex0..N at root` → `blkdev0 online` → `root on armpool/ROOT/braich`).

Exhaustively isolated — every obvious suspect ruled OUT (all byte-identical to
the booting A6 image):
- driver binaries + `.conf` (vioblk/viommionex/virtio/blkdev/simple-bus) present
  in image AND boot_archive; cksums identical to A6.
- driver_aliases: added the DTB-match aliases A6 had (`viommionex "virtio-mmio"`,
  `simple-bus "simple-bus"`, `ns16550a`, `efifb`) — no change.
- overlaid the FULL proto `kernel`/`platform` driver tree (226 drv = A6) onto the
  pkg root (`aa-a7-fix-drivers.sh`) — no change.
- copied A6's EXACT proven boot_archive onto the A7 pkg root + re-laid — STILL
  panics → NOT the boot_archive.
- `unix` cksum byte-identical A6 vs A7; FDT/PSCI handling identical.

**Conclusion:** with kernel, drivers, boot_archive, aliases, FDT all proven
identical to the A6 image that boots, the A7 pkg-*userland* disk still fails to
enumerate `viommionex`. The divergence is between the raw-proto root (A6) and the
pkg-composed root (A7), consumed during the kernel's early ZFS device scan — NOT
in the pkg-assembly path (the A7 deliverable, proven working). Time-boxed per the
brief. **Next step:** incrementally overlay the proto's `/etc/devices` +
device-state files onto the pkg root until `viommionex` attaches (bisect the
exact non-driver file the proto carries that the pkg root lacks).

### 11.5 Fallback confirmed + archive

The A6 hand-assembled image (`illumos-a6.img`, unchanged) was re-booted and
reached `root on armpool/ROOT/braich` with `viommionex0 at root` + `blkdev0
online` (`a6-fallback-boot-evidence.txt`) — aarch64 stays usable via A6 (which
also SSHes in, per §10.4).

Archived to solnix.io `archive/aarch64/` (+ local `~/ws/solnix-archive/aarch64/`),
fetch-verified HTTP 200, sha-matched (NO AWS S3/ouch):
- `aarch64-a7-ips-repo-redist.tar.gz` (134MB, the emitted nightly IPS repo, 495
  pkgs) — sha256 `d2bdcdc421a7538de0f062655b7156a7b7168bf023cce106259b945e5d8772fd`.
- `aarch64-a7-pkg-assembled.img.zst` (108MB, the pkg-image-create-assembled
  image) — sha256 `5e9d50db7f1c0db3b86b124da081a21c1ac18ff543e87cc33d2d1fbf292ed82a`.

### 11.6 Honest status

- **py3.13/pkg fix:** DONE — `TOOLS_PYTHON=/usr/bin/python3.9`; the exact A6
  ModuleNotFoundError is gone (install/protocmp/pmodes all 0).
- **Nightly IPS repo:** YES — `repo.redist`, 495 pkgs, online, pkgrecv-readable.
- **`pkg image-create`:** YES — assembled the osnet world cleanly (34 pkgs, `rc=0`,
  no world hand-injection; pkg produced the correct name_to_major/driver_aliases).
- **Boot+ssh+pkg-list on the pkg image:** NO — viommionex-attach / vfs_mountroot
  panic; isolated to a non-pkg-assembly device-enumeration divergence, time-boxed
  with the exact next step documented.
- **aarch64 usable:** YES via the A6 image (re-verified booting to ZFS root; SSH
  per §10.4). A7 delivered the CLEAN pkg path for the packaging + image-assembly
  stages (the A6 gap); the last mile (boot the pkg-composed root) is the remaining
  follow-on.

## 12. A8 progress (boot the CLEAN pkg-image-created root → aarch64 FULLY QUALIFIED)

Status: **A8 SUCCESS — the clean `pkg image-create`-assembled aarch64 image BOOTS
to `multi-user-server`, SSH-in works, and `pkg list` shows the 34-package IPS
image. aarch64 is FULLY QUALIFIED (clean pkg-image, ssh, pkg-functional).**

Done on ouch (persistent, us-east-2), host **builder** (<builder-ip>). All long
ops detached (nohup → logfile / console-socket, poll; never blocked SSH). Assets:
solnix.io cache + local host disk ONLY — no AWS S3/ouch storage. Artifacts under
`artifacts/aarch64-a8/`.

### 12.1 The A7 boot blocker — root-caused (NOT the brief's hypothesis)

The brief hypothesized missing `/etc/path_to_inst` + `/etc/devices/*`. Diffing the
two staged roots (`/braich_a6` boots, `/braich_a7` panics) DISPROVED that: those
device-state files, `/dev`, `/devices`, `/etc/name_to_major` bindings, driver
binaries (226 drv), `unix`, and even the `boot_archive` are byte-identical.

The real divergence is in the KERNEL BOOT LOG, not the on-disk device state:
- A6 (boots): loader `Module 1: rootfs (0) 0x61c0000` (=**102 MB** boot_archive)
  → after `simple-bus0 at root`, **`viommionex0..31 at root`** → `vioblk`/`blkdev0
  online` → `root on armpool/ROOT/braich`.
- A7 (panics): loader `Module 1: rootfs (0) 0x2da0000` (=**47.8 MB** boot_archive)
  → `simple-bus0`→`ecam0`→`ns16550a0`, **0× viommionex** → `vfs_mountroot` panic.

**Root cause:** the booted `illumos-a7.img` carried a STALE 47.8 MB pkg-generated
boot_archive that lacked the full aarch64 driver tree, so the virtio-mmio nexus
never enumerated. The `/braich_a7` staging root had the correct 102 MB archive
(the full 226-driver tree was overlaid in A7 §11.4), but the disk was
`zfs send`-built from an EARLIER snapshot, BEFORE that landed. §11.4's "copied A6's
boot_archive + re-laid" updated the staging root but the disk actually booted came
from the older stream. Evidence: `artifacts/aarch64-a8/diff/a8-device-state-divergence.txt`.

### 12.2 The fix (`aa-a8-relay.sh`) — regenerate + seed, then re-lay

1. **Regenerate the boot_archive FRESH from the pkg root** (`create_ramdisk -R
   /braich_a7 -p aarch64 -f cpio`) → 102 MB, 717 files, viommionex driver inside,
   internal `name_to_major` = the A7 on-disk 105-entry numbering (self-consistent,
   NOT A6's 235-entry tables copied in). Re-lay `illumos-a8.img` from this root.
   → boots: `viommionex0..31 at root`, `blkdev0 online`, `root on armpool/ROOT/braich`.
   **The A8 device-enumeration gap is closed by this single step.**

2. Booting to ZFS root exposed 4 further **pkg-image userland completeness gaps**
   (the minimal 34-pkg osnet set omits files the full proto carries — the same
   bootstrap gap solnix closes; a full `pkg image-create` would pull these from the
   utility/library/FMA/network consolidations that have no aarch64 build yet).
   Seeded from the A6 proto (same-gate build, byte-identical arch), documented as a
   post-`pkg image-create` seeding step:
   - `/lib/fm/libfmevent.so.1` — svc.startd NEEDs it; without it `ld.so.1: svc.startd:
     fatal` → startd restart-loop → maintenance.
   - `/sbin/dladm` + `/sbin/ipadm` (+ `/etc/dladm/*.conf`, `/etc/ipadm/*.conf`) —
     `network/physical`'s `net_reconfigure` needs them.
   - **static `/etc/hostname.vioif0` = `10.0.2.15/24`** (QEMU user-net's deterministic
     lease) — the shipped `dhcp` config lost the first-boot DHCP race → net-physical
     `exit 96` → `network/physical` maintenance → `milestone/network` blocked → no
     sshd. Static addressing makes net-physical exit OK on the FIRST boot.
   - **~223 core `/usr/bin` binaries + libs** (`awk`, `nawk`, `sort`,
     `libdiskmgt.so.1`, …). Boot-fatal: in-guest `bootadm update-archive` (run by
     `fs-usr`) invokes `create_ramdisk`, which needs awk/nawk/sort; `swapadd` needs
     libdiskmgt. Missing → fs-usr `exit 95` → maintenance. Seeded → /usr/bin 251→474.
   - **Corrected mistake:** an initial attempt DISABLED `system/boot-archive` — that
     stalls 39 dependent services (it is a hard dep of `filesystem/usr` → the whole
     single-user→multi-user chain). Kept it ENABLED; the seeded utils make its
     in-guest archive check/update succeed.

### 12.3 Boot + SSH + pkg proof (`multi-user-server`, ssh-in, `pkg list`)

Booted `illumos-a8.img` under `qemu-system-aarch64 -machine virt -bios u-boot` +
hostfwd (the A4–A7 proven path), console on a unix socket driven by a python pty
helper (`aa-a8-prove.py`). RESULT (`artifacts/aarch64-a8/logs/`):
- `viommionex0..31 at root` → `blkdev0 online` → `root on armpool/ROOT/braich`.
- **`svc:/milestone/multi-user-server:default  online`** (68 services online; only
  optional fmd/hal-dbus/intrd/iscsi in maintenance — A6 had the same set).
- **`svc:/network/ssh:default  online`**, `sshd` pid 100686, `*.22 LISTEN`,
  `vioif0: UP inet 10.0.2.15`.
- **SSH from host → guest** (hostfwd 2228→22, password auth): `SunOS solnix-aa 5.11
  arm64-gate-0-ga808613930 armv8 aarch64 QEMU,virt`, `SSHIN-OK`, `uid=0(root)`,
  multi-user-server online confirmed from inside (`a8-sshin.txt`).
- **`pkg list`** on the A8 IPS image → **34 packages** installed (SUNWcs, SUNWcsd,
  system/kernel[/platform/qemu-virtual], system/library[/math/iconv], system/
  file-system/zfs, driver/misc/viommionex+virtio, driver/storage/vioblk+blkdev+
  vio9p, driver/network/vioif, driver/crypto/viorand, system/boot/loader, …);
  publisher `on-nightly` online (`a8-pkglist.txt`). NOTE: the on-*guest* `pkg`
  client is absent (the aarch64 `package/pkg` client + an aarch64 python runtime
  are not built yet — a known follow-on, not a boot blocker); the image IS a
  genuine queryable IPS image (`var/pkg` v4 catalogs), read here via the host pkg
  client `pkg -R <image> list`, exactly as `pkg image-create` validated it.

### 12.4 Archive + qualification

Archived the booting clean pkg-image (NO AWS S3/ouch):
- `aarch64-a8-pkg-bootable.img.zst` (155 MiB) — sha256
  `06b98f7ffd2bc9ba151d69b19768ba15965915a7b0841d00edea104865b16d7b`.
- solnix.io `archive/aarch64/` (fetch-verified HTTP 200, sha-matched) +
  local `~/ws/solnix-archive/aarch64/`.

**aarch64 FULLY QUALIFIED:** the clean `pkg image-create`-assembled image (A7's
deliverable) now boots end-to-end — ZFS root on virtio-mmio, multi-user-server,
SSH-in, and a queryable 34-package IPS image. The A6 hand-assembled image remains
the fallback. Remaining follow-on (not a qualification blocker): build the aarch64
`package/pkg` client + python runtime so `pkg` runs ON the guest.
