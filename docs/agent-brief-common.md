## Non-negotiable operating rules (read fully; violations have cost real money/work)

### Checkpointing — the single most important rule
Write `/tmp/<task>-progress.txt` ON THE DEV BOX after your **FIRST step**, then update after
EVERY milestone. Include **FULL PATHS** and every AMI/snapshot/instance id you create.
You WILL possibly be truncated mid-sentence with no warning (observed at 42/51/121/195/282/365
tool uses; successful runs span the same range). The brief's job is to make truncation HARMLESS.
Three agents were fully salvaged from checkpoints; one had already found the day's best result.
"Persisted" without a path nearly lost artifacts once — always write the path.

### You do NOT commit
The orchestrator commits. Leave work on disk with paths in your checkpoint. Never run
`git commit` / `git push`. Never use recursive-force delete (a guard blocks it); use
`find -delete` or write into a fresh directory name.

### Refuting this brief is a GOOD outcome
Everything below marked HYPOTHESIS is exactly that, not a diagnosis. **Measure before you
change anything.** If evidence refutes the brief, say so plainly and follow the evidence —
that is a success, not a failure. The orchestrator has been wrong 6+ times reasoning from
general knowledge instead of tracing the actual dependency or measuring the actual value.

### Verification demands
- **Negative-control every test**: sabotage the mechanism, confirm the check flips to FAIL.
  A test that cannot fail proves nothing.
- **Judge flaky things by RATE over >=4-6 attempts**, never one pass.
- **Distrust a plausible explanation until the mechanism is OBSERVED.** One symptom was blamed
  on a compiler, then on committed binaries, and was a dead comparison all along.
- **Tag everything REAL / STUB / ENOSYS.** A stub reported as an implementation is worse than
  a known gap.
- **Ask what a comparison actually compares** — one A/B was meaningless (different drivers).
- **An instrument that changes the system is not an observer.** If adding output changes
  behaviour, suspect the output's cost first.

### AWS rules (account `bene`, profile `bene`, region us-east-2)
- HARD SECURITY: **NEVER open a security group to 0.0.0.0/0 or ::/0.** Scope to the
  operator /24 only. Revoke any temporary rule before you finish. SG `sg-07689ce3114d45ec9`.
- **ONLY 128 vCPU of headroom** (limit 512, other tenants hold 384). Do NOT launch anything
  larger than told. Check `describe-instances` before launching.
- **The account is SHARED.** Tag everything `solnix-*`. NEVER touch/stop/terminate an
  instance or volume you did not create (`fts-*`, `libumem-*`, `osv-*`, `skiplist-*`,
  `libdb-*`, `pgtv-*`, `bcs-*`, `xtc-*`, `undo-*` belong to other tenants).
- **TERMINATE what you launch** when done, and record it in your checkpoint.
- Keypair `solnix-key`. Wrap EVERY remote command: `timeout -s KILL <n> setsid ssh` + ONE
  short non-interactive command. Background long work on-node
  (`nohup ... > /tmp/x.log 2>&1 &`) and poll the log with separate short reads.
- **NEVER** `zpool import` / `format` / chained disk probes over ssh — they block forever and
  local `timeout` will not save you. `aws ec2 get-console-output --latest` is the only safe
  console read.

### illumos gotchas (each cost hours before)
No GNU `env -u`, no GNU `sed a\ text`, no `cpio --no-absolute-filenames`, no `sort -h`;
`grep` needs `-E` for `\|`. illumos `/usr/bin/diff` prints "No differences encountered" for
identical files → install `text/gnu-diffutils` and put `/usr/gnu/bin` FIRST in PATH.

### Style
Code comments explain WHAT/WHY, never WHO/WHEN. **Never use the word "ponytail" anywhere**
(use `NOTE:`) — but never blanket-scrub it either; doing so once corrupted a real dependency
name and broke every lockfile update.

### Budget
Aim to finish inside ~150 tool uses. **A well-evidenced root cause is a SUCCESS even without
the fix.** If a NEW blocker appears, capture its exact console text and STOP rather than
chaining a second fix — a precisely-named next blocker is a better deliverable than a
half-attempted second repair.

## Addendum — hazards MEASURED this session (each one cost real time)

