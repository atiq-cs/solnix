# Blocker 6: the fetchClosure rewrite is gated on a REBUILD, not a publish

`nix eval .#solnixConfigurations.dixi.config.system.build.toplevel.drvPath` stops
on one thing (`pkgs/illumos/starter.nix:71`):

    error: 'builtins.storePath' is not allowed in pure evaluation mode

That is blocker 6 exactly as recorded, confirmed as the LAST line of the acceptance
eval (forced `drvPath`, not a grep) on the dev box. `storePath` is the sole remaining
stopper: blockers 1-5 are fixed and the toplevel evaluates up to this line.

The fix has two halves (`fetchClosure` rewrite + publish the closures). The rewrite is
ready (below). The publish half is **not a publish** — it is a from-source rebuild,
because the artifacts do not exist anywhere. This document records why, with the
evidence, so the rewrite can land the day the rebuild produces the closures.

## The closure walk: exactly 8 paths missing, matching AUDIT-cache-gap

Walked the transitive `References` closure of the 13 starter roots dixi's toplevel
pulls in (`git curl` from `configurations/dixi.nix:105`; `coreutils file gnugrep
gnused bzip2 xz zlib pcre2 nvi which gdb` from `configurations/base.nix:44`) against
`cache.solnix.io`, HTTP-only, negative-controlled (bogus hash -> 404, real `which` ->
200). 87 paths seen; **exactly 8 have a 404 narinfo**, and they are identical to the
`blocks_eval` column of `docs/registry/AUDIT-cache-gap-x86_64.tsv`:

| store path | pname | pulled in by | in registry? | cache.solnix.io | s3.solnix.io inbox |
|---|---|---|---|---|---|
| `0mh27ap6inkhbjacbn5kc0magi0gj8ww-pcre2-10.47-dev` | pcre2-dev | git | **NO** | 404 | 404 |
| `3wlwvk71i6dfwiq63kdakq02fig8m68p-coreutils` | coreutils | perl, git, illumos-cc, illumos-bintools | yes (published) | 404 | 404 |
| `63b1x7j2x0dvnhcxfrszgri7b1a2hrij-openssl-3.6.3-dev` | openssl-dev | git, curl-dev | yes (staged) | 404 | 404 |
| `a6yl9zl8zw7sxfr44000hlwm3hrgh6h1-binutils` | binutils | illumos-bintools | yes (published) | 404 | 404 |
| `agvfjzh4cc3l9cw1sgnyjr911dbj8r5h-ncurses-6.6` | ncurses | bash-interactive, gdb, nvi | yes (published) | 404 | 404 |
| `i9szssxplv8mz45mk4fdzy2f8w8kcndr-openssl-3.6.3` | openssl | git, curl (all outputs) | yes (staged) | 404 | 404 |
| `jn4pbjb4nxli1hnpldzicn6rzld0fbyl-readline-8.3p3` | readline | bash-interactive, gdb | yes (staged) | 404 | 404 |
| `qi4yafp9s8002rnyqf1kmp3p22pw10gc-curl-8.21.0-man` | curl-man | curl-dev | yes (published) | 404 | 404 |

All 8 are **404 on BOTH the durable cache AND the transient inbox** (spot-checked and
verified independently by the orchestrator on `0mh27`/`3wl`/`a6y`). Nothing is mid-drain.
The rest of every closure (e.g. `illumos-seed-unpacked`, `pcre2-10.47`) is present AND
5HAV-signed, so the gap is precisely these 8, no more.

## Why this is unbuilt-and-unstored, not merely unpublished

* **No illumos build store survives.** Launched a build node (c5.4xlarge, instance
  `i-0829e7d0ed373b8e9`, from the baked AMI `ami-0cb14e40f9355bd0c`). It has **no `/nix`
  at all** — 0 store paths, no nix binary; it is a bare hipster base image, not a
  provisioned build host. Both x86_64 AMIs (`ami-0cb14e40f9355bd0c`,
  `ami-062d017ec6cd47b16`) and every self-owned snapshot are 20 GB base images. **No
  host or snapshot with a populated `/nix/store` exists.** (Node terminated; see below.)
* **The `.drv` files are unrecoverable.** Nix binary caches do not serve `.drv`s
  (`git-2.55.0.drv` narinfo = 404), so the exact derivations that produced these output
  hashes are gone with the build host.

So publishing them requires **rebuilding from source** on a freshly bootstrapped illumos
Nix — a multi-hour job, not a `nix copy`.

## The sharpest single fact: publishing every registry row still leaves git broken

git-2.55.0 (`4qzc...`, itself 200 and 5HAV-signed) has in its `References`:

    0mh27ap6inkhbjacbn5kc0magi0gj8ww-pcre2-10.47-dev

