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
| **Public key** | `cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=` |
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
  --option trusted-public-keys 'cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=' \
  --option require-sigs true \
  /nix/store/b1q9mlpjpy9k31j0q6mjmc1h7l99ha2s-system-path
```

Fetching with a *wrong* trusted key + `require-sigs true` must fail with
"lacks a signature by a trusted key" — that's the real proof the signature gate
works, not just that bytes downloaded.
