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
