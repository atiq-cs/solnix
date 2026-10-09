# Builder steering: drain solnix.io's work queue, daily, with no LLM in the loop

Source: the infra team's `builder-steering-queue-and-work.md` (2026-10-08, also in their
repo as infra/docs/handoff/builder-steering-queue-and-work.md). solnix.io is theirs; we
are a client (AGENTS.md). This file is our copy of the contract plus what we MEASURED
against their live service and code on 2026-10-09 -- where the two differ, the
measurement wins and the difference goes to them in a /tmp/solnix-io-<topic>-report.md.

## The contract (what the builder must keep true)

- **Deterministic, LLM-free.** The daily driver (`scripts/solnix-builder.py`, ours to
  write and own) decides what to build only from a queue row plus its recipe. If a job
  cannot be turned into a build command mechanically, that is a recipe bug to fix, not
  a reason to add judgement.
- **Recipes are the configuration.** `docs/registry/recipes.tsv` (10 columns: pname
  version url sha256 buildsys deps flags system out debug; one row per output path)
  says how each package is built for each system. The `out` column is the authority
  anchor: solnix.io accepts a submission only for a path the SERVED copy lists. Our
  repo's file is the source of truth; the infra team reviews and publishes it.
- **Submit is mechanical.** Signed challenge (ed25519, the enrolled `site-team`
  identity), /begin -> PUT unsigned NAR + narinfo to staging -> /finalize -> poll
  /status. We never sign narinfos and never hold the cache key: the site signs with
  `cache.solnix.io-1:8UNr...`. Client: `scripts/cache-submit.py` (dry-run default).
- **Failures are queue states.** retry/backoff/attempts live in the queue; a human
  looks only at `failed` rows.
- **Security.** Build in a sandbox and never run upstream build scripts as root on the
  host. Record real reproducibility (drv, out, narhash) and never claim a hash we did
  not produce. The submit key is our identity: sops only, 0600 decrypted copies under
  /tmp, deleted after use.
- **Systems.** x86_64-solaris, aarch64-solaris, riscv64-solaris, sparcv9-solaris. A
  builder advertises only what it can actually produce.

## The queue (measured 2026-10-09, not as the doc says)

The doc describes SQL functions behind "the authenticated builder API (the same
ssh-ed25519 identity used for submit)". What is deployed:

| | doc | measured |
|---|---|---|
| read | -- | `GET https://search.solnix.io/api/v1/build-queue` -> 200 `{"counts":{"queued":19},"oldest_queued_secs":...}`; counts only, no rows |
| claim | `rebuild_claim(agent, systems, max, lease)` | `POST /api/v1/build-queue/claim` `{agent_id, systems[1..4], max 1..16, lease_secs 60..14400}` -> `{jobs:[{id,pname,system,reasons,priority,current_version,target_version,attempt,claim_token,claim_expires_at,lease_secs}]}` |
| heartbeat | `rebuild_heartbeat(job, agent, token)` | `POST /api/v1/build-queue/<id>/heartbeat` |
| complete | `rebuild_complete(job, agent, token, result)` | `POST /api/v1/build-queue/<id>/complete`; `result.status` must be `done` or `failed` (failed calls rebuild_retry inside) |
| retry | `rebuild_retry(job, message)` callable | not an endpoint: send `complete` with `{"status":"failed","error":...}` |
| auth | ssh-ed25519 builder identity | a shared bearer secret in header `X-Solnix-Build` (BuildQueueBoundary, 32..256 bytes); POST without it -> 403 (measured). We do not have this secret. |
| reasons | includes `manpage-missing` | the SQL CHECK allows only manual, policy-refresh, dep-rebuilt, upstream-newer, validation-failed; `manpage-missing` cannot be enqueued |
| work-queue.json (federation doc) | signed snapshot at cache.solnix.io | listed as "build" (not live) |

So the builder cannot claim today: it needs the queue credential (or the promised
ed25519 auth) from the infra team, and the 19 queued rows are invisible without
claiming. That is in the report to them; do not guess the secret, do not use any
operator DB access.

## Order of work for the driver

1. `solnix-builder.py run --systems x86_64-solaris` -> claim (when credentialed) -> for
   each job: recipe from the SERVED recipes.tsv for (pname, system, target_version) ->
   `nix build` the attribute (a real derivation; the north star) -> our publish gate
   (store-only RUNPATH, every NEEDED resolved, deriver, complete references) ->
   cache-submit.py -> `complete` done with `{store_path, narhash}`, or `complete`
   failed with the reason. Heartbeat every lease/3.
2. Dry-run mode end to end with a local queue file, so it is testable before the
   credential exists. Each step is negative-controlled (a broken binary fails the gate;
   a path absent from the served recipes.tsv is not submitted).
3. Where it runs: a solnix builder must BUILD, and today only an OpenIndiana host can
   (docs/pending/builders-need-store-tools.md). Until the store-tool stdenv lands, the
   daily driver runs on bhost or an EC2 OpenIndiana builder; after it, on any solnix
   system (dixi, an EC2 solnix instance) from cron.

## Man pages (the infra team's 2026-10-08 requests)

Their indexer reads `share/man/man*/*` from the NAR of any PUBLISHED package whose
ledger row has `has_manpages=y`, and wants `edition` and `origin_distro` per package.
What they asked for, in order: (1) the illumos core-OS pages (pfexec, zfs/zpool, svcs,
dtrace, zoneadm, dladm/ipadm, beadm, ...) as an `illumos-man` package carrying the
gate proto's /usr/share/man; (2) coreutils and the core userland with their man pages
(help2man at build time); (3) distro-specific pages (SmartOS, OmniOS, OpenIndiana,
Tribblix) where solnix takes a tool from them. docs/design-manpages.md covers per-package
pages; the gate's pages are the new work. Both are published through the same queue and
submit path; the queue cannot carry `manpage-missing` until they add it to the CHECK.
