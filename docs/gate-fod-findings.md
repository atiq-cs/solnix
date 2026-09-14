# `pkgs/illumos/gate.nix`: the illumos gate as a real Nix derivation

What was measured, on a fresh `m5.8xlarge` illumos node (`i-0c7f14c1a71bcc8e9`, AMI
`ami-0cb14e40f9355bd0c`, Nix 2.24.15, `sandbox = false`, `system = x86_64-solaris`).

## The claim ladder, stated honestly

The brief asked for three distinct claims to be kept separate. They are:

| claim | status |
|---|---|
| **WRITTEN** FOD | **YES** — `pkgs/illumos/gate.nix`, replacing the proto-ingest |
| **BUILDING** FOD | **YES** — realised a store path from pinned source; see below |
| **REPRODUCIBLE** FOD | **see §4** — measured, not assumed |

## 1. The headline: `nightly` DOES tolerate running inside a Nix derivation

The brief's open question was whether the gate can be built inside a derivation at all —
sandbox, `SYS_spawn`, or absolute-path assumptions in `nightly` were the suspects. **None of
those is the blocker.** The gate compiled normally under the Nix builder:

```
/opt/onbld/bin/i386/dmake -m serial install                     (x5 concurrently)
.../onbld/bin/i386/cw --primary gcc10,/usr/gcc/10/bin/gcc ...    -mcmodel=kernel
    -c -o debug64/aio.o ../../common/os/aio.c
.../onbld/bin/i386/ctfconvert -X -l "5.11" debug64/aio.o
```

That is `onbld`'s own compiler driver invoking gcc-10 on `usr/src/uts/common/os/aio.c` and
`ctfconvert` generating CTF, all inside the derivation. The precedent cited in the brief
(`cmakeMinimal` 4.3.4 building from source on illumos under Nix) holds for the gate too.

Result, run 1:

| | |
|---|---|
| store path | `/nix/store/wn8w5j1pkc9k3zgkq3bsqxk285dqbi7m-illumos-gate-proto` |
| `nix-store --query --deriver` | `/nix/store/7p4xnckxli48djlh6i6k3zx85y9qm5g2-illumos-gate-proto.drv` (resolves) |
| size | **491 MB** (`du -sh`), 24,927 files |
| `unix` | `platform/i86pc/kernel/amd64/unix`, 2,616,328 B, ELFCLASS64/EM_AMD64 |
| `genunix` | `kernel/amd64/genunix`, 6,034,616 B, ELFCLASS64/EM_AMD64 |
| `libc.so.1` | `lib/amd64/libc.so.1`, 2,013,192 B, ELFCLASS64/EM_AMD64 |
| wall time | ~1 h 55 min (`dmake -m serial`), 13:49Z → 15:44Z |

⚠️ **Size correction:** the brief expected ~1 GB. The proto measures **491 MB**.
`nix path-info -S` reports 2,143,458,088 B, but that is the **closure** — it includes the
pinned *source* store path, not just the proto. For the step-3 ramdisk work the number that
matters is 491 MB.

## 2. The two things that actually blocked it — both environment-shaped

Neither was a sandbox or syscall problem. Both were found by running the build, not by
reasoning about it.

### Blocker 1: `Usage: su [-] [ username [ arg ... ] ]`

`nightly` died before creating `proto/` at all.

**Mechanism (observed):** `usr/src/tools/env/illumos.sh:217` does `export STAFFER="$LOGNAME"`.
`nightly`'s `staffer()` function runs `eval su $STAFFER -c \'$arg\'` whenever it is root
(`ISUSER -eq 0`). **Nix's builder environment contains no `LOGNAME` and no `USER`.** Proved
with a probe derivation whose entire `env` is:

```
HOME=/homeless-shelter  NIX_BUILD_CORES  NIX_BUILD_TOP  NIX_LOG_FD  NIX_STORE
PATH  PWD  SHLVL  TEMP  TEMPDIR  TERM  TMP  TMPDIR  builder  name  out  system
```

So `STAFFER` is empty, the command becomes `su -c <cmd>`, and illumos `su` reads `-c` as the
*username*.

**Fix:** export `LOGNAME`/`USER=root` and a real writable `HOME` in the builder (Nix's
`/homeless-shelter` does not exist), and pin `STAFFER` in the generated `solnix.sh`.

