# solnix aarch64: honest readiness assessment + native-boot path (Goal 1)

> ⚠️ **URL CORRECTION 2026-09-12.** Every `archive/aarch64/...` URL in this file is **wrong** — that entire
> prefix does not exist in the bucket and returns **HTTP 404** (verified unauthenticated). The surviving
> aarch64 assets are:
>
> | asset | key | size |
> |---|---|---|
> | cross seed | `seed/aarch64-solaris/aarch64-seed-cross-14.3.0.tar.gz` | **286,655,805 B**, HTTP 200 |
> | **proto** | `ami/aarch64-proto-20260912/proto-root_aarch64.tar.gz` | **122,611,618 B**, HTTP 200 |
>
> The proto is newly rebuilt and banked; the older `aarch64-proto-73466454.tar.zst` is gone for good. An
> agent lost time following the dead path, so this is corrected here rather than only in a new document.


Node: i-0c94705fd4d3f3768 / 3.138.61.121 (solnix-aarch64-xbuild-2), left RUNNING.
Substrate: x86 illumos build host, 16 vCPU / 64G RAM, nixpool 90G free.

## TL;DR verdict

- **Native aarch64 EC2 (Graviton) boot = BLOCKED at the port, not weeks-away.**
  The out-of-tree port (richlowe/arm64-gate, IPD 24) is **GICv2 + devicetree
  only**; Graviton/Nitro is **GICv3 + ACPI**. The port has no interrupt
  controller Graviton exposes and no devicetree, so it cannot boot on Graviton
  bare-metal or as a Nitro guest until SystemReady-SR (GICv3+ACPI) work lands —
  which IPD 24 itself calls "in its infancy". This is a multi-**month**+
  upstream-kernel effort, not a solnix packaging task. **Do not plan an aarch64
  AMI.**
- **The port's real boot target is QEMU `virt` (GICv2).** That substrate works on
  this node (qemu-system-aarch64 11.0 present, `-machine virt,gic-version=2 -cpu
  cortex-a72` parses clean). A QEMU-virt boot is **feasible but not demonstrated
  here** — it needs the arm64-gate build artifacts (u-boot.bin + illumos-disk.img)
  which are not on this node and whose archives are now gone; regenerating them =
  the multi-hour `make setup` + `make illumos` gate build.
- **What WORKS TODAY and is reliable: x86 -> aarch64-solaris CROSS-BUILD.** A real
  aarch64 illumos userland is cross-built and reproducible from this x86 host.
  **This is the deliverable "aarch64 build-farm animal" role right now.** PROVEN
  this session (see §3).

## 1. Does the arm64-gate kernel build? How far?

**The cross TOOLCHAIN builds and works; the KERNEL (`unix`/`genunix`) was not
built to completion, and could not be here without a multi-hour re-bootstrap.**

State found on this node:
- arm64-gate tree is NOT present (it lived on a prior build host, now gone).
- The archived aarch64 **proto** (`aarch64-proto-73466454.tar.zst`) 404s.
- What SURVIVES is the **cross seed** (286 MB, HTTP 200). ⚠️ **URL CORRECTION
  (measured 2026-09-12):** the key is
  `https://s3.solnix.io/solnix-cache/seed/aarch64-solaris/aarch64-seed-cross-14.3.0.tar.gz`
  (286,655,805 bytes). The `archive/aarch64/...` path this file used to cite
  **404s** -- the `archive/` prefix does not exist in the bucket at all. The
  asset claim was true; the address was wrong. See
  docs/aarch64-gicv3-crs-metal-CONFIRMED.md. = the arm64-gate `make setup` output folded into a Nix FOD:
  cross **GCC 14.3.0**, the illumos **Solaris ld** (`sgs`, opt/onbld/bin/amd64/ld),
  cross binutils (`aarch64-unknown-solaris2.11-{as,ar,nm,...}`), and the aarch64
  **sysroot** (libc.so.1, ld.so.1, crt*.o, full usr/include).

