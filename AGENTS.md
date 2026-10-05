# Project instructions

See .agent-steering-domains.md for domain-specific steering (local).

## solnix.io belongs to the infra team; we are a client of its APIs

The site, the binary cache (cache.solnix.io), the search API (search.solnix.io),
the submit pipeline and staging (staging.solnix.io), and the `../solnix.io`
checkout are owned by the infra team. Do not edit, commit to, deploy or operate
anything there, and do not use its credentials. We use the public endpoints and
the documented submit flow (`docs/cache-submit-onboarding.md`) like any client.
When something on their side is wrong or missing, write a report to
`/tmp/solnix-io-<topic>-report.md` (what we observed, the exact request and
response, what we need) and hand it to the maintainer, who routes it to that team.

## Keep the public roadmap current

The published roadmap at https://solnix.io/roadmap is generated from the infra
team's `site/data/roadmap.json`. Whenever a milestone lands that changes phase
state -- a release cut, an architecture crossing planned -> in progress -> done,
a RISC-V R-P bump, or the GPU stack reaching runtime -- run
`scripts/roadmap-sync-check.sh`. It compares this repo's real state (registry
rows, RISC-V phase, release notes, src/drm-port) against the site's claimed
phase states and exits non-zero on drift. On drift, write the required state
changes (states: `planned` | `in progress` | `done`) into a report in /tmp for
the infra team, per the rule above; do not edit their file.

## When a design decision comes up, check what NixOS does first

solnix aims to be exactly Nix. For any question NixOS has already answered (store
permissions, nix-daemon vs single-user, trusted-users, read-only store, what an
installer image contains, how first boot activates a toplevel), find NixOS's default
and use it. Depart from it only where illumos can't do the same thing (no Linux mount
namespaces, no seccomp sandbox), and write down why. Don't invent a solnix-specific
answer when NixOS has a working one.

## Dispatching sub-agents

Read `docs/working-with-subagents.md` before writing a brief. Agents on this project have
truncated or wedged ten times at unpredictable points, and the difference between "lost a
day" and "lost nothing" has been purely mechanical: an early checkpoint with full paths, the
orchestrator committing work as it appears, a cost check before salvaging, and telling agents
that refuting the brief is a good outcome. That file also collects the verification demands
(negative controls, judge flaky things by rate, demand a mechanism not a plausible story) and
the platform hazards (never `zpool import` over ssh; `get-console-output` is the only safe
console read) worth restating in every brief.
