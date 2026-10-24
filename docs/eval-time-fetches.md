# Evaluation downloads nothing: sources are fixed-output derivations

`nix eval` of a solnix attribute now writes `.drv` files and the repo's own local
sources, and nothing else. Every source, firmware blob and the gate proto is a
fixed-output derivation (FOD), the way nixpkgs does it. Downloads happen at
realisation time, and a FOD output can be substituted from a cache.

## Why

`builtins.fetchurl` and `builtins.fetchTarball` run while the expression is being
EVALUATED. They never ask a substituter (nix 2.24 and 2.31 fetchTree.cc: "TODO:
fetching may fail, yet the path may be substitutable", NixOS/nix#4313). So every
cold eval went to the origin servers and needed about 2 GB of writable store. The
live installer has about 45 MB free, so it could not evaluate anything, and an EC2
user whose network could not reach ftp.gnu.org could not evaluate either.
nixpkgs never uses builtin fetchers in packages: `fetchurl` is a derivation with
builder `builtin:fetchurl` (`<nix/fetchurl.nix>`), and `fetchzip` unpacks the
tarball inside a derivation.

## What moved (pkgs/illumos)

| Where | Before | Now | Store path |
|---|---|---|---|
| mk-src-pkg.nix `srcTar` (every from-source package) | `builtins.fetchurl` | `<nix/fetchurl.nix>` | same |
| gcc-src.nix (gcc, gmp, mpfr, mpc) | `builtins.fetchurl` | `<nix/fetchurl.nix>` | same |
| nix-src.nix cacert | `builtins.fetchurl` | `<nix/fetchurl.nix>` | same |
| iwm-, iwx-, nvidia-gsp-firmware.nix | `builtins.fetchurl` | `<nix/fetchurl.nix>` | same |
| kernel-nd.nix illumos-gate source | `builtins.fetchTarball` | `fetch-tarball.nix` | same (`vsnxlmf0…-source`) |
| nvidia-oss.nix `rmSrc` | `builtins.fetchTarball` | `fetch-tarball.nix` | same (`cbzxm9jn…-source`) |
| base-src.nix home-manager | `fetchTarball` + eval-time `builtins.path` filter dropping `tests/` | `fetch-tarball.nix` with `exclude = [ "tests" ]` | same (`7wha58m1…-home-manager-source`) |
| gate.nix `prebuiltProto` | `builtins.fetchTarball` of the banked proto tarball | `fetch-tarball.nix` over the same URL | same (`s7zkx8nx…-illumos-gate-proto`) |

`fetch-tarball.nix` (new, 40 lines) is the nixpkgs `fetchzip` shape: a flat
`<nix/fetchurl.nix>` FOD for the tarball, plus a recursive FOD (bash + GNU tar,
`--strip-components=1`) whose `outputHash` is the NAR hash `fetchTarball`
reported, under the same name. A FOD's output path depends only on its name and
hash. That is why every unpacked tree, the gate proto included, kept its store path.
The flat tarball hashes were measured on floki (`tarhash/flat.txt` in the work dir):

- illumos-gate ac45d71: `37684f10…8d7c`
- open-gpu-kernel-modules 8da2326c: `386540bc…eb00`
- home-manager db7d5e2: `63657a72…0941`
- gate proto tarball: `2abbfda8ebcfd755dfad0b8065499f1b11a7957497a49c05679ce03af6da7325`, 219,678,907 B

Output paths downstream change, because sources moved from inputSrcs to inputDrvs
(htop: `l5m59h4k…` drv at HEAD, now `whnkv70x…-htop-3.4.1`). The cc/c++ wrappers
in mk-src-pkg.nix are untouched; only the `srcTar` line changed there.

## Measured: before and after (floki, eval only)

Method: `nix eval --store <fresh chroot store> --option substituters ''` with an
empty `XDG_CACHE_HOME`. The flake inputs (nixpkgs, solnix-pkgs, nixpkgs-host) are
`nix flake archive`d first so that only what the EVAL adds is counted. The
attributes are the cloud-ec2, installer-live and arnold toplevel `drvPath`s and
`packages.x86_64-solaris.htop.drvPath`. Script: `eval.sh` in the work dir.

| | HEAD 6bf1cc4 | this change |
|---|---|---|
| store growth | 519,884 → 2,499,632 KB (**+1.98 GB**) | 519,888 → 521,836 KB (**+1.9 MB**) |
| `~/.cache/nix` growth | 99,132 → 451,380 KB (+352 MB, tarball-cache-v2) | 99,064 → 100,316 KB (+1.2 MB, eval cache) |
| paths added | 298: 210 .drv + **88 non-drv, 2,131,885,896 B NAR** | 301: 276 .drv + 25 non-drv, 17,947,648 B |
| of which downloaded | 58 flat `builtins.fetchurl` (462.6 MB) + 5 `fetchTarball` trees (1,651.4 MB: illumos-gate src 842 MB, gate proto 679.8 MB, nvidia RM 117.8 MB, home-manager 7.1 + 4.6 MB) | **0** |
| local repo sources | 25 (17.9 MB) | the same 25 (`solnix-channel` differs because it is a snapshot of the edited repo) |
| eval with NO network (`unshare --map-current-user -n`) | **fails**: `unable to download 'https://s3.solnix.io/…/proto-root_i386-gate-ac45d71fc2.tar.gz': Could not resolve hostname` | **all four rc=0** |

The eval graph holds 66 FODs: 61 flat `builtin:fetchurl` and 5 unpack derivations.
Every path HEAD fetched at eval time is the output of one of them, at the same path.
The one exception is the unfiltered home-manager tree `41xfn9jz…-source`, which
existed only as input to the old filter. The drvPaths evaluated on the EC2 build
host (nix 2.24.15) equal the floki ones (nix 2.34.9).

## Measured: building it (EC2 us-west-2, OpenIndiana build host, nix 2.24.15)

A pure flake build (no `--impure`, `SOLNIX_GATE_PROTO` unset) of
`packages.x86_64-solaris.{htop,jq,less,git,home-manager,kernelNd,gcc}` and the
cloud-ec2 toplevel. Twelve source tarballs were **substituted from
cache.nixos.org**: a FOD output is substitutable, which a `builtins.fetchurl` path
never was. The other 145 derivations built, BUILD_RC=0:

| attribute | output |
|---|---|
| htop | `/nix/store/whnkv70xr70dmggx004fkxk1kf771vz0-htop-3.4.1` (`htop --version` 3.4.1) |
| jq | `/nix/store/qlm377swxa92g9cbc8gms4135azgcaaw-jq-1.7.1` |
| less | `/nix/store/b386l0csb0ynyvqk0svyib433mcvhrpy-less-679` |
| git | `/nix/store/h2p6rds6japdy0207z4p5zg42lakx195-git-2.54.0` (`git version 2.54.0`) |
| home-manager | `/nix/store/gj3yyx72jmr65z5hncv1rkqdv2g9z3xq-home-manager-26.05-db7d5e2` (`--version` 26.05-pre). Its source `7wha58m1` is a FOD output with a deriver, and `tests/` is absent |
| kernelNd | `/nix/store/6z5z5x8hpsmgrxbbcic9bg26dv5g8bdv-illumos-kernel-nd`, built from `vsnxlmf0…-source`. That is the same path HEAD's fetchTarball gave, built here from FODs `mshzjna3` (tarball) and `jkfvdnvp` (unpack) |
| gcc | `/nix/store/6jxijj8hz0bhkb7klwnb1dcn6jk9y2w8-gcc-14.3.0` |
| cloud-ec2 toplevel | `/nix/store/bgjb9dcpazcgxvjwi0bv1wnfl6w7ycq0-solnix-system-solnix` |
| gate | `/nix/store/s7zkx8nx…-illumos-gate-proto`: the path already on the host, so nothing was fetched |

The final tree (the `prebuiltProto` text as shipped) was built again: BUILD_RC=0 for
the installer-live toplevel `b9f0qk4w…-solnix-system-solnix-installer`, the cloud-ec2
toplevel `kf78kssw…` (the outPath floki evaluated), htop `whnkv70x` and the gate
`s7zkx8nx`. `scripts/make-installer-image.sh` built the media (101 store paths,
boot_archive 237,816,102 B). `scripts/image-acceptance-test.sh` on that
boot_archive gave **42 pass, 0 fail, 1 skip**; the skip is "not in a git tree", from the tar
checkout. `--selftest` passed, which shows the checks can fail. Logs are under
`evidence/` in the work dir.

## Measured: the gate proto realises into a store that lacks it

The gate proto runs inside a chroot: an EMPTY real `/nix`, and read-only lofs mounts
of the host's `/usr /lib /sbin /bin /opt /etc /dev`. `nix-build` of
`import pkgs/illumos/gate.nix { }` downloaded the banked tarball from s3.solnix.io
(FOD `lm94y87x…-proto-root_i386-gate-ac45d71fc2.tar.gz.drv`), unpacked it
(`8zm4hxqz…-illumos-gate-proto.drv`), and produced
`/nix/store/s7zkx8nx5sfxixmyqmlnrybrrh14jkmb-illumos-gate-proto`. Its narHash is
`sha256-Hdk/8nbeOHwP9Xz2WzF0giaqO2HYEXtnByqwTHvKEjg=` (the host's copy has the
same) and `nix-store --verify-path` passes. The path now has a deriver, where the
host's `nix store add-path` copy had none. Negative control: with `protoHash`
changed by one character, the build fails with "hash mismatch in fixed-output
derivation", RC=102.

A NAR form of the proto also works (`builtin:fetchurl` with `unpack = true` over a
`nix-store --dump | xz`, system `builtin`, no builder). It realised the same path
in the same kind of empty store. It is not used, because it would need a new upload,
and the tarball is already banked under the path the served recipes.tsv authorizes.
The `.nar.xz` is banked on floki:
`/home/gburd/solnix-bank/proto/x86_64-gate-ac45d71fc2-nar/`. It is 115,575,960 B,
sha256 `560c7064f95a56aa0bee6a443a3fead390d6e5a8a9f6ebf758c045de1be69ced`, and was
read back: the sha256 matches the build host, and the decompressed NAR hash is `0f0jr9xl`.

## Finding: the gate proto cannot go on the public cache

`scripts/publish-gate.sh` on `s7zkx8nx` reports **FAIL**:

- **no deriver**: the host copy was added with `nix store add-path`. A FOD
  realisation does set one, as measured above.
- **ELF RUNPATH `/usr/gcc/10/lib`**: in `usr/bin/ls`, `usr/bin/make`,
  `opt/nvme-tests/tests/unit/firmware.32` and others. nightly links the proto
  against the build host's gcc 10 runtime.

The cache2 and cache3 tracks reached the same verdict (their infra replies). There
are no waivers, so `s7zkx8nx` was not submitted. It stays a build input that Nix
fetches from the banked tarball, and it is never substituted from cache.solnix.io.
Fixing it means building the proto in a sandbox-equivalent way, with store-only
RUNPATHs and a real deriver. That is a separate track.

## Known limit: no fresh `--store` builds on illumos

nix 2.24 refuses to BUILD into a diverted store (store dir ≠ real dir) on
non-Linux systems (`local-derivation-goal.cc:225`):

    error: building using a diverted store is not supported on this platform

This was measured on the build host with a one-file `<nix/fetchurl.nix>` FOD. It
applies to `builtin:fetchurl` too, so a `--store /tmp/x` cannot realise anything on
illumos. Substitution into such a store is not a build and is unaffected. To prove a
realisation in a fresh store, use a chroot with an empty real `/nix` (the
`p3.sh` script in the work dir).

## Not changed

- `pkgs/illumos/phase3/fetchurl-shim*.nix`: the nixpkgs-fork tranche path. It is not
  reachable from this flake's outputs (no file outside phase3 imports it) and has
  its own owner. It still fetches at eval time.
- `gate.nix`'s `srcHash` branch (build the gate from source) still uses
  `builtins.fetchTarball`. It is opt-in and reached only with `gateArgs.srcHash`.
- The 26.11 branch keeps today's hashes.