Prior-host progress (per docs/design-aarch64-bootstrap.md, corroborated by the
surviving seed):
- `make download` COMPLETE (gate 1.15G + richlowe/gcc 1.68G + binutils-gdb +
  u-boot + ATF + dtc + RPi firmware + OmniOS braich sysroot 501M).
- `make setup` well underway — stamps done: sysroot, binutils-gdb, barn, dtc,
  u-boot, **sgs** (Solaris ld), **boot-gcc**, cross **GCC 14.3.0**. The A2 gate
  PASSED: the cross gcc compiles `.c` -> `ELF 64-bit aarch64 relocatable`,
  `-dumpmachine = aarch64-unknown-solaris2.11`.
- `make illumos` (the actual kernel: `unix`/`genunix` via `nightly -T aarch64`)
  was the NEXT multi-hour step and was **never reported complete**.

Why not resumed here (anti-wedge STOP, honest reasons):
1. arm64-gate tree gone -> needs ~7 GB re-download (git remote IS reachable,
   HEAD `43502da9`).
2. Host **Python is 3.9.25**; the `sgs` build breaks unless the host python minor
   matches the braich sysroot's (**3.13**) — the exact documented break, needs
   `pkg install runtime/python-313` first.
3. Root FS has only 2.3 G free; the gate tree must live on /nixpool (90 G).
4. `make setup` (finish) + `make illumos` is multi-hour and would consume the
   whole budget for a data point the design doc already records honestly.

**Verdict for step 1:** the core toolchain artifact (cross gcc 14.3.0 + Solaris
ld + sysroot) is BUILT and DEMONSTRABLY WORKS (it cross-compiles our whole
userland — §3). The kernel proper is a resumable but incomplete multi-hour
bootstrap; it is NOT a built artifact today.

## 2. The EC2/Graviton boot gap (honest, enumerated)

Even with a finished kernel, a bootable aarch64 EC2 AMI is **far**. Concrete gaps:

Top 3 blockers (in order):
1. **Interrupt controller: GICv3 vs GICv2.** arm64-gate implements GICv2/GICv2m
   only (IPD 24: "GICv3/ITS = No"). Graviton/Nitro presents **GICv3**. The kernel
   has no driver for the only interrupt controller the instance exposes -> dead
   at boot. This is real driver/kernel work upstream, not config.
2. **Platform description: devicetree vs ACPI.** The port targets EBBR/IR
   **devicetree**; Graviton is server-class **ACPI (SBBR/SBSA)**. No DT is
   provided by Nitro, and the port has no ACPI enumeration path -> it cannot even
   discover CPUs/memory/timers.
