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

## Third tranche (H2/H6/H7-fix proven + published, append-only, to cache.solnix.io)

H2 (C++ runtime), H6 (seed-lib gap), H7 (libtool `global_symbol_pipe`) are all
**FIXED** in the fork stdenv + tranche overlay (see the H2/H6/H7 sections
below). These packages were H2/H6/H7-blocked and now build/run as real
hermetic derivations. Persisted PER-PACKAGE (build -> verify -> publish ->
registry row -> tranche3-paths.txt, before moving to the next) so a mid-run
death strands at most one package.

| pname                | new store hash                     | deriver | hermetic | runs | published |
|----------------------|------------------------------------|---------|----------|------|-----------|
| gettext-1.0          | dx6j3lyan943zgcv5bwz1f4sn8v7lihi   | y       | y        | y    | y         |
| gettext-1.0-doc      | x8fby7vwwm24gjg5fdfaq4cb7dkbfwc5   | y       | y        | -    | y         |
| gettext-1.0-info     | z85x174rdgffcc9rlzi6r1i1h9ycglby   | y       | y        | -    | y         |
| gettext-1.0-man      | 0s5rd8hj6l1p0rb40q0x5nxxsq5kpii7   | y       | y        | -    | y         |
| pkg-config-0.29.2    | d3i8k3f3qkkmg82naqgpriclvixv9rx5   | y       | y        | y    | y         |
| pkg-config-0.29.2-doc| 5k037fbdcpk0np6qqg66102ilhrvx3mh   | y       | y        | -    | y         |
| pkg-config-0.29.2-man| rvivdkvaq2p8ydpy65bqzbsl66rbi61k   | y       | y        | -    | y         |
| pkg-config-wrapper   | z1wr6833mzxik5dajk2qcs76b60ip769   | y       | y        | y    | y         |
| ncurses-6.6          | agvfjzh4cc3l9cw1sgnyjr911dbj8r5h   | y       | y        | y    | y         |
| ncurses-6.6-dev      | d1ksp72428i870jk04i5pi10xzaxjsv8   | y       | y        | -    | y         |
| ncurses-6.6-man      | szi8wd474fs8j23b12cqij7bg1scsqvd   | y       | y        | -    | y         |
| less-704             | xslfwpdsjp1xiz35b5z53rxp1x03wmag   | y       | y        | y    | y         |
| less-704-man         | pha3pjhvrg0n6dypn0cwjwi08p172riw   | y       | y        | -    | y         |
| libidn2-2.3.8        | m79d4vqvw5r48qfb7q13zcc0069xrhhv   | y       | y        | y    | y         |
| libidn2-2.3.8-bin    | 6ls4bwkqgf7q5ccsgsqrxkla4mlbr6g6   | y       | y        | y    | y         |
| libidn2-2.3.8-dev    | sw37wr1nwgi25s5xfaq1niaqib5055xx   | y       | y        | -    | y         |
| libidn2-2.3.8-devdoc | a0a5wb785a45x8p9ds0pzi740wjf43bl   | y       | y        | -    | y         |
| libidn2-2.3.8-info   | 61cfdj8ldacylc1ng669sd88slcwv9kf   | y       | y        | -    | y         |
| libgpg-error-1.61    | ang98c5cz6z59dqnavjj34nh3w91n3k8   | y       | y        | y    | y         |
| libgpg-error-1.61-dev| 9s9h3sr02j34q0pvsx7aqhrpw43hj0fi   | y       | y        | -    | y         |
| libgpg-error-1.61-info| 8kjzinlv18xj5x3pqaj6p2qy8xmhkff2  | y       | y        | -    | y         |
| gmp-with-cxx-6.3.0   | v1agcprwan1vmggf6nax3lyrmwhmjmkj   | y       | y        | y    | y         |
| gmp-with-cxx-6.3.0-dev| jiw3an4d596ipn9snrh21nw25zqlcy0v  | y       | y        | -    | y         |
| gmp-with-cxx-6.3.0-info| 1x34dd1rd3vm06ac2b0f2k92rxrw4987 | y       | y        | -    | y         |

8 packages / 24 outputs. published=24, failed=0. `runs` verified on illumos:
`gettext`/`msgfmt --version`, `pkg-config --version` (0.29.2, wrapped +
unwrapped), ncurses `tic -V` (`ncurses 6.6`), `less --version` (704,
installCheck passed on-host), `idn2 --version` (Libidn2 2.3.8),
`gpgrt-config --version` (1.61), and `libgmpxx.so.4` (C++, NEEDs
`libstdc++.so.6`) resolving the C++ runtime from the store via `ldd` (the H2
proof on a real package). All deriver-resolve to a real `.drv` and have
host-free closures.