### Never run an unbounded recursive grep/find over this repo
One agent hung PERMANENTLY on `grep -rn "driver_aliases" --include='*' -l .` — zero progress past
tool use #10, no output, unrecoverable. This repo holds multi-GB artifacts, committed `.a`
archives, a ~1MB generated header, and image/ISO blobs; an unbounded walk never returns and the
harness has no timeout that saves it. ALWAYS: `--exclude-dir=.git`, `-I` to skip binaries, a
SPECIFIC subdirectory, a trailing `| head`, and an outer `timeout 60`.

### Flaky things here are BURSTY, so a small sample lies
Measured on the riscv64 gates: **1/4, then 8/8 on the identical tree**, then 4/4 loaded and 4/4
idle. Overall 17/20 — but the three failures were CONSECUTIVE. "Judge by rate" assumes the
attempts are INDEPENDENT and they are not: a 4-run sample inside a burst reports 25% and outside
reports 100%, both honestly. **Use >=8 runs, and if failures cluster, REPORT the clustering
instead of averaging it away.** Host CPU load is NOT the trigger (measured), so do not assume
"the box was busy".

### Check whether the cited evidence EXISTS before believing a claim
Three separate stale claims were retracted this session, all found the same way — by looking for
the file rather than by reasoning about plausibility:
* an install path documented as "VERIFIED" citing a proof log that **never existed** in git;
* "regeneration measures 6/6" — actually a lucky timing phase, not a correct kernel;
* a PCIe "Ground truth" table measured on a **VM** and used to reason about metal.
The shape is always: a real measurement, correctly recorded, then summarised one step too
confidently — and **the summary outlives the caveat.** If you rely on a documented claim, verify
its evidence first, and say so if it does not hold up.

### An observation window shorter than the phenomenon's period sees nothing
An aarch64 "stall" was recorded as reproduced from a **27-second** console read holding ONE
firmware banner. It is really a reset loop on an ~8–10 minute period. Four agents inherited the
wrong phenomenon. Before concluding "hung", establish how long you actually watched.

### illumos is missing GNU tools, and the failures are SILENT
Three cases bit this project: no `readlink(1)` (a `$(...)` expanded empty, `ln -sf ""` no-oped,
and the live ramdisk silently got ZERO of its 13 `/dev` nodes); no `stat(1)` at all — not even
`gstat` — so a `stat -c %s` size gate was ALWAYS FALSE and the `&&` check after it never ran; and
`/usr/bin/diff` prints "No differences encountered". **Verify a tool exists on the target before
depending on it**, and prefer POSIX (`wc -c`, `ls -ld`) or the helpers already in these scripts.

### A `.patch` with no diff hunks is a trap
Five files under `rust-patches/` were prose notes with a `.patch` extension; applying them
silently no-ops and ships an unpatched binary that looks fine. `scripts/repo-integrity-check.sh`
now fails on this. Prose belongs in `.notes.md`.

## ⚠️ NEVER create a world-open security-group rule — not even to test

`0.0.0.0/0` or `::/0` ingress **kills a burner account in minutes** via a T&C violation. Prior fleets have
been terminated for exactly this. Scope every rule to the networks in `scripts/operator-cidrs.txt` (Comcast `73.4.58.0/24` plus the Starlink backup
blocks) or a /32, and add every one of them, so the fleet stays reachable when the primary uplink is down.

This is not hypothetical caution about a future mistake: the orchestrator created a real world-open rule
**three times** while verifying that `sg-guard.sh` could detect one. The finding was real (the guard was
blind), but the method risked the account.

`scripts/sg-guard.sh` **refuses** world-open CIDRs on its `authorize` path, with a message about prior
terminated fleets. Do not bypass it by calling `aws ec2 authorize-security-group-ingress` directly — that
is precisely how the protection was defeated.

To prove the detector works, use:

```sh
SG_GUARD_SELFTEST=1 bash scripts/sg-guard.sh audit us-east-2
```

It injects a synthetic hit into the detector's input stream, so detection is provable **without creating
any rule**. It is purely additive — it can only push the verdict toward DIRTY, never toward CLEAN.

`--dry-run` does **not** substitute: it returns `DryRunOperation` and creates nothing, but it only tests
IAM permission, not the detector.

### And the deeper lesson: a guard that cannot fail is worse than no guard

`sg-guard.sh` reported CLEAN for this project's entire history while auditing **nothing** — it set no AWS
profile, so every `describe-security-groups` failed with `NoCredentials`, and `2>/dev/null || true` turned
that into "no violations". Same failure shape as an empty serial log being indistinguishable from a hang.
**Every guard needs a negative control proving it can report failure.**
