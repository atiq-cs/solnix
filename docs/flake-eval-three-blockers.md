# `--flake .#dixi` has THREE independent blockers, and only one is the gate

Measured before spending anything on a publish run. Each has an impure control, so these are mechanisms rather
than stories.

## 1. The gate: `getEnv` + `storePath` are both unavailable in pure eval

`flake.nix:75-76` reads `SOLNIX_GATE_PROTO` with `builtins.getEnv` and wraps it in `builtins.storePath`. Verified:

```
nix eval --expr 'builtins.getEnv "HOME"'      →  ""              (pure)
nix eval --impure --expr 'builtins.getEnv …'  →  "/home/gburd"
builtins.storePath  in pure mode              →  error
builtins.storePath  with --impure             →  works
```

⚠️ **So `SOLNIX_GATE_PROTO` is inert via `nix eval .#` even when set.** It was never a working prerequisite — only
`--impure`, or the host path (`lib/eval-host.nix`), ever honoured it. My earlier framing of it as "a prerequisite
for use" was wrong.

**Fix shape (measured legal):** `builtins.fetchTarball { url; sha256; }` in pure mode fails with *"unable to
download"* — a download error, not a purity error — so a sha256-pinned fetch is legal. The banked proto is already
pinnable:

```
sha256 2abbfda8ebcfd755dfad0b8065499f1b11a7957497a49c05679ce03af6da7325   219,678,907 B
https://s3.solnix.io/solnix-cache/proto/x86_64-gate-ac45d71fc2-20260914/proto-root_i386-gate-ac45d71fc2.tar.gz
```

⚠️ Note `gate.nix`'s existing `srcHash` path fetches **source** and then builds (~2 h). What is wanted is a pinned
fetch of the **built proto**. Those are different, and conflating them buys every consumer a two-hour build.

## 2. `builtins.currentSystem` does not exist in pure eval

Not "returns something odd" — **`error: attribute 'currentSystem' missing`**. Verified:

```
pure    →  error
impure  →  "x86_64-linux"
```

**14 files** in this repo use it, including `lib/build-env.nix:44`, which `modules/config/system-path.nix` routes
through. So even with the gate fixed, forcing the toplevel hits this.

The fix is mechanical — thread the system in as an argument instead of reading it from the evaluator — but it
touches 14 files, so it is not a one-line edit.

## 3. ⚠️ An infinite recursion in the `x86_64-solaris` stdenv — and this one is NOT about purity

Reachable under `--impure` with the gate supplied, so **fixing purity would not fix it.** Minimal reproducer with
no solnix repo involved:

```nix
pkgs = import solnix-pkgs.lib.nixpkgsSrc {
  system = "x86_64-solaris"; overlays = [ solnix-pkgs.overlays.default ];
};
pkgs.zlib.drvPath   # → error: infinite recursion encountered
```

The cycle, from `--show-trace`:

```
zlib → zlib-1.3.2.tar.gz → perl → libxcrypt → perl → openssl → curl → …
```

`fetchurl` needs `curl`; `curl` needs `openssl`/`perl`; `perl`'s own source tarball needs `fetchurl`.

**The discriminator that makes this actionable:** `pkgs.fetchurl` is in the cycle, `stdenvNoCC.fetchurlBoot` is
**not** — it returns a `drvPath` fine. `fetchurlBoot` is precisely the bootstrap escape hatch that exists to break
this loop, so **the solnix-pkgs overlay/patches are selecting the wrong `fetchurl` somewhere.**

Control: the same nixpkgs and the same overlay at `system = "x86_64-linux"` yields a clean `bash` `drvPath` — so it
is the solaris bootstrap wiring, not the overlay in general.

⚠️ This is almost certainly the same root cause as the `shellPath`/recursion pair the maintainer hit in nix-config
and gated behind `solnixReady = false`. Two symptoms, one bootstrap.

## What this changes about the plan

| step | status |
|---|---|
| publish the gate proto store path | still worth doing for `nix build`, but **does not unblock eval** |
| publish the 8 eval blockers | still needed, still not sufficient |
| pinned-fetch gate | fixes blocker 1 only |
| thread `system` through 14 files | fixes blocker 2 |
| **solaris stdenv bootstrap** | **fixes blocker 3, and is the real work** |

**Blocker 3 is the one that matters**, because it is not a packaging chore: an `x86_64-solaris` package set that
cannot evaluate `zlib` cannot evaluate a toplevel, no matter what is published. It is also the reason
`solnixReady` exists in nix-config.

**Honest read: `--flake .#dixi` is not one publish run away.** It is a stdenv bootstrap fix away, and that is a
different kind of job.

---

## Update 2026-09-16: blocker 4 refuted, blockers 5 and 6 found — eval now stops at `starter.nix`

Re-measured with all three real fixes locked (`solnix-pkgs` input at `07e59bd`, which includes the stdenv fix
`7ff01f8`). No AWS spend — the dev box completed in under a minute.

**Blocker 4 is an ARTIFACT.** The `solnix-system-path → … → bash` recursion the earlier run captured does not
reproduce with the real patch fix — it was an artifact of that agent's overlay stand-in. Proved at the stdenv level:
`bash-interactive`, `bison`, `perl` (the exact cycle) all resolve at `x86_64-solaris` with `7ff01f8` and all recurse
with the pre-fix `c73f24ae`. So blocker 3's fix is load-bearing and blocker 4 is closed.

**Blocker 5 (fixed here): `lib/build-env.nix:44`** read `builtins.currentSystem` — the same class as blocker 2, in
a file `4845812f` did not cover. Fixed the same way: `system` is now an argument defaulted to `"x86_64-solaris"`.

**Blocker 6 (NEW, not fixed): `pkgs/illumos/starter.nix:71`** — `value = builtins.storePath (builtins.elemAt cols 3)`.
`builtins.storePath` is forbidden in pure eval, so wiring the 175 published starter packages by absolute store path
cannot work from `nix eval .#`. This is a **design change, not a one-liner**: the pure-legal equivalent is
`builtins.fetchClosure { fromStore = "https://cache.solnix.io"; fromPath = <path>; }`, which works only if the path
and its full closure are substitutable and signed by a **trusted** key.

We are positioned for that: the signing key is settled (`cache.solnix.io-1` / `5HAV…`, held in
`secrets/cache-signing.yaml`), so a `fetchClosure` rewrite of `starter.nix` is viable — but it depends on the 175
paths actually being published and closure-complete, which loops back to the cache-publishing job (8 eval blockers +
the proto). So blocker 6 and the publish job are the same work seen from two ends.

### The honest ledger

| # | blocker | status |
|---|---|---|
| 1 | gate proto in pure eval | ✅ `2ed40f30` |
| 2 | `currentSystem` in `mk-illumos-component.nix` | ✅ `4845812f` |
| 3 | `x86_64-solaris` stdenv recursion | ✅ `solnix-pkgs 7ff01f8` |
| 4 | extra recursion | ✅ artifact — does not reproduce |
| 5 | `currentSystem` in `lib/build-env.nix` | ✅ fixed here |
| 6 | `storePath` in `starter.nix` | ❌ needs `fetchClosure` + published closure |

**`--flake .#dixi` is now one design change (blocker 6) away, and that change is the same publishing work already
scoped.** Not a recursion, not a mystery — a `fetchClosure` rewrite gated on a closure-complete cache.
