# Binary cache (solnix.io) — layout, URL form, publishing

The solnix binary cache is the S3 analog of `cache.nixos.org`: prebuilt
`pkgs.solnix.*` and image closures so systems and CI don't rebuild the world.
It lives on solnix.io's S3-compatible endpoint and is served as a standard Nix
binary cache. (T2.3.)

## Coordinates

| | |
|---|---|
| **S3 bucket** | `s3://solnix-cache` |
| **S3 endpoint** | `https://s3.solnix.io` (S3-compatible, **not** AWS S3), region `us-east-1`, **path-style** |
| **Substituter URL (consumers)** | `https://s3.solnix.io/solnix-cache` |
| **Signing key** | `cache.solnix.io-1` |
| **Public key** | `cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=` |
| **Secret key** | `secrets/cache-signing.yaml` (sops, repo age key) |
| **S3 creds** | `secrets/s3-cache.yaml` (sops) — read in-shell, never written to disk |

The public key + substituter are baked into `configurations/base.nix`
(`nix.settings.substituters` / `trusted-public-keys`), so a solnix system pulls
signed binaries by default — no credentials needed for **reads** (the bucket is
publicly readable over path-style HTTPS).

## Two URL forms

- **Consumers (systems, CI reads):** the plain HTTPS URL of the bucket,
  `https://s3.solnix.io/solnix-cache`. Nix's `HttpBinaryCacheStore` fetches
  `nix-cache-info`, `<hash>.narinfo`, and `nar/<filehash>.nar.xz` by GET. No
  creds.
- **Publishers (writes):** the `s3://` store URL with the endpoint baked in:
  `s3://solnix-cache?endpoint=s3.solnix.io&region=us-east-1&scheme=https`.
  `scheme=https` is required (path-style S3-compatible endpoint), and creds come
  from `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` + `AWS_EC2_METADATA_DISABLED=true`
  (never hit EC2 IMDS) + `AWS_DEFAULT_REGION=us-east-1`.

## Cache layout (standard Nix binary cache)

```
s3://solnix-cache/
  nix-cache-info                      # "StoreDir: /nix/store"
  <storehash>.narinfo                 # one per store path (signed)
  nar/<filehash>.nar.xz               # xz-compressed NAR per path
  bootstrap/                          # relocatable, compiler-free artifacts
    nix-illumos-2.3.16.tar.zst        # prebuilt native illumos Nix (see below)
    nix-illumos-2.3.16.tar.zst.sha256
```

## Bootstrap: prebuilt native illumos Nix (no compiler)

A bare illumos host cannot fetch from this cache until it has a working `nix`,
and building Nix from source needs a C++ toolchain (gcc-14 + boost 1.78 + ...).
To break that chicken-and-egg, a **prebuilt, relocatable, compiler-free** Nix
2.3.16 lives under `bootstrap/`:

| | |
|---|---|
| **URL** | `https://s3.solnix.io/solnix-cache/bootstrap/nix-illumos-2.3.16.tar.zst` |
| **sha256** | `ebe3a573a4e0045caf600fc8148b0fa37ba46c38a443d5a6210195f5c02388ed` |
| **sidecar** | `.../nix-illumos-2.3.16.tar.zst.sha256` |
| **size** | 44.5 MiB (compressed), ~224 MiB unpacked |
| **system** | `x86_64-solaris` |

Contents: `nix-tools/` (the whole install prefix — nix 2.3.16 binaries + libs),
`runtime-lib/` (every non-base shared lib the binaries need: gcc-14 runtime
`libstdc++`/`libgcc_s`, boost 1.78, openssl, curl, sqlite, sodium, readline, ...
verified sufficient to run nix with only the base illumos image present), and
`bootstrap-register.sh`. A bare host installs with NO compiler:

```sh
curl -fsSL https://s3.solnix.io/solnix-cache/bootstrap/nix-illumos-2.3.16.tar.zst \
  | zstd -d | tar -xf -              # -> ./nix-tools ./runtime-lib ./bootstrap-register.sh
./bootstrap-register.sh              # installs /nix-tools + /nix store + cache.solnix.io substituter
# then: export PATH=/nix-tools/bin:$PATH NIX_CONF_DIR=/nix-tools/etc/nix LD_LIBRARY_PATH=/nix-tools/runtime-lib
```

`bootstrap-register.sh` writes `/nix-tools/etc/nix/nix.conf` with the
`cache.solnix.io` substituter + trusted key, so the freshly-installed nix pulls
signed binaries immediately. Produced by `scripts/oi-nix-setup.sh` (from-source
build) then packaged; regenerate + re-upload when the version or patches change.
The nix binaries install to `/nix-tools` (a normal prefix, not a store path), so
there is no nix store-path closure to publish as narinfos — the tarball IS the
artifact.

