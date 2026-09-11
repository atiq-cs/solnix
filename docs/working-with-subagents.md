# Working with sub-agents on this project

Hard-won from a long campaign in which **agents truncated or wedged ten times**. None of
those runs lost work, and the reason is entirely mechanical: they were checkpointing. This
file is the distilled version of what to put in every brief.

## The truncation reality

Agents die mid-task, mid-sentence, with no warning. Observed tool-counts at death: 42, 51,
121, 132, 195, 206, 210, 215, 282, 365 — and *successful* completions occur across the same
range. **There is no safe tool-count and no warning.** Plan for every run to be cut off at a
random point.

Therefore the brief's job is not to prevent truncation. It is to make truncation **harmless**.

## The four rules that actually did the work

### 1. Checkpoint after the FIRST step, then every milestone, with FULL PATHS

Not at the end. Not "when there's something to report."

```
Write /tmp/<task>-progress.txt on the DEV BOX after your FIRST step, and update it
after EVERY milestone with FULL PATHS and every AMI/snapshot id you create.
```

Three agents truncated in one day and **all three were fully salvaged** from their
checkpoints — one of them had already found the single most valuable result of the day
(the console costing ~13 s/char) and would otherwise have taken it to the grave.

**Full paths matter specifically.** One agent's artifacts were briefly believed lost because
the harvest looked in the wrong repo — the file said "persisted" without saying *where*.

### 2. "Persisted to disk" is not "safe" — only committed is safe

Agents must not commit (the orchestrator does), so the orchestrator must **commit as work
appears**, not at task end. Nine load-bearing patches sat untracked for weeks because nobody
did. A near-miss: two files were reported lost, found untracked, and were one careless clean
from actually being gone.

### 3. Cost check FIRST when an agent dies

Before reading the result, before salvaging: **is something expensive still running?** A
`c6g.metal` left running is real money. Check, terminate, *then* investigate. Also verify any
temporary security-group rule the agent opened was revoked.

### 4. Tell them refuting the brief is a good outcome

Say it explicitly:

```
This is a HYPOTHESIS, not a diagnosis. Measure before you change anything. If the
evidence refutes it, say so plainly and follow where the evidence leads — that is a
good outcome, not a failure.
```

Five substantive corrections to the orchestrator's own briefs came back this way, including
one that would have wasted an expensive hardware test and one that caught an ABI break
(an oversized `ucontext_t` that would have smashed the stack on real hardware). The
orchestrator was reliably wrong wherever it reasoned from general knowledge instead of
tracing the actual dependency or measuring the actual value.

## Verification demands that keep paying

* **Negative-control the test.** "Sabotage the mechanism and confirm the check flips to
  FAIL." A test that cannot fail proves nothing. This caught a harness that got the right
  answer for the wrong reason, and one that tested a function but not its *input path*.
* **Judge flaky things by RATE, not one pass.** "Boot rate over ≥6 attempts." A dispatcher
  race hid behind 2/10-vs-8/10 and was invisible to any single run. A single pass also led to
  a compiler being blamed for what was a kernel bug.
* **Demand the mechanism, not a plausible story.** One symptom got blamed on a compiler
  version, then on committed binaries, and was a dead `TS_IDLE` comparison all along. Rule:
  **distrust a plausible explanation until the mechanism has been observed.**
* **Insist on REAL vs STUB vs ENOSYS tagging** in anything partial. "A stub reported as an
  implementation is worse than a known gap."
* **Ask what a comparison is actually comparing.** A cross-environment comparison looked
  like evidence and was meaningless — the two boots ran *different drivers*.

## Platform-specific hazards to restate every time

* **Wrap every remote command**: `timeout -s KILL <n> setsid ssh` + ONE short
  non-interactive command. Background long work on-node (`nohup ... > /tmp/x.log 2>&1 &`) and
  poll the logfile with separate short reads.
* **Never let an agent run an unbounded recursive `grep`/`find` over this repo.** One agent
  wedged permanently — zero progress past tool use #10, ~15 minutes with no output — on
  `grep -rn "driver_aliases" --include='*' -l .`. This repo holds multi-GB artifacts, committed
  `.a` archives, a ~1MB generated header, and image/ISO blobs, so an unbounded walk never
  returns and the harness has no timeout to save it. Require in every brief: `--exclude-dir=.git`,
  `-I` to skip binaries, a **specific subdirectory**, a trailing `| head`, and an outer
  `timeout 60`. This is the same class of hazard as the ssh rules below: a command that cannot
  be interrupted is worse than one that fails.
* **Do NOT diagnose a wedge from a frozen tool count over one interval.** The orchestrator did
  exactly that and was **wrong**: an agent sat at 10 tool uses for ~15 minutes and looked
  hung — the transcript even showed it had just issued an unbounded recursive grep, which made
  the story compelling. It was merely SLOW; it went on to 32 tool uses and was the one actually
  writing its checkpoint. The unbounded grep was real but not fatal.
  This is the *general* rule failing on its author: **a plausible explanation is not a diagnosis
  until the mechanism is observed.** Before declaring a wedge, require BOTH: a frozen tool count
  across *several* well-separated checks, AND a stalled checkpoint file. On tasks whose steps are
  long (reading multi-MB console logs, walking a 150G gate tree) minutes of silence are normal.
  Cost of the false positive here was mild — a redundant agent queued 27 minutes and never ran,
  so no spend and no file touched — but re-dispatching a duplicate onto a task that is already
  progressing risks two agents fighting over the same files.