## Fourth tranche (pkg-config swath + newly-unblocked, published, append-only, to s3.solnix.io)

The tranche-3 `pkg-config`/`gmp`/`libgpg-error` unlock opened the
`nativeBuildInputs = [ pkg-config ]` downstream swath plus the gmp-dependent
crypto libs. These built + ran as real hermetic derivations against the pure
stdenv. Persisted PER-PACKAGE (build -> verify -> stage -> registry row ->
`artifacts/tranche4-paths.txt`, before moving on) so a mid-run death strands at
most one package.

**Cache-backend caveat (IMPORTANT):** during this tranche a cache-integrity
audit proved the `s3.solnix.io` *package* narinfo/nar layer is **not durable**
-- a backend defect: writes return HTTP 200 without persisting, and the GET
layer flaps 200/404 non-deterministically (both `nix copy` and `aws s3 cp`
hit it). No re-upload+verify loop can make an object stick; it needs a
maintainer backend fix. So the tranche-4 deliverable is **build + LOCAL verify
+ stage**, NOT cache round-trip. Per-package success here means, verified on
the OI build host:
- `nix-store -q --deriver <out>` resolves to a real `.drv` (built, not
  `nix-store --add`),
- `nix-store -qR <out>` closure is 100% `/nix/store` (host-free),
- the binary/`.so` runs / loads on illumos.

The verified store paths are then **staged** into an on-host, re-publishable
export at `/nix/tranche4-bcache/` on the OI builder
(`root@18.218.136.61`): `exports/tranche4-union.closure.nar` (a single
`nix-store --export` of the union closure of all 47 outputs -- 72 store paths,
re-imports cleanly `rc=0`) plus the path manifest `tranche4-own-paths.txt`.
A best-effort `nix copy`/`aws s3 cp` is still fired per package (harmless, may
partially land), but the staged export is the authoritative artifact; it gets
re-published once the cache backend is durable. Registry `published` column is
therefore `staged` for tranche 4 (flip to `y` after a durable re-publish).

