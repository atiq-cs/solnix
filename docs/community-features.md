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
- The service runs as `daemon`, waits a random 0-6 h, sends at most once per UTC day, and treats a non-200 as
  "try next hour". `DO_NOT_TRACK=1` in its environment, or the file `/etc/solnix/telemetry-off`, stops it sending.

## Turning it on for a host (nix-config nixos/solnix/<host>.nix)

```nix
solnix.privacy.enable = false;                # census + seed + build
solnix.telemetry.census.hostKind = "laptop";  # lixi; dixi and dixa stay "server"
# solnix.telemetry.census.location = { country = "US"; region = "MA"; };   # only if the maintainer wants one
solnix.builder.contactEmail = "greg+dixi-solnix@burd.me";   # per host; used once enrolment ships
```

## Cache proxy (svc:/site/solnix-cache-proxy, installed with cache.seed)

- An inetd service: `proto=tcp` (IPv4 only), `bind_addr=127.0.0.1`, port 37515. inetd runs one ksh93 process per
  request as `nobody`. inetd's `name` must be a services(5) entry (it calls getservbyname, and a bare port number
  comes back NULL), so the generation owns /etc/inet/services: the gate's stock file (modules/config/community/services.stock,
  the same bytes as dixi's and dixa's) plus one line.
- nix.conf gets `extra-substituters = http://127.0.0.1:37515`, and the proxy's nix-cache-info says `Priority: 30`
  (cache.solnix.io says 50), so nix asks the proxy first. Nix checks each signature and NAR hash itself.
- narinfo: relayed from cache.solnix.io. The proxy records the `Torrent:` line under the NAR name; it reads the line
  and never builds it from the URL. NAR: when the narinfo had a `Torrent:` line and a fetcher is configured
  (PROXY_TORRENT_FETCH, patch 4), the proxy serves the fetcher's bytes. Otherwise, or on any failure, it answers
  302 to `https://cache.solnix.io/nar/<file>`, which is the HTTP fallback.
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

## Queue builder (svc:/site/solnix-builder, installed with cache.build)

- Each tick (15 min): if the 1-minute load is below `solnix.cache.build.loadMax`, read
  `GET https://telemetry.solnix.io/api/v1/build-queue/rows` (public) and the served recipes.tsv, and plan every row:
  - `BUILD`: a served row matches (pname, or pname-version, plus version and system).
  - `MET`: manpage-missing, but the served out already ships share/man.
  - `NO-MAN`: the recipe says has_manpages=n.
  - `NO-RECIPE`: no served row at that version.
  - `OTHER-SYSTEM`: a system this host does not build.
- Claim is not selective (registry.rebuild_claim hands out the next job by priority, available_at, id), so the
  builder claims (max 1) only when the plan has a BUILD. A claimed job is heartbeat at once and every lease/3.
  BUILD jobs run `nix build --rebuild` of the attr whose outPath is the recipe's out: built from source here, and it
  fails unless the output is identical. Then `complete done {version, nar_hash, store_path}`, after checking that
  the narHash equals the one cache.solnix.io serves. Every other claimed job is `complete failed` with the reason,
  which feeds the queue's own backoff and park.
- It runs in project `solnix-builder` (`project.cpu-cap`, default 400 = four CPUs; the generation owns /etc/project:
  the gate's stock file plus that line) and builds under `nice 19`. FSS is not used: the solnix kernels load only
  TS, SDC and FX by default. The cap and the nice value bound its CPU share.
- Measured 2026-10-28 against the live queue: 19 rows, 2 MET (wget, ncurses: their served outs already have man
  pages), 1 NO-MAN (openssl: has_manpages=n), 16 NO-RECIPE. Nothing there is buildable from the served recipes, so
  infra's feeder and our recipes have to change before any of it can be done.

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
