# Phase 3 — real hermetic x86_64-solaris derivations against the pure stdenv

This directory captures the **proven pattern** for rebuilding real nixpkgs
packages as fully-hermetic `x86_64-solaris` derivations on top of the PURE
`stdenv-illumos` (the GATE 1b-PURE North Star stdenv). It is the beginning of
the full 6467-package fully-Nix rebuild.

"Real hermetic derivation" here means, verified per package:
- `nix-store -q --deriver <out>` resolves to a `.drv` (NOT a `nix-store --add`
  content blob — these are genuinely built),
- `nix-store -qR <out>` closure is 100% `/nix/store` (no host `/usr`, `/lib`,
  `/opt` leak) tracing to the pure stdenv + seed,
- the output actually runs on illumos (`ls --version`, `grep --version`, ...).

## First tranche (proven + published, append-only, to cache.solnix.io)

| pname                | new store hash                     | deriver | hermetic | published |
|----------------------|------------------------------------|---------|----------|-----------|
| zlib-1.3.2           | v3ifdyma44ihb9ibj0dg5v6daxamr914   | y       | y        | y         |
| zlib-1.3.2-dev       | rqhipgqxz8w9w1szb7xnp6xd711qxmaf   | y       | y        | y         |
| zlib-1.3.2-static    | n8bvp1hv22bzhxxixd0v5mv2kz3kk00i   | y       | y        | y (cached)|
| bzip2                | 3qapqhh7ka0rjcvm4sxawjcscy82n631   | y       | y        | y         |
| xz                   | yc2lxizi541jv5ifja06kkl0nf936wjd   | y       | y        | y         |
| file-5.48            | 7bnpc66nfnr7gvn6nfm5x42pvnzfifdv   | y       | y        | y         |
| file-5.48-dev        | saj7vpsk48j27q1r4ys2mdvn9jmj7jfv   | y       | y        | y         |
| file-5.48-man        | 06dnl3xi0bdbsl2ds9p1wh77yhfq10vm   | y       | y        | y         |
| gnugrep (grep 3.12)  | d9zrp2hjgbdq8gv0b2gi46pdlq88qyp7   | y       | y        | y         |
| gnused               | mky1cdsy45vkbb60qlwnhkkywnwnyhh6   | y       | y        | y         |
| coreutils 9.11       | 3wlwvk71i6dfwiq63kdakq02fig8m68p   | y       | y        | y         |
| pcre2-10.47-bin      | 8p33gx33w5jqxhx2nwl2y5ihycm92xd3   | y       | y        | y         |
| pcre2-10.47-dev      | wjd10rk610g39cslak2zwmlbf3f57x9b   | y       | y        | y         |
| pcre2-10.47 (lib)    | 5f5vlcfg511sh4zfi6ij3zjk95f2bwyf   | y       | y        | y (cached)|
| pcre2-10.47-doc      | 3w2fby5mkv9fq1nb10li30wyhf7jlg1j   | y       | y        | y         |
| pcre2-10.47-man      | 7xsrmxmp6prqsxmxk6bg6j74g65i7v50   | y       | y        | y         |
| pcre2-10.47-devdoc   | vasrsip3yiyk2vcfr1mjvlh71283sjxr   | y       | y        | y         |

8 packages / 17 outputs. published=15, skipped(already-cached)=2, failed=0.
These coexist at NEW hashes with any prior `nix-store --add` artifacts
(append-only; nothing existing was removed or mutated).

## The composition (`tranche-entry.nix`)

Four glue overlays on top of the fork's solnix overlay + `solaris-overlay.nix`.
Each fixes a distinct blocker that stops arbitrary `pkgs.<name>` from
evaluating/building against the pure stdenv:

1. **`fetchurl-shim.nix`** — the nixpkgs `fetchurl` builds a real `curlMinimal`
   (openssl/perl/krb5/...) as its downloader; evaluating that toolchain against
   the pure solaris stdenv hits a `perl <-> libxcrypt` infinite recursion.
   `stdenv.fetchurlBoot` avoids curl but emits a derivation that trips blocker
   (2). The shim routes every src through `builtins.fetchurl` (eval-time,
   hash-verified fixed-output = hermetic-by-hash, no builder, no stdenv),
   expanding `mirror://` from the upstream `mirrors.nix`. The src closure still
   traces to a `/nix/store` fixed-output path.

