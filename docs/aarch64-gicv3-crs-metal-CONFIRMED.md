# aarch64 GICv3 + `_CRS`-in-SSDT: BOTH FIXES CONFIRMED ON REAL c6g.metal

Two fixes that had been committed but **never run on hardware** are now verified on a real
AWS Graviton bare-metal instance. The proto that produces them is banked in R2 with
read-back-verified sha256s, so this cannot evaporate with a burner account again.

## The result

`i-03526e3d3334a569e` (`c6g.metal`, AMI `ami-04a384a52cfe7f52a`), launched 14:45:12Z,
console read only via `aws ec2 get-console-output --latest`. Full capture:
`src/aarch64-arm64-gate-patches/a6crs-metal-console-CONFIRMED.txt`.

```
[A6GIC] ngicc=40 distinct_gicr_base=40 regions=4 stride=0x20000
[A6GIC] region[0] base=0xbc00080000 size=0x200000 ncpu=0x10
[A6GIC] region[1] base=0xbd00080000 size=0x200000 ncpu=0x10
[A6GIC] region[2] base=0xbe00080000 size=0x200000 ncpu=0x10
[A6GIC] region[3] base=0xbf00080000 size=0x200000 ncpu=0x10
[A6GIC] gicr_base min=0xbc00080000 max=0xbf00260000
[A6CRS] crs_nwin=0x2 crs_have=0x1 necam=0x1 ecam0=0xc000000000 qemu=0x0 fdt_used=0x236d fdt_max=0x4000
[A6CRS] win[0] space=0x2000000 child=0x80000000    parent=0x80000000    size=0x20000000
[A6CRS] win[1] space=0x3000000 child=0x18000000000 parent=0x18000000000 size=0x2000000000
[A6KCON:BOP]
[A6KCON:BCONS]
```

### `_CRS`-in-SSDT (`b46583f9ba`): CONFIRMED

Every predicted value hit exactly:

| quantity | predicted (metal) | measured | meaning |
|---|---|---|---|
| `crs_nwin` | `0x2` | **`0x2`** | the brief's success criterion, verbatim |
| `crs_have` | `0x1` | **`0x1`** | firmware `_CRS` **was found** (old code: `0` → fallback) |
| `ecam0` | `0xc000000000` | **`0xc000000000`** | real metal ECAM, not the VM's `0x20000000` |
| `qemu` | `0x0` | **`0x0`** | the QEMU-virt fallback did **not** fire |
| MEM32 | `0x80000000` sz `0x20000000` | **matches** | identity-mapped |
| MEM64 | `0x18000000000` sz `0x2000000000` | **matches** | identity-mapped |
| IO window | absent | **absent** (no `space=0x1000000`) | metal has none |

Cross-checked against the independently captured firmware tables in
`a6pcie-c6gmetal-firmware-tables.txt`, which report `alloc[0] ECAM base=0xc000000000` and
`TOTAL ECAM ALLOCATIONS = 1` — matching `ecam0` and `necam=0x1`.

**The built-in negative control:** the *same binary* under QEMU printed
`crs_nwin=0x3 ecam0=0x4010000000 qemu=0x1` plus a third `space=0x1000000` IO window. The
instrument therefore *distinguishes* the two platforms; it is not printing a constant that
would appear anywhere. That contrast is what makes the metal reading a measurement.

### GICv3 multi-region redistributor: CONFIRMED

`ngicc=0x40` (64 cpus), `distinct_gicr_base=0x40` (64 — **not** the buggy `1`), 4 regions of
`ncpu=0x10` spanning `0xbc00080000..0xbf00260000`. Matches the committed
`a6hw-graviton-MADT.bin` block layout exactly. Zero occurrences of `gicthree` or
`num_redistributors` in the console — the old `VERIFY3U` panic is gone.

### The FR-poll fix was load-bearing

Both `[A6KCON:BOP]` **and** `[A6KCON:BCONS]` print. `BCONS` is precisely the marker that was
missing in the historical run 2, when `boot_uart.c` went unpatched. See "the trap that was
real", below.

## It is not the historical reset loop

The prior metal failure was a silent reset loop: 3 EDK2 banners in 32 minutes. This boot shows
**1 banner across 77 minutes and 8 console reads**, no `panic`, no `Resetting`. Forward
progress was established by *diffing successive reads*, not by assuming:

