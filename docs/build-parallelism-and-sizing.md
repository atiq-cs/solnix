# Do we need a 300+ vCPU machine? No — and here is the measurement

Short answer: **no.** The 512-vCPU figure is an *account ceiling shared with other tenants*, not a
requirement. Our builds are dominated by phases that do not parallelise.

## What the scripts actually ask for

Across all of `scripts/`:

| requested parallelism | occurrences |
|---|---|
| `-j2` | 3 (hardcoded) |
| `-j$(nproc)` | 1 |

That is the whole inventory. **Nothing asks for wide parallelism**, so a 300-vCPU host would sit idle.

## What we have actually used

| instance | vCPU | mentions | what for |
|---|---|---|---|
| `c6g.metal` | 64 | 47 | **aarch64 boot testing** — needs metal for real PCIe/ACPI, not for compiling |
| `m5.4xlarge` | 16 | 37 | the workhorse |
| `m6i.4xlarge` | 16 | 13 | ditto |
| `c5.4xlarge` | 16 | 10 | image j was built on this |
| `m5.large` | 2 | 18 | probes, console reads |

The largest machines were chosen for **hardware fidelity**, never for core count. `c6g.metal` exists in
this project because a VM's ACPI tables lied to us, not because 64 cores were needed.

## Why more cores would not help

| phase | scaling |
|---|---|
| **livecd assembly** (`cpio`, `mkfs`, `gzip`) | **sequential and IO-bound.** `gzip` is single-core, and it compresses a ~440 MB ramdisk. This is the long pole. |
| **AMI 21-stage bootstrap** | `pkg install` + reboots — network and disk latency, not CPU |
| **illumos gate build** | genuinely parallel, but saturates around 16–32 |
| **nix derivations** | parallel *across* packages, but we run `--option substitute false`, so it is one build at a time by design |

The single most effective speedup available is **not more cores** — it is replacing `gzip` with a
parallel compressor (`pigz`) for the boot_archive, which is one line and would cut the longest phase.

## Sizing guidance

* **16 vCPU (`c5.4xlarge` / `m5.4xlarge`)** — default for image and gate builds.
* **Metal** — only when the *hardware* must be real: aarch64 PCIe/ACPI, NVMe behaviour, GPU work.
* **2 vCPU (`m5.large`)** — plenty for console reads, probes, and publishing.

## ⚠️ The ceiling is shared, which is the real constraint

The 512-vCPU limit is per-account and other tenants have held **384–608**. At the time of writing,
`i4i.metal` (`libdb-xbench-*`, 128 vCPU) belongs to another tenant — never touch `libdb-*`, `fts-*`,
`pgtv-*` and friends. So the practical question is never "how big can I get" but "how little can I take",
and 16 vCPU leaves the ceiling almost untouched.