2. **`__structuredAttrs = false` adapter** — Nix 2.3.16 has NO structuredAttrs
   support: it never writes `.attrs.sh`, so `NIX_ATTRS_SH_FILE` is empty at
   build time, `$stdenv` is never populated, and the builder's
   `source $stdenv/setup` fails with `/setup: No such file`. Every `by-name`
   package defaults to structuredAttrs, and the stdenv was baked with
   structured-by-default ON (so the import-time `config` knob can't undo it).
   `stdenvAdapters.addAttrsToDerivation { __structuredAttrs = false; }` forces
   the classic env-var builder the old daemon handles. **This one fix unblocked
   the whole by-name package universe** (pcre2 and everything downstream).

3. **`bashNonInteractive.shellPath` + `runtimeShell` pin** — under this nixpkgs
   vintage `bashNonInteractive` (a `lowPrio` + spliced-pkgset value) lost its
   `shellPath` passthru, so `runtimeShell = "${bash}${bash.shellPath}"` throws
   `attribute 'shellPath' missing`. Restored so packages that read
   `runtimeShell` in `configureFlags` evaluate. (Only *partially* effective —
   see blocker H1 below; the spliced set defeats a top-level override for some
   packages.)

4. **`solaris-overlay.nix`** — the existing Phase-2 portability patches
   (`-lnsl -lsocket`, gnulib const fix, gcc-14 relax, ...). Applied last.

Plus a one-time store seed: the `gnu-config` `config.sub`/`config.guess` FODs
at rev `948ae97` (`vq0j27nvpks679djbiykl8ikdyj6z5a9-config.guess-948ae97`,
`1p61qjvlqmwrqab3zp5yh3z8rf3mvjmz-config.sub-948ae97`). git.savannah.gnu.org
cgit is unreachable from the OI host (all endpoints time out / 502), so these
were substituted from cache.nixos.org (content-addressed FODs, so the store
path is identical regardless of source) and imported into the host store.
Every autotools package that pulls `updateAutotoolsGnuConfigScriptsHook` needs
them; seed once, reuse forever.

## Verify + publish (per the task, append-only)

```
# on the OI host, for each attr:
OUT=$(nix-build /root/tranche2.nix -A <attr> --no-out-link)
nix-store -q --deriver "$OUT"                       # must resolve to .drv
nix-store -qR "$OUT" | grep -v '^/nix/store/'       # must be EMPTY (hermetic)

# publish from the workstation (bridges through a local temp store):
BUILDER_IP=<oi-ip> SYSTEM=x86_64-solaris \
  ./scripts/oi-fleet-publish.sh artifacts/tranche1-paths.txt
```

## Blocker families still open (for the full rebuild — need a stdenv fix, not a per-package patch)

These stopped the rest of the daily-toolset batch. Each is a *shared* stdenv
gap; fixing them in the fork's stdenv/cc-wrapper unblocks large swaths at once.

- **H1 conftest RUNPATH (biggest blocker).** `pkg-config`, `ncurses`, `less`,
  `gettext`, `libidn2`, `libunistring` fail configure with `cannot run C
  compiled programs` — root cause `ld.so.1: conftest: fatal: libiconv.so.2:
  open failed`. The fork's bintools-wrapper does NOT bake an illumos `-R`
  runpath from the `-L` dirs the way the Linux wrapper does, so any configure
  *run-test* that links a shared buildInput lib can't find it at runtime.
  `LD_RUN_PATH`/`LD_LIBRARY_PATH` from `-L` dirs is the lever; the right home
  is the cc/bintools-wrapper (auto `-R` for every `-L`), not a per-package
  `preConfigure`. Unblocks pkg-config and everything that nativeBuildInputs it.

- **H2 C++ runtime.** `gmp-with-cxx` (hence `nettle`) fails
  `C++ compiler not available` / `program does not run`. The pure stdenv's
  g++ can't produce runnable C++ binaries yet (libstdc++ runtime slice /
  namespace). Needed for the whole C++ world.

- **H3 curl-bootstrap `/setup` for build-dep srcs.** `openssl` pulls a real
  `perl` build whose `libxcrypt-4.5.2.tar.xz` src is fetched by the *curl
  bootstrap* `fetchurlBoot` (a different stdenv path the adapter in (2) does
  not wrap), so it still hits the structuredAttrs `/setup` failure. Fix: apply
  the `__structuredAttrs=false` force to the bootstrap/spliced stdenvs too, or
  point `fetchurlBoot` at the same builtin-fetchurl shim.

- **H4 spliced-pkgset overrides.** `curl`/`libffi` still throw `shellPath
  missing` despite fix (3): `runtimeShell`/`bashNonInteractive` resolve from
  `__splicedPackages`, which a top-level overlay does not reach. Fix belongs in
  the fork stdenv/bash passthru (make `bashNonInteractive` carry `shellPath`
  natively), not the tranche overlay.

- **H5 fragile upstream fetches (per-package, low priority).** `gnutls` closure
  pulls a GitHub auto-generated `libevent` `.patch` whose hash drifts (hash
  mismatch); `readline`/`libffi` hit transient `ftpmirror.gnu.org`
  interruptions (Nix's own downloader retries, but the mirror flaked past the
  retry budget). Retry later or pin a stable mirror/`fetchpatch` snapshot.

## SKIPPED this tranche (with blocker)

`ncurses` `less` `pkg-config` `gettext` `libidn2` (H1) · `nettle` `gmp` (H2) ·
`openssl` `sqlite`(needs bzip2-dev via unzip + is downstream of openssl-ish
deps) (H3) · `curl` `libffi` (H4) · `gnutls` `readline` (H5) · `htop` `git`
`vim` (bintools-wrapper assertion / H1 chains — deferred with the batch).