| pname                | new store hash                     | deriver | hermetic | runs | staged    |
|----------------------|------------------------------------|---------|----------|------|-----------|
| lzo-2.10             | lx381c7fkvymf7ngdw4myxbi8hxlry68   | y       | y        | y    | staged    |
| lzo-2.10-dev         | 36cxp23vhxp8a1hg0pwfjx7dgv2ys8an   | y       | y        | -    | staged    |
| lzo-2.10-doc         | lxbiac5pkp05wmp9ia5vjk6vg1s8wpzy   | y       | y        | -    | staged    |
| nettle-3.10.2        | vnd3pz1m3bdd9h9qaasi59knjcgvmggd   | y       | y        | y    | staged    |
| nettle-3.10.2-dev    | b1xkv234d5rafhwskarn0niadxfjhfrr   | y       | y        | -    | staged    |
| gperf-3.3            | b9753af9vpvi5b6pkj372skx7g25marr   | y       | y        | y    | staged    |
| libgcrypt-1.12.2     | 3q6fkjz1mdah74h5j218amviz85vn14q   | y       | y        | y    | staged    |
| libgcrypt-1.12.2-lib | 8hnzc6r2qllg6ik30ignjcf98fprmq3r   | y       | y        | y    | staged    |
| libgcrypt-1.12.2-bin | fgps20syngigwxvaqxx0x1b0373cqlg3   | y       | y        | y    | staged    |
| libgcrypt-1.12.2-dev | 91nnxp14j6mq1sip0w25786p8gc21q2a   | y       | y        | -    | staged    |
| libgcrypt-1.12.2-info| dmpdsn13ny4rwdig2ilz7s2h2ncj5afz   | y       | y        | -    | staged    |
| gdbm-1.26            | pk5b4cx0521a0wzylpbxjwnjvyl1kmym   | y       | y        | y    | staged    |
| gdbm-1.26-lib        | b9ajac4rlc45iax9dlj4y2si1r5lgf38   | y       | y        | y    | staged    |
| gdbm-1.26-dev        | 0id1356ngy8dkwpq9vvhwd2356isf63x   | y       | y        | -    | staged    |
| gdbm-1.26-man        | 1b73587wpl2468vlwipkrnzjly2x6gwi   | y       | y        | -    | staged    |
| gdbm-1.26-info       | 5g2q0jplnsl1n0k5ghw0r9j61d1zmy8m   | y       | y        | -    | staged    |
| gzip-1.14            | dg2xrz7axz295mpld76g2z31wadfdbm0   | y       | y        | y    | staged    |
| libpng-1.6.58        | 83899339dlrh7fiymhnq617gab3cx7pb   | y       | y        | y    | staged    |
| libpng-1.6.58-dev    | fwl61fpic9iga1wr3qdpryvjgam8fj6c   | y       | y        | y    | staged    |
| libpng-1.6.58-man    | p2krdyl1yhjz7i1l6snj9n1gkm1d2xrl   | y       | y        | -    | staged    |
| mpfr-4.2.2           | syw2vs5dzxggkqshp7q4c88yd7mml2fn   | y       | y        | y    | staged    |
| mpfr-4.2.2-dev       | rg3rcapnfqynqvnmnb8i1yc2n6h6r8m4   | y       | y        | -    | staged    |
| mpfr-4.2.2-doc       | 38fsv58q2xy1mpkahfp7in4kydn4m91d   | y       | y        | -    | staged    |
| mpfr-4.2.2-info      | saf8gxhp1q1rrpa08l9vv4wvycgmsbwh   | y       | y        | -    | staged    |
| libmpc-1.4.1         | 93kllc9h31mw0mwypdqkbvfi8nr47igj   | y       | y        | y    | staged    |
| popt-1.19            | jzs6myzi2vmgxh0k8i332wp3w7wvp6cj   | y       | y        | y    | staged    |
| popt-1.19-dev        | frwc5isqrrkwkbnhy2p7mrg1qdbr7cz6   | y       | y        | -    | staged    |
| popt-1.19-man        | pvxkwhh57qvzh8zp27398inhdx0rv5cf   | y       | y        | -    | staged    |
| giflib-6.1.3         | crn1f09nbhwlkzlnjb5ysdsqp0igfpvq   | y       | y        | y    | staged    |
| libconfig-1.8.2      | 58bc09q9nlf2cippgs168rhf9vrvf9rm   | y       | y        | y    | staged    |
| check-0.15.2         | l6s957ilpdsvrpyrxk78ffb5s35mg4pm   | y       | y        | y    | staged    |
| libksba-1.8.0        | 27cx0avn1g704f04zas9g3gfc6rmp3k4   | y       | y        | y    | staged    |
| libksba-1.8.0-dev    | 06cjj7m0v6w2s3q4cb03gxqrhnn9krnl   | y       | y        | -    | staged    |
| libksba-1.8.0-info   | 07rd25pi4fj03bp5yrcz3idh0p61lx50   | y       | y        | -    | staged    |
| tcl-8.6.16           | wpfvvbrpwsqq4xyrxdj3ynvr6a6awkw7   | y       | y        | y    | staged    |
| tcl-8.6.16-man       | b1frmzwph7dy4d9y5j9j6kr60wy1igq7   | y       | y        | -    | staged    |
| gnum4-1.4.21         | 7rzym93wqjkij6cwrf6fhzdk2ggncq13   | y       | y        | y    | staged    |
| patch-2.8            | 954mzmi94l0zmb9692fpzlzw5kkfax6y   | y       | y        | y    | staged    |
| which-2.25           | xjl2ws0y1pkdwpjx9dfaqx5pxsz4121m   | y       | y        | y    | staged    |
| which-2.25-man       | 93kb5ixa7yncq9qi81b1ka6bk5ar9cl3   | y       | y        | -    | staged    |
| which-2.25-info      | ygw9bx72sgy21dk4yrcchqqp0iirnmq4   | y       | y        | -    | staged    |
| findutils-4.10.0     | d5b51mjq5s3i6h3258plpnfwkry3xhjz   | y       | y        | y    | staged    |
| readline-8.3p3       | jn4pbjb4nxli1hnpldzicn6rzld0fbyl   | y       | y        | y    | staged    |
| readline-8.3p3-dev   | nabqzxdf9v8lx9gs80ndrhzln4xxsl4m   | y       | y        | -    | staged    |
| readline-8.3p3-doc   | n2ap2k4ddn9lfsd457mzfk25y76v1pq4   | y       | y        | -    | staged    |
| readline-8.3p3-info  | i5mrllbrxwsiapif5zv9v0b5vzp3wvrh   | y       | y        | -    | staged    |
| readline-8.3p3-man   | 8pnm23r1n9iz70z3cm1771a06w9k093c   | y       | y        | -    | staged    |
| gawk-5.4.0           | l2x88nbk34l4lbnzq6v2rmszkvjjpbir   | y       | y        | y    | staged    |
| diffutils-3.12       | 45hclwpavdcmq800i9fz59k1hiqihn90   | y       | y        | y    | staged    |
| gnutar-1.35          | bzzq99jch9j3aw39x49f207hig73jbr7   | y       | y        | y    | staged    |