* **Never** `zpool import` / `format` / chained disk probes over ssh — they block forever and
  the local `timeout` will not save you.
* **`aws ec2 get-console-output --latest` is the only safe console read** — a plain API call
  that cannot hang. Serial-console SSH wedged multiple agents.
* **An instrument that changes the system is not an observer.** Debug output on one platform
  cost ~13 s/char, so 19 markers injected ~2.5 hours of settle time and invalidated an A/B
  experiment outright. If adding output changes behaviour, suspect the output's cost before
  believing the hypothesis it was added to test.
* **Never open a security group to 0.0.0.0/0 or ::/0**, ever. Scope to the operator /24.
  Revoke temporary rules before finishing.
* **Tag every resource** and never touch another tenant's or agent's instance/volume — these
  accounts are shared.

## Hazards measured in the multi-agent campaign (fold these into every brief)

These are in `/tmp/briefs/COMMON.md` as a reusable preamble; the durable copy is here.

* **Flaky things in this project are BURSTY, so a small sample lies.** Measured on the riscv64
  gates: **1/4, then 8/8 on the identical tree**, then 4/4 loaded and 4/4 idle — 17/20 overall with
  the three failures *consecutive*. "Judge by rate" tacitly assumes independent attempts; these are
  not. A 4-run sample inside a burst reports 25% and outside reports 100%, **both honestly**. Ask
  for **>=8 runs**, and for the *clustering* to be reported rather than averaged away. Host CPU
  load was measured NOT to be the trigger, so "the box was busy" is not an explanation.
* **Ask whether the cited evidence EXISTS.** Three stale claims were retracted in one session, all
  caught by looking for the file rather than reasoning about plausibility: an install path
  documented "VERIFIED" citing a proof log **never present in git**; "regeneration measures 6/6"
  that was a lucky timing phase; and a PCIe "Ground truth" table measured on a **VM** and used for
  metal. The shape is always *a real measurement, correctly recorded, then summarised one step too
  confidently* — and **the summary outlives the caveat.** Annotate the retraction at the SOURCE,
  not only in the doc that supersedes it, or the next reader inherits it.
* **An observation window shorter than the phenomenon's period sees nothing.** An aarch64 "stall"
  was recorded as reproduced from a **27-second** console read containing ONE firmware banner; it
  is really a reset loop on an ~8-10 minute period. Four agents inherited the wrong phenomenon.
  Before concluding "hung", establish how long you actually watched.
* **illumos's missing GNU tools fail SILENTLY.** No `readlink(1)` (a `$(...)` expanded empty, so
  `ln -sf ""` no-oped and a live ramdisk got ZERO of its 13 `/dev` nodes); no `stat(1)` at all, not
  even `gstat`, so a `stat -c %s` size gate was **always false** and the `&&` check after it never
  ran; `/usr/bin/diff` prints "No differences encountered". Verify a tool exists on the target
  before depending on it; prefer POSIX (`wc -c`, `ls -ld`) or the helpers already in these scripts.
* **A `.patch` with no diff hunks is a trap** — applying it silently no-ops and ships an unpatched
  binary that looks fine. Five such files existed. `scripts/repo-integrity-check.sh` now fails on
  it; prose belongs in `.notes.md`.

## Budget the run

State a tool-use target and what to do when it runs out:

```
BUDGET: aim to finish inside ~150 tool uses. Prefer landing a well-evidenced root cause
over also attempting the fix. If you identify the cause with evidence and run out of
room, that is a SUCCESS — report it and stop.
```

Also: **"if a new blocker appears, capture its exact console text and STOP"** rather than
chaining a second fix. On a deep bring-up, one fix reveals the next; a precisely-named next
blocker is a better deliverable than a half-attempted second repair.

## Never create a world-open SG rule, including to test a guard

`0.0.0.0/0` / `::/0` ingress ends a burner account in minutes (T&C violation; fleets have been terminated).

The orchestrator did this **three times** verifying that `sg-guard.sh` could detect one. The finding was
real — the guard was blind — but the method risked the substrate the work depends on. Use
`SG_GUARD_SELFTEST=1`, which injects a synthetic hit and creates no rule. `--dry-run` tests IAM permission,
not the detector, so it is not a substitute.

Generalised: **when verifying a safety mechanism, find a way to exercise the detector without performing
the dangerous act.** If the only test you can think of is doing the dangerous thing, that is a signal the
mechanism needs a test hook, not that the test is unavoidable.

## A guard that cannot fail manufactures confidence

`sg-guard.sh` reported CLEAN across this project's whole history while auditing nothing: it set no AWS
profile, `describe-security-groups` failed with `NoCredentials`, and `2>/dev/null || true` converted that
into "no violations". The hard no-world-open rule was in fact held by hand discipline.

This is the same shape as several other errors here — the empty serial log indistinguishable from a hang,
`consconfig_errlevel` inert on a non-DEBUG kernel, a byte-grep read as a driver inventory. **Ask whether
the check could report failure at all**, and prove it with a negative control before trusting a pass.