### Blocker 2: `nightly: Error: VERSION not set`

**Mechanism:** `nightly:1645` does `git -C "$CODEMGR_WS" describe --long --all --dirty`, which
printed `fatal: No tags can describe 'ac45d71fc2b04a5422e72a14b54dd1e746e7be07'`. This is
**not** a missing `.git` — the build copy has one; I checked rather than assuming. `git
describe` only considers refs that are *ancestors* of `HEAD`, and a pinned historical rev has
none (`refs/heads/master` is a *descendant*).

**Fix:** pin `export VERSION=solnix-<rev12>`. This is strictly *better* for reproducibility
than the git-derived value, which embeds `--dirty` state and whatever refs the local clone
happens to have. The string lands in `uname -v`.

Also required: `CODEMGR_WS` retargeted from the template's `git rev-parse --show-toplevel` to
the writable build copy.

## 3. The proto assertion, and its negative control

`nightly` **exits non-zero while still producing a good kernel** — confirmed on our own build,
where run 1 exited non-zero and the proto was fine. So `|| true` is correct and the exit code
cannot be the verdict. `gate.nix` therefore *inspects the proto*: `unix`, `genunix` and
`libc.so.1` must exist **and** be ELFCLASS64/EM_AMD64, and `usr/include` must exist.

`scripts/gatefod-assert-proto.sh` holds the identical logic plus a `selftest`:

```
complete proto ................ PASS    (positive control)
empty proto ................... REJECT
partial proto (no kernel) ..... REJECT
wrong arch (ELFCLASS32/EM_386)  REJECT
zero-byte genunix stub ........ REJECT
selftest: 5/5 as expected
```

5/5 **on illumos** and 5/5 on the Linux dev box. Two further controls, because fabricated
inputs alone are weak evidence:

* **Real-data control:** `check /` against the node's live root accepts the actually-running
  kernel (`unix` 2,328,608 B, `genunix` 4,633,584 B, `libc` 1,992,008 B).
* **Production control:** the assertion **fired for real, twice**, on the two failed runs
  above — `FATAL: no proto dir ... the build produced nothing`. Had `gate.nix` trusted
  `nightly`'s exit code it would have installed an **empty `$out`** both times.

## 4. Reproducibility

An `outputHash` is only meaningful if the output is byte-reproducible, and **a wrong
`outputHash` is worse than none** — it fails at *download* time with a confusing hash mismatch
instead of failing loudly at build time. So `outputHash` in `gate.nix` is **opt-in and
defaults to `null`**, i.e. a plain content-addressed derivation. It should be set only from a
measured two-build comparison.

Both builds ran to completion. Run 2 used identical inputs, forced into a separate store path
so the cache could not short-circuit the measurement.

| | |
|---|---|
| A | `/nix/store/wn8w5j1pkc9k3zgkq3bsqxk285dqbi7m-illumos-gate-proto` — 24,927 files |
| B | `/nix/store/3bbc2zcsswjcz9rw2cdk9gch9rcj5zi9-illumos-gate-proto-run2` — 28,069 files |

**Verdict: NOT byte-reproducible.** 24,775 of 24,927 shared files are identical; **152 differ**
and **3,142 exist only in B**. So `outputHash` stays `null`, and an FOD would be wrong today.

Measured with `scripts/gatefod-repro-diff.sh`, which is itself negative-controlled: it detects
an extra file, detects same-size content drift, and reports `BYTE-IDENTICAL` on a true copy.

### The mechanisms, established by dumping bytes rather than assuming "timestamps"

**1. 125 of the 152 are the derivation's own fault — a random build path in DWARF.**
The builder used `mktemp -d "$buildRoot/gate-build.XXXXXX"`. Run A's objects embed
`/var/tmp/gate-build.VPWgKb/illumos-gate/usr/src/common/avl/...`; run B's embed
`/var/tmp/gate-build.mPafJD/...` — same length, same everything else:

```
A:  /   v   a   r   /   t   m   p   /   g   a   t   e   -   b   u   i   l   d   .   V P W g K b
B:  /   v   a   r   /   t   m   p   /   g   a   t   e   -   b   u   i   l   d   .   m P a f J D
```

