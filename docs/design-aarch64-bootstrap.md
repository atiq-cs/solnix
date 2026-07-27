# Design: solnix on aarch64 — port assessment, substrate, and bootstrap plan (A1)

Status: research + substrate decision + A2 started. This is the deliverable for
task **A1** in `.kiro/specs/solnix-aarch64/tasks.md`. It (1) assesses the
out-of-tree aarch64 illumos port, (2) fixes the build/test substrate with a
QEMU-boot analysis, and (3) gives a concrete A2/A3/A4 plan mapped to our proven
x86_64 recipes. Sources are cited inline (repos, IPD, commit dates). Honest
about what is unmerged, unproven, and hard.

Verified on 2026-07-25 against: the OI amd64 build host `solnix-oi-build`
(illumos-960edb1c89, 16 cores / 64 GB, us-east-2 `i-01a55d152d2e59beb`), and
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
- **A2 started AND progressing** on `solnix-oi-build` (idle at the time; x86_64
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

- **Build host = amd64 illumos** (our existing `solnix-oi-build`, or a dedicated
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

Started A2 on `solnix-oi-build` (idle at the time: load ~0.6, no nightly
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
solnix.io). Done on ouch (persistent account, us-east-2), host **ouch-w7-8**
(3.142.68.35, i-02d180655d42f2d41; secondary hosts ouch-w7-6/w7-7 claimed but
were still SSH-warming — a single host sufficed for the exploratory integration).
Every long host op ran DETACHED via `scripts/oi-job.sh` (no blocking SSH).
Assets: solnix.io cache + local seed store ONLY — no AWS S3/ouch storage.

### 7.1 Proto restore (step 1) — DONE, kernel present

Restored the archived aarch64 proto onto ouch-w7-8 by fetching it directly from
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

Built on ouch-w7-8 (host Nix 2.3.16; the slicing/relocation runs on the amd64
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

Done on ouch (persistent, us-east-2), host **ouch-w7-8** (3.142.68.35,
i-02d180655d42f2d41) — the host that already had the A3 proto restored. Every
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
`proto/`, not the harness/`$CROSS`). Progress on ouch-w7-8, detached job
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
