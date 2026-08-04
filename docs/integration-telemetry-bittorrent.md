# solnix packages: telemetry + BitTorrent integration spec

For the team building out the solnix package set / base config. This is what to
wire into `pkgs.solnix.*` / the solnix NixOS-style modules so a running solnix
system participates in the community telemetry (the /pulse dashboard + popularity
ranking) and the BitTorrent cache distribution — all opt-in, no PII.

The server side (ingest endpoint, tracker, seeder, B2/Cloudflare cache) is LIVE
and will not change; this spec is the CLIENT/base-config side you implement.

Ground rule enforced everywhere: **no personally-identifiable information.** No
name, IP, MAC, machine-id, hostname. Region is derived from the connecting IP at
the edge and the IP is immediately discarded. Everything is **default-OFF**
(ship-private); a running system that never edits config sends nothing and seeds
nothing.

---

## 1. The privacy master switch (authoritative — both features gate on it)

```nix
solnix.privacy.enable = true;   # DEFAULT true = fully private, nothing phones home / seeds
```

Setting it `false` opts into the community pulse; then these default **on** but
are individually controllable:

```nix
solnix.privacy.enable            = false;   # opt in
solnix.telemetry.enable          = true;    # group: all telemetry
solnix.telemetry.census.enable   = true;    #   platform/active-user census
solnix.telemetry.packages.enable = true;    #   installed / in-use / transferred
solnix.cache.seed.enable         = true;    # BitTorrent: seed built cache objects
solnix.site.p2p.enable           = true;    # (browser WebRTC site sharing — site side)
```

**Effective-enable rule (implement EXACTLY):**
```
active(feature) = (not solnix.privacy.enable)
               && solnix.telemetry.enable        # for telemetry features
               && solnix.telemetry.<feature>.enable
active(seed)    = (not solnix.privacy.enable) && solnix.cache.seed.enable
```
The master switch always wins. Also honor a global kill: if `DO_NOT_TRACK=1` in
the environment or `/etc/solnix/telemetry-off` exists, send/seed nothing
regardless. When a feature is disabled, DON'T INSTALL its unit at all (not just
disable it) — a default-private box has no reporter/seeder scheduled.

---

## 2. TELEMETRY — the wire contract (server LIVE, do not change)

- **Endpoint:** `POST https://search.solnix.io/telemetry`  (also reachable on
  cache.solnix.io — same service). Body = **EDN**. `Content-Type: application/edn`
  advisory (server reads the raw body).
- **Required key:** `:kind` (string). Missing `:kind` → HTTP 400.
- **Server first-classes** `:kind`, `:attr`, `:system`; the ENTIRE EDN map is
  also stored verbatim (pg_mentat), so extra keys are fine and preferred
  namespaced (below) for future analysis.
- **Region:** DO NOT send any location. The edge derives a coarse region from
  the IP (`X-Region`) and drops the IP. The client sends NOTHING location-bearing.
- **Response:** `200 ok\n`. Treat non-200 as "try later"; never retry hard.

### Event kinds (one EDN map per POST)

Platform census — once/day:
```edn
{:kind "platform_census"
 :system "x86_64-solaris"          ; the solnix system tuple
 :host-kind "bare-metal"           ; closed vocab: bare-metal | vm | zone
 :illumos-flavor "solnix"          ; coarse, non-fingerprinting
 :nonce "<per-day per-device nonce>"   ; §2.1
 :day "2026-07-31"}
```

Packages in daily use — once/day (the set actively used):
```edn
{:kind "packages_in_use"
 :system "x86_64-solaris"
 :attrs ["pkgs.solnix.ripgrep" "pkgs.solnix.git" "pkgs.solnix.tmux"]
 :nonce "<same-day nonce>" :day "2026-07-31"}
```

Package installed — per install (or daily batch):
```edn
{:kind "package_installed" :attr "pkgs.solnix.ripgrep"
 :system "x86_64-solaris" :day "2026-07-31"}
```

