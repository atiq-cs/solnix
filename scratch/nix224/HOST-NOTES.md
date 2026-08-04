# Nix 2.24.15 productionization — host build notes (resumable)

Host: root@3.144.4.136 (i-0039fb6e12a04bc7b, m5.4xlarge, fresh OI-build-AMI clone)
Target: x86_64-pc-solaris2.11 / x86_64-solaris

## Step log

### STEP 1: host bootstrap — DONE
- oi-fleet-bootstrap.sh: MTU 1400, rpool expand pending online-e, Nix 2.3.16 seed OK, cache 200.
- rpool was 1.62G / 298G EXPANDSZ pending.

### STEP 1b: pkg update --accept (2026 userland) — IN PROGRESS
- Fresh AMI userland-incorporation pinned 2025 -> BLOCKS developer/gcc-13.
- Must: pkg update --accept -> new BE -> reboot -> 2026 userland -> gcc-13.
- Verify with which gcc / pkg contents, NOT pkg exit code.

### STEP 2: clean patch series — DONE (local)
- pkgs/illumos/nix-illumos-patches/224/{0001..0005}.patch + README.md
- All 5 apply -p1 cleanly + in sequence (verified against fresh 2.24.15 source).
- 0001 terminal.cc winsize/termios; 0002 signals.cc sigorset fallback;
  0003 local-derivation-goal.cc cfmakeraw+ptem/ldterm; 0004 pathlocks.cc LOCK_UN;
  0005 current-process.cc getSelfExe /proc/self/path/a.out.

### STEP 3: from-source derivation — AUTHORED (local), build pending host
- pkgs/illumos/nix224.nix (standalone derivation, sandbox=false, RUNPATH relocate
  via elfedit, CA baked to $out/etc/ssl/certs + ssl-cert-file in nix.conf).
- scripts/oi-nix224-setup.sh (reproducible host build driver, RUNPATH-audit gate).

### STEP 1b: pkg update --accept — DONE (RC=0)
- New BE openindiana-2026:08:04 created + activated. Rebooting to 2026 userland.

### STEP 1c: gcc-13 + deps — DONE
- gcc-13.4.0 at /usr/gcc/13, -std=c++2a. All build tools present (gmake/gpatch/
  gsed/cmake/flex/bison/jq/gnu-tar/autoreconf/pkg-config).
- pkgconfig: sqlite 3.53.4, curl 8.21.0, libsodium 1.0.22, brotli 1.2.0,
  nlohmann_json 3.12.0, libarchive 3.8.9, openssl-3 libcrypto/libssl 3.5.7.
- No new BE (installed into active openindiana-2026:08:04).

### STEP 1d: reproduce Nix 2.24.15 build — starting (detached on host)

### STEP 1d + STEP 3 core: Nix 2.24.15 BUILT + RUNS — DONE
- Installed to /nix-tools224. nix --version = 2.24.15.
- ldd: RUNPATH OK, all NEEDED resolve — runs WITHOUT LD_LIBRARY_PATH.
- nix-build realised hi224 -> hi-from-2.24 (deriver-backed).
- nix profile present.
- NEXT: verify substitute from cache.solnix.io + nix profile install by name.

### STEP 3: from-source DERIVATION — building
- pkgs/illumos/nix224.nix instantiates to real .drv:
  /nix/store/7pf2rn33av99q8bys14dlb9cgv05j6y3-nix-2.24.15.drv
- Realising with the freshly-built 2.24 nix (/nix-tools224) — seed 2.3.16 routes
  builds to a missing build-remote hook (banked substitute-only), 2.24 builds
  locally fine.
- TLS substitute PROVEN: nix store info --store https://cache.solnix.io works via
  baked ssl-cert-file (no NIX_SSL_CERT_FILE in env). Full copy roundtrip works.
  nix profile install/list work.

### STEP 3: from-source DERIVATION — DONE (clean)
- Store path: /nix/store/lccl39c0wnq0ssx5lcgi1zqhhhbl9z7a-nix-2.24.15
- .drv: /nix/store/57d4vj880dx2dpfnwn2r2lh11svzmkkj-nix-2.24.15.drv (deriver resolves)
- RUNPATH clean: $out/lib + $out/lib/amd64 + /usr/gcc/13/lib/amd64 +
  /usr/openssl/3/lib/amd64 + /usr/lib/amd64. NO /tmp build-temp.
- libgit2.so.1.7.2 bundled into $out/lib, resolves from store.
- ldd: no "not found"; runs with NO LD_LIBRARY_PATH. CA baked in
  $out/etc/ssl/certs/ca-bundle.crt + ssl-cert-file in $out/etc/nix/nix.conf.
