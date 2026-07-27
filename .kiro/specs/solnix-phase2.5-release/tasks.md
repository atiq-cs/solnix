# Phase 2.5 — Distributed cache, first release, published ISO

Bridges the Phase-2 gate (installable, usable solnix) to a public,
self-distributing release. Ordered; each builds on the prior.

## T2.11 — Opt-in peer-to-peer distributed package cache (BitTorrent-backed)

Every solnix system can (OPT IN) become part of the cache: it seeds the
pre-built store paths it already has, and fetches missing ones from peers over a
secure swarm — so the whole user base collectively provides pre-built assets,
falling back to solnix.io only when no peer has a path.

- **Model:** the authoritative signed cache stays solnix.io (`s3://solnix-cache`,
  `cache.solnix.io-1` pubkey). The P2P layer is an ADDITIONAL substituter/seed
  in front of it. A store path = a torrent (content-addressed by NAR hash); the
  narinfo (signed) names the torrent/magnet. Peers seed NARs they hold; a client
  needing a path resolves narinfo → fetches the NAR from the swarm → verifies the
  existing cache SIGNATURE (`require-sigs`) before admitting to the store. **Trust
  is unchanged: signature verification is authoritative; peers only move bytes.**
- **Secure swarm:** private/authenticated tracker (or DHT with a shared secret /
  allowlist) so it's a solnix swarm, not the public internet. Consider a
  well-maintained torrent lib (libtorrent) or an existing Nix-P2P effort
  (e.g. `nix-casync`/IPFS-style content addressing) before writing our own —
  reuse over reinvention.
- **Integration points (all three):**
  1. **Installer:** an opt-in prompt/flag ("join the solnix package swarm?");
     default OFF (privacy — you advertise which paths you hold).
  2. **Source/packages:** package the P2P daemon as `pkgs.illumos.*` (or an
     overlay), + an SMF service (`smf.services.solnix-cache-peer`).
  3. **Config:** a `services.solnix.cache.peer.enable` module option that wires
     the daemon + adds the P2P substituter to `nix.settings` and seeds the
     store, gated on opt-in.
- **Safety rails (do NOT simplify away):** signature verification stays
  mandatory; opt-in default-off; no seeding of anything not in the signed cache;
  bandwidth/disk caps; a clear privacy note (peers see the NAR hashes you serve).
- **Gate:** two solnix instances, both opted in; instance B fetches a store path
  that only instance A holds, over the swarm, signature-verified — solnix.io
  never serving that NAR (prove via the tracker/logs). Falls back to solnix.io
  when no peer has it.

## T2.12 — Cut release 2026.08

Once the Phase-2 gate + T2.11 are green and stable:
- Pin the release: nixpkgs-fork rev, illumos-gate commit, the exact toplevel +
  package closure. Tag `solnix` + `solnix-pkgs` `v2026.08` (date-based, per the
  maintainer's release-tagging convention).
- Publish the release's closures to the cache (signed), on the `unstable`
  channel for now (a `stable`/release channel slots in once qualified).
- Release notes: what boots, what's included, known issues (e.g. any residual
  boot caveat), install instructions.

## T2.13 — Build the install ISO + publish

- Produce a real bootable **install ISO** (live media that boots to the
  installer, per T2.7) — an actual `.iso`, not just an EBS/AMI image.
- Smoke-test: the ISO boots (QEMU/EC2), runs `solnix-install`, installs to disk,
  reboots into a working multi-user solnix.
- **Drop the `.iso` in `../solnix.io/`** (the site repo) for the site team to
  publish + advertise for download. Include the sha256 + a short "how to install"
  alongside it.

## T2.14 — Opt-OUT-off (default-private) community telemetry client (LOWER PRIORITY)

Client-side reporter feeding the ALREADY-LIVE server at
`https://search.solnix.io/telemetry` (aggregates shown at solnix.io/pulse). Full
client spec archived at docs/design-telemetry-client.md. Lower priority — land
late, as we finish the distro for publication. Ground rule: **no PII, ever**;
default fully private.

- **Unify the privacy switch with T2.11.** One `solnix.privacy.enable = true`
  (DEFAULT true = fully private, nothing phones home / nothing installed). The
  P2P seed opt-in (T2.11's `solnix.cache.seed.enable`) and telemetry share this
  framework. Effective rule (implement EXACTLY):
  `send(feature) = (not solnix.privacy.enable) && solnix.telemetry.enable
                   && solnix.telemetry.<feature>.enable`.
  Master switch always wins; a user who never edits config sends nothing. Also
  honor a global kill: `DO_NOT_TRACK=1` env OR `/etc/solnix/telemetry-off` file
  → send nothing regardless (defense in depth).
- **Module:** `modules/config/telemetry.nix` (options in the spec §1) that, ONLY
  when the effective rule is true, installs a ~50-line reporter + an SMF timer
  (illumos has no systemd — SMF periodic service, the daily/`RandomizedDelaySec`-
  equivalent via a jittered schedule; `Persistent=false`). In the default private
  state install NOTHING (not just disable). Reporter uses the base-closure curl
  (no new dep).
- **Events (once/day, coalesced, best-effort):** `platform_census` (system,
  host-kind∈{bare-metal,vm,zone}, illumos-flavor, day, nonce), `packages_in_use`
  (attrs from the SYSTEM/PROFILE CLOSURE — never scan processes/open files),
  `package_installed` (per-install or daily batch), `package_seeding` (only if
  cache.seed on). Wire = one EDN map per POST, `:kind` required, endpoint reads
  raw body. Prefer one event per attr with `:attr` (shows in /pulse immediately).
- **Anonymity nonce (get right):** per-day, per-device, NON-persisted nonce for
  same-day dedup only: `base64(HMAC-SHA256(key=random-per-day secret,
  msg="solnix-telemetry"+day))[:16]`. Secret = fresh getrandom() in tmpfs/memory,
  rotates ≥daily, NEVER a machine-id/MAC/hostname/serial. Never send the secret,
  IP, geo, timezone, locale, uptime, or free-form strings (region derived server-
  side from IP, IP dropped). Closed vocab for host-kind/flavor.
- **Good citizen:** ≤5s timeout, non-blocking (never block a rebuild/boot/pkg op),
  no aggressive retry (drop + next scheduled run), jittered schedule, verify TLS
  (Let's Encrypt, no pinning), offline → silently skip (NO disk queue — avoids
  accumulating identifiable history).
- **Docs:** a handbook page "Privacy, telemetry & the community pulse" (server
  team drafts site copy); link from the module description.
- **Gate:** default config installs no reporter + sends nothing (verify: no SMF
  unit, no POST). Opt in (`solnix.privacy.enable=false`) → a `package_installed`
  test POST returns `200 ok` and appears in /pulse once k-anon threshold met;
  missing `:kind` → 400; `DO_NOT_TRACK=1` / `/etc/solnix/telemetry-off` → silent.
  Nonce verified rotating + non-identifying. No PII in any payload (audit the EDN).

## Sequencing

T2.11 (P2P cache) → T2.12 (release 2026.08) → T2.13 (ISO + publish). T2.11's
installer/config hooks depend on T2.7 (installer) landing first. The release and
ISO are the public-facing payoff once the distributed cache is proven. **T2.14
(telemetry) is LOWER PRIORITY — land it late in the publication run, sharing
T2.11's `solnix.privacy` switch; it must never gate the release.**
