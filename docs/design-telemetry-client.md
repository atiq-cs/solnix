# solnix client-side telemetry reporter — implementation spec

**For:** the solnix OS team (to implement in the `solnix` / `solnix-pkgs` repos).
**Server side is already live** — this spec describes the *client* that feeds it.
**Ground rule:** no PII, ever. No name, phone, IP, MAC, hostname, or stable
machine ID leaves the box. Default is fully private (opt-out, off).

---

## 0. TL;DR for the implementer

Build a small NixOS/solnix module + a tiny reporter script that, **only when the
user has opted in**, POSTs a few EDN facts per day to
`https://search.solnix.io/telemetry`. No daemon required — a `systemd`/SMF timer
that runs a short-lived reporter is enough. If `solnix.privacy.enable` is left at
its default (`true`), the reporter is never installed/scheduled and nothing is
sent.

---

## 1. The privacy switch (authoritative — must match the server design)

```nix
solnix.privacy.enable = true;   # DEFAULT true = fully private, phone-home OFF
```

- **Default `true` = private.** Nothing phones home. The reporter timer must not
  even be installed in this state.
- Opt in by setting `solnix.privacy.enable = false`. Then these default **on**
  but are individually overridable:

```nix
solnix.privacy.enable = false;             # opt into the community pulse
solnix.telemetry.enable          = true;   # group master: all phone-home
solnix.telemetry.census.enable   = true;   #   platform / active-user census
solnix.telemetry.packages.enable = true;   #   installed / in-use / transferred
solnix.cache.seed.enable         = true;   # P2P: advertise seedable packages
```

**Effective rule (implement exactly this):**
```
send(feature) = (not solnix.privacy.enable)
             && solnix.telemetry.enable
             && solnix.telemetry.<feature>.enable
```
The master switch always wins. A user who never edits config sends nothing.

Also honor a global kill: if `DO_NOT_TRACK=1` is in the environment or
`/etc/solnix/telemetry-off` exists, send nothing regardless of config (defense in
depth; cheap to check).

---

## 2. The wire contract (already implemented server-side — do not change)

- **Endpoint:** `POST https://search.solnix.io/telemetry`
- **Body:** one EDN map per request. `Content-Type: application/edn` (the server
  reads the raw body; the header is advisory).
- **Required key:** `:kind` (string). Missing `:kind` → HTTP 400.
- **Recognized keys the server indexes today:** `:kind`, `:attr`, `:system`.
  The **entire EDN map is also stored verbatim** (pg_mentat), so you MAY include
  extra keys (below) for future analysis — they won't error. Prefer the
  namespaced keys shown so they map cleanly to datoms later.
- **Region:** DO NOT send location. The server derives a coarse region from the
  connecting IP at the edge (`X-Region`) and **discards the IP**. The client must
  never send IP, geo, or anything location-bearing.
- **Response:** `200 ok\n` on success. Treat any non-200 as "try later", never
  retry aggressively (see §5).

### EDN examples (one POST each)

Platform census (once/day):
```edn
{:kind "platform_census"
 :system "x86_64-solaris"
 :host-kind "bare-metal"        ; one of: bare-metal | vm | zone
 :illumos-flavor "openindiana"  ; coarse distro/flavor string, no version detail that fingerprints
 :nonce "b3f1...day-scoped..."  ; see §4 — rotating, per-day, per-device, NOT stable
 :day "2026-07-27"}
```

Packages in daily use (once/day, batched):
```edn
{:kind "packages_in_use"
 :system "x86_64-solaris"
 :attrs ["pkgs.solnix.ripgrep" "pkgs.solnix.git" "pkgs.solnix.tmux"]
 :nonce "b3f1...same-day-nonce..."
 :day "2026-07-27"}
```

Package installed (per install event, or batched):
```edn
{:kind "package_installed"
 :attr "pkgs.solnix.ripgrep"
 :system "x86_64-solaris"
 :day "2026-07-27"}
```

Seedable packages (once/day, only if `solnix.cache.seed.enable`):
```edn
{:kind "package_seeding"
 :system "x86_64-solaris"
 :attrs ["pkgs.solnix.ripgrep" "pkgs.solnix.git"]
 :day "2026-07-27"}
```

> The server currently first-classes `:kind :attr :system`. For `packages_in_use`
> / `package_seeding` you may either send one event per attr with `:attr`, or one
> event with `:attrs [...]` (stored verbatim for later datom expansion). **Prefer
> one event per attr with `:attr`** if you want it to show in `/pulse` and
> `/popular` immediately, since those read the indexed `attr` column. Batched
> `:attrs` is fine for census-style rollups the indexer will expand later.

---

## 3. What each feature sends, and when