| time | bytes | new output |
|---|---|---|
| 14:50 | 12980 | `[A6GIC]` 4 regions, `[A6CRS] crs_nwin=0x2`, BOP, BCONS |
| 15:02 | 13102 | `module .../unix: text at 0xfffffffffe02b000` |
| 15:13 | 13212 | `module /kernel/aarch64/genunix` |
| 15:26 | 13411 | `module .../platmod`; **`illumos Version arm64-gate-0-g6cd2521c1e 64-bit`**; `DEBUG enabled` |
| 15:38 | 13529 | `mem = 134217728K (0x2000000000)` — 128 GiB, correct for `c6g.metal` |
| 15:50 | 13714 | `SMBIOS not loaded`; **`root nexus = Amazon EC2`**; `pseudo0 at root`/`is /pseudo` |
| 16:02 | 13798 | `WARNING: failed to resolve 'scsa,probe' driver alias, defaulting to 'nulldriver'` |

Monotonic growth every read. The limiter is the documented ~13 s/char slow console, not a
hang. `SunOS Release` was **not** reached and is not claimed.

## Next blocker, precisely named and deliberately not fixed

Device-tree attach is proceeding, and the visible gaps are artifacts of a **proto-only** image
(no `pkg`-assembled `/etc` tables):

```
WARNING: add_spec: No major number for fp
init_spec_child: parent=pseudo, bad spec (zconsnex)
WARNING: failed to resolve 'scsa,probe' driver alias, defaulting to 'nulldriver'
```

These trace to `aa-fix-ntm.sh`'s *synthesised* `name_to_major` (237 entries) and
`driver_aliases` (17 entries) standing in for what `pkg install` assembles. Not a GICv3 or
`_CRS` problem.

## Banked artifacts (the durability half)

`scripts/aa-bank-proto.sh` — new. Runs on the illumos build node with only python3 + gzip/tar.
Two independent defences against the 20-byte-truncation failure that has sat in this bucket
since August:

1. SigV4 with `x-amz-content-sha256` = sha256 of the **whole** body, so a truncated body
   cannot produce a valid signature and the store rejects it rather than keeping a short object.
2. Read-back: `GET` the object, stream-hash it, compare sha256 **and** byte count. Success is
   decided only by that comparison, never by exit status.

Verified with a positive case and **four negative controls**, all measured:

| control | result |
|---|---|
| proto missing `unix` | exit 2, refuses to bank |
| `unix` only 20 bytes | exit 2, refuses |
| stored object sabotaged | `verify` exit 1: `expected bd1eed47…/350641 got fe7d8cce…/23` |
| bogus credentials | PUT 403, exit 1, no false pass |

Banked at `s3://solnix-cache/ami/aarch64-proto-20260912/`:

| object | bytes | sha256 |
|---|---|---|
| `proto-root_aarch64.tar.gz` | 122,611,618 | `40596bc145b1d1d3b7d6185e15da0034d87f210a7e960a379de782935809cffa` |
| `illumos-disk.img.gz` | 286,011,323 | `b728149dfe0e898416b3804a2fc1bb47d01aac1bf3841e7756be25a2baa0c90d` |
| `MANIFEST.txt` | 839 | `45305f0e0c3d6de6447d106e6235c39628ce02366ce33e78317ef26bdd66b4bc` |
| `SHA256SUMS` | 241 | `d7b1b5d421fd7d7a1d02b8e0b5db47584c7f3401beab8401e5f841c23877b4bd` |

Verified three ways: on-node read-back during upload; a second `verify` run from a *different
host with different credentials* against the store alone; and a bucket listing plus
unauthenticated `HEAD` showing the full byte count. Restore:

```sh
curl -fsSL https://s3.solnix.io/solnix-cache/ami/aarch64-proto-20260912/proto-root_aarch64.tar.gz \
  | gzip -dc | tar xpf -      # Solaris tar needs the explicit 'f -'
```

Proto contents: `unix` 2,148,536 B (`ELFCLASS64`/`EM_AARCH64`/`ET_EXEC`), `genunix` 7,897,896 B,
`loader64.efi` 782,848 B, 33,699 files.

## Corrections to the record

**1. The documented seed URL is wrong.** `archive/aarch64/aarch64-seed-cross-14.3.0.tar.gz`
**404s**; the `archive/` prefix does not exist in the bucket at all. The real key is
`seed/aarch64-solaris/aarch64-seed-cross-14.3.0.tar.gz` (286,655,805 B, HTTP 200
unauthenticated). The wrong path appears in `docs/aarch64-native-readiness-verdict.md:35` and
`docs/design-aarch64-bootstrap.md:1617,1659`. The asset claim was true; the address was not.

