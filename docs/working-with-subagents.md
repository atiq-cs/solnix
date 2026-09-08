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
* **A wedged agent looks different from a truncated one.** Truncation ends the run; a wedge
  leaves it `running` with a **frozen tool count**. Compare tool count across two checks a few
  minutes apart — if it has not moved, it is wedged, not thinking. Cost-check, then re-dispatch
  with the specific hazard named in the brief (an addendum describing exactly how the previous
  agent died is more useful than a general warning).
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
