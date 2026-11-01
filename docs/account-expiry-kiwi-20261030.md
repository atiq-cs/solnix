# kiwi (437803535746) expires 2026-10-30 19:14:53 UTC: what was there, where it is now, what breaks

Prepared 2026-10-30 11:18-13:00Z by track kiwi-expiry. The inventory was measured, not copied from notes. Raw listings are in
`/scratch/solnix/kiwi-expiry/inv/` (`{inst,vol,snap,ami,sg}-<region>.json`, `key-<region>.txt`, `sami-ami-<region>.json`).
Five regions were listed in full (us-west-2 us-east-1 us-east-2 eu-west-1 eu-central-1). The other 12 enabled regions have
0 instances, volumes, AMIs and snapshots. No S3 bucket in the account is ours (`access-log-*` and `noxu-kiwi3-vmimport-*` belong
to tenants).

## Instances and volumes (all us-west-2, Project=solnix)

| resource | what | durable copy | action |
|---|---|---|---|
| i-0e6295292bacb036e c5.4xlarge, running | x1enet build host (`/scratch/solnix/x1enet/bh.sh`, 34.213.60.56). OI 2026:10:17 + nix 2.24.15; npool 119G (102G used): /nix 57 GB, /var/tmp/big 20 GB | the host image: `~/solnix-bank/ami/x86_64-buildhost-20261017` (+ R2 `ami/x86_64-buildhost-20261017`, 200, 7214995566 B). Its unique contents: see "The build host" | terminate after the orchestrator says go |
| vol-090a65a92c4cc73d4 40G (root), vol-0dcdc35905a34a856 250G (npool) | bh's disks, DeleteOnTermination=true | as above | go with the instance |
| i-04debbbe45f7d363a c5.4xlarge, stopped | hlcli build host (stopped 10-28 02:39Z; started 12:19-12:27Z today to pull logs and cores, then stopped again) | `~/solnix-bank/hlcli-20261027/` (bank, bank-go2, outs.tsv, hlcli.patch) + `kiwi-final-20261030/hlcli/` | terminate after go |
| vol-0e7efe3baebedf84e 120G, vol-0ca161ca83b7e11de 200G | hlcli's disks, DeleteOnTermination=true | as above | go with the instance |
| aa64vm-* (none at 12:52Z) | track aa64vm (agent f28c9394, `/scratch/solnix/aa64vm/progress.txt`), from 12:50Z | that track banks to `~/solnix-bank/aa64vm-20261030/` | NOT ours to end without the orchestrator's go |

Not ours, left alone: us-east-2 vol-00b3e76de84274a56 ("omnios-r151058-raw", no tag), its snapshot snap-0d9e378193aef77c9 and AMI
ami-0a647800b65f8764e (omnios-r151058-noxu); every instance in us-east-1/us-east-2 (bark-*, lime-impl-*, noxu n-*, pgdyn-*,
pgprop-*, hashmeta4-*, pg-llvm21-*, undo-v8f-*) with their SGs and keypairs.

## AMIs and snapshots owned by kiwi

The durable copies of the published images live in **solnix-ami (788352824872)**. I listed its AMIs in all 5 regions
(`inv/sami-ami-<region>.json`) and confirmed that every snapshot behind them is owned by 788352824872 (12/9/6/6/6). Every banked
raw image below was re-hashed on floki today and matches its SHA256SUMS (`/scratch/solnix/kiwi-expiry/shacheck/out.txt`).