The registry's standalone x86_64-solaris pcre2-dev is a **different hash**,
`wjd10rk610g39cslak2zwmlbf3f57x9b-pcre2-10.47-dev` (which IS 200). git was built against
a pcre2-dev output the registry does not contain. Therefore **rebuilding every registry
ROW would still leave git's closure incomplete** — the registry does not hold the hash
git needs. Reproducing `0mh27` requires the exact deriver inputs the git build used, which
no longer exist. This is why the closure walk (not the registry's `published` column) is
the load-bearing check, and why the rebuild must discover the true closure by BUILDING it.

## The rebuild starts from the R2 seed (bootstrappable, not from scratch)

The seed FOD fetches `https://solnix.io/seed/x86_64-solaris/seed.tar.zst` (hash-pinned;
~118 MB per `docs/design-build-strategy.md:40`; manifest at `artifacts/seed/`). That is the
bootstrap starting point: build nix-on-illumos with the seed gcc, then build the userland
slice from the `solnix-pkgs` fork. This deserves its own scoped run with a proper build-host
bootstrap, not a tail-end of the eval-blocker work.

**Open reproducibility risk for that run:** it must be confirmed that the current
`solnix-pkgs` fork revision reproduces the exact output hashes the *published* roots
(git `4qzc`, curl `6waw`, gdb `sbxd`) reference. If the tree has drifted and rebuilds
yield different hashes, the published roots themselves go stale and the whole starter set
needs republishing, not just the 8 refs.

## Half A: the starter.nix rewrite is ready (do NOT apply until the closures exist)

Applying it now would trade a clear pure-eval error for a confusing 404 fetch failure
across EVERY configuration that imports `base.nix`, so the rewrite lands WITH the publish.

The change is ONE hunk (`pkgs/illumos/starter.nix`, the `entry` binding). Filtering,
last-wins, and row-shape validation are unchanged, so the package selection is identical.

    -    value = builtins.storePath (builtins.elemAt cols 3);
    +    value = builtins.fetchClosure {
    +      fromStore = "https://cache.solnix.io";
    +      fromPath = builtins.elemAt cols 3;
    +      inputAddressed = true;
    +    };

`inputAddressed = true` is **required** (measured on the dev box): our x86_64-solaris
paths are input-addressed, and plain `fetchClosure` errors "fromPath ... is not
content-addressed" for that class. With it set, `fetchClosure` does not re-verify
content-addressing, so **signature trust does all the integrity work** — the path and its
whole closure must be signed by a key in `trusted-public-keys` (`cache.solnix.io-1:5HAV...`,
already in `base.nix`). A path under an untrusted key is REFUSED at eval, which makes
"publish only under 5HAV..." load-bearing. `fromPath` is passed as the tsv's string column
unchanged (do NOT wrap in `storePath` or coerce with `./.`). The evaluating Nix needs the
`fetch-closure` experimental feature.

**Dev-box vs. target:** with `inputAddressed = true`, `which-2.25` gets past the not-CA
check and substitutes; it then fails on a reference with "lacks a signature by a trusted
key". That reference IS 200 and IS 5HAV-signed — the failure is the dev box being a
**daemon client** (it silently ignores `--option trusted-public-keys`, per
`docs/cache.md`). So the acceptance test is only meaningful where the closure can actually
substitute under a trusted 5HAV: the target `/nix-tools224` (Nix 2.24.15) with the paths
published and closure-complete. A dev-box "cannot add path / lacks signature" is expected
there, not a defect of the rewrite. (Whether the target's 2.24.15 also needs
`ca-derivations` alongside `fetch-closure` should be confirmed on the node, not assumed.)

## Ledger

| # | blocker | status |
|---|---|---|
| 1 | gate proto in pure eval | fixed (`2ed40f30`) |
| 2 | `currentSystem` in `mk-illumos-component.nix` | fixed (`4845812f`) |
| 3 | `x86_64-solaris` stdenv recursion | fixed (`solnix-pkgs 7ff01f8`) |
| 4 | extra recursion | artifact — does not reproduce |
| 5 | `currentSystem` in `lib/build-env.nix` | fixed (`e38bda62`) |
| 6 | `storePath` in `starter.nix` | rewrite READY; **gated on rebuilding 8 closures** |
| **7** | **8 starter closures unbuilt-and-unstored** | **NEW: rebuild-from-seed, own scoped run** |

`--flake .#dixi` is one from-source rebuild away, not one publish run away. The rebuild
must (a) bootstrap nix-on-illumos from the R2 seed, (b) build the 8 packages AND everything
between them and git/curl/gdb, discovering the true closure by building it, (c) confirm the
published roots' hashes still reproduce, then (d) publish under 5HAV and apply the
starter.nix hunk above. Only then does the acceptance eval resolve pure with nothing dropped.

## AWS cleanup

Node `i-0829e7d0ed373b8e9` (c5.4xlarge, us-east-2) **terminated**; both volumes
(`vol-0862335e456658013`, `vol-00d5cdb363016c8c1`) were `DeleteOnTermination=true`. No
temporary security-group rule was created (the `solnix-lava` SG already scoped port 22 to
`73.4.58.0/24`). Nothing left running.
