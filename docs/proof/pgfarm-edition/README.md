# Proof logs — the declarative pgfarm edition

Evidence for the claim in `docs/build-farm-animal-provisioning.md` that
`configurations/pgfarm.nix` + `modules/config/pgfarm.nix` produce a working
PostgreSQL build-farm animal. Kept in the repo because a documented claim whose
proof log is not in git has been retracted in this project before.

Substrate: one `c5.4xlarge` from `ami-014c4aaccd37b2356`
(`solnix-base-x86_64-hipster-20251026-20260904`), us-east-2, instance
`i-016858bb1d7660b38` (terminated). The whole configuration was evaluated and
built natively on that illumos node with its own Nix 2.24.15.

| file | what it shows |
|---|---|
| `run_build-PASS-all-stages-succeeded.log` | The acceptance test. `run_build.pl` launched as the module-declared `pgbf` user from the module-generated driver + `build-farm.conf`, reaching the literal `All stages succeeded`. 87 stages, zero failures, `module-test_json_parser` among them. |
| `run_build-NEGCONTROL-gnuBinFirst-false.log` | The negative control. Same everything, rebuilt with `--arg gnuBinFirst false`. Ends `Stage module-test_json_parserCheck failed with status 2` — the identical failure recorded on dixi's first run. |
| `test_json_parser-NEGCONTROL-excerpt.log` | The MECHANISM, directly observed rather than inferred: subtests 2, 5, 8, 11 fail `'no output diff'` with `got: 'No differences encountered'` — illumos `/usr/bin/diff` speaking, because `/usr/gnu/bin` was no longer first on PATH. |

The control matters: it establishes that the passing run passes *because of* the
`gnuBinFirst` PATH ordering, not incidentally. Flipping one Nix option flips the
stage from green to red and back.

Not proven here, and deliberately not claimed: `system.build.toplevel` for this
configuration was NOT built, because it needs the illumos gate proto at
`/code/illumos-gate/proto/root_i386`, which was absent on this node. What was
built and run is the pgfarm role and the modules it composes with — i.e. exactly
the part that replaces `scripts/bene-provision-dixi.sh` steps 4+5. The remaining
imperative steps are listed as known gaps in
`docs/build-farm-animal-provisioning.md` and in the footer of
`modules/config/pgfarm.nix`.