| kiwi AMI (region) | snapshot | image | durable copy | delete when |
|---|---|---|---|---|
| ami-0c3f16422f8943a8b us-west-2 | snap-0a94b65d057cc016d | x86 build host COMPLETE | `~/solnix-bank/ami/x86_64-buildhost-20261017/solnix-base-raw.img.gz` gz 502098a5 (raw c1bd97b2) + R2 same | after bh/hlcli are gone |
| ami-0c5f8390e2341fcca us-east-2 | snap-01340738a4c6c17d7 | same build host, restored 10-23 | same | any time |
| ami-0c0153919fcf35ad4 us-west-2, ami-0ac3865f0202d7601 us-east-2 | snap-076c01f02d2d17dc5, snap-087a8df3cdd83ca24 | 26.11 DP dde2cbe (superseded) | `ami/x86_64-dp-26.11-dde2cbe-20261023` gz e2fc2c31 | any time |
| ami-0f823762498c50c28 us-west-2 | snap-02bb731a2a80d50e3 | 26.11 DP 36dc227 (superseded by tserrno) | `ami/x86_64-dp-26.11-36dc227-20261024` gz 307b969f | any time |
| ami-0cf467f906237058d us-west-2 + copies ami-0f3a2b74a73006c81 (ue1), ami-068759471711e0700 (ue2), ami-03284b39e46f8647d (euw1), ami-04bc25756cd7970e0 (euc1) | snap-03e8ebeabbdc33a6f, -03dd6c5da4f454428, -044c9609c1b2c49a1, -01d847e7099bee94c, -02c94d38e962d392a | 26.11 DP 36dc227 tserrno | `ami/x86_64-dp-26.11-36dc227-tserrno-20261024` gz 466c498e + solnix-ami copies in all 5 regions | any time |
| ami-0a5a2d13bb3e10e26 us-west-2 | snap-04b1342c97aa8a7b6 | dpimg3 98c3fa0 (superseded: AMD panic loop) | `ami/x86_64-dpimg3-20261029` gz dff67860 + solnix-ami | any time |
| ami-097535d16544556cb us-west-2 | snap-0ef0bf50a89724362 | dpimg3 fix (98c3fa0+keymap+0010) | `ami/x86_64-dpimg3fix-20261029` gz 1318fa80 (raw 743df527) + solnix-ami 5 regions | any time |
| ami-0101334f6666fcbae us-west-2 | snap-0256dc286c3216105 | rootgrow p3 | `rootgrow-20261029/raw-p3.img.gz` 699ce384 + solnix-ami (ue1, uw2) | any time |
| ami-058f141e996b929f9 us-west-2 | snap-05d4711742dfbee21 | aa64f b2 | `ami/aarch64-6cd2521c1e-serror-20261024/aa64f-b2-20261024.img.gz` ce8fdad5 + solnix-ami PREVIEW | any time |
| ami-0d829adab130ea81c us-west-2 | snap-000245d78c7c62e41 | aa64h f1 | `ami/aarch64-6cd2521c1e-aa64h-20261028/aa64h-f1.img.gz` 6c1dd822 + solnix-ami 5 regions | any time |
| ami-0e70db39aa962a8a4 us-west-2 | snap-062ad9d78324057d8 | aa64tls m1 (superseded by m2) | `ami/aarch64-6cd2521c1e-aa64tls-20261029/aa64tls-m1.img.gz` 542e2948 (raw 8f51bea6) | any time |
| ami-0ac943ea6bc027dc3 us-west-2 | snap-0b8fa866e7aeea1c2 | aa64tls m2 | `.../aa64tls-m2.img.gz` 4063b1b0 (raw ecc11f29) + solnix-ami uw2/ue1 | any time |
| **ami-0db4448441e41d58c** us-west-2 | snap-03ec7f20db2ea487f | aa64rb m4 | `ami/aarch64-6cd2521c1e-aa64rb-20261029/aa64rb-m4.img.gz` a53e9f80 (raw 1af90736) + solnix-ami ami-0c58280779782f854 (uw2), ami-0b544e93ac70551d6 (ue1) | **LAST: aa64vm launches from it** |

