# Parallel package-build fleet

How solnix builds the registry (thousands of packages) fast, using the numa
account's headroom (~1024 vCPU, cost-free burner). Aggressive parallelism is the
right call here.

## Topology

- **Builder AMI (`solnix-builder`):** a snapshot of the `solnix-build` OI host
  once it carries Nix + the world slices + the modern toolchains (gcc-14 +
  clang). Fleet hosts launch from this — a full illumos+Nix build environment,
  reproducible, no hand setup.
- **Fleet:** N large illumos builders (`m6i.8xlarge` = 32 vCPU each; scale count
  for throughput). `scripts/oi-builder-fleet.sh up N`. Use `m6i.*` (ena + EBS);
  NOT instance-store/Nitro-v5+ (illumos won't boot those). The AMI carries the
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