| Feature (config)                    | Event `:kind`         | Cadence          | Payload |
|-------------------------------------|-----------------------|------------------|---------|
| `telemetry.census`                  | `platform_census`     | once/day         | system, host-kind, illumos-flavor, nonce, day |
| `telemetry.packages`                | `packages_in_use`     | once/day         | system, the set of attrs actively used, nonce, day |
| `telemetry.packages`                | `package_installed`   | on install (or daily batch) | attr, system, day |
| `cache.seed`                        | `package_seeding`     | once/day         | system, seedable attrs, day |

- **"actively used"** = a defensible, cheap definition you choose and document,
  e.g. packages in the current system closure / user profile. Do **not** scan
  process lists or open files (privacy + cost). The system/profile closure is
  the right, boring source.
- **Coalesce**: at most one `platform_census` and one `packages_in_use` per day.
  Don't send on every rebuild; send on the first reporter run of a new day.

---

## 4. The anonymity nonce (important — get this right)

Goal: the server can **deduplicate within a single day** (so one machine counts
once toward "active users") **without ever having a stable identifier**.

- Compute a **per-day, per-device nonce** that is NOT persisted long-term and NOT
  derivable back to the machine:
  `nonce = base64( HMAC-SHA256( key = random-per-boot-or-per-day secret,
                                msg = "solnix-telemetry" + day-string ) )[:16]`
- The secret MUST rotate at least daily and MUST NOT be a hardware ID, MAC,
  `/etc/machine-id`, hostname, or anything stable/identifying. A fresh
  `getrandom()` value stored only in tmpfs/memory for the day is ideal.
- The server does not persist the nonce beyond same-day dedup. The client never
  sends the secret, only the derived per-day nonce.
- `package_installed` events need no nonce (they're counted as events, not users).

**Do not** send: hostname, machine-id, MAC, serial, username, IP, timezone,
locale, uptime, or free-form strings that could fingerprint. Keep host-kind and
illumos-flavor to a **small, closed vocabulary** so they can't act as a
fingerprint.

---

## 5. Networking, retries, and being a good citizen

- **Timeout fast** (≤5s). Telemetry is best-effort; never block a rebuild, boot,
  or package op on it.
- **No aggressive retry.** On failure (non-200, timeout, offline): drop it and
  try again at the next scheduled run. At most one lightweight retry. Never spin.
- **Jitter the schedule.** The daily timer should fire at a randomized time
  (e.g. `RandomizedDelaySec` on the systemd timer) so the fleet doesn't stampede
  the endpoint at 00:00 UTC.
- **Respect rate limits.** The edge rate-limits + fail2bans abusive senders; a
  well-behaved once-a-day client is far under any limit.
- **TLS:** verify the cert (it's a real Let's Encrypt cert). No cert pinning
  needed.
- **Offline/air-gapped:** if the POST can't connect, silently skip. No queueing
  to disk (that risks accumulating identifiable history).

---

## 6. Suggested implementation shape (non-prescriptive)

- A NixOS/solnix **module** `modules/telemetry.nix` exposing the options in §1
  and, when enabled, installing:
  - a **reporter** (a ~50-line script: build the EDN, `curl -m5 -XPOST`, exit) —
    `curl` + a shell/Python/tiny Haskell/Rust binary all fine; prefer whatever
    is already in the base closure to avoid a new dependency.
  - a **systemd timer** (`OnCalendar=daily`, `RandomizedDelaySec=6h`,
    `Persistent=false`) or the SMF equivalent, running the reporter as an
    unprivileged user.
- Gate the *entire* unit behind the effective-enable rule so that in the default
  private state, nothing is installed at all (not just disabled).
- Ship a handbook page "Privacy, telemetry & the community pulse" (server team is
  drafting the site copy) — link it from the module description.

---

## 7. How to verify against the live server

```sh
# should return "ok"; then it shows up in /pulse + /popular aggregates.
curl -m5 -H 'Content-Type: application/edn' \
  --data '{:kind "package_installed" :attr "pkgs.solnix.ripgrep" :system "x86_64-solaris" :day "2026-07-27"}' \
  https://search.solnix.io/telemetry

# missing :kind must 400:
curl -m5 -XPOST --data '{:attr "x"}' https://search.solnix.io/telemetry   # -> 400
```

Aggregates are visible at `https://solnix.io/pulse.html` and
`https://search.solnix.io/pulse` (k-anonymized: buckets < 5 contributors are
suppressed, so a single test event won't appear — that's by design).

---

## 8. Non-negotiables (from the server-side design; do not relax)

1. No PII. Region is derived server-side from IP and the IP is dropped; the
   client sends **no** location.
2. Default private. `solnix.privacy.enable = true` (default) = install nothing,
   send nothing.
3. Opt-out must be trivial and total: the master switch disables everything.
4. Best-effort, non-blocking, jittered, rate-limit-friendly.
5. Closed vocabularies for host-kind/flavor; rotating per-day nonce only.