- TLS substitute + copy roundtrip + nix profile install/list all PROVEN.

### STEP 4: re-bank bootstrap tarball nix-illumos-2.24.15.tar.zst — starting

### STEP 4: bootstrap tarball — BANKED + RELOCATABILITY PROVEN
- /var/tmp/nix224-bootstrap/nix-illumos-2.24.15.tar.zst
- sha256: ced9cf5e5fed64e3deaa8847f5c70fc1e8cd3541d84bbe64c785d0c00a24ec7f (133MB)
- RUNPATH baked to /nix-tools224/{lib,lib/amd64,runtime-lib}; 39-lib runtime-lib
  closure (real .so files, NO dangling symlinks); CA bundle bundled + ssl-cert-file.
- PROVEN relocatable: env -i (empty env) nix --version = 2.24.15, ldd all resolve,
  NO LD_LIBRARY_PATH. Fixes the 2.3.16 tarball fragility.
- bootstrap-register.sh writes profile.d with NO LD_LIBRARY_PATH.
- NEXT: publish to s3.solnix.io/solnix-cache/bootstrap/ + verify durable at cache.

### STEP 4: bootstrap tarball — PUBLISHED
- Uploaded to s3://solnix-cache/bootstrap/nix-illumos-2.24.15.tar.zst (+ .sha256)
  via decrypted secrets/s3-cache.yaml creds (aws --endpoint-url s3.solnix.io).
- sha256: ced9cf5e5fed64e3deaa8847f5c70fc1e8cd3541d84bbe64c785d0c00a24ec7f
- Durability at cache.solnix.io pending B2 drain (~10min); verify cache-busted.
- Copy staged at dev-box artifacts/nix224-bootstrap/.

### STEP 5: new pure stdenv on 2.24 (drop __structuredAttrs adapter) — starting

### STEP 4: tarball durability — ORIGIN DURABLE, CDN healing
- s3.solnix.io origin: sha256=200, tarball=206, body MATCHES local
  (ced9cf5e...). Durable in B2.
- cache.solnix.io CDN: still 404 (sticky Cloudflare negative-cache H28 from
  premature pre-drain checks); heals on negative-TTL expiry. Object IS durable.

### STEP 5: __structuredAttrs adapter DROP — PROVEN
- __structuredAttrs=true derivation BUILDS on the store-path 2.24 nix:
  .attrs.sh written, myList a real bash array (list1=b count=3), myBool=1.
  This is exactly what 2.3.16 could NOT do (the reason the adapter existed).
- Authored pkgs/illumos/phase3/tranche-entry-224.nix: DROPS the
  __structuredAttrs=false adapter + the H3 fetchurlBoot re-assert (only needed
  because the adapter re-wrapped stdenv) + structuredAttrsByDefault=false knob.
- REMAINING: GATE 1b-PURE hello on the pure stdenv needs the forked nixpkgs
  (not on this fresh host); the structuredAttrs mechanism proof is the crux.

## HANDOFF (resume point for full cutover)
DONE: host bootstrap; Nix 2.24.15 reproduced+working (build+profile+substitute);
clean 5-patch series; from-source derivation (real .drv, RUNPATH-correct, CA
baked, nix profile works); bootstrap tarball banked+relocatable+uploaded (origin
durable); __structuredAttrs adapter drop proven + tranche-entry-224.nix authored.

TO RESUME (needs seed-wired illumos build host + the forked nixpkgs on it):
1. GATE 1b-PURE hello REALISE on 2.24: rsync forked nixpkgs + illumos overlay +
   seed to the host, build `pkgs.hello` via tranche-entry-224.nix with the
   store-path 2.24 nix. Assert: realises, deriver resolves, runs, host-free
   closure, EM_X86_64. (structuredAttrs machinery already proven on 2.24.)
2. Repoint scripts/oi-fleet-bootstrap.sh to bootstrap/nix-illumos-2.24.15.tar.zst
   (+ ssl-cert-file, drop LD_LIBRARY_PATH from profile.d).
3. Re-validate the 79 carry-over store paths under 2.24; re-cut images.

KEY HOST PATHS (root@3.144.4.136):
- store-path nix (from-source drv): /nix/store/lccl39c0wnq0ssx5lcgi1zqhhhbl9z7a-nix-2.24.15
- .drv: /nix/store/57d4vj880dx2dpfnwn2r2lh11svzmkkj-nix-2.24.15.drv
- install-tree nix: /nix-tools224/bin/nix
- tarball: /var/tmp/nix224-bootstrap/nix-illumos-2.24.15.tar.zst
- notes: this file. Build logs: /var/tmp/{nixbuild,drv2,bank7}.log
