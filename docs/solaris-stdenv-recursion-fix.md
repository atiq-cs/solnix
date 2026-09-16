# The `x86_64-solaris` stdenv recursion: one overlay line, and the shim was a red herring

## The measurement

```nix
pkgs = import solnix-pkgs.lib.nixpkgsSrc { system = "x86_64-solaris"; };
pkgs.zlib.drvPath                    # → error: infinite recursion encountered

# with ONE overlay line:
overlays = [ (final: prev: { fetchurl = prev.stdenvNoCC.fetchurlBoot; }) ];
pkgs.zlib.drvPath  → /nix/store/a9qxjdxh350b4g1f0f6cajk5pbyhhn1h-zlib-1.3.2.drv
pkgs.bash.drvPath  → /nix/store/6vj41i32vc4560nkvjn4zlrinzvp4pi2-bash-interactive-5.3p15.drv
```

Cycle: `zlib → zlib-1.3.2.tar.gz → perl → libxcrypt → perl → openssl → curl → fetchurl`. `fetchurl` builds
`curlMinimal`; `curl` needs `openssl`/`perl`; `perl`'s own tarball needs `fetchurl`. `fetchurlBoot` is built with
**`curl = null`**, so it has no such edge.

**Linux is unaffected** — `x86_64-linux` `zlib.drvPath` is the same `zlib-1.3.2.drv` with and without the overlay.

## ⚠️ Why `curl = null` is legitimate, not a hack

From the patched tree's own `pkgs/build-support/fetchurl/default.nix`:

```
line 7:   curl, # Note that `curl' may be `null', in case of the native stdenvNoCC.
line 14:  defaultNativeBuildInputs = [ curl ];
line 300: nativeBuildInputs = defaultNativeBuildInputs ++ nativeBuildInputs;
```

So `curl = null` is an **upstream-documented configuration**. With it null, `nativeBuildInputs` becomes `[ null ]`,
which Nix filters — the derivation is valid and simply ships no downloader. That is safe because a **fixed-output
derivation is fetched by the daemon from its hash**, not by the builder.

⚠️ **The historical objection to `fetchurlBoot` does not apply here.** `fetchurl-shim-qmvlnvf0.nix`'s header says
`fetchurlBoot` *"emits a derivation whose /setup sourcing breaks under Nix 2.3.16"*. That is **Nix-version
specific**, and it is why someone once chose `builtins.fetchurl` instead. We are not on 2.3.16.

## Two corrections to my own work

**My brief blamed the wrong layer.** I said `overlays.default` caused the recursion and that wiring the phase3
`fetchurl` shim would fix it. Both wrong: the recursion reproduces with `overlays = [ ]` on the plain patched
nixpkgs. An agent refuted it, and the control that convinced me was **`x86_64-freebsd` on the same patched tree
resolving `zlib` cleanly** — so it is the illumos stdenv specifically, not non-linux in general.

⚠️ **And my first negative control was itself wrong.** Grepping the failure output for `/nix/store/` "found" a store
path and I briefly read that as the recursion being absent. The match was the **`nixpkgsSrc` path in the error
message**, not a `drvPath`. Re-run with `tail -1` instead of a pattern match: plain `zlib` gives
`error: infinite recursion encountered`. **A negative control matched on the wrong string is not a control** — this
is the eleventh instance of that shape this campaign, and the second of mine.

## The shim is a red herring — and worse, a trap

`pkgs/os-specific/illumos/phase3/fetchurl-shim-qmvlnvf0.nix` *describes this exact cycle correctly* and is
**not wired into `overlays.default`** (which is three lines and never mentions `fetchurl`). It is applied only by
hand in phase3 tranches, which reference it as **`/root/fetchurl-shim.nix`** — an absolute path outside the repo.

⚠️ Its `forkPath` default is a **dead store path**:
`/nix/store/qmvlnvf0kk1zkfjpjpxwimg5ym8sfwnk-nixpkgs-patched-1785781297346528064` does not exist locally, and the
same dead default is duplicated in `solaris-overlay-qmvlnvf0.nix:40`. It is used *only* for
`import (forkPath + "/pkgs/build-support/fetchurl/mirrors.nix")`.

**That committed file is what made me brief this incorrectly.** A file that looks like the fix, describes the bug
accurately, and is never applied is worse than no file at all.

## Where the real fix belongs

⚠️ **`all-packages.nix` is not in the repo.** `flake.nix:83` sets `lib.nixpkgsSrc = patchedNixpkgs` — the tree is
built at eval time by applying `patches/` to upstream nixpkgs. So this lands as a **patch hunk**, not a file edit:

* `patches/0004-stdenv-illumos-bootstrap-stage.patch` — owns the illumos stdenv (its `overrides` pins
  `coreutils`/`gnugrep`/`xz`/`bzip2` and, notably, **no `zlib`**, which linux and darwin both pin)
* `patches/0003-all-packages-illumos.patch` — owns all-packages illumos changes

## ⚠️ Build risk, stated rather than left silent

This is verified at **eval**, not build. A `*-solaris` `fetchurlBoot` FOD that ever has to download *in-builder*
(substitution miss) has **no curl**. Given this campaign measured **30 x86_64 paths already missing from the
cache**, that is not hypothetical. Either those paths get published, or a solaris build host needs a working
in-builder fetcher.