3. **Nitro device drivers on aarch64 illumos: ena + nvme.** Even past GIC/ACPI,
   an AMI needs the **ena** NIC and **nvme** disk drivers working on arm64
   illumos under Nitro. The port targets QEMU-virt/RPi4/Odroid; there is no
   Graviton/Nitro `ena`/`nvme` bring-up. (illumos has an nvme driver; arm64+Nitro
   MSI-X/interrupt wiring via GICv3 is the unproven part — and it depends on #1.)

Secondary: UEFI/boot path (port uses u-boot + EFI aarch64 loader `bootaa64.efi`;
Nitro provides its own UEFI, untested against illumos-arm64), and console
(port uses PL011/virt UART; Nitro serial differs).

Rough effort: **months of upstream kernel work (GICv3 + ACPI + Nitro drivers),
not a solnix task.** Even the port's own server-class testing story is QEMU
`sbsa-ref`, not real cloud ARM.

Minimal experiment done (cheap data point, no budget burn): confirmed
`qemu-system-aarch64` 11.0 is on the node and the port's exact machine config
(`-machine virt,gic-version=2 -cpu cortex-a72`) instantiates cleanly (fails only
on the absent u-boot ROM). So the QEMU-virt substrate is ready; only the
arm64-gate boot image is missing. A full QEMU boot was NOT attempted — it needs
the multi-hour gate build first (§1), which would wedge the budget.

## 3. PROVEN: x86 -> aarch64-solaris cross-build (deliverable TODAY)

This is the honest "aarch64 capability" the maintainer can rely on now.

**Reproducible from-source cross-build this session:**
`nix-build /root/entry-aa-fin.nix -A zlib` rebuilt zlib 1.3.2 FROM SOURCE (the
prior store path was GC'd): it fetched the cross seed (150 MB) from
s3.solnix.io, then the **cross GCC 14.3.0** compiled every `.c`
(`aarch64-unknown-solaris2.11-gcc -O3 -fPIC -c -o deflate.o deflate.c` ...) and
`aarch64-unknown-solaris2.11-ar` linked `libz.a`. Verified the fresh object:

```
$ elfdump -e deflate.o        # extracted from the just-built libz.a
  ei_class:   ELFCLASS64      e_machine:  EM_AARCH64      e_type: ET_REL
```

**A real, non-trivial package already built + valid in the store:**
openssl 3.6.3 (`.../8kh68a2g...-openssl-aarch64-unknown-solaris2.11-3.6.3-bin`):

```
$ elfdump -e bin/openssl
  ei_class: ELFCLASS64   e_machine: EM_AARCH64   e_type: ET_EXEC
$ elfdump -i bin/openssl   -> .interp = /lib/ld.so.1
$ elfdump -d bin/openssl   -> NEEDED: libssl.so.3 libcrypto.so.3 libsocket.so.1
                               libnsl.so.1 libmd.so.1 libc.so.1 libgcc_s.so.1
```
A genuine dynamically-linked aarch64 illumos executable resolving the illumos
aarch64 system libraries.

**Breadth (218 valid aarch64-unknown-solaris2.11 store paths right now),
including:** openssl, zlib, python3, glib, sqlite, tcl, zstd, gettext, pcre2,
readline, ncurses, libffi, expat, gdbm, bzip2, xz, tzdata, mpdecimal, libiconv,
bash, cmake-minimal, pkg-config-wrapper, and a hand-compiled hello.

The Nix wiring is real: `aarch64-illumos = { config = "aarch64-unknown-solaris2.11"; }`
in the nixpkgs fork's lib.systems/examples.nix; the cross set routes through
nixpkgs `stagesCross` with buildPackages = the proven native x86_64-solaris
stdenv and cc = the seed aarch64 cross cc-wrapper (crossOverlay `aarch64CcSwap`).

**ELFOSABI note (honest nuance, not a blocker):** the hand-compiled `hello`
(seed cc + Solaris ld direct) is `ELFOSABI_SOLARIS` + EM_AARCH64. The
autotools/stdenv package builds (openssl, zlib) come out `ELFOSABI_NONE` +
EM_AARCH64. Both are valid aarch64 illumos ELF (interp `/lib/ld.so.1`, correct
EM_AARCH64). The OSABI-byte difference is a final-link flag artifact of the port
(IPD 24 is predraft; native x86 illumos uses ELFOSABI_SOLARIS). It does not stop
the objects being correct aarch64 illumos code, but it's worth tracking as a
toolchain-consistency item before claiming ABI parity with native illumos.

## Bottom line for Goal 1

- The **long-term aarch64 build-farm animal that works today** is exactly this
  x86 host cross-building aarch64-solaris packages. Reliable, reproducible,
  broad (218 paths incl. openssl/python3/glib). Ship/rely on this now.
- A **native aarch64 solnix in QEMU-virt** is feasible but needs the multi-hour
  arm64-gate `make setup`+`make illumos` finished (toolchain done, kernel not);
  budget: days-to-weeks of build-break triage, QEMU-only, slow.
- A **native aarch64 EC2/Graviton AMI is blocked** at the port level (GICv3 +
  ACPI + Nitro drivers = months of upstream kernel work). Do not claim or plan
  an aarch64 AMI.
