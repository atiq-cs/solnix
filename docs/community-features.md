# The solnix.io community features: census, cache proxy, seeding, queue builder

Opt-in, private by default (infra handoff 2026-10-28 §1, docs/design-telemetry-client.md). Code:
modules/config/community/. Tests: scripts/test-community-eval.sh (eval, floki), scripts/test-census.sh (illumos).

## The switches

| option | default | effect |
|---|---|---|
| `solnix.privacy.enable` | `true` | master switch. While true nothing below is installed, and the MOTD asks. |
| `solnix.telemetry.enable` | `true` | group switch for reporting |
| `solnix.telemetry.census.enable` | `true` | the daily census (svc:/site/solnix-census) |
| `solnix.telemetry.census.endpoint` | `https://telemetry.solnix.io/api/v1/census` | `null` = never send |
| `solnix.telemetry.census.hostKind` | `"server"` | `server` / `laptop` / `workstation` |
| `solnix.telemetry.census.location` | `null` | operator-volunteered `{ country; region; locality; }`, checked at eval |
| `solnix.cache.seed.enable` | `true` | BitTorrent seeding of what this host fetched or built |
| `solnix.cache.build.enable` | `true` | idle-time queue builder |
| `solnix.builder.enable` | `false` | identified builder (enrol/rotate with the host key); separate opt-in |
| `solnix.builder.contactEmail` | `null` | sent only in the enrolment record |

Effective = `!privacy.enable && <group> && <feature>` (`solnix.community.active.*`).

## Census

- The record is JSON. The live ingest (`POST https://telemetry.solnix.io/api/v1/census`) rejects the EDN form infra's
  note shows with `400 {"error":"invalid census record"}` and accepts the same fields as JSON. Measured from dixi on
  2026-10-28: the EDN form got 400 and the JSON form got 200.
- Fields: `version kind system host-kind illumos-flavor [seeding building builder] [location] nonce day`. The flags are
  true only when the matching service is installed on this host. `location` appears only when the operator set it.
- nonce = first 16 base64 chars of HMAC-SHA256(secret, "solnix-telemetry"+day). The secret is 32 random bytes in
  /var/lib/solnix/census/census-secret (0600, owner `daemon`) and is replaced each UTC day. It is never sent.
- The service runs as `daemon` and sends at most once per UTC day, inside the host's own 15-minute window: one of the
  day's 96 quarter-hours, picked at random once and kept in /var/lib/solnix/census/census-slot. Each day it sends at a
  fresh random moment inside that window. A fleet's pings spread over the whole day instead of arriving together, and
  one host keeps to the same time of day. A non-200 is retried twice, 2 min apart, inside the window, then tomorrow. `DO_NOT_TRACK=1` in its environment, or the file `/etc/solnix/telemetry-off`, stops it sending.

## Turning it on for a host (nix-config nixos/solnix/<host>.nix)

```nix
solnix.privacy.enable = false;                # census + seed + build
solnix.telemetry.census.hostKind = "laptop";  # lixi; dixi and dixa stay "server"
# solnix.telemetry.census.location = { country = "US"; region = "MA"; };   # only if the maintainer wants one
solnix.builder.contactEmail = "greg+dixi-solnix@burd.me";   # per host; used once enrolment ships
# solnix.cache.seed.torrentPackage = pkgs.solnix.solnix-torrent;   # seeder + swarm probe + the proxy's swarm path
```

## Cache proxy (svc:/site/solnix-cache-proxy, installed with cache.seed)

- An inetd service: `proto=tcp` (IPv4 only), `bind_addr=127.0.0.1`, port 37515. inetd runs one ksh93 process per
  request as `nobody`. inetd's `name` must be a services(5) entry (it calls getservbyname, and a bare port number
  comes back NULL), so the generation owns /etc/inet/services: the gate's stock file (modules/config/community/services.stock,
  the same bytes as dixi's and dixa's) plus one line.
- nix.conf gets `extra-substituters = http://127.0.0.1:37515`, and the proxy's nix-cache-info says `Priority: 30`
  (cache.solnix.io says 50), so nix asks the proxy first. Nix checks each signature and NAR hash itself.