Snapshot shares that die with kiwi (nothing depends on them): snap-000245d78c7c62e41, -05d4711742dfbee21, -03e8ebeabbdc33a6f and
-0b8fa866e7aeea1c2 to 788352824872; snap-03ec7f20db2ea487f to 399683337502 (dixa's account, which launches from the solnix-ami
copy ami-0c58280779782f854; that AMI's launch permission for 399683337502 is set in solnix-ami and survives). No kiwi AMI has a launch permission.

## Security groups and keypairs (ours)

| region | SG | rule | used by |
|---|---|---|---|
| us-west-2 | sg-07df1f7e74f16a32d solnix-ssh-20261023 | 22 <- 73.4.58.0/24 | bh, hlcli (aa64vm will use it too) |
| us-east-2 | sg-04f36c6fddef7b370 solnix-ssh-20261023 | 22 <- 73.4.58.0/24 | nothing |
| us-east-1, eu-west-1, eu-central-1 | sg-08a1d923c24d71900, sg-0ca4fb0777fdfe118, sg-0385e1d98e7688fb6 (solnix-ssh-20261024) | 22 <- 73.4.58.0/24 | nothing |
| us-east-1, eu-west-1, eu-central-1 | sg-09111db5a31562d47, sg-096970a34c3bb050c, sg-019672edbaf7c9110 (ami2611-20261024-ssh) | 22 <- 73.4.58.0/24 | nothing |

None of our SGs has a world-open rule. Keypairs `solnix-baked` (fingerprint 66:a3:bb:39..., which is the public half of
`~/.ssh/solnix-lava.pem.AMI-BAKED-still-works`, checked) and `ami2611-20261024-verify` (`/scratch/solnix/ami2611/ami2611-verify.pem`)
exist in all 5 regions. Only the AWS records die; both private keys are on floki.

## The build host: what was on it and not banked anywhere

The method: list every store path on bh (3139 paths, 57.2 GB of NAR, `inv/bh-pathinfo.json`), probe each on cache.solnix.io (146
are there), and compare with every narinfo on floki (`~/solnix-bank` and `/scratch/solnix`, including inside tars: 16,9xx hashes,
`inv/floki-all.txt`). 454 non-FOD build outputs from 10-24 or later were in neither place (6.2 GB, `inv/cand2.tsv`). Nearly all of
them are older iterations: about 40 kernels (-gpu/-iwx/-iwm/-nd/-touchpad), the 10-28 cosmic set (the 10-29 set is banked), and
the old-unserved go chain listed in stdenv3's wave.tsv. To decide what still mattered, I took the closures of what is in use or
published (lixi d7nwkaci = solnix-17 default, qr52y0zw = solnix-20, yc5wdlbc; dixi 50jhzqh9; the AMI toplevels; the tpad2
drivers) and the stdenv3 HEAD outs, then banked what in them was missing:

- `~/solnix-bank/kiwi-final-20261030/` (186 MB; MANIFEST.txt, SHA256SUMS 9/9 OK): 43 store paths as a nix-store export,
  each NAR re-hashed against path-info (43 OK; a corrupted-hash control fails rc=1); bh text evidence (2886 logs/scripts); 6 src
  and nixcfg tars that had no floki copy; hlcli evidence and 7 go-1.27.3 cores.
- The /var/tmp/big tars: each one is already on floki (name+size), or its narinfos are on floki/cache, except
  gpu3-gpu3b.tar and lixi-cache-b3.tar. Those two hold 10 paths of the 10-27 gpu3 iterations (mesa mrrqki6r, kernel-gpu n2l0138a):
  superseded, not banked.
- hlcli store: 133 paths (7.0 GB) not on cache/floki, all from the 10-27 hlcli build round (old go chain, old tool outs).
  The stdenv3 wave replaced them. Not banked.

Checked against the 12:30Z submit (recipes.tsv eb053b4, 378 outs): 201 are on the cache and 172 in floki banks. The other 5
(rust-illumos-1.97.1 8daydacs, -1.98.0 ygnypz36, -1.99.0 mxn53s79, rust-1.98.0-stage pngbrvmx, rust-1.99.0-stage xp2sv9n9; in the
registry since 10-12) are on no bank and not on bh either, so expiry changes nothing for them. No recipe out exists only on bh.

**Found: three bh store paths were modified after registration**: meson-1.4.2 jyqnmbay, mako-1.3.5 blbj04zx, markupsafe-2.1.5
2pjg7768. `nix-store --verify-path` fails on all three. The mechanism, observed: they contain `__pycache__/*.cpython-39.pyc`
(cpython-39 is the host's /usr/bin/python3.9) with mtimes 1 s after registration. Store dirs are r-x, but root ignores DAC, so the
first root python import wrote bytecode into the store. This explains the BAD-LOCAL meson line in
`~/solnix-bank/stdenv3-20261029/T4gfx/readback-dryrun.log`. None of the three is in recipes.tsv, and no banked path references
them. They have to be rebuilt (and should be built with PYTHONDONTWRITEBYTECODE=1) before the T4gfx follow-up batch.

## What breaks after expiry

In the repo (`grep -E '437803535746|AWS_PROFILE=kiwi|i-0e6295292bacb036e|x1enet/bh.sh'` over scripts docs .kiro AGENTS.md pkgs nixos):
- **No script defaults to kiwi.** `scripts/sg-guard.sh` needs an explicit AWS_PROFILE. Some defaults point at long-dead
  accounts and fail loudly, not silently: `make-base-ami.sh` and `ami-bank.sh` (SOLNIX_PROFILE:-lava), `oi-be-to-ami.sh`,
  `oi-boot-batch.sh`, `oi-make-ami.sh` (AWS_PROFILE:-numa), `oi-cache-publish.sh` (--profile numa), `ouch-/beef-/fred-*-base-ami.sh`,
  `bene-provision-dixi.sh`.
- `AGENTS.md` line 25 names kiwi 437803535746 as the current account: update it when the next account arrives.
- `docs/solnix-buildhost-ami.md:86` shows `AWS_PROFILE=kiwi aws ec2 run-instances ...` as an example (still valid if the next burner is again called kiwi).
- History docs (account-migration-*, aarch64-*-result.md) cite 437803535746 as a fact about the past; leave them.

On floki (not in the repo): 22 track dirs under `/scratch/solnix/` have helpers hard-wired to the kiwi hosts or profile
(`x1enet/bh.sh` + `bh.ip` 34.213.60.56, `hlcli/bh.sh`, `stdenv3/bh.sh`, `stdenv3/bank-tier.sh`, `tpad*/bput.sh`, `dixi1/xfer.sh`,
`gpu3/xfer.sh`, `aa64*/launch.sh`/`poll.sh`, `dpimg3/aws.sh`, `rootgrow/aws.sh`, `cosmic3/launch.sh`, `ami2611/verify.sh`, ...). After
19:14Z they fail at ssh or STS. Every brief that says "build on the kiwi build host (sh /scratch/solnix/x1enet/bh.sh)" (tpad3,
aa64vm, and the older gpu*/tpad*/cosmic3/stdenv3 briefs) needs a new host. **tpad3 and aa64vm are live today.**

Also gone: the solnix-ami to kiwi launch-permission round trip (COMMON-2026-10-26: share to 437803535746, launch, remove). The next
account's id must be used instead.

## What the next account needs, in order

1. `aws --profile <p> sts get-caller-identity`; quota L-1216C47A in the regions we use (metal needs it raised from 32).
   `SG_GUARD_SELFTEST=1 AWS_PROFILE=<p> scripts/sg-guard.sh audit` must report DIRTY, which proves the guard can read the account.
2. SG with **one** rule, tcp/22 from **73.4.58.0/24**, added only through `scripts/sg-guard.sh authorize <region> <sg> tcp 22 73.4.58.0/24`.
   Never 0.0.0.0/0 or ::/0.
3. Keypair: import the public half of `~/.ssh/solnix-lava.pem.AMI-BAKED-still-works` (`ssh-keygen -y -f ...`) as `solnix-baked`. The
   build-host and DP images bake the same key, so root login works with any keypair name.
4. x86 OI build host: restore from `~/solnix-bank/ami/x86_64-buildhost-20261017/` (gz 502098a5, raw c1bd97b2; same object in R2
   `ami/x86_64-buildhost-20261017/`, HTTP 200, 7214995566 B) per its MANIFEST "RESTORE INTO A FRESH ACCOUNT" (`scripts/ami-bank.sh
   restore`, or dd onto a 20 GiB gp3 volume, snapshot, register uefi/ENA /dev/xvda). Boot it with a 120 GiB root plus a data volume for
   npool, run `. /etc/profile.d/nix-illumos.sh; export TMPDIR=/var/tmp/big`, and add a swap zvol (go1.24 needs one: hlcli 10-27).
   The store starts at the 10-17 warm set. Substitute from cache.solnix.io and import the floki banks (stdenv3-20261029 tiers,
   kiwi-final-20261030) instead of rebuilding. Rebuild meson/mako/markupsafe.
5. AMIs: use the solnix-ami copies (share to the new account id to launch). To re-register in the new account, use the raw images above.
6. Record the new account in AGENTS.md and write the migration doc.

## Teardown (orchestrator gate; not done at the time of writing)

The list and the commands are in `/scratch/solnix/kiwi-expiry/progress.txt` under "READY TO TERMINATE". Order: aa64vm finishes and
reports first (the orchestrator decides). Then terminate bh and hlcli and wait for terminated and for their 4 volumes to be gone
(DeleteOnTermination=true). Then deregister the AMIs, ami-0db4448441e41d58c last, and delete their snapshots. Then delete the
8 SGs and 2x5 keypairs. Never vol-00b3e76de84274a56, snap-0d9e378193aef77c9, ami-0a647800b65f8764e or any untagged resource.

## Added 2026-10-30 15:45Z: the build-host AMI is in solnix-ami

The OI build host image (kiwi `ami-0c3f16422f8943a8b`, `solnix-buildhost-x86-COMPLETE-20261017`) was copied to the
permanent account: solnix-ami us-west-2 snapshot `snap-019a21615100cfe32`, AMI **`ami-0e4a740ebfc5bec81`** (x86_64,
UEFI, ENA, /dev/xvda 20 GiB gp3). The next account can launch it from a launch share
(`AWS_PROFILE=solnix-ami aws ec2 modify-image-attribute --launch-permission Add=[{UserId=<new account>}]`) instead of
restoring the raw image from ~/solnix-bank/ami/x86_64-buildhost-20261017. The temporary createVolumePermission on the
kiwi snapshot was removed after the copy (read back empty).
