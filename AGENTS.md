# Project instructions

See .agent-steering-domains.md for domain-specific steering (local).

## Where work runs: EC2 solnix instances or arnold, never floki

Host names (maintainer, 2026-10-24; d = EC2, l = local hardware):
- **dixi**: x86_64 EC2 host. **dixa**: aarch64 EC2 host. **dixr**: hosted riscv64 server, headless, no GPU (likely qemu-system-riscv64 on EC2, emulating a many-core, large-RAM virt machine).
- **lixi**: ThinkPad X1 Extreme Gen 5 (192.168.1.11; i9-12900H, Iris Xe, RTX 3080 Ti, AX211).
- **arnold**: ThinkPad X1 Extreme Gen 1 (192.168.1.37; i7-8850H, UHD 630, GTX 1050 Ti, AC 9560). It runs Fedora today.
- **lixr**: Milk-V K3, riscv64 (192.168.1.179).
Docs older than 2026-10-24 say "dixi" for arnold and "arnold" for lixi.

Builds, image builds, VMs (KVM/QEMU, bhost) and boot tests run on EC2 instances
(solnix instances where possible) or on arnold, the maintainer's X1 (called dixi before 2026-10-24). Not on floki,
the dev box: floki is for editing, git, evaluation (`nix eval`), reading sources,
and driving remote machines over ssh. No local qemu guests there, bhost included.
The maintainer restated this on 2026-10-09 after a session ran bhost and KVM
boot tests on floki. When no EC2 account works (burner accounts expire:
docs/account-expiry-hotdog.md), say so and ask for one rather than falling back
to floki. Image builds that need an OpenIndiana host go on an EC2 OI builder
restored from R2 (docs/account-migration-lava-to-hotdog.md), and KVM boot tests
go on an EC2 metal instance (nested virtualization) or real hardware.

The current EC2 account is **chef** (`AWS_PROFILE=chef`, `842964983020`, us-west-2), since 2026-10-30; its
expiry is not known yet (burners live about 7 days). docs/account-migration-kiwi-to-chef.md. kiwi (`437803535746`)
closed 2026-10-30 19:14:53 UTC (docs/account-expiry-kiwi-20261030.md). Durable images live in the permanent account
**solnix-ami** (`788352824872`): the OI build host `ami-0e4a740ebfc5bec81`, aarch64 v4 (boots on Nitro VMs)
`ami-0e08aa06f629ffbac` (us-west-2) / `ami-0ecdc3a731f13adff` (us-east-1), the x86 DP fix AMIs. Share an image to a new
account with `modify-image-attribute --launch-permission` from solnix-ami. Name `AWS_PROFILE` explicitly (sg-guard has
no default), re-check `describe-instances` before a launch, never a `0.0.0.0/0`/`::/0` rule, and terminate instances
plus their volumes after. Burner accounts are shared with other tenants (chef had a libxtc instance on day one); touch
only Project=solnix resources, and check free vCPU before a metal launch.

**Burner accounts live about 7 days.** Anything that took more than an hour to make, or
that someone depends on (boot-verified AMIs as raw disk images, build hosts, toolchains,
installer images, test evidence), is backed up OFF the account the same day it is
verified: to floki `/home/gburd/solnix-bank/` and, for AMI images, the R2 bank
(`scripts/ami-bank.sh`), each read back and sha256-compared. An AMI id is not a backup.
See .kiro/steering/burner-account-backups.md.

## solnix.io belongs to the infra team; we are a client of its APIs

The site, the binary cache (cache.solnix.io), the search API (search.solnix.io),
the submit pipeline and staging (staging.solnix.io), and the `../solnix.io`
checkout are owned by the infra team. Do not edit, commit to, deploy or operate
anything there, and do not use its credentials. We use the public endpoints and
the documented submit flow (`docs/cache-submit-onboarding.md`) like any client.
When something on their side is wrong or missing, write a report to
`/tmp/solnix-io-<topic>-report.md` (what we observed, the exact request and
response, what we need) and hand it to the maintainer, who routes it to that team.

Publishing to the cache and draining solnix.io's work queue follow
`.kiro/steering/builder-queue.md` (the infra team's builder contract plus what we
measured against the deployed service): no waivers on the publish gate, nothing
host- or user-specific in the public cache, submit only what the served
recipes.tsv authorizes, and prove installability with the 8UNr client check.

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