Package seeding — once/day, only if `cache.seed.enable` (reports what this host
can seed, so the swarm/popularity view is real):
```edn
{:kind "package_seeding" :system "x86_64-solaris"
 :attrs ["pkgs.solnix.ripgrep" "pkgs.solnix.git"] :day "2026-07-31"}
```

> Prefer ONE event per attr with `:attr` for anything you want to show in /pulse
> + /popular immediately (those read the indexed `attr` column). Batched
> `:attrs [...]` is fine for census rollups the indexer expands later.

### 2.1 The anonymity nonce (get this right)
The server dedups within a single day (so one machine counts once toward "active
users") WITHOUT a stable identifier:
- `nonce = base64(HMAC-SHA256(key = per-boot-or-per-day random secret,
                              msg = "solnix-telemetry" + day-string))[:16]`
- The secret MUST rotate ≥ daily and MUST NOT derive from any stable/identifying
  value (no machine-id, MAC, hostname, serial). A fresh `getrandom()` held only
  in tmpfs for the day is ideal. Client never sends the secret, only the derived
  per-day nonce. `package_installed` events need no nonce (counted as events).
- NEVER send: hostname, machine-id, MAC, serial, username, IP, timezone, locale,
  uptime, or free-form fingerprintable strings. Keep host-kind/flavor to a small
  closed vocabulary.

### 2.2 What each feature emits + cadence

| Config feature            | :kind               | cadence            |
|---------------------------|---------------------|--------------------|
| telemetry.census          | platform_census     | once/day           |
| telemetry.packages        | packages_in_use     | once/day           |
| telemetry.packages        | package_installed   | on install / daily |
| cache.seed                | package_seeding     | once/day           |

"Actively used" = a cheap, documented definition (system closure / user
profile). Do NOT scan process lists or open files. Coalesce to ≤1 census + ≤1
in-use per day (first reporter run of a new day).

### 2.3 Networking / good-citizen rules
- Timeout ≤5s; telemetry is best-effort, never blocks a rebuild/boot/pkg op.
- No aggressive retry — drop on failure, try next scheduled run (≤1 light retry).
- **Jitter** the daily timer (systemd `RandomizedDelaySec`, or SMF equivalent) so
  the fleet doesn't stampede at 00:00 UTC.
- Verify TLS (real Let's Encrypt/CF cert). No queueing to disk (avoids
  accumulating identifiable history).

### 2.4 Suggested shape
- A solnix/NixOS module `modules/telemetry.nix` exposing the §1 options; when
  active, installs a ~50-line reporter (build the EDN, `curl -m5 -XPOST`, exit)
  + a systemd timer (`OnCalendar=daily`, `RandomizedDelaySec=6h`,
  `Persistent=false`) / SMF equivalent, run as an unprivileged user. Gate the
  WHOLE unit behind the effective-enable rule.

### 2.5 Verify against the live server
```sh
curl -m5 -H 'Content-Type: application/edn' \
  --data '{:kind "package_installed" :attr "pkgs.solnix.ripgrep" :system "x86_64-solaris" :day "2026-07-31"}' \
  https://search.solnix.io/telemetry            # -> ok
curl -m5 -XPOST --data '{:attr "x"}' https://search.solnix.io/telemetry   # -> 400 (missing :kind)
```
Aggregates appear at https://solnix.io/pulse.html (k-anonymized: buckets < 5
contributors are suppressed — a single test event won't show; by design).

---

## 3. BITTORRENT — cache distribution (opt-in seeding + fetch)

Users seed cache objects by default WHEN opted in (`cache.seed.enable`), so the
cache has a distributed second life and egress is offloaded. Signatures gate
trust — a NAR fetched over BitTorrent is verified against the SAME narinfo
signature before import, so a malicious peer can only waste bandwidth.

### 3.1 Live server-side facts (use these; don't change)
- **Tracker:** `https://tracker.solnix.io/announce` (HTTP/WS announce).
- **Cache origin:** `https://cache.solnix.io` (Cloudflare-fronted B2). narinfos
  are pre-signed and carry a `Torrent:` field pointing at the object's `.torrent`.
- **Signing pubkey** (already in users' `trusted-public-keys`):
  `cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=`
- Each cache object may have `torrent/<file>.nar.xz.torrent` in the bucket
  (served at `cache.solnix.io/torrent/...`).

### 3.2 Torrent conventions the client MUST match (deterministic infohash)
Peers only swarm together if the infohash is identical, so the `.torrent` MUST be
reproducible from the NAR bytes alone:
1. **Fixed piece length** — pin ONE project-wide value (spike used 256 KiB).
2. **NO `creation date`, NO `created by`** — these per-run fields change the
   infohash and split the swarm. Strip them (see the `normalize-torrent.py`
   reference in solnix-infra `docs/handoff/torrent-shim-spike/`).
3. **Single announce** = `https://tracker.solnix.io/announce`. No announce-list,
   no embedded DHT-node list in the infohash-relevant fields. (DHT/PEX may be
   enabled at the client layer separately if swarms prove thin.)
4. **Name** = the NAR filename / store-path basename (deterministic).
The build team + the seeder + the fetch shim MUST all produce the byte-identical
`.torrent` for a given NAR. The reference impl + the fixed spike are in
solnix-infra `docs/handoff/bittorrent-cache-shim.md` (+ `torrent-shim-spike/`).

### 3.3 Fetch side (the tricky part — read the handoff)
Nix can't natively fetch via BitTorrent. The recommended shape: a local
swarm-backed helper that, for a wanted NAR, reads the narinfo `Torrent:` field,
pulls the NAR from the swarm, and **falls back to `https://cache.solnix.io` on
miss/timeout**. The NAR is then verified against the narinfo signature by Nix's
normal `trusted-public-keys` check before import — unchanged. `post-build-hook`
is push-only (good for seeding), not a pre-fetch hook; see the handoff for the
exact integration options + open decisions.

### 3.4 Seed side (module)
```nix
# active = (!solnix.privacy.enable) && solnix.cache.seed.enable
solnix.cache.seed.enable = true;                              # opt-in
# a systemd/SMF service that announces + seeds VALID, SIGNED, PUBLIC store paths
# to tracker.solnix.io. Seeds only paths that verify against cache.solnix.io-1.
```
- Announce URL: `https://tracker.solnix.io/announce`.
- Seed ONLY signed public store paths (never private user data).
- **Honest tradeoff to document to users:** BitTorrent peers see each other's
  IPs (that's how a swarm works). That's precisely WHY seeding is opt-in behind
  the privacy switch — a box that hasn't set `solnix.privacy.enable = false`
  never joins a swarm and never exposes its IP. (Telemetry never stores IPs; the
  swarm IP visibility is inherent to BitTorrent.)

### 3.5 Security (non-negotiable)
- Signatures gate trust unconditionally: verify every fetched NAR against
  `cache.solnix.io-1` before import. A bad peer can only waste bandwidth (HTTP
  fallback recovers). Torrent piece hashes catch transit corruption; the Nix
  signature catches forgery.

---

## 4. Reference material (in solnix-infra, more detail)
- `docs/handoff/bittorrent-cache-shim.md` — full fetch/seed design + open decisions.
- `docs/handoff/torrent-shim-spike/` — the working spike + `normalize-torrent.py`
  (deterministic-infohash fix).
- The /pulse + telemetry design: solnix-infra `docs/design-telemetry-ask.md`.
- The handbook privacy page (solnix.io/handbook/privacy.html) is the user-facing
  explanation; keep the module docs consistent with it.

## 5. Non-negotiables (do not relax)
1. No PII, ever. Region derived server-side, IP dropped. Client sends no location.
2. Default private: `solnix.privacy.enable = true` (default) installs nothing,
   sends nothing, seeds nothing.
3. Opt-out is trivial + total (the master switch).
4. Telemetry: best-effort, non-blocking, jittered, rate-limit-friendly, rotating
   per-day nonce only.
5. BitTorrent: deterministic infohash; seed only signed public paths; signatures
   gate trust; seeding opt-in (IP visibility consented up front).