This is **not** an illumos or `nightly` problem — I introduced it. **Fixed:** the build path is
now a fixed `$buildRoot/solnix-gate-build`, with an explicit `.lock` (a fixed path means two
concurrent builds would collide) and a clean-before-build. That should make those 125
reproducible for free; re-measuring is the obvious next step and is *not* claimed here.

**2. 24 are jars and seed databases.** `usr/share/lib/java/dtrace.jar` (155,059 differing
bytes), `opt/SUNWdtrt/tst/common/java_api/test.jar`, `lib/svc/seed/{global,nonglobal}.db`,
`usr/lib/libzpool.so.1`. Zip/jar containers embed member mtimes; the SMF seed databases carry
creation state. These need `SOURCE_DATE_EPOCH` plus jar normalisation.

**3. Three differ in size**, two of them trivially: `slp.jar` and `slpd.jar` are off by exactly
one byte, and `.nightly-log/nightly.log` is a log (124,737,710 vs 124,737,747 B) — that one is
expected and could be excluded from the hash.

**4. The 3,142 files only in B are the most interesting result**, and they are not drift:
they are `usr/lib/iconv/*.so`. Run A's `nightly` died in the CHECK phase before staging them;
run B got further. **The two runs were not the same build phase-for-phase**, which is a
determinism problem in its own right and traces back to the missing `msgcc` (hazard 4 below).
Fixing that is a prerequisite to any hash, independent of the DWARF paths.

⚠️ `DT_SUNW_CHECKSUM` also differs (`elfdump`: `0x823f` vs `0x8240`), but it is a *consequence*
of the content drift, not an independent cause. I checked rather than counting it as a fifth
mechanism: **zero** files differ by checksum alone.

### Re-measurement after the fixed-build-path fix (runs 3 and 4)

Two more full builds of the *fixed-path* derivation, run sequentially:

| | |
|---|---|
| r3 | `/nix/store/bl8xgamhfjdgryv1c3s3sv2yg8s6qha4-illumos-gate-proto-r3` — 28,069 files |
| r4 | `/nix/store/6pn68bpyyrriyf7kqxjiaylzvp21r09j-illumos-gate-proto-r4` — 22,242 files |

**The DWARF-path fix worked: differing shared files fell from 152 to 24**, and 22,218 of
22,242 shared files are now byte-identical. What remains in that 24 is exactly the predicted
residue — `libc.so.1`, `libc_hwcap{1,2,3}.so.1`, `libzpool.so.1`, the jars
(`jdtrace.jar`, `test.jar`, `Audit.jar`, off by 1 byte at offset 11 — a zip mtime), the SMF
seed DBs (`global.db`, `nonglobal.db`, differing at byte 61), `libssp_ns.a` (ar timestamp), and
the log.

**But the file-count divergence got worse, and it is the real blocker.** Across four builds
of identical inputs, the count of staged `usr/lib/iconv` files was:

| build | 1 | 2 | r3 | r4 |
|---|---|---|---|---|
| files total | 24,927 | 28,069 | 28,069 | 22,242 |
| `usr/lib/iconv` files | 179 | 3,321 | 3,321 | **0** |

That is **not** monotonic drift and not something the build-path fix influenced — r3 and r4 are
the *same* derivation. It is bursty, which is this project's documented pattern for flaky
things, and a two-build sample would have reported either "fixed" (r3 vs run 2, identical
counts) or "much worse" (r3 vs r4) — **both honestly**.

**What is established:** the two nightly logs are the same length (186,504 lines) and contain
the *same* 3,789 `usr/lib/iconv` lines and the same `geniconvtbl` activity (257 each), so both
runs did the same work. In r4 the entire `usr/lib/iconv` **directory is absent** from the
output, not merely empty. The `libast`/`libcmd` targets that fail for want of `msgcc`
(`Error 127`) issue `rm -f <proto>/usr/lib/...` against the proto as part of their
rm-then-install idiom, and `usr/perl5/5.42/bin/i386/perl: not found` fails the same way in the
`cmd/perl` tree.

**What is NOT established:** the precise trigger that makes those removals win over the
installs in some runs and not others. I can name the failing subsystem and show it is bursty; I
cannot yet show the mechanism, and per this project's own rule a plausible story is not a
diagnosis. **This is the precise next blocker**, and it is upstream of any `outputHash`: no
hash can be pinned while the *file set* varies by 5,827 entries between runs.