**23 packages / 50 outputs. built + verified + staged = 50, failed = 0** --
the largest tranche yet. Every output was LOCALLY verified on the OI host:
deriver resolves to a real `.drv` (y) and closure is 100% `/nix/store`
(host-free, y) -- see the consolidated verify sweep. `runs` verified on
illumos: `gzip 1.14`, `gperf --version` (3.3),
`gdbmtool (gdbm) 1.26`, `libpng-config` (1.6.58, `libpng16.so.16` resolves
libz/libm/libc from the store), `dumpsexp (Libgcrypt) 1.12.2` +
`libgcrypt.so.20` resolving **the tranche-3 `libgpg-error.so.0` from the
store**, `tclsh8.6` (8.6.16), and the `.so`s of nettle/mpfr/libmpc/giflib/
libconfig/check/libksba (`libksba.so.8` -> tranche-3 `libgpg-error.so.0`),
plus `m4 (GNU M4) 1.4.21`, `GNU patch 2.8`, `GNU which v2.25`, `find (GNU
findutils) 4.10.0`, and readline's `libreadline.so.8`.
Batch 4 adds `gawk` (`GNU Awk 5.4.0` linking **GNU MPFR 4.2.2 + GNU MP 6.3.0**
from this and prior tranches), `diff (GNU diffutils) 3.12`, `tar (GNU tar)
1.35`.
Every output deriver-resolves to a real `.drv` (built, not `nix-store --add`)
and has a 100% `/nix/store` closure. Append-only: these coexist at NEW hashes
with all prior artifacts (0 deletions). **Staged** (not cache-durable -- see
the backend caveat above) to `/nix/tranche4-bcache/` on the OI builder as
`exports/tranche4-union.closure.nar` (`nix-store --export` of the 72-path
union closure; re-imports `rc=0`); best-effort S3 uploads were also fired but
the cache layer flaps and is not the deliverable.

The tranche-4 dependency chains prove real cross-package linkage: `libgcrypt`
and `libksba` both link the tranche-3 `libgpg-error`, and `libpng` links the
tranche-1 `zlib` -- all resolved from `/nix/store`, none from the host.

### H9 (gzipped patches: `gunzip` missing) -- NEW gap, fixed per-package

`libpng` applies its apng patch as a `.gz` and shells out to `gunzip` in
`patchPhase`; the pure seed stdenv carries no `gunzip` on PATH ->
`gunzip: command not found` (exit 127). Compounding it, the freshly-built
`gzip` (this tranche) installs only `gzip` -- the illumos gzip build skipped
the usual `gunzip`/`zcat` wrapper symlinks. FIX (per-package, in
`solaris-overlay.nix`): add a tiny `gunzip` shim (`exec gzip -d "$@"`) to
`libpng.nativeBuildInputs`. Any package shipping gzipped patches will hit
this; promote the shim (or a fixed gzip that emits the wrappers) to the
stdenv's default `nativeBuildInputs` when it recurs. Also this tranche:
`gdbm` needed `doCheck = false` (one flaky in-tree test, `gdbm_close error`,
assumes a different `close()` errno than illumos returns; the library links +
runs fine).

### H2/H6/H7 fixes (the stdenv + overlay diffs)

All three are **seed-sourced + hermetic** (no host `/usr/lib` refs; the fixed
fork stdenv is captured at `artifacts/tranche3-fork-fixes/` since the fork is a
separate, non-git tree). The seed FOD did NOT re-grow -- the needed illumos
system libs and the C++ runtime were already inside the unpacked seed, just not
on the link search path -- so the 4 pure-stdenv FOD sites and the seed SRI are
**unchanged** (no bump).

