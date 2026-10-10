# Builder federation — a self-driving builder that drains solnix.io's work queue

Source: the infra team's builder steering (2026-10-08) and their federation design
(infra/docs/design/community-build-federation.md). Contract and measured deviations:
`.kiro/steering/builder-queue.md`. solnix.io is the infra team's; every task here is
client-side, and anything their side lacks goes to them as a /tmp report.

Prereqs: the signed submit client (`scripts/cache-submit.py`, 8090cf52); recipe rows
in `docs/registry/recipes.tsv` (28 gate-clean x86_64 rows, 8090cf52); the infra team
publishing them.

## B1 — Queue credential and contract alignment (infra answered 2026-10-09)

Infra reply builder-reports-reply-2026-10-09.md: an interim per-builder bearer token for
site-team comes via the maintainer (target state = the submit Ed25519 challenge on the
queue). manpage-missing IS enqueuable (manpage-pipeline.sql migration, live). Submit is
one-leaf-per-submission (option c): stage only the leaf; the site walks the published
closure; retry = complete with status failed. The 28 recipe rows are committed and pushed
(8090cf52); the served recipes.tsv (sha256 841aff93) picks them up on the infra sync.
Remaining open:

- The claim/heartbeat/complete endpoints are live (`/api/v1/build-queue/...`) but gated
  by a shared secret header (`X-Solnix-Build`), not the ed25519 builder identity the
  steering promises. We have no secret. Ask for: ed25519 auth on the queue (the same
  identity as submit), or the secret for our builder via sops.
- Ask them to add `manpage-missing` to the queue's reasons CHECK (the steering lists
  it; the deployed table rejects it).
- Ask for a row-level read of the queue for a credentialed builder (GET returns counts
  only: 19 queued on 2026-10-09).
- Gate: one claim -> heartbeat -> complete(failed, "probe") round trip succeeds with
  our identity, and the job returns to `queued` with attempts+1.

## B2 — `scripts/solnix-builder.py` (ours)

A plain Python script, no LLM:
- config `~/.config/solnix/builder.toml` (builder-id, key path from sops, systems,
  concurrency, cache url); `run --systems ...`, `--dry-run`, `--queue-file` (a local
  JSON queue for testing).
- loop: claim -> recipe from the SERVED recipes.tsv for (pname, system,
  target_version) -> `nix build` the attribute -> publish gate (store-only RUNPATH,
  every NEEDED resolved, deriver, complete references) -> cache-submit.py ->
  complete(done, {store_path, narhash}) or complete(failed, reason); heartbeat every
  lease/3 on a thread.
- every reason handled mechanically: upstream-newer/manual/policy-refresh (build
  target_version), dep-rebuilt (rebuild against the new dep), validation-failed
  (clean rebuild + resubmit), manpage-missing (rebuild with man pages).
- Gate: dry-run end to end against a local queue of three jobs (one good, one whose
  binary is broken, one not in the served recipes.tsv). Exactly the good one is
  submitted. Negative controls: the broken binary is refused by the gate, and the
  unauthorized path is never offered.

## B3 — Where the builder runs, and cron

- Today only an OpenIndiana host can BUILD solnix packages
  (docs/pending/builders-need-store-tools.md). Run the driver on bhost / an EC2
  OpenIndiana builder from cron until the store-tool stdenv lands.
- After it lands: any solnix system (an EC2 solnix instance first, then dixi at most 4
  streams x --cores 4 --max-jobs 2) runs `solnix-builder run` daily from cron.
- Gate: two consecutive daily runs; the second claims nothing already done (idempotent);
  a killed build is reaped and requeued (lease expiry), measured.

## B4 — Man-page corpus (the infra team's 2026-10-08 requests)

- `illumos-man`: a package whose $out/share/man is the gate proto's /usr/share/man
  (pfexec, zfs, zpool, svcs, svcadm, svccfg, dtrace, zoneadm, zonecfg, dladm, ipadm,
  beadm, ...), x86_64-solaris, recipe row with has_manpages=y, edition, origin_distro=
  illumos. Content review first: pages that describe IPS/pkg, beadm-as-upgrade, or
  /usr paths the solnix way (T3.1a).
- coreutils and the from-source userland with man pages (help2man at build time;
  docs/design-manpages.md). These ride the world rebuild (builders-need-store-tools,
  mk-src-pkg-guardfix) since they change mk-src-pkg's packages.
- distro pages (SmartOS, OmniOS, OpenIndiana, Tribblix) only where solnix ships that
  distro's tool or a modified page; origin_distro set.
- Gate: `pfexec`, `zfs`, `ls` searchable on solnix.io/docs after their hourly index
  (measured by a search request), and the published package passes the 8UNr client check.

## B5 — Federation pieces that are ours (after the infra team's build order 1-4)

- The fetch shim (swarm-first, reputation-preferring, HTTPS fallback) is listed as a
  build-team item in their design. It must keep the invariant: no client imports a
  byte whose 8UNr signature it did not verify. Not started; wait for their signed
  work-queue.json and reputation feeds (their items 1-2).
- Reproducibility attestations: record (drv, out, narhash) for every path we build and
  post them once their attestation endpoint exists.