### Recommendation

Keep `gate.nix` a **plain (non-FOD) derivation** for now — which is what it is. It is
content-addressed by its own NAR like any other derivation, it fails loudly at build time
rather than at download time, and the proto assertions already guarantee the output is real.
Revisit `outputHash` only after, in this order:

1. **Install `msgcc` and a working `/usr/perl5/5.42/bin/i386/perl`** and re-measure the file
   count over **>= 4 builds**, not two. This is the blocker; the iconv variance is 5,827 files
   and no hash survives it. (`msgcc` is the one prereq `oi-build-host-setup.sh` gates rather
   than installs, and this is the cost of that gap.)
2. `SOURCE_DATE_EPOCH` + jar/ar normalisation for the 24 residual files.
3. Only then compute the hash, from builds that already agree.

The alternative the brief asked about — a **non-FOD impure derivation** — is exactly the
current state, and on this evidence it is the correct one, not a fallback. It fails loudly at
build time, the proto assertions guarantee the output is real, and it does not pretend to a
reproducibility that four measured builds refute.

## 5. Host prereqs — three corrections to `oi-build-host-setup.sh`

Measured on the base AMI, all three absent from the script until now:

1. **`pkg install a b c` aborts the entire batch on one bad pattern.**
   `developer/versioning/patch` does not exist (the real name is `text/gnu-patch`) and it took
   all 15 other packages down with it. Install one at a time.
2. **The base AMI ships no compiler at all.** `/usr/gcc/{10,14}` contain only `lib` —
   runtime libraries, no `bin/gcc`.
3. **`userland-incorporation@0.5.11-2025.0.0.31598` rejects most of the gate prereqs** —
   `gcc-10`, `gnu-make`, `flex`, `bison-38`, `git`, `texinfo`, `cups`, each with
   `Reason: This version is excluded by installed incorporation`. The brief flagged this for
   `developer/gnu-binutils`; it is **not** specific to binutils. `pkg update` (new BE +
   reboot) lifts it, after which every one of those installs cleanly.

## 6. Four hazards worth carrying forward

Each one produced a *confidently wrong* result before being caught.

1. **An ssh mux master makes key auth untestable.** Every candidate key appeared to
   authenticate because `~/.ssh/config` sets a `ControlPath` and the requests rode an existing
   master. Only with `-o ControlPath=none -o ControlMaster=no` did the truth appear: **the AMI
   trusts the OLD REVOKED keypair, not `solnix-lava2`** — the runbook's known caveat, still
   live. (Re-seeded `authorized_keys`; `solnix-lava2` works now.)
2. **`pgrep -f`/`pkill -f` match the polling command's own argv.** `pgrep -f gatefod-update`
   reported `RUNNING` for seven minutes with no such process; worse, `pkill -f gatefod-pkgs`
   *killed its own ssh shell* before the `nohup` ran, so the update silently never started.
   Use `ps -ef | grep -c "[g]atefod-..."`.
3. **illumos `od` zero-pads numeric output; GNU `od` does not.** The same byte reads `2` on
   Linux and `002` on illumos (`e_machine`: `62` vs `00062`). My ELF check compared those as
   *strings*, so it passed on the dev box and **failed on the real target** — the *positive*
   control failed while all four negatives still "passed", reporting 4/5 and looking nearly
   right. **An all-negative test suite would have reported a clean pass.** Fixed with `-eq`.
   Note the first hypothesis (nested `printf` octal escapes) was **wrong**; `awk` produced a
   correct 64-byte header on illumos. Only dumping the actual `od` output on the node found it.
4. **A tool's absence is not the failure it looks like.** `nightly` reporting `FAILED` with
   `msgcc` missing does not mean the kernel failed — `uts/` had already staged a good
   `unix`+`genunix`. That is the whole reason the assertions exist.

## 7. Scope

This is **step 1 only**. Not attempted: proto slicing (`illumos-core-utils`,
`illumos-oamuser`, …), the closure-built ramdisk, `solnix-install --config`. Those are steps
2–4 of `docs/design-nixos-iso-methodology.md` §"Order of work", each its own run.