- narinfo: relayed from cache.solnix.io. The proxy records the `Torrent:` line under the NAR name; it reads the line
  and never builds it from the URL. NAR: the proxy tries the swarm only when the narinfo had a `Torrent:` line, a
  fetcher is configured (PROXY_TORRENT_FETCH, from `solnix.cache.seed.torrentPackage`), and solnix-swarm-probe found
  the swarm reachable in the last 30 min (`/var/lib/solnix/cache-proxy/swarm/ok`). Then it serves the fetcher's bytes.
  Otherwise, or on any failure, it answers 302 to `https://cache.solnix.io/nar/<file>`, which is the HTTP fallback.
  A failed fetch deletes swarm/ok, so the next NAR goes straight to HTTP.
- Evidence (2026-10-28):
  - Loopback proof from another host: /scratch/solnix/community1/loopback-proof.txt. From floki, the proxy port was
    refused 3/3 while a 0.0.0.0 control on the same host and the same SG rule connected 3/3. Negative control:
    with `bind_addr=""` the port was reachable 3/3.
  - Nix through the proxy into a throwaway chroot store, on the kiwi OI host under real inetd
    (scripts/oi-nix-through-proxy.sh, log /scratch/solnix/community1/nix-through-proxy.log):
    - A, clean: jq is substituted from the proxy alone.
    - B, a narinfo with one Sig byte flipped: "lacks a signature by a trusted key".
    - C, a valid xz whose NAR has one content byte flipped, served by the torrent path: hash mismatch.
    - D, an untrusted key: refused.
    - C2, an honest fetcher on the same torrent path: jq is substituted, and the fetcher log names the three NARs.

## Seeding (svc:/site/solnix-seed and solnix-swarm-probe, installed with cache.seed and a torrentPackage)

- The client is `pkgs.solnix.solnix-torrent` (src/solnix-torrent/solnix-torrent.cpp) on `pkgs.solnix.libtorrent-rasterbar`
  2.0.11 (pkgs/illumos/solnix-torrent.nix), built from source against the store openssl and the nixChain boost 1.86
  headers. Its licence is BSD-3. The tarball also carries a GPL-3 simulator, which is not built. The default is
  `torrentPackage = null`: no seeder, no probe, and an HTTP-only proxy.
- solnix-swarm-probe (as `nobody`, every 10 min) announces once for jq's served torrent. It keeps swarm/ok only when
  the tracker reports a seed (`complete > 0`) and lists at least one peer outside 0/8, 10/8, 100.64/10, 127/8,
  169.254/16, 172.16/12 and 192.168/16.
- solnix-seed (as `nobody`) seeds only what this host fetched through the proxy or built (the post-build hook queues
  each `$OUT_PATHS` entry), and only if cache.solnix.io serves it signed by 8UNr. The NAR bytes come from the cache and
  are checked against the signed FileHash. solnix-seed-setup (root) creates the state directories.
- Fetches: TCP only; DHT, PEX and LSD are off; only `tracker.solnix.io` is used. The fetch gives up after 10 s
  without a payload byte. libtorrent checks every piece's SHA-1 against the info dict, and nix then checks the NAR
  hash.