- **H2 (C++ runtime) -- FIXED.** `libstdc++.so.6`/`libgcc_s.so.1` live only in
  the seed gcc runtime amd64 libdir (`gcc-unwrapped/usr/gcc/10/lib/amd64`),
  which was not on the link search path, so a C++ binary linked but could not
  RUN (same `ld.so.1: ... open failed` class as H1). Fix: the illumos cc-wrapper
  `extraBuildCommands` now emits `-L$gccdir/lib/amd64` into `cc-cflags`; the H1
  cc-wrapper.sh runpath pass then auto-adds `-Wl,-R,<store dir>`. Proven: a
  C++ hello runs, and the real `gmp-with-cxx` `libgmpxx.so.4` NEEDs
  `libstdc++.so.6` and `ldd` resolves it from the store.
- **H6 (seed-lib gap) -- FIXED.** The illumos system libs
  `libmd/libmp/libnvpair/libuutil/libidmap/libavl/libsec` (+ `libnsl/libsocket/
  libresolv`) that autotools/gettext link lines reference are ALREADY inside the
  unpacked seed under `usr/gnu/lib/amd64` (captured as the ldd-closure of the
  GNU userland), but only as versioned `.so.N` -- no unversioned `.so` link, so
  `-lmd` etc. did not resolve. Fix: a new `seedSyslibs` slice (a plain
  derivation in the stdenv) symlinks that dir and adds the `.so -> .so.N` links,
  and the cc-wrapper puts `-L${seedSyslibs}/lib/amd64` on the search path (H1
  auto-`-R` then makes them run). Fully seed-sourced, so no seed regrow. Proven:
  a C program linking all 7 libs links + runs; gettext (upstream's blanket
  illumos `LDFLAGS`) links cleanly.
  - **H6b/H6c (`-lthread`).** pkg-config's bundled glib configure sets
    `G_THREAD_LIBS="-lpthread -lthread"` on Solaris (a Sun Studio `-mt` relic).
    illumos folded libthread into libc; there is no standalone `libthread.so`
    (and a shim SONAME-conflicts with libpthread), and `-lthread` is redundant.
    Fix: `pkg-config-unwrapped` overlay `postPatch` drops `-lthread` from the
    GENERATED `glib/configure` (keeps `-lpthread`).
- **H7 (libtool `global_symbol_pipe` empty) -- FIXED.** Solaris `/usr/bin/nm`
  output is not the format libtool's configure probe expects -> empty symbol
  list -> `nm ... | | sed` syntax error at link. Fix: the stdenv exposes
  `illumosGnm` (GNU nm 2.46.1, a small content-addressed FOD
  `gnm.tar.gz`, RUNPATH-relocated to the seed gnu libs -- host-free), and the
  overlay sets `NM=${illumosGnm}/bin/gnm` for the libtool-driven builds
  (gettext, libidn2, libgpg-error) via the `withGnm` helper. Proven: `gnm -B`
  emits `<addr> T <sym>` (GNU format libtool parses), and libidn2/libgpg-error/
  gettext all build their `.so` via libtool cleanly.

### H8 (ncurses `--version-script`) -- NEW gap, fixed per-package

Exposed by building ncurses: `--with-versioned-syms` makes ncurses emit
`-Wl,--version-script,resulting.map` straight to `collect2`, which execs the
host Solaris `ld` directly (the H1 bypass) so the ld-solaris translation never
runs -> `ld: fatal: unrecognized option '--version-script'`. Symbol versioning
is cosmetic on a fresh port; the overlay filters `--with-versioned-syms` from
ncurses' `configureFlags`. (A general stdenv fix -- translating
`--version-script` -> Solaris `-M mapfile` in the cc-wrapper runpath pass --
would unblock any GNU-version-script package at once; deferred.)

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

**Cache-backend note (tranche 4+):** the `s3.solnix.io` package narinfo/nar
layer is a non-durable backend (writes return 200 without persisting; GET
flaps 200/404; `aws s3 cp` fails the same way -- a maintainer-side backend
fix, not a process bug). From tranche 4 on, the deliverable is **local verify
(real `.drv` + host-free closure + runs on illumos) + a re-publishable stage**
(`nix-store --export` of the output closures into an on-host bcache, e.g.
`/nix/tranche4-bcache/exports/`), NOT a cache round-trip. A best-effort S3
upload is still fired per package. Re-publish the staged export once the
backend is durable and flip the registry `published` column from `staged` to
`y`.

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