## Publishing

`scripts/oi-cache-publish.sh [store-path ...]` — idempotent (skips paths whose
narinfo already exists). Reads S3 creds + the signing key from sops in-shell.

### The Nix-2.3.16 S3 gotcha (why the script bridges through a local store)

The illumos build host runs **Nix 2.3.16, which has NO S3 store support**
(`error: don't know how to open Nix store 's3://...'`), and its
`LocalBinaryCacheStore` (`nix copy --to file://`) is also broken on illumos
(`getting status of .../foo.nar.xz: Error 0`). So the publish path can't run on
the host directly. Instead the script bridges:

1. On the host (2.3.16, rock-solid): `nix-store --export $(nix-store -qR PATH)`
   — streams the whole closure in topological order.
2. Pipe to the **dev box** (Nix 2.4+ with working S3): `nix-store --store $TMP
   --import` into a throwaway local store.
3. `nix store sign --store $TMP -k <key> --recursive PATH` — sign with
   `cache.solnix.io-1`.
4. `nix copy --store $TMP --to 's3://solnix-cache?endpoint=s3.solnix.io&region=us-east-1&scheme=https' PATH`.

The dev box needs no illumos toolchain to do this — `--import`/`sign`/`copy`
only touch NAR bytes, hashes, references, and signatures; they never execute the
foreign-platform binaries.

## Published so far (T2.3, renamed to plain `<pname>-<version>` per T-RENAME)

The bootable world (`system-path` closure) + the gate/seed FOD.
Store hash → NAR size (uncompressed) / xz size:

| store path | NAR | xz |
|---|---:|---:|
| `libc` | 38.4 MB | 6.0 MB |
| `rtld` | 3.5 MB | 0.9 MB |
| `ld` | 2.2 MB | 0.4 MB |
| `external-libs` | 83.7 MB | 20.8 MB |
| `base-tools` | 10.2 MB | 3.2 MB |
| `sys` | 102.6 MB | 25.9 MB |
| `system-path` | 0.8 MB | 0.03 MB |
| `illumos-gate-proto` (seed, FOD name unchanged) | 650.1 MB | 114.3 MB |

Store names are now plain `<pname>-<version>` / `<slice>` (no `solnix-`/`illumos-`
prefix); the store hash disambiguates. Rename republished the world slices +
the 51 core packages under these names (T-RENAME, 2026-07-26).

Bucket total: ~171 MB compressed across 18 objects.

## Verify a fetch (the T2.3 gate)

Prove the cache serves *our signed* paths — fetch into a fresh, empty store with
only the public key trusted and `require-sigs` on:

```sh
nix copy --from https://s3.solnix.io/solnix-cache \
  --to /tmp/freshstore \
  --option trusted-public-keys 'cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=' \
  --option require-sigs true \
  /nix/store/b1q9mlpjpy9k31j0q6mjmc1h7l99ha2s-system-path
```

Fetching with a *wrong* trusted key + `require-sigs true` must fail with
"lacks a signature by a trusted key" — that's the real proof the signature gate
works, not just that bytes downloaded.

## PUBLISH-PATH GOTCHAS (2026-08-03, found via aarch64 gate)
TWO bugs that silently broke publishes (caused mysterious 404s + under-counted caches):
1. **S3 prefix durability**: the `archive/` prefix is TRANSIENT (objects expire within minutes).
   The `seed/` + package prefixes are DURABLE. FOD/seed URLs MUST use durable prefixes
   (seed/<sys>/...), never archive/. (aarch64 + sparc seed FODs were on archive/ -> 404.)
2. **`nix copy` S3 driver is BROKEN on this backend**: it reports "copying path..." then
   "interrupted", objects never land -> narinfos 404 despite apparent success. This under-counted
   prior batch publishes. WORKAROUND: `nix copy` to a local `file://` cache, then `aws s3 sync`
   (or `aws s3 cp`) the result up. The oi-fleet-publish.sh path should use aws s3, NOT nix copy.
   Also: stale local binary-cache-v*.sqlite positives make Nix SKIP re-uploads -> clear them when
   re-verifying (deletes nothing from S3, just forces honest re-checks).

