# Durability: what an account loss destroys, and how to not pay twice

Three burner accounts have now closed (chiuso, mala, lala). Each time, **source
was safe (git) but the BUILD ENVIRONMENT was not** — and rebuilding the
environment costs far more than rebuilding any artifact. This is the single most
expensive recurring failure in the project. The rules below exist to make the
next account loss a ~30-minute event instead of a multi-hour one.

## What actually died (and what did not)

| Asset | Survived? | Why |
|---|---|---|
| Kernel/driver source, patches, docs | **YES** | committed to git |
| Bootable AMIs (x86 10/10 base, aarch64, GPU, gtk4, pgbf) | NO | account-scoped; AMI cross-account share is SCP-denied by the org guardrail |
| **x86_64 base disk image (as of 2026-09-11)** | **YES** | **banked in R2 at `s3://solnix-cache/ami/x86_64-20260911/`, read-back verified, restore path tested (5/5 boots). This is the rule below finally being applied to an AMI.** |
| Snapshots (arm64-gate build tree, desktop session, nixpool store) | NO | account-scoped (snapshot-share worked account→account, but only while BOTH were alive) |
| The aarch64 cross toolchain + OmniOS gate env | NO | lived only on the build node's volume |
| The RISC-V toolchain + prebuilt seed userland | NO | lived only on the dev node |
| Node-local assets referenced by scripts (e.g. `/root/solnix-assets/ena-mtu-fix`) | NO | never captured; the *patch* was in git, the built module was not |

The pattern: **anything a script references by node-local absolute path is a
future loss.** Either the input (patch/source/recipe) is in git and the artifact
is cheaply rebuildable, or the artifact must be snapshotted.

## Rules

0. **Bank the artifact off-account, and VERIFY IT BY READ-BACK.** A recipe alone is not
   enough: a one-hour rebuild is still a bad day when it is the only copy, and three burner
   losses were each answered with a *new per-account script* (`beef-`, `ouch-`,
   `bene-make-base-ami.sh` — one per dead account) rather than a durable artifact. R2 is not
   account-scoped; use it. `scripts/ami-bank.sh` is the worked example (bank / verify /
   restore, all three tested). **Never trust an upload's exit status** —
   `images/release-224-ena-mtufix/solnix-raw.img.gz` in that bucket is 20 bytes, a silently
   truncated upload from a command that exited 0. Re-download and compare sha256.
1. **Snapshot a toolchain the moment it works — before using it.** A cross
   toolchain (`make download` + `make setup`, or the RISC-V seed gcc) is hours of
   wall clock and is pure derived state. When it first builds clean: snapshot the
   volume AND register an AMI, tagged `solnix-<arch>-buildhost`. Do it *before*
   the first nightly/image run, not after.
2. **Build trees live on a separate EBS volume with `DeleteOnTermination=false`.**
   Never on the instance root. Then a wedged/degraded node is disposable: stop it,
   attach the volume elsewhere.
3. **Prefer STOP over TERMINATE** for a build host whose volume you still want,
   and snapshot before stopping if the work is significant.
4. **"Copied to the dev box" is NOT "safe" -- only COMMITTED is safe.** A real
   near-miss: the riscv64 libc patch and syslib shim were written into the repo
   working tree and left UNTRACKED. They were briefly believed lost with a
   terminated node (the check looked in the wrong repo), and even once found they
   were one careless clean from genuine loss. Corollary for the orchestrator:
   harvesting an agent's artifact is not done until `git commit` has run. Corollary
   for agents: say WHERE you persisted something, with a full path, so the harvest
   cannot look in the wrong place.
5. **A script must not depend on an un-captured node-local artifact.** If a
   script wants `/root/solnix-assets/X`, then either X's *source* is in git with a
   documented rebuild step, or X is in a snapshot. State which, in the script.
6. **Record the substrate in `.infra/`** (gitignored): account id, region, quota,
   keypair, SG, serial-console status, and the ids of every durable AMI/snapshot.
   The published repo must not carry cloud specifics.
7. **Re-verify the rebuild path is real, not assumed.** The x86 base is
   rebuildable because it starts from a *public* source
   (`dlc.openindiana.org/isos/hipster/.../OI-hipster-cloudimage.img.zst`) plus
   committed fixes. Any platform whose starting point is NOT public+committed is
   one account closure from a multi-hour rebuild — that is a gap to close, not a
   risk to accept.

## Rebuild starting points (keep these public + committed)

- **x86_64 base**: **fastest path is now the R2 bank** —
  `scripts/ami-bank.sh verify ami/x86_64-20260911` then `restore` + `restore-reg`, which skips
  the seed stage and was measured at 5/5 cold boots in a real account. The from-scratch
  fallback remains the OI Hipster cloudimage (public URL) → `scripts/make-base-ami.sh`
  (account-portable; supersedes the three per-account forks) → the cold-boot fixes.
  ⚠️ The dominant cold-boot factor is the **AMI-build method** (in-place boot_archive edits; a
  ZFS-import edit corrupts DHCP 0/6 vs 6/6) then the **single-DHCP-addrobj** shim; the ena
  MTU-1500 driver patch is secondary. See `docs/ena-rx-coldboot-fix.md`,
  `docs/kernel-hang-tsc-pit-fix.md` (`set pit_is_broken=1`), and
  `docs/base-ami-rebuild-runbook.md` (which also retracts the "root pool is stuck at ~2 GiB"
  claim — that was a silent no-op in the grow step, now fixed and asserted).
- **aarch64 gate host**: OmniOS cloud raw image (downloads.omnios.org) → `make
  download` + `make setup` (the multi-hour cross toolchain — SNAPSHOT IT) →
  `bldenv -d -T aarch64 <env/aarch64>` (the `-T` flag is mandatory; without it
  MACH silently falls back to the native i386 and the whole build goes -m32) →
  re-apply `src/aarch64-arm64-gate-patches/a6-mem-plus-gcc14-build-fixes.patch`
  (gcc-14 CERRWARN + the stale 0-byte assym.h regeneration).
- **RISC-V**: `src/riscv/build-all.sh` with `RISCV_GCC` pointing at a riscv64 gcc
  (nixpkgs `pkgsCross.riscv64-embedded.stdenv.cc` works and is cache-fetched, so
  this one is genuinely cheap to re-establish). The solnix riscv64-solaris cross
  gcc is the expensive variant — snapshot it when built.
