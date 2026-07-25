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

## Sequencing

T2.11 (P2P cache) → T2.12 (release 2026.08) → T2.13 (ISO + publish). T2.11's
installer/config hooks depend on T2.7 (installer) landing first. The release and
ISO are the public-facing payoff once the distributed cache is proven.