## RESOLVED (2026-08-04): s3.solnix.io is the WRITE INBOX; cache.solnix.io is the durable read cache
The earlier "backend defect / objects evicted" notes below were a MISDIAGNOSIS on my part.
solnix uses the NixOS.org two-endpoint model:
  - **s3.solnix.io** (rustfs) = TRANSIENT write inbox. Builders upload here. A b2-mirror
    reconciler (~10min) copies each package object to B2, verifies size, then DELETES it from
    the inbox. So nar/, root *.narinfo, torrent/ objects correctly vanish from s3.solnix.io
    minutes-to-hours after upload -- that is the inbox draining, NOT data loss. (seed/,
    bootstrap/, arch-manifest.tsv are on a keep-list and stay in the inbox.)
  - **cache.solnix.io** (Cloudflare -> B2) = DURABLE public read cache. 12,922+ narinfos live
    here permanently. This is the substituter consumers/AMIs read. Standard Nix binary-cache
    HTTP API (/nix-cache-info, /<hash>.narinfo, /nar/<file>.nar.xz), signed cache.solnix.io-1,
    anonymous read + signature verification.
  - **Trusted read pubkey (current): cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=**
    (the older 5HAV... key is superseded; verified 8UNrVA... realises with require-sigs).
RULES: upload -> s3.solnix.io (unchanged); READ + durability-verify -> cache.solnix.io ONLY
(never re-read the s3.solnix.io inbox to check durability). Narinfos carry a Torrent: field
(opt-in BitTorrent package sharing, NixOS-model + P2P).
FUTURE DIRECTION (maintainer): move OFF the s3.solnix.io endpoint for packages entirely and use
the SAME model as NixOS.org (CDN -> object store), plus solnix's additional opt-in BitTorrent
package sharing. s3.solnix.io stays only as the bootstrap-era upload convenience.

## (SUPERSEDED - misdiagnosis, kept for history) 2026-08-03/04 "non-durable backend" notes
## ⚠️ CRITICAL (2026-08-03): s3.solnix.io PACKAGE layer is NOT durable — backend defect
Cache-integrity audit finding (docs/registry/AUDIT-cache-phantom-2026-08-03.md):
- The `s3.solnix.io` MinIO-style gateway does NOT durably commit/replicate narinfo+nar objects
  under the package (bucket-root) prefix. Writes return 200 without persisting; reads are
  NON-DETERMINISTIC (same object: 200 on one request, 404 seconds later; 44/50 vs 8/50
  request-to-request). This is NOT the nix-copy bug — `aws s3 cp` fails identically. It is a
  BACKEND durability/replication defect. No client-side re-upload+verify loop can fix it.
- STABLE / trustworthy: the `seed/` and `bootstrap/` prefixes — 10/10 stable (the churn-immune
  bootstrap trust root is INTACT). Only the package narinfo layer flaps.
- RECOVERY STAGED: 49/51 exactly-Nix real-derivation store paths re-exported + signed, staged
  locally at /tmp/cache-audit/repair/bcache (on the OI host / dev-box) — ready for one-command
  re-publish ONCE THE BACKEND IS DURABLE. 1 lost (gmp-with-cxx-info) needs rebuild.
- ACTION REQUIRED (maintainer / infra): fix s3.solnix.io backend durability+replication for the
  package prefix, OR migrate the package cache to a durable bucket, then re-publish the staged
  bcache + re-run the tranches' publishes. Until then, treat package publishes as NOT PERSISTED
  and do NOT gate build-verification on cache round-trip (verify locally: deriver + hermetic
  closure + runs; the cache round-trip is unreliable by backend, not by our process).

## ⚠️ BACKEND FIX INCOMPLETE (2026-08-04) — objects EVICTED after write (slow-timescale)
The site-team fix restored the immediate read/HEAD path + a dropped anon-read bucket policy,
but object DURABILITY still fails on a minutes-to-hours timescale (was ms before):
- Full re-publish uploaded 197 narinfos/190 nars, all read-back 200 at write time.
- ~2h later: 78 present; then 44; churning non-monotonically (44<->49) -> final 49.
- A zlib narinfo verified sticky 200x3 at 11:37 then GONE by ~13:xx (auth HEAD absent).
- Only the NEWEST writes survive; older objects are culled. seed/+bootstrap/ prefixes EXEMPT (stable).
- 0 package objects durably persist. This looks like an eviction/TTL/GC/quota policy on the MinIO
  backend, NOT a client/publish-script issue (fixed publish path file://->aws s3 sync was used).
HAND BACK TO SITE TEAM — the durability fix is incomplete: stored package objects are evicted
  within minutes-hours; only trust-root prefixes and freshest writes survive.
READY WHEN FIXED: all 177 signed closures staged locally (OI host store + local file:// cache);
  re-run = single sign->file://->aws s3 sync sweep, then sticky-verify + staged->published flip.
  Ask the team to confirm a test object PERSISTS FOR HOURS (not just passes an immediate sticky read).
