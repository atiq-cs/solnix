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

## Second tranche (H1-fix proven + published, append-only, to cache.solnix.io)

H1 (conftest RUNPATH) is **FIXED** in the fork cc-wrapper (see below). These
packages were H1-blocked and now build/run as real hermetic derivations against
the H1-patched pure stdenv:

| pname               | new store hash                     | deriver | hermetic | runs | published |
|---------------------|------------------------------------|---------|----------|------|-----------|
| libiconv-1.19       | i77sy5x8qkkz6w97hjirmxmm0d88v36d   | y       | y        | y    | y (cached)|
| libunistring-1.4.2  | dlv6i05zqisnj0irdcw3s3dh6vmlhzs8   | y       | y        | y    | y         |
| libunistring-dev    | rzb37h6gc18lgjaclnpjp4bydddfs69y   | y       | y        | -    | y         |
| libunistring-doc    | ilgljycrvvbkmzaziihzi0b5l1ml0xja   | y       | y        | -    | y         |
| libunistring-info   | p63hkyn3cv8w24sqvh3hag3gihkpvvpc   | y       | y        | -    | y         |
| expat-2.8.2         | 2ly9rs9p5q6r1hp0lrkwhicbpgzxwwvr   | y       | y        | y    | y         |
| expat-dev           | m3ly2w4lfqrk7lzbbr3d34l84bvi7cfp   | y       | y        | -    | y         |
| libatomic_ops-7.10.0| 6axl50x5alpraqw16mprk1nacjg5if1x   | y       | y        | y    | y         |
| libatomic_ops-dev   | gsa37vsgszi20yss5hgwjgiv236fnl7z   | y       | y        | -    | y         |
| libatomic_ops-doc   | b4r20q3j5v6m2ds8ga4d9q6vdwbgns98   | y       | y        | -    | y         |

4 packages / 10 outputs. published=9, skipped(already-cached)=1 (libiconv),
failed=0. `runs` verified: libunistring `.so` loads via a linked test binary
that execs (RUNPATH -> /nix/store), expat `libexpat.so.1` resolves from the
store in a linked+run test, libiconv `bin/iconv --version` runs, libatomic_ops
`.so` RUNPATH -> store. All deriver-resolve to a real `.drv` (built, not
`nix-store --add`) and have host-free closures.

### H1 fix (the wrapper diff)

The biggest lever. Root cause found by tracing the failing conftest exec:
the solnix seed **gcc is configured `--with-ld=/usr/bin/ld`**, so
gcc/`collect2` execs the host link-editor directly and BYPASSES the nixpkgs
`ld-wrapper` entirely -- so the ld-wrapper's `-L`->`-rpath` auto-rpath logic
AND the `ld-solaris` `-rpath`->`-R` translation (patch 0002) never run. A
dynamically-linked binary that pulls a shared lib out of a `/nix/store` `-L`
dir therefore got NO RUNPATH and could not exec
(`ld.so.1: fatal: libiconv.so.2: open failed`), breaking every autotools
conftest that links a shared buildInput lib.

Fix (`patches/0005-cc-wrapper-solaris-runpath.patch` in the fork, applied to
`pkgs/build-support/cc-wrapper/`):
- `cc-wrapper.sh`: after args are assembled, scan `extraBefore+params+extraAfter`
  for every `-L <store-dir>` / `-L<store-dir>`, and for each unique dir under
  `$NIX_STORE` append `-Wl,-R,<dir>`. gcc forwards `-Wl,-R,DIR` straight to the
  host `ld` as a Solaris `-R` RUNPATH entry, so ld.so.1 resolves the dep from
  the store. Only store paths are added (hermetic; no host `/usr/lib`). Gated
  on the marker `nix-support/add-solaris-runpath` + off when
  `NIX_DONT_SET_RPATH` is set + off when not linking.
- `cc-wrapper/default.nix`: `postFixup` drops the
  `nix-support/add-solaris-runpath` marker only when `targetPlatform.isSunOS`.

Verified: `libiconv.so.2`-linked conftest now execs (`run-exit=0`) with
`RUNPATH -> .../libiconv-1.19/lib`; the whole autotools-conftest swath is
unblocked (pkg-config's configure now runs conftests fine and reaches much
later probes). Did not touch the ld-solaris `=`-form / `-dynamic-linker`
fixes already in place (patch 0002).

### Did H1 incidentally unblock H2-H5?

- **H2 (C++ runtime) is the SAME CLASS as H1.** A C++ conftest links
  `libstdc++.so.6`/`libgcc_s.so.1` and fails to run with the identical
  `ld.so.1: ... open failed` because those runtime libs live ONLY in the seed
  (`illumos-seed-unpacked/usr/gcc/10/lib/amd64`) and get no RUNPATH. H1's
  mechanism fixes it too *once that gcc-runtime dir is a tracked `-L`* --
  manually adding `-Wl,-R,<seed gcc amd64 libdir>` makes `std::cout` C++ hello
  run (`run-exit=0`). The remaining H2 work is small: bake that gcc-runtime
  `-R` into the cc-wrapper (the dir is not in `gcc-unwrapped`, only the seed,
  so it needs the `gccForLibs`/seed path wired in). NOT done here (H1 scope).
- H3/H4/H5: unchanged by H1.

### Newly diagnosed shared blockers (exposed *because* H1 now lets configure run)

