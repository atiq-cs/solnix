# Builder onboarding — submitting packages to the solnix.io cache

This is the single authoritative document for the build team. It supersedes the
earlier `/tmp/solnix-builder-*.txt` notes (the interim "sign with 8UNr yourself"
bridge is retired by the flow below). If anything here conflicts with an older
note, this wins.

## The model (what changed, and why you'll like it)

**You no longer sign anything, and you no longer hold the cache signing key.**
solnix.io is the sole signer. You:

1. authenticate to the site with an **enrolled ssh-ed25519 key**,
2. upload your **unsigned** build outputs (NAR + narinfo) to a private staging
   area,
3. the **site validates and signs** them with the canonical
   `cache.solnix.io-1:8UNr…` key and publishes them.

A compromised or buggy builder cannot forge a client-trusted object — the site
re-derives the expected store path from the reviewed recipe, re-hashes your
bytes, and only signs what checks out. This is strictly better for you: nothing
secret to guard, no re-signing, no "wrong key" footguns.

## One-time onboarding

### 1. Generate a submit key (you keep the private half)
```sh
ssh-keygen -t ed25519 -f solnix-cache-builder -C 'yourteam@solnix.io cache builder'
```
Send **only** `solnix-cache-builder.pub` to the operator (greg). Keep
`solnix-cache-builder` private (0600, in your secrets manager). This key proves
"this submission came from you"; it is NOT a cache signing key.

### 2. Operator enrolls your public key
The operator runs (reviewed, applied to the registry):
```sh
infra/k8s/cache-builder.py enroll <your-builder-id> <independence-group> \
  --note 'onboarded YYYY-MM-DD' < solnix-cache-builder.pub > enroll.sql
# operator vets ownership, then applies enroll.sql
```
You'll be told your `<builder-id>`. (The site-team's key is already generated at
`/tmp/solnix-site-team-builder-key/` — operator: relay the private half and run
`enroll-site-team.sql`.)

### 3. Confirm you can authenticate
```sh
curl https://search.solnix.io/api/v1/cache/submit   # info endpoint, 200
```

## The submit protocol (per package)

All requests to `search.solnix.io`. Two headers authenticate every POST:
- `X-Solnix-Builder: <your-builder-id>`
- `X-Solnix-Submit-Sig: <base64(ed25519 sig over the canonical challenge)>`

**Canonical challenge** (newline-terminated, trailing newline):
```
solnix-cache-submit-v1
<METHOD>          e.g. POST
<PATH>            e.g. /api/v1/cache/submit/begin
<builder-id>
<nonce>           empty string on /begin; the nonce on /finalize
<sha256-hex of the exact request body bytes>
```
Sign that exact byte string with your ed25519 private key.

### Step 1 — begin
`POST /api/v1/cache/submit/begin`, body:
```json
{"objects":[
  {"store_path":"/nix/store/<hash>-<name>",
   "nar_hash":"sha256:<nixbase32>",
   "nar_size":<int>,
   "nar_key":"nar/<filehash>.nar.xz",
   "compression":"xz"}
]}
```
Response: `{submission_id, nonce, staging_url, objects:[{nar_key, capability}], expires_in}`.

### Step 2 — upload (unsigned, direct to staging)
For each object, PUT the bytes to the staging proxy with its capability:
```sh
# NAR
curl -XPUT --data-binary @my.nar.xz \
  -H "X-Solnix-Capability: <capability-for-that-nar_key>" \
  "<staging_url>/staging/<submission_id>/nar/<filehash>.nar.xz"
# unsigned narinfo (NO Sig: line — the site signs)
curl -XPUT --data-binary @my.narinfo \
  -H "X-Solnix-Capability: <capability-for-the-narinfo-key>" \
  "<staging_url>/staging/<submission_id>/<hash>.narinfo"
```
Your narinfo must carry StorePath, URL, Compression, FileHash, FileSize,
NarHash, NarSize, References — and **no Sig and no CA line**.

### Step 3 — finalize
`POST /api/v1/cache/submit/finalize`, body `{"submission_id":"…","nonce":"…"}`
(signed, nonce in the challenge). The site then, out of band:
- derives the authority from the reviewed `recipes.tsv` + the already-published
  dependency closure,
- validates (re-hashes your NAR, checks references, store-path shape),
- signs with `8UNr…` and publishes to `cache.solnix.io`.

Poll your submission (or ask the operator) for `validated` → `promoted`, or
`rejected` with a reason.

## Rules that will reject your submission (so you don't hit them)

- **Store path must match the reviewed recipe's `out`.** The site anchors to
  `recipes.tsv`; you can't publish a path it doesn't know. Get your recipe
  reviewed/merged first.
- **Every reference must already be published.** A leaf can't be published
  before its runtime deps are in the cache (deps-first). Publish bottom-up.
- **Declared references must include the recipe's source-level deps.** You may
  not drop a dependency the reviewed recipe lists.
- **Unsigned uploads only.** Don't attach a Sig; the site signs. (A Sig line is
  stripped; a wrong one won't help you.)
- One submission per nonce; nonces/capabilities are single-use and short-lived
  (~15 min) — begin → upload → finalize promptly.

## Current status / prerequisites before this is live for you

The pipeline is built, deployed, and **validated end to end on live Civo**
(a real package went submission → site-signed → served, verifying under 8UNr).
It is currently **gated off** pending these onboarding steps:

1. **Your key enrolled** (section above).
2. **A reachable `staging_url`.** Today the staging proxy is in-cluster only
   (no public ingress). The operator must expose it (authenticated ingress; the
   capability HMAC is the auth) OR you upload via an operator-fronted address.
   Ask the operator for the current `staging_url`.
3. **`recipes.tsv` with your packages** published to
   `https://cache.solnix.io/registry/recipes.tsv` in the `out`-schema
   (pname·version·…·system·out·…). The sample there today has 5 packages.
4. **Operator un-suspends the controller** (currently suspended with PROMOTE=1
   baked). A validate-only window is recommended first.

## Interim (only if you must ship before the above)

The old bridge — you sign with the `8UNr…` key and upload to rustfs — still
works but is being retired. Prefer the submit flow. If you genuinely need the
interim, see the operator; do not mix the two for the same package.

## Who to contact
Operator: greg@burd.me. Report your `<builder-id>`, and whether you want the
interim bridge or to wait for the submit flow to be opened to you.

## Who is enrolled (2026-10-05)

- Builder identity `site-team` (historical label) = the BUILDER team's key, held
  in their repo's sops (~/ws/solnix: secrets/site-team-cache-builder.yaml).
  Verified: their private key derives to the enrolled public key, which matches
  the registry row — so their signatures authenticate.
- The SITE/operator team is NOT enrolled as a builder, by design: the site is
  the signing authority (runs cache-signer, validates, publishes); it does not
  submit packages. No operator builder identity is needed or wanted.
- Test builders from bring-up (sb-dbg, e2e-live, cc-canary-b) are REVOKED.

To add a genuinely separate builder later: generate a key, send the .pub, the
operator runs `cache-builder.py enroll <new-id> <group>` and vets ownership.
Re-keying an existing id = revoke + enroll under a NEW id (the schema refuses
to overwrite an identity or re-register a key).