**2. The seed shortcut works, and it is why this fit in one run.** The banked seed is the
installed output of the `boot-gcc` + `gcc` legs at the same `--prefix` layout, so
`rsync`-ing it into `build/cross/` is what `gmake install` would have written. Verified
*before* stamping: `-dumpmachine` → `aarch64-unknown-solaris2.11`, a `.c` → `EM_AARCH64`
relocatable, and a full link → `ET_EXEC`. Those are the two multi-hour legs.

**3. `nightly` reported FAILED but had already produced the kernel.** `/usr/ast/bin/msgcc` is
missing, so every `libast` `.mso` target died `Error 127` and the `check` phase failed — after
the `uts/` legs had built and staged `unix` + `genunix`. Reading the tree rather than trusting
the exit status is what turned a "failed build" into a banked proto.

**4. The QEMU "failure" was an invocation mismatch, not a regression.** `aa-qemu-boot.sh`
hardcodes `-machine virt` = **GICv2**, so dboot printed `MADT missing GICv3
distributor/redistributor` and reset-looped (15 EDK2 banners in ~5 min, 13 × `BOP` with zero
`BCONS`). With `-machine virt,gic-version=3`: 2 banners, `BOP`+`BCONS`, `illumos Version`,
`scsi_vhci0 is /scsi_vhci`, `Performing full ZFS device scan!` passed, and
**`root on armpool/ROOT/braich fstype zfs`** — ZFS root mounted, no regression. Note the same
*silent-reset-loop shape* arose from a completely different cause; counting EDK2 banners is
what told them apart.

**5. The `a6-cumulative-all-legs` trap is real in a fresh tree.** After applying it,
`boot_uart.c` was untouched and still had **both** unbounded spins (`while (FR & TXFF)` at
:98, `while (!(FR & TXFE))` at :105). The whole FR-poll patch conflicts because its
`fakebop.c` half is already in cumulative, so only its `boot_uart.c` hunk was extracted and
applied. Verified by counting constructs: 0 unbounded spins, 2 bounded `for (cap = 0` loops.
`a6-acpi-handoff` was deliberately skipped as a strict subset of cumulative;
`a6-loader-efipart-chunked-read` was already present.

## Five host-prereq gaps, none in `oi-build-host-setup.sh`

Each failed in the silent-missing-GNU-tool shape:

1. **`patch(1)` absent** → `make download` died at `download-perl` (`Error code 127`). Fix: `text/gnu-patch`.
2. **`makeinfo` absent** → `binutils-gdb` died on `doc/bfd.info`. Fix: `text/texinfo`.
3. **`developer/illumos-closed` absent** → nightly aborted at `nightly:438` (`! -d $ON_CLOSED_BINS`).
4. **`astdev`/`msgcc` absent** → the `libast` failure above. `pkg search basename:msgcc` finds nothing, so the providing package still needs identifying.
5. **u-boot host tools fail** — `tools/image-host.c` needs `EVP_MD_CTX_new`/`_free`, absent from the host OpenSSL 1.0.2u headers. Stamped past: u-boot is not a nightly input (the kernel does not link it, QEMU uses EDK2 AAVMF, Nitro supplies its own UEFI).

Also mandatory: `pkg update` **then reboot** before installing prereqs — `python-313`, `gcc-14`,
`git`, `gnu-coreutils`, `gnu-binutils` are all rejected by the shipped
`userland-incorporation` until then. With python-313 present first, the documented `sgs`
python-version wall did not fire.

## Resources (all terminated)

| id | type | state |
|---|---|---|
| `i-03526e3d3334a569e` | `c6g.metal` | **terminated** |
| `i-0632f497304c2d487` | `m5.8xlarge` | **terminated** |
| `i-031512c267ca596e4` | `c5.2xlarge` | **terminated** |

Kept deliberately: `ami-04a384a52cfe7f52a` (arm64/uefi), `snap-059d64acb0e69ffa4`,
`vol-097ef2a45642b2189` (300 G gate tree, `DeleteOnTermination=false`),
`vol-00a8927b196048dcc` (10 G image). `sg-guard.sh audit` → **CLEAN** at task end; no SG rule
was created at any point (the detector was proven able to fail via `SG_GUARD_SELFTEST=1` →
DIRTY). Image transfer used `curl | gunzip | dd` onto a device identified by **EBS serial**,
never by device ordering; no `zpool import`, no `format`, no chained disk probe.

**Operational slip, disclosed:** a malformed `scp` argument list briefly copied
`~/.ssh/solnix-lava2.pem` to the build node at 14:14Z. Deleted immediately and confirmed absent
(`find / -name solnix-lava2.pem` → nothing). It was mode 0600, root-only, on a host whose SG
allows `:22` from the operator /24 only, exposed roughly one minute. The key was **not**
rotated — flagging for the maintainer to decide.