- **H6 seed-lib gap.** With conftests running, gettext's configure link
  (`LDFLAGS=-lm -lmd -lmp -luutil -lnvpair -lnsl -lidmap -lavl -lsec`, set by
  upstream nixpkgs `gettext/default.nix` for all illumos) fails
  `library -lmd: not found`: the seed carries only
  libc/libm/libnsl/libresolv/libsocket/libdl/libelf/libpthread/librt and NOT
  libmd/libmp/libnvpair/libuutil/libidmap/libavl/libsec (and the seed's own
  `libnsl.so.1` NEEDs the absent libmp/libmd). Same gap behind pkg-config's
  bundled-glib `res_query` probe. Partial mitigation landed for gettext
  (`solaris-overlay.nix` pins its `LDFLAGS=-lm`), which pushed it past
  configure. Real fix: regrow the seed FOD with those system libs. Blocks
  gettext (a nativeBuildInput for a large swath), libgpg-error, libidn,
  pkg-config internal-glib.
- **H7 libtool `global_symbol_pipe` empty.** With configure passing, libtool's
  link step emits `nm ... | | sed` (`syntax error near unexpected token '|'`)
  because its configure probe of Solaris `/usr/bin/nm` output yields an empty
  `global_symbol_pipe`. Proven fix: point libtool `NM` at a GNU-format nm --
  swapping to `gnm` builds `libintl.so` cleanly. Blocks gettext (post-config),
  libidn2 (which otherwise passed H1 configure). Hermetic fix needs a GNU nm
  in the toolchain (seed regrow / bintools `gnm`); there is no GNU-format nm
  in the store today.

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

- **H1 conftest RUNPATH (biggest blocker) -- FIXED (tranche 2).** Was:
  `pkg-config`, `ncurses`, `less`, `gettext`, `libidn2`, `libunistring` fail
  configure with `cannot run C compiled programs` / `ld.so.1: conftest:
  libiconv.so.2: open failed`. Root cause: the seed gcc is
  `--with-ld=/usr/bin/ld`, so gcc/collect2 execs the host ld directly and
  bypasses the nixpkgs ld-wrapper's `-L`->rpath logic (+ the ld-solaris
  `-rpath`->`-R` translation), leaving store-shared-lib binaries with no
  RUNPATH. FIX: `patches/0005-cc-wrapper-solaris-runpath.patch` makes the
  cc-wrapper inject `-Wl,-R,<store-dir>` for every store `-L` dir (see
  "Second tranche" above). Proven: libiconv/libunistring/expat/libatomic_ops
  now build+run hermetically. Downstream of H1, gettext/libidn2/pkg-config
  now reach *later* stages and hit the distinct H6/H7 gaps below.

- **H2 C++ runtime -- SAME CLASS as H1 (now understood).** `gmp-with-cxx`
  (hence `nettle`) fails `C++ compiler not available` / `program does not
  run`. Diagnosed: the C++ conftest links `libstdc++.so.6`/`libgcc_s.so.1`
  which live ONLY in the seed (`illumos-seed-unpacked/usr/gcc/10/lib/amd64`)
  and, like H1, get no RUNPATH -> `ld.so.1: ... open failed` at exec. H1's
  `-Wl,-R` mechanism fixes it: adding `-Wl,-R,<seed gcc amd64 libdir>` makes a
  C++ hello run. Remaining work is small -- bake that gcc-runtime `-R` into the
  cc-wrapper (the dir is in the seed, not `gcc-unwrapped`, so it needs the
  `gccForLibs`/seed path wired in). Needed for the whole C++ world.

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

- **H6 seed-lib gap (newly exposed by H1).** Now that conftests run, packages
  whose configure link line references illumos system libs the seed lacks fail
  `library -lmd: not found`. The seed carries only
  libc/libm/libnsl/libresolv/libsocket/libdl/libelf/libpthread/librt and NOT
  libmd/libmp/libnvpair/libuutil/libidmap/libavl/libsec (and the seed's own
  `libnsl.so.1` NEEDs the absent libmp/libmd). Hit by gettext (upstream
  `gettext/default.nix` sets a blanket illumos
  `LDFLAGS=-lm -lmd -lmp -luutil -lnvpair -lnsl -lidmap -lavl -lsec`) and by
  pkg-config's bundled-glib `res_query` probe. Partial mitigation: the
  `solaris-overlay.nix` gettext entry now pins `LDFLAGS=-lm` (past configure).
  Real fix: regrow the seed FOD with those system libs. Blocks gettext (a
  nativeBuildInput for a large swath), libgpg-error, libidn.

- **H7 libtool `global_symbol_pipe` empty (newly exposed by H1).** With
  configure passing, libtool's link emits `nm ... | | sed` -> `syntax error
  near unexpected token '|'`, because its configure probe of Solaris
  `/usr/bin/nm` yields an empty `global_symbol_pipe`. Proven fix: point libtool
  `NM` at a GNU-format nm (`gnm`) -> `libintl.so` links cleanly. Hermetic fix
  needs a GNU nm in the toolchain (seed regrow / bintools `gnm`); there is no
  GNU-format nm in the store today. Blocks gettext (post-config), libidn2
  (which cleared H1 configure but dies here).

## SKIPPED this tranche (with blocker)

H1 FIXED (tranche 2): `libiconv` `libunistring` `expat` `libatomic_ops` built +
published. Still blocked downstream of H1:
`gettext` `libidn2` `libgpg-error` (H6 seed-lib gap / H7 libtool nm) ·
`pkg-config` internal-glib `res_query` (H6) · `ncurses` `less` (need pkg-config
-> H6 chain) · `nettle` `gmp` (H2 -- same class as H1, small remaining fix) ·
`openssl` `sqlite` (H3) · `curl` `libffi` (H4) · `gnutls` `readline` (H5).
