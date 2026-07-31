# Parallel package-build fleet

How solnix builds the registry (thousands of packages) fast, using the build
account's headroom (large vCPU quota, cost-free burner). Aggressive parallelism is the
right call here.

## Topology

- **Builder image (`solnix-builder`):** a snapshot of the `solnix-build` OI host
  once it carries Nix + the world slices + the modern toolchains (gcc-14 +
  clang). Fleet hosts launch from this — a full illumos+Nix build environment,
  reproducible, no hand setup.
- **Fleet:** N large illumos builders (~32 vCPU each; scale count
  for throughput). `scripts/oi-builder-fleet.sh up N`. Use an EBS-backed type
  with the paravirt net driver; NOT instance-store/newer-hypervisor types
  (illumos won't boot those). The image carries the
  `pit_is_broken` fix so boots are reliable.
- **Shared cache is the coordination point:** every builder pulls the base world
  + toolchains + already-built deps FROM `https://s3.solnix.io/solnix-cache`
  (signed) instead of rebuilding them, and pushes its finished packages back
  (signed). So work is never duplicated across the fleet — the cache dedupes it.

## How agents use the fleet

- The orchestrator launches the fleet, then dispatches **one package-build agent
  per builder host** (or per batch), each given: its builder IP, a slice of the
  tiered build-order (docs/registry/build-order.md), the toolchains to use
  (gcc-14 + clang), and the cache creds (sops) to publish.
- **Tier discipline:** tier N packages depend on tier N-1. Build a tier across
  the fleet in parallel, publish to cache, then the next tier's builders pull
  those deps from the cache. Within a tier, packages are independent → maximal
  parallelism.
- **Ledger:** agents update docs/registry/build-ledger.tsv (fmri, tier,
  gcc_status, clang_status, cached) so we track coverage + avoid double-work.

## Cost hygiene (still applies to a burner)

- `oi-builder-fleet.sh down` terminates the whole fleet when a build wave is done
  — don't leave 30 idle 32-vCPU hosts running overnight.
- Tag everything Role=builder-fleet so the fleet is easy to list/reap separately
  from the keepers (solnix-build, the *-PASS instances).
- Scale to the work: a few big hosts for a tier of ~100 core packages; scale up
  for the long tail of thousands, scale down between waves.

## Why cache-backed fleet beats one big host

- Linear-ish speedup: 8 builders ≈ 8x throughput on independent packages, vs one
  host serializing. The cache means the base isn't re-carried per host.
- Resilience: a builder dying loses only its in-flight batch; the cache holds
  everything already built.
- It's also the dogfood for T2.11 (the P2P distributed cache) — the fleet is the
  first "many nodes sharing pre-built assets" workload.

## Boot reliability (learned wave 1)

Wave 1: 3/5 m6i.8xlarge (32-vCPU) builders boot-hung (stock OI kernel on the
builder AMI hits the TSC/PIT early-boot hang; reboot didn't recover). The
`pit_is_broken` fix is a KERNEL SOURCE default (read in startup_tsc() BEFORE
/etc/system is parsed) — so it's baked into our built solnix kernel, NOT the
stock OI kernel the builder AMI runs, and `set pit_is_broken=1` in /etc/system
is TOO LATE to help.

The hang is vCPU-count-correlated: 16-vCPU (m6i.4xlarge) and 8-vCPU (m6i.2xlarge)
boot reliably; 32-vCPU (m6i.8xlarge) hangs ~60%. So the fleet default is now
**m6i.4xlarge (16 vCPU)** — run MORE hosts rather than bigger ones. (256 vCPU =
16 x m6i.4xlarge, all reliable, vs fighting 8 x m6i.8xlarge that half-hang.)

Proper fix (later): build a solnix-kernel builder AMI (our pit-fixed kernel) so
any size boots — or rebuild the OI gate host kernel with the pit default. Until
then: m6i.4xlarge, scale by count.

## Fleet first-boot reliability (observed 2026-07-27)

~37% of freshly-launched builders (17/46 in one batch) come up port-22-filtered /
SSH-dead — the OI cloud-image first-boot flakiness at scale (metadata-agent IMDSv1
hang and/or paravirt-net/DHCP race). Impact: wasted instances + capacity
miscount. Handling: (1) launch +30-40% over target and reap the dead (interim);
(2) fleet capacity = SSH-able count, not launched count; (3) DURABLE: rebuild the
builder image with a hardened first-boot (metadata-shim baked in + a boot settle/
retry + net/DHCP ordering) so first-boot is reliable. Agents MUST skip unreachable
hosts without blocking (they do). TODO: harden the image first-boot (PS-7-adjacent).
