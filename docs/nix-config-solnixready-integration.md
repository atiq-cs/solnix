# Integrating the maintainer's `solnixReady` gate — reviewed and verified

The maintainer corrected `~/ws/nix-config` in `9c62f17` after the agent's `b58a2d0`. His diagnosis is sharper
than what our own docs recorded, so it is worth restating precisely.

## What he found

Wiring `dixi`/`dixa`/`dixr` to the real solnix-pkgs solaris pkg set **broke `nix flake check`** for all three
`gburd@dix*` home configs, because forcing `activationPackage` hits the incomplete `*-solaris` stdenv:

* a minimal HM config on `x86_64-solaris` throws **`attribute 'shellPath' missing`**
* the full module tree hits **infinite recursion in the patched-nixpkgs lib**

⚠️ **That is a more precise account than ours.** The previous run reported "`pkgs.bash` infinite recursion in the
solaris stdenv" and left it untraced. `shellPath` is the actual first failure, and it is a *different* symptom from
the recursion — the recursion is what the *full* tree hits, not the minimal case.

## What his fix does, and why the shape is right

**1. `mkHome` gains `solnixReady` (default `false`).** While false, a `-solaris` host falls back to
`x86_64-linux` pkgs so the configs **evaluate** (profile shape) and CI stays green.

⚠️ Verified the fallback is **visible, not silent**:

```
homeConfigurations."gburd@dixi".pkgs.stdenv.hostPlatform.system  ->  x86_64-linux
config.home.homeDirectory                                        ->  /home/gburd
```

A fallback that could not be observed would be the "silently wrong" shape this project has been bitten by
repeatedly. This one answers directly when asked.

**2. `mkSolnixHost` does NOT fall back.** Confirmed at `lib/helpers.nix:58` — `platform ? "x86_64-solaris"`
unconditionally. So the **system** half stays honest on solaris while only the **home** half is stubbed. That is
the correct split: the system toplevel is the thing that now genuinely builds on an illumos host, and softening it
would have hidden real progress.

`helpers.nix:55-57` also carries the right warning: *"It EVALUATES on this Linux box; it can only be REALISED on
an illumos host… Do not read a successful `nix eval` as a build."*

**3. `nix run .#check-solnix-ready` — an INVERTED trigger.** It exits **nonzero** the moment solnix-pkgs *can*
evaluate a closure, prompting the `solnixReady` flip.

⚠️ **This is the good pattern and worth naming.** A normal check asserts the state you want and rots quietly when
the world changes. An inverted trigger asserts the state you *have* and fires when it improves — so the flag
cannot be left stale silently. Ran it:

```
solnix-pkgs still cannot evaluate a HM closure; solnixReady=false is correct.
exit=0
```

He also explains why it is an **app** rather than a flake check: the check sandbox cannot do the nested
`getFlake`, and `builtins.tryEval` **cannot catch** the `shellPath`/recursion error class. That second point is a
real Nix limitation worth remembering — `tryEval` is not a general "did this fail" wrapper.

## Verified state

| check | result |
|---|---|
| `nix flake check --no-build` | **all checks passed** |
| `homeConfigurations."gburd@dixi"` evaluates | ✅ |
| `solnixConfigurations.{dixi,dixa,dixr}` hostnames | `dixi` / `dixa` / `dixr` |
| `check-solnix-ready` | exit 0 — flag correctly `false` |

## What this means for `--flake`

Nothing blocks the **system** path: the `dixi` toplevel now instantiates *and* builds on an illumos host
(`/nix/store/rk5mgx…-solnix-system-dixi`, rc=0), with kernel bytes matching the pinned proto.

The **home-manager** half is gated off deliberately and honestly. So `solnix-install --flake .#dixi` can proceed
while `--home-manager .#gburd@dixi` must wait on the `*-solaris` stdenv — and `check-solnix-ready` is what will
tell us the moment that changes.
