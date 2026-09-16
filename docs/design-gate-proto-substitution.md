# `--flake` needs the gate proto to be SUBSTITUTABLE, not hand-staged

## The measurement

The gate proto is banked, and it is not usable by `nix`:

| | |
|---|---|
| tarball | `proto/x86_64-gate-ac45d71fc2-20260914/proto-root_i386-gate-ac45d71fc2.tar.gz` — **HTTP 200**, 219,678,907 B |
| **store path** | `/nix/store/wn8w5j1pkc9k3zgkq3bsqxk285dqbi7m-illumos-gate-proto` — **narinfo 404** on both `s3.solnix.io/solnix-cache` and `cache.solnix.io` |

So `nix` cannot substitute it. `flake.nix:74-77` sources the gate from `SOLNIX_GATE_PROTO` via
`builtins.storePath`, and `gate.nix:68` asserts `srcDir != null || srcHash != null` — meaning that with the env var
unset, forcing the toplevel throws.

**That is why `dixi`'s `drvPath` still does not evaluate**, and it is *not* a cache-completeness problem. It sits
upstream of the eight eval-blocking paths in `AUDIT-cache-gap-x86_64.tsv`.

## Why the current shape cannot be an install flow

To run `--flake .#dixi` on the X1 today, the operator must:

1. fetch a 220 MB tarball by hand,
2. unpack it,
3. `export SOLNIX_GATE_PROTO=<unpacked path>`,

*before* `nix eval` will resolve the attribute. An installer that requires three manual steps to reach the point
where it can read its own configuration is not an installer.

⚠️ Note the honest reason the current design is like this, from `flake.nix:57-71`: **the gate is a host artifact.**
An unpinned network fetch is not reproducible, and the real proto is a 491 MB tree that only exists on an illumos
build host. Making it an argument was correct — the mistake would be leaving it *only* an argument.

## The fix shape

**Publish the proto as a real store path** — `nix copy --to <cache>` from the illumos host that built it — so
`nix build .#solnixConfigurations.dixi…toplevel` substitutes it like any other dependency. Then
`SOLNIX_GATE_PROTO` becomes an **override for local iteration**, not a **prerequisite for use**.

That is the same distinction the rest of the system already respects: `externalLibs` copies host libraries but the
*slices* are derivations; the gate should be no different once it exists.

### Why this is not just "run `ami-bank.sh` on it"

⚠️ Banking a tarball and publishing a store path are **different operations with different verification**:

* a tarball is verified by **sha256 read-back** — that is what `ami-bank.sh` does, and it is right for AMIs
* a store path is verified by **`narinfo` fetch plus every entry in its `References` closure** returning 200

The second is what the cache audit found four of five names failing: they return 200 for themselves and 404 on a
reference. A proto published without its closure checked would reproduce that class.

⚠️ **And the signing key is unresolved.** The cache signs with a key whose *name* matches `cache.solnix.io-1`, but a
name match is not key material, and consumers currently need `require-sigs=false`. **A path published under a key
consumers do not trust is worse than a 404** — it fails later, and more confusingly. That must be settled *before*
publishing, not after.

## Order of work

1. **Settle the signing key** — which key do consumers trust, and does the publisher hold it? This gates everything
   else and needs a non-daemon `nix` (a daemon client silently ignores `--option substituters`).
2. **Publish the proto store path** with closure verification.
3. **Make `SOLNIX_GATE_PROTO` optional** in `flake.nix` — fall through to the substitutable path when unset, and
   keep the assertion as the last resort rather than the first.
4. **Publish the eight eval blockers** from `AUDIT-cache-gap-x86_64.tsv`.
5. **Then** `--flake .#dixi` should evaluate with nothing dropped and nothing hand-staged.

Steps 1–2 are the interesting ones. Step 4 is a chore that is already fully enumerated.