- Evidence (2026-10-29, kiwi OI host; logs in /scratch/solnix/seed2/):
  - scripts/test-swarm.sh, 8/8 (tests1.log):
    - Seed and fetch through a local tracker: the fetched NAR is byte-identical to the cache's.
    - Control: a non-libtorrent peer (scripts/bt-test-peer.py liar) serving the honest bytes: the fetch completes.
    - The same peer with one byte flipped: the fetcher reports "191824 B failed the piece hash", exits 1 and leaves
      no file.
    - No seeder: the fetch gives up in 10 s.
    - The probe says down for a loopback-only peer list and for no tracker, and ok for a public peer.
  - The live tracker (probe-live.log): with this host seeding jq, the tracker reports `complete 1`. It lists the
    seed as the ingress 10.42.0.158, so the probe says down (infra tracker defect #1).
  - Cost with that tracker (timing1.log): one served NAR through the proxy under real inetd, 3 runs each, interleaved:
    - torrentPackage off: 0.377, 0.417 and 0.393 s.
    - torrentPackage on: 0.406, 0.376 and 0.387 s; the fetcher never ran.
    - Control with the probe bypassed: 11.4, 11.2 and 11.2 s.

## Queue builder (svc:/site/solnix-builder, installed with cache.build)

- Each tick (a random 10-30 min apart, so a fleet does not poll solnix.io in step) first sizes itself: busy CPUs over a
  5 s `vmstat` sample. None of the builder's own jobs run between ticks, so that is other work; the 1-minute load average
  would still count the last tick's builds. It runs up to `floor((CPUs - busy) / coresPerJob)` jobs at once, capped by
  `parallelJobs`. A numeric `loadMax` keeps the older gate: no job while that many CPUs are busy, otherwise at least one.
  Then it reads the served recipes.tsv and the public listing (cache-api v44): `GET .../build-queue/rows?system=<system>`
  (that system's first 500 rows in claim order, mostly nixpkgs attrs with no recipe), plus `?system=<system>&pname=a,b,...`
  for every pname the served recipes have for the system (100 a query), so a job it could do is never hidden past the
  window. It plans every row.
  A row's outs are every served recipe row at (pname, version, system): recipes.tsv has one row per output path, and
  rows from older solnix commits stay (jq 1.7.1 has two).
  - `BUILD`: a served row matches (pname, or pname-version, plus version and system). For manpage-missing, only the
    outs cache.solnix.io does not serve yet.
  - `MET`: manpage-missing, but a served out already ships share/man.
  - `MAN-GAP`: manpage-missing, has_manpages=y, every out is served and none has share/man. A rebuild that matches the
    served NAR is the same bytes, so it cannot add pages: a recipe fix, not a build.
  - `NO-MAN`: the recipe says has_manpages=n.
  - `NO-RECIPE`: no served row at that version.
  - `OTHER-SYSTEM`: a system this host does not build.
- Build first, claim only what was built. The queue spends an attempt at claim time (`registry.rebuild_claim`), so the
  builder proves each BUILD row here before it touches the queue, in the listing's order. Each row is one job with its own
  state directory (`/var/lib/solnix/builder/job/<pname>/`: drv.json, dry, resp, claim.json), started as a slot frees
  (ksh93 `JOBMAX`), its rebuild given `--option cores <coresPerJob>`. Every job of a tick evaluates the same locked commit
  of `BUILDER_FLAKE` (`nix flake metadata` once per tick):
  1. evaluate `packages.<system>.<pname>` of `BUILDER_FLAKE` (default `git+https://git.solnix.io/solnix.git?ref=main`,
     not the registry's `solnix`, which is the 26.11 edition with other outs) and keep the out that is one of the row's;
  2. the out must be served (its narinfo NarHash). An unserved out is a first build, i.e. a submission, which needs the
     submit key: declined, not wired (the maintainer's decision);
  3. dry run of the leaf and every input derivation: declined unless all of it is a substitute (a dry run of the leaf
     alone lists nothing when the leaf is substitutable);
  4. fetch the served out and check its local NarHash equals the served one (a copied-in local copy can differ:
     qbuild2 measured jq), then `nix build --rebuild`, which fails unless this build is identical;
  5. only then claim it, `pnames=[<pname>]`, max 1, and complete `done {version, nar_hash, store_path}` with the served
     NarHash. An empty claim means another builder has it. A pname with two rows for the system is declined (pnames
     cannot choose between them).
  A declined or failed job costs the queue nothing, and nothing is completed `failed` because this host cannot do it.
  A failed rebuild is remembered per derivation in `/var/lib/solnix/builder/tried/` and not retried (delete the file to
  retry). Without the bearer it stops before the fetch and logs `dry run`. Every nix call is time-bounded
  (`bounded`, illumos has no timeout(1)): a `nix store ls` against cache.solnix.io hung for over 8 minutes on dixi.
- It runs in project `solnix-builder` (`project.cpu-cap`, default `parallelJobs * coresPerJob * 100`, 400 = four CPUs for
  the idle profile, none for dedicated; the generation owns /etc/project: the gate's stock file plus that line) and builds
  under `nice` (19). FSS is not used: the solnix kernels load only TS, SDC and FX by default. The cap and the nice value
  bound its CPU share. Root's nix builds in the builder's own process tree (the local store, not the daemon), so the
  cap and nice cover the builds.
- Settings (`solnix.cache.build`): `profile = "idle"` (default: one job, all CPUs as its `cores`, cap 400, `loadMax` 2,
  10-30 min between ticks) or `"dedicated"` (a build host: as many 4-core jobs as idle CPUs allow, no cap, no `loadMax`,
  1-5 min to the next tick after one that rebuilt or completed a job, 10-30 min after one with nothing to do). Each of
  `parallelJobs` (null = as many as fit), `coresPerJob`, `cpuCap` (null = none), `loadMax` (null = none), `nice`,
  `tickMin`/`tickMax` and `busyTickMin`/`busyTickMax` overrides the profile. The isolated zone builder exports the same
  settings, and its zone `capped-cpu` and nix-daemon `max-jobs` follow them.
- Measured 2026-10-28 against the live queue: 19 rows, 2 MET (wget, ncurses: their served outs already have man
  pages), 1 NO-MAN (openssl: has_manpages=n), 16 NO-RECIPE. Nothing there is buildable from the served recipes, so
  infra's feeder and our recipes have to change before any of it can be done.
- Measured 2026-10-29 on dixi (`PATH=/usr/bin ksh93 scripts/test-builder.sh`: RESULT PASS, 24 checks). The gate runs
  with real nix against a fixture flake served from a file:// cache and a fake queue: a nondeterministic rebuild, a
  local NarHash unlike the served one, an input that would be built here, an unserved out, no matching attr and a
  duplicated pname each end with no claim. The good fixture is rebuilt, claimed with `pnames=["good"]`, heartbeat and
  completed done. Live, jq at main declines because the dry run would build 11 derivations here first (the
  build-tool closure is not on the cache). The live queue (14 rows) plans 3 MET, 1 NO-MAN, 10 NO-RECIPE, so there is
  nothing to build. The old builder fails 15 of the checks. Today no solnix host can build a leaf
  (docs/pending/builders-need-store-tools.md), so every BUILD row is declined at the dry run.

- Measured 2026-10-31 on dixi (qbuild4, `PATH=/usr/bin ksh93 scripts/test-builder.sh`: RESULT PASS, 37 checks). Four
  4-second fixture builds ran at once at N=4 (every build window overlaps the others; the tick took 8 s), and one after
  another at N=1 (27 s). Five jobs made five claims, each completed with its own id, token, out and NarHash. A fixture
  whose out is its `NIX_BUILD_CORES` proves `--option cores` reaches the build, and a hung rebuild at N=1 is killed at
  `BUILDER_BUILD_SECS`. Sabotaged copies fail the matching checks: a shared state dir, no `JOBMAX` reset in the job,
  serial jobs, a bare `/rows`, no `?pname=` queries, no `--option cores`. The old builder fails 16 checks. Live on dixi
  (32 CPUs, idle): `size` gives 8 jobs of 4 cores. The listing is 581 rows (the 500-row window plus 81 recipe rows past it),
  which plan to 95 BUILD and 486 NO-RECIPE in 1.8 s, and the whole dry-run tick takes 14 s. Of the 95, 64 are not served
  (first builds), 6 have no attr at main, 3 need a non-FOD input built here, and 22 pass the dry run (10 of those
  rebuilt and failed earlier: nondeterministic, or a missing build tool). On dixa, with other work holding 30 of 32
  CPUs, `size` gives 0 jobs, and all 500 aarch64 rows plan NO-RECIPE: no served aarch64 recipe rows yet.

### The bearer (never in the store)

One shared `X-Solnix-Build` secret for all hosts: sops `secrets/build-queue-bearer.yaml`, key `build-queue-bearer`,
encrypted to the solnix dev key. Without the file the builder plans and logs `dry run`, and never claims. The builder
passes it to curl on stdin (`-H @-`), never in argv (psargs is world-readable). To place it on a host, from floki:

```sh
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d --extract '["build-queue-bearer"]' secrets/build-queue-bearer.yaml |
  ssh <host> 'pfexec ksh93 -c "umask 077; mkdir -p /var/lib/solnix; cat > /var/lib/solnix/build-queue-bearer"'
```

## Host identity: the host's own ssh-ed25519 key, kept in sops

The builder identity is `/etc/ssh/ssh_host_ed25519_key`. dixa, dixi and lixi are enrolled at tier 1 (infra,
2026-10-28), so do not enrol them again. Their private keys are in nix-config `nixos/solnix/secrets.yaml`
(commit fc43aa4), keys `<host>_ssh_host_ed25519_key` and `<host>_ssh_host_ed25519_key_pub`, encrypted to the solnix
dev key. On a reinstall, restore the key before the new system first starts sshd, so the identity (and the
known_hosts pin) survives:

```sh
H=dixi; cd ~/ws/nix-config
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d --extract "[\"${H}_ssh_host_ed25519_key\"]" nixos/solnix/secrets.yaml |
  ssh root@<new-host> 'umask 077; cat > /etc/ssh/ssh_host_ed25519_key.new && ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key.new'
# compare that output with the _pub value; if they match:
ssh root@<new-host> 'mv /etc/ssh/ssh_host_ed25519_key.new /etc/ssh/ssh_host_ed25519_key &&
  ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key > /etc/ssh/ssh_host_ed25519_key.pub && svcadm restart network/sshd'
```

If the key cannot be restored (it was lost or compromised), the host's identity moves by `rotate`, signed by the old key from
sops (patch 5: scripts/solnix-builder-identity). A new host with a new key uses `enroll`, which lands at tier 0
until infra raises it.

## Enrol and rotate (scripts/solnix-builder-identity)

`solnix-builder-identity enroll <key> <arch> [email] [--send]` and `rotate <old-key> <new-key> [--send]` build the
JSON bodies infra specified (live at `https://telemetry.solnix.io/api/v1/builder/{enroll,rotate}` since cache-api v37).
Each signature is `ssh-keygen -Y sign -n solnix-builder` (armored SSHSIG) over the fixed-domain payload, with a
newline after each line including the last. Rotate is signed by both keys. Without `--send` the script only prints
the body. Use it for a new or reinstalled host whose key could not be restored. Do not use it for dixa, dixi or lixi:
they are enrolled at tier 1 already. `solnix.builder.enable = true` sets the census `builder` flag. The operator sets it
once the host is enrolled.

Tested 2026-10-28:
- scripts/test-builder-identity.sh, offline on illumos, needing only /usr/bin (ksh93, ssh-keygen, nawk; no jq): 16/16 on
  dixi as gburd with PATH=/usr/bin. Each signature verifies with `ssh-keygen -Y verify` over the exact payload. A broken
  signature, a tampered payload, the wrong key, the wrong namespace, a rotate to the same key and a quoted email are
  all refused. It exits 1 when any check fails (last line `RESULT:`), and that exit code is negative-controlled with
  three broken copies of the client: a corrupted signature, a missing `arch`, and swapped rotate keys each give rc=1.
  The first version needed jq, so on a host without it 7 positive checks failed and the run still looked green:
  piped through `tail`, the reported rc was tail's 0.
- solnix-builder-identity itself needs no jq: it uses ssh-keygen, nawk, and curl for `--send`, all in /usr/bin on a
  solnix host. curl verifies TLS against the default CA path there; measured 200 without CURL_CA_BUNDLE.
- Live, once, with throwaway keys (/scratch/solnix/community1/identity-live-test.txt): enroll A returned 200 (tier 0,
  keyid ssh-d5ae18c7c6a1), then rotate A to B returned 200 "rotated". The private keys were deleted afterwards.