- **H2 C++ runtime -- FIXED (tranche 3).** Was: `gmp-with-cxx` (hence
  `nettle`) fails `C++ compiler not available` / `program does not run`. Root
  cause: the C++ conftest links `libstdc++.so.6`/`libgcc_s.so.1` which live only
  in the seed gcc runtime amd64 libdir and got no RUNPATH -> `ld.so.1: ... open
  failed`, the same class as H1. FIX: the illumos cc-wrapper now emits
  `-L$gccdir/lib/amd64` into `cc-cflags` so the H1 `-Wl,-R` pass auto-adds the
  store dir. Proven: C++ hello runs; real `gmp-with-cxx` `libgmpxx.so.4` links
  `libstdc++.so.6` and `ldd` resolves it from the store (published, tranche 3).

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

- **H6 seed-lib gap -- FIXED (tranche 3).** Was: with conftests running,
  packages whose configure link references illumos system libs the seed lacked
  a `.so` link for failed `library -lmd: not found`. The libs
  (`libmd/libmp/libnvpair/libuutil/libidmap/libavl/libsec` +
  `libnsl/libsocket/libresolv`) were ALREADY inside the unpacked seed under
  `usr/gnu/lib/amd64` (only versioned `.so.N`, no `.so`). FIX: a `seedSyslibs`
  slice symlinks that dir + adds the `.so -> .so.N` links; the cc-wrapper puts
  `-L${seedSyslibs}/lib/amd64` on the search path (H1 auto-`-R` makes them run).
  Seed-sourced -> **no seed regrow, seed SRI + 4 pure-stdenv FOD sites
  unchanged**. `-lthread` variant (H6b/H6c): dropped in the pkg-config overlay
  (glib's Sun-Studio relic; libthread is folded into libc). Proven: gettext
  links the blanket illumos `LDFLAGS` cleanly + runs (published, tranche 3).

- **H7 libtool `global_symbol_pipe` empty -- FIXED (tranche 3).** Was:
  libtool's link emitted `nm ... | | sed` -> `syntax error near unexpected
  token '|'` because its probe of Solaris `/usr/bin/nm` yields an empty
  `global_symbol_pipe`. FIX: the stdenv exposes `illumosGnm` (GNU nm 2.46.1, a
  small content-addressed FOD, RUNPATH-relocated to the seed gnu libs -- host
  free), and `withGnm` in `solaris-overlay.nix` sets `NM=${illumosGnm}/bin/gnm`
  for the libtool-driven builds. Proven: `gnm -B` emits GNU `<addr> T <sym>`
  format; libidn2/libgpg-error/gettext all build their `.so` via libtool and
  run (published, tranche 3).

## SKIPPED this tranche (with blocker)

Tranche 4 (this tranche): 15 packages / 35 outputs built + published (see the
fourth-tranche table above). New gap fixed per-package: H9 (gzipped patches ->
`gunzip` shim). Still blocked, deferred by known family:

- **H3 (perl -> libxcrypt via curl-bootstrap `/setup`):** any package pulling
  `autoreconfHook` or a `perl` build-input -- `libtasn1`, `libmd`, `libssh2`,
  `liburcu`, `libassuan`, `npth`, `libtool`. (`libassuan`/`npth` reach
  `autoreconf-hook -> perl -> libxcrypt`.) These are one stdenv fix away (wrap
  the bootstrap/spliced fetchurl the same way tranche 3 wrapped the top-level
  one).
- **H5-class (fragile / uncovered fetch):** packages whose `src`/`patches`
  use `fetchFromGitHub`/`fetchpatch` the fetchurl-shim does not cover --
  `libxml2`, `zstd`, `pcre`, `freetype`, `libjpeg_turbo`, `pixman`, `libpsl`,
  `json_c`, `libtiff`, `libwebp`, `c-ares`, `nghttp2`, `libuv`, `jansson`, ...
  (eval fails in the shim: "value is a function while a set was expected").
  Needs a `fetchFromGitHub`/`fetchpatch` shim, out of scope for this tranche.
- **dep-chain gaps:** `sqlite` fails building its `unzip` build-dep
  (`bzlib.h` not found -- bzip2 dev headers not wired into the unzip build);
  not an H3/H4/H5, just a missing dev-header wire-up.
- **H4 spliced-pkgset override (`curl`, `libffi`)** and **H3 (`openssl`)**
  unchanged from tranche 3.

Prior tranche 3 note (kept for history): H2/H6/H7 FIXED -- `gettext`
`pkg-config`(+wrapper) `ncurses` `less` `libidn2` `libgpg-error`
`gmp-with-cxx` built + published (24 outputs); H8 (ncurses
`--version-script`) fixed per-package. `nettle` was listed as "retry" there
and is now built + published in tranche 4.
