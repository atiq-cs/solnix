# Project instructions

See .agent-steering-domains.md for domain-specific steering (local).

## Keep the public roadmap current

The published roadmap at https://solnix.io/roadmap is generated from
`../solnix.io/site/data/roadmap.json` (a sibling checkout). Whenever a milestone
lands that changes phase state -- a release cut, an architecture crossing
planned -> in progress -> done, a RISC-V R-P bump, or the GPU stack reaching
runtime -- run `scripts/roadmap-sync-check.sh`. It compares the repo's real
state (registry rows, RISC-V phase, release notes, src/drm-port) against the
site's claimed phase states and flags drift (exit non-zero on drift). Fix drift
by editing `data/roadmap.json` (states: `planned` | `in progress` | `done`);
CI regenerates the page on push. Do NOT let the site fall behind reality again.

## Dispatching sub-agents

Read `docs/working-with-subagents.md` before writing a brief. Agents on this project have
truncated or wedged ten times at unpredictable points, and the difference between "lost a
day" and "lost nothing" has been purely mechanical: an early checkpoint with full paths, the
orchestrator committing work as it appears, a cost check before salvaging, and telling agents
that refuting the brief is a good outcome. That file also collects the verification demands
(negative controls, judge flaky things by rate, demand a mechanism not a plausible story) and
the platform hazards (never `zpool import` over ssh; `get-console-output` is the only safe
console read) worth restating in every brief.
