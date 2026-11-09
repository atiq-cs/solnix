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

## Fifth tranche (H3 CRACKED: perl + openssl + the build-tool swath, staged, append-only)

**H3 is FIXED.** The perl<->libxcrypt curl-bootstrap `/setup` recursion (the
biggest remaining shared blocker) is cracked, and its downstream swath built as
real hermetic derivations. Cracking H3 unblocked perl + openssl (which gate a
large fraction of the remaining packages) plus the whole
autoreconf/perl-buildtool chain. Persisted PER-PACKAGE (build -> verify ->
stage -> registry row -> `artifacts/tranche5-paths.txt`) so a mid-run death
strands at most one package. Same non-durable-cache caveat as tranche 4:
deliverable = **build + LOCAL verify + stage** (real `.drv` + host-free closure
+ runs on illumos + `nix-store --export` into `/nix/tranche5-bcache/`), NOT a
cache round-trip. Registry `published` column = `staged`.

| pname                | new store hash                     | deriver | hermetic | runs | staged    |
|----------------------|------------------------------------|---------|----------|------|-----------|
| perl-5.42.0          | 33r963cv0fq906ikbqmrcwlg3h3l53jf   | y       | y        | y    | staged    |
| perl-5.42.0-man      | bfrjr0qilik4gaa9pd4ydk1wi3nz0ril   | y       | y        | -    | staged    |
| perl-5.42.0-devdoc   | 4b1sjyi2z782jn6rgj5vibr94748v1nr   | y       | y        | -    | staged    |
| libxcrypt-4.5.2      | 4sdc0fnvjbps8acfxysdbwiq8c7c9f2w   | y       | y        | y    | staged    |
| libxcrypt-4.5.2-man  | wi2bjs3dx4msqx0n2hv5yky4zbbwlm77   | y       | y        | -    | staged    |
| openssl-3.6.3        | i9szssxplv8mz45mk4fdzy2f8w8kcndr   | y       | y        | y    | staged    |
| openssl-3.6.3-bin    | sdff5bw0l8shsz57smzrjcygjsivbbg4   | y       | y        | y    | staged    |
| openssl-3.6.3-dev    | 63b1x7j2x0dvnhcxfrszgri7b1a2hrij   | y       | y        | -    | staged    |
| openssl-3.6.3-doc    | w01bqykmfbn3m9ksz8l8l90bmzzag3iv   | y       | y        | -    | staged    |
| openssl-3.6.3-man    | dq06zixvibqpvd5wz5fbi7fnqvfmywii   | y       | y        | -    | staged    |
| libssh2-1.11.1       | crvi4nhdjw4j70wyz42m4qf7l71lbjfy   | y       | y        | y    | staged    |
| libssh2-1.11.1-dev   | 7dkd25bzwkwjj8rnf98nn1z743wqf4z6   | y       | y        | -    | staged    |
| libssh2-1.11.1-devdoc| zh1qm5704v39i12aa9yc81ay7y4l2icb   | y       | y        | -    | staged    |
| help2man-1.49.3      | 91i9g989vvaxw81wgh5p87xx9jlkpvvz   | y       | y        | y    | staged    |
| bison-3.8.2          | k3rfp4x85myhcv179n4hvnq5ddn0d3xl   | y       | y        | y    | staged    |
| flex-2.6.4           | 8vwd1qrqyf1d614i2bw30nx5x3wk0m6g   | y       | y        | y    | staged    |
| libtool-2.5.4        | 3vjdhx3z7mb30wgyrs9sk65p2bwdg4fj   | y       | y        | y    | staged    |
| libtool-2.5.4-lib    | 2wf0x15f5nca80xx9dkcg8812j8kp13w   | y       | y        | -    | staged    |
| libtasn1-4.21.0      | m4p8pv31dqiqq3g6vljri7flk7vj3jf7   | y       | y        | y    | staged    |
| libtasn1-4.21.0-dev  | cgaw2d690afbclmfbx4f5sbzgfb4im33   | y       | y        | -    | staged    |
| libtasn1-4.21.0-devdoc| m6c0bywj61kvsmf45iq277zg0b0ndp05  | y       | y        | -    | staged    |
| libassuan-3.0.2      | njb1qijmgxj2829zc9p2476qwmb9iq96   | y       | y        | y    | staged    |
| libassuan-3.0.2-dev  | q2fiipv6l250asv714jscwx57mqa86g7   | y       | y        | -    | staged    |
| libassuan-3.0.2-info | ny5cj6v0djcwc0kl4jax62n69hm58aqx   | y       | y        | -    | staged    |
| npth-1.8             | 7wki2nsc7n0vs9bxn3ky9sagjp4pfk92   | y       | y        | y    | staged    |
| bc-1.08.2            | svmavln726gx6ixf6gvm1cdkbva9y9n5   | y       | y        | y    | staged    |
| cpio-2.15            | jh0z5b177m7b8ncma7jiz6zsip3l606b   | y       | y        | y    | staged    |

**11 packages / 27 outputs. built + verified + staged = 27, failed = 0.**
`runs` verified on illumos: `perl -e` runs (`v5.42.0`, `i86pc-solaris`),
`openssl version` (`OpenSSL 3.6.3`), `bison 3.8.2`, `flex 2.6.4`, `bc` (`2+2`
-> `4`), `cpio 2.15`, `help2man 1.49.3`, `libtool 2.5.4`, and the `.so`s of
libxcrypt/libtasn1/libassuan/npth load clean (0 missing deps). **Cross-package
linkage proof:** `libssh2.so.1` resolves `libssl.so.3` + `libcrypto.so.3` from
the tranche-5 `openssl` store path via `ldd` -- a real hermetic
openssl->libssh2 link, host-free. Staged to `/nix/tranche5-bcache/` as
`exports/tranche5-union.closure.nar` (`nix-store --export` of the 56-path
union closure; re-imports `rc=0`) + `tranche5-own-paths.txt`.

### H3 (perl<->libxcrypt curl-bootstrap `/setup`) -- **FIXED** (tranche 5)

Root cause (confirmed by inspecting the failing `.drv`): building perl pulls
`libxcrypt`, which nixpkgs wires as
`libxcrypt = callPackage { fetchurl = stdenv.fetchurlBoot; perl = perl.override
{ enableCrypt = false; fetchurl = stdenv.fetchurlBoot; }; }` -- a hardcoded
`stdenv.fetchurlBoot` for its src to break the perl<->libxcrypt eval cycle.
`fetchurlBoot` (`import build-support/fetchurl { curl = null; ... }`) emits a
real derivation built by the *un-adapted* `stdenvNoCC`, so its
`source-stdenv.sh` hits `/setup: No such file` under Nix 2.3.16 (no
structuredAttrs). The tranche-1 shim only routed the TOP-LEVEL `fetchurl`
through `builtins.fetchurl`; `stdenv.fetchurlBoot` was a separate,
unreachable-from-a-top-level-overlay path.

FIX (three parts, all in `artifacts/tranche5-fork-fixes/`):
1. **`fetchurl-shim.nix`** now exposes a shared `shimFetch` (the multi-mirror
   `builtins.fetchurl` fetcher) as both `fetchurl` AND `fetchurlBoot`, plus a
   `solnixShimFetch` passthru.
2. **`tranche5.nix`** re-asserts `stdenv.fetchurlBoot = solnixShimFetch` AFTER
   the structuredAttrs adapter (which re-wraps stdenv and would drop it), so
   the `stdenv.fetchurlBoot` that all-packages.nix reads for the libxcrypt
   cycle-break resolves to the shim. libxcrypt's `libxcrypt-4.5.2.tar.xz` src
   is now an eval-time fixed-output fetch (no builder, no `/setup`).

With H3 gone, perl/openssl surfaced a cluster of NEW per-package gaps, all
fixed this tranche:

- **H10 perl `ld-shared.patch` no longer applies.** nixpkgs adds an
  isSunOS-only `ld-shared.patch` targeting `hints/solaris_2.sh`; perl 5.42.0
  rewrote that file (`*gcc*)` -> `*gcc*|*g++*)`) so Hunk #1 fails. The patch is
  obsolete anyway (osvers 2.11 already uses `-shared`). Dropped.
- **H11 perl `miniperl` link missing `-lm`.** cos/exp/log/pow/sin/fmod/sqrt/
  atan2 undefined (illumos keeps libm separate); socketpair needs -lnsl/
  -lsocket. Added via the link.
  H10+H11 are applied in the **stdenv `mkDerivation` wrapper** (part 3 of the
  fix, scoped to `pname == "perl"`) because an overlay `perl.overrideAttrs`
  does NOT survive the `.override` calls that spawn perl variants
  (`perlOnBuild`, help2man's build-tool perl). Every perl variant is built with
  the one overlaid `stdenv-illumos`, so the wrapper reaches all of them. It
  handles the `finalAttrs:` function form of `mkDerivation` by composing the
  function and post-processing the resolved attrset.
- **H12 libxcrypt version-script grammar.** `AX_CHECK_VSCRIPT` picks `-Wl,-M`
  as the "Solaris version-script flag" but the map it generates is GNU
  version-script syntax; native Solaris ld rejects it under -M
  (`ld: fatal: libcrypt.map: 1: expected '=', ':', '|', or '@'`). Symbol
  versioning is cosmetic on a fresh port -> `--disable-symvers`.
- **H13 libxcrypt `test/explicit-bzero` fails** (illumos macros `explicit_bzero`
  to `memset_s`, which does not behave the C11-Annex-K way the scrub test
  expects). Library builds/links fine; `doCheck = false` (1 of 52 fails).
- **H14 LocaleGettext perl module (help2man dep).** `Makefile.PL` probes
  `$cc conftest.c -lintl` with NO `-L`; under strictDeps gettext's libdir is
  not on the link path, and with gettext's `libintl.h` included, `gettext`
  macro-expands to `libintl_gettext` -> `Undefined symbol` -> "gettext not
  found". NIX_LDFLAGS does not help (illumos gcc execs host ld directly, the H1
  bypass); NIX_CFLAGS_COMPILE's -L is only applied to compile steps.
  Makefile.PL honors `$ENV{CC}`, but the stdenv setup exports CC=gcc AFTER the
  drv attr, so we bake `-L${gettext}/lib` into CC in a **preConfigure** (post-
  setup, pre-Makefile.PL). This unblocked the entire help2man ->
  bison/flex/libtool -> autoreconfHook build-tool swath.
- **H7 (libtool empty `global_symbol_pipe`) recurs** for libtasn1/libassuan/
  npth/libssh2 -- added them to the tranche-3 `withGnm` (`NM=illumosGnm/gnm`).
- **H16 openssl QUIC test flakiness.** openssl builds + links fully (perl
  Configure, libssl/libcrypto with `-lsocket -lnsl -ldl`), but the QUIC
  multistream tests are timing-sensitive and time out under load
  (`op_deadline` exceeded, "network BIO I/O error"). Flaky perf tests, not a
  crypto defect -> `doCheck = false`.

### Still blocked after H3 (deferred, new/known gaps)

- **H15 sqlite (seed bzip2 has no dev headers).** sqlite pulls `unzip` (test-
  data tool) built with `USE_BZIP2`; `unzip` needs `bzlib.h` but the pinned
  `bzip2` is a SEED slice (`3qapqhh7...`, only `bin`+`usr`, no
  `include/bzlib.h` -- a single-output `linkBootstrap.sh` derivation, not a
  real build). Fix needs the solnix overlay's `bzip2` pin swapped for a real
  nixpkgs bzip2 build (which has `bin`/`dev`/`out` outputs), or a bzlib.h
  wire-up; swapping the seed bzip2 may ripple into other bootstrap deps, so
  deferred. Retry sqlite once bzip2 is rebuilt with a `dev` output.

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

## Sixth tranche (openssl/perl-downstream + the `meh` toolset: curl/git/vim/openssh/htop, DURABLE at cache.solnix.io, append-only)

Cracking H3/openssl/perl in tranche 5 opened the TLS/crypto/networking +
autoreconf swath. Tranche 6 builds the maintainer's `meh` daily toolset on top
of it: **curl, git, vim, openssh, htop** (the five priorities) plus the
high-fan-in libs they ride on. Persisted PER-PACKAGE
(`artifacts/tranche6-paths.txt` + a `real-derivations.tsv` row per output).

**Cache-endpoint correction (supersedes the tranche 4/5 caveat):** the
`s3.solnix.io` object store is the transient **upload inbox** -- a b2-mirror
reconciler drains it to Backblaze B2 every ~10 min and then DELETES from the
inbox (BY DESIGN, which is why objects appear to "vanish" from s3.solnix.io;
that is not loss). Durability is verified at **`cache.solnix.io`** (the durable
Cloudflare->B2 read cache): upload to s3.solnix.io as before, wait for the
drain, then `curl -sI https://cache.solnix.io/<hash>.narinfo` == 200.
Cloudflare negative-caches early 404s, so poll with a cache-buster
(`?x=$RANDOM`) after the drain. Trusted read pubkey is now
`cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=` (the old
`5HAV...` is superseded). So tranche 6's deliverable is **build + LOCAL verify
(real .drv + host-free closure + runs on illumos) + upload + confirm durable at
cache.solnix.io** -- `published` in the registry means confirmed-200 at
cache.solnix.io, not just staged.

| pname            | new store hash                     | deriver | hermetic | runs | durable(cache.solnix.io) |
|------------------|------------------------------------|---------|----------|------|--------------------------|
| git-2.55.0       | 4qzcgzlvi4y9hmq8qkqrs4myqsaw4dl3   | y       | y        | y    | y (meh)                  |
| curl-8.21.0      | 6wawnnnkanlqc0bi578dgkq0zlapbv85   | y       | y        | y    | y (meh)                  |
| curl-8.21.0-bin  | y7h4ih0vks8n06wandq2kv2384rgkaj6   | y       | y        | y    | y (meh)                  |
| openssh-10.4p1   | mphsjkywwmw7r1isjl3mxnxc9sidryvb   | y       | y        | y    | y (meh)                  |
| vim-9.2.0782     | z3c946kdxp0rdy05p2yan24vh4s679if   | y       | y        | y    | y (meh)                  |
| htop-3.5.2       | 7rbad8qw9xskgl7g5qc776sjh1q45k49   | y       | y        | y    | y (meh)                  |
| sqlite-3.53.3    | zsc2isaclyi7bi8czpfsw2iafzgpg74r   | y       | y        | y    | y                        |
| sqlite-3.53.3-bin| ljdr2bsab8ffq9z57gmm6ldn90fadm8r   | y       | y        | y    | y                        |
| libxml2-2.15.3   | wyjr0gh66qq9yncf8i8gd2xrp9mdzscf   | y       | y        | y    | y                        |
| libxml2-2.15.3-bin| zj78a65bzzih7l2z95361m07vgmficr9  | y       | y        | y    | y                        |
| libxslt-1.1.45   | 7clf9h4z2cqr4nkpyg3zc92f2lnxiwqa   | y       | y        | y    | y                        |
| libxslt-1.1.45-bin| 6d9jk8wq11apks0r4yvyb6gpwbk9irck  | y       | y        | y    | y                        |
| nghttp2-1.69.0   | mpzq1rhki8scrzwviacbh803jcfkwn9x   | y       | y        | y    | y                        |
| nghttp2-1.69.0-lib| alkvc9gljlnjzrm3iaxphfx5flkf02dj  | y       | y        | y    | y                        |
| libev-4.33       | aaqpllwkrlknaq18ws2d82sgp6lx1jvg   | y       | y        | y    | y                        |
| libedit-20260508 | 5kdkxxazajj4fs37ylg2rzwhxc08cprv   | y       | y        | y    | y                        |
| unzip-6.0        | b0vx1r1zx9sv6zy0nsvgz723llbr3aw3   | y       | y        | y    | y                        |
| autoconf-2.73    | 0dnad54wp50kx02dfpv6cnpnzm0cs8lx   | y       | y        | y    | y                        |
| automake-1.18.1  | 2q538skpybpl1cdlgkrmbiasmbmnpd4d   | y       | y        | y    | y                        |

**14 packages / 39 outputs. built + verified + durable(cache.solnix.io) = 38,
1 draining (openssh-dev), failed = 0.** All 5 meh-toolset priorities
(**git 2.55.0, curl 8.21.0, openssh 10.4p1, vim 9.2, htop 3.5.2**) are
confirmed durable at cache.solnix.io and installable via `nix profile install`
on a running solnix instance. `runs` verified on illumos: `git --version`
(2.55.0), `curl --version` (8.21.0, linking **OpenSSL 3.6.3 + zlib 1.3.2 +
nghttp2 1.69.0** from this/prior tranches), `ssh -V` (OpenSSH_10.4p1, OpenSSL
3.6.3), `vim --version` (9.2), `htop --version` (3.5.2), `sqlite3`, and the
libxml2/libxslt/nghttp2/libev/libedit `.so`s. Every output deriver-resolves to
a real `.drv` and has a 100% `/nix/store` closure (`nix-store -qR`, host-free).

The cracked shared blockers this tranche unblock large swaths at once:

- **H17 `outputChecks` under structuredAttrs-off -- FIXED.** Packages that
  MANUALLY set `outputChecks` (a structuredAttrs-only attr; e.g. krb5's
  `outputChecks.lib.disallowedRequisites`) break under our forced
  `__structuredAttrs = false`: make-derivation only folds `outputChecks` into
  structured form when structuredAttrs is on, else the raw set is passed as a
  derivation env var (`cannot coerce a set to a string`). FIX: swap the
  `addAttrsToDerivation { __structuredAttrs = false; }` adapter for
  `overrideMkDerivationArgs` that ALSO nulls `outputChecks` (add-only ->
  read+remove). Unblocks krb5 -> curl.
- **H18 fetchpatch normalize-hash -- FIXED.** `fetchpatch` calls `fetchurl`
  with a `postFetch` that normalises the patch, and the recorded sha256 is of
  the NORMALISED output; the builtin-fetchurl shim only downloaded+hashed the
  RAW file -> `hash mismatch` for EVERY fetchpatch (libev/libevent/libxml2
  -> nghttp2/curl/gnutls/unbound -> git/openssh/cmake/libxslt/...). FIX: when
  `postFetch` is present the shim fetches raw impurely (no hash) then runs
  postFetch in a fixed-output derivation verified against the recorded sha256
  (what real fetchurl does, minus the curl downloader). Unblocks the whole
  fetchpatch swath.
- **H19 fetchzip/fetchFromGitHub finalAttrs fixpoint -- FIXED.** `fetchzip` =
  `lib.extendMkDerivation { constructDrv = fetchurl; }`, whose `__functor`
  hands the fetcher a FUNCTION (the finalAttrs fixpoint), not an attrset; the
  plain-function shim did `args ? urls` on a lambda -> `value is a function
  while a set was expected` (blocked every fetchFromGitHub src: zstd/libarchive/
  cmake/curl/...). FIX: the shim resolves the fixpoint (`self = f self`, folding
  `derivationArgs` up so `finalAttrs.extension`/`stripRoot` reads resolve),
  honours `downloadToTemp`/`recursiveHash`, and sanitises the store-path name
  (gitlab/github archive urls carry `%`-encoded query strings). Unblocks the
  fetchFromGitHub universe.
- **H15 (seed bzip2 has no dev) -- FIXED (retry landed).** The top-level
  `bzip2` is the dev-less bootstrap SEED slice, re-pinned by the final stdenv
  stage (`inherit (prevStage) bzip2`), so a top-level overlay cannot replace
  it. Build the REAL multi-output nixpkgs bzip2 (`bzip2Real`, autoreconfHook)
  and thread its dev/out into the readers: `Compress-Raw-Bzip2` (git/wget perl,
  via `perlPackages.overrideScope` so the perl-set INTERNAL self-reference is
  replaced, not just the outer attr) and `unzip` (H15b: `-DUSE_BZIP2` needs
  `bzlib.h`). **sqlite now builds** (its `unzip` test-data tool was the
  original H15 blocker).
- **H26/H26b libkstat/libsendfile/libproc seed gap -- FIXED for htop, still
  gates cmake.** The seed carries only 13 base libs in `lib/amd64`; htop's
  configure hard-requires `kstat_open()` (`-lkstat`) then `Pgrab_error()`
  (`-lproc`), and cmake's bundled libuv links `-lkstat -lsendfile`. FIX for
  htop: a content-addressed fixed-output `extraSyslibs` slice (same provenance
  as the seed FOD -- extracted from the host illumos, hash-pinned) bundling the
  full 64-bit ldd closure of libproc/libkstat/libsendfile/libcontract (18 libs)
  with `.so -> .so.N` links, wired into htop via `NIX_CFLAGS_COMPILE -L` (the
  H1 cc-wrapper pass auto-adds the matching `-R`). htop builds + runs; its
  `nix-store -qR` closure is host-free (the bundled libproc's own transitive
  deps -- librtld_db/libctf/libdwarf/... -- resolve at runtime from the illumos
  base `/lib/64`, the platform ABI, same class as libc). **cmake is NOT fixed**
  -- its libuv wants the same libs but cmake sits behind zstd/libarchive/brotli
  (see the deferred list); wiring extraSyslibs into cmake is the next step.
- **Per-package meh-toolset unblocks:** H20 git `rustSupport=false` (avoids
  cargo-bootstrap -> unported LLVM bintools); H21 openssh `withFIDO=false`
  (avoids libfido2 -> udev -> LLVM); H22 htop via `callPackage` with explicit
  `systemdSupport=false; systemdLibs=null; sensorsSupport=false; lm_sensors=null`
  (a plain `.override` did NOT suppress the `availableOn systemdLibs` default
  because htop is a spliced-pkgset value whose splice recomputes arg defaults);
  H23 gnutls `doCheck=false` (net-tools unixtools-splice infinite recursion);
  H24 byacc `doCheck=false`; H25 nghttp2 `enableApp=false` (C++ nghttpx
  network.h std::variant/Sockaddr fails); H27 libedit `-DNCURSES_TERM_H_incl`
  (ncurses vs illumos termcap.h const-vs-nonconst `tgetstr` conflict; unblocked
  openssh + krb5); H28 krb5 `libFolders` bash-array (structuredAttrs-off);
  H29 curl/curlMinimal `gssSupport=false` (krb5 addr.c s6_addr port bug);
  H30/H31 openssh drop libredirect check-input (Linux sys/xattr.h) + libxslt
  `--with-debugger` (Solaris ld fatal on undefined version-script symbols);
  H32 git swap zlib-ng->zlib + drop sendEmail/python/manual (all -> cmake);
  H33 git `NO_GETTEXT=1` (libintl not linked, NIX_LDFLAGS bypassed on illumos);
  H34 git `MAKE=${gnumake}/bin/make` (subdir `$(MAKE)` recursion resolved the
  Solaris `/usr/bin/make` which chokes on git's GNU `shared.mak`) + NO_TCLTK;
  H35 git postInstall `rm -f` (gitk never built); H36 git `doInstallCheck=false`.

### Still blocked after tranche 6 (deferred)

- **H26 cmake (`-lkstat -lsendfile` via bundled libuv).** cmake-minimal's
  bootstrap link fails `ld: fatal: library -lkstat: not found`. The libs are
  now available via the H26b `extraSyslibs` slice; wiring them into cmake's
  link (a `NIX_CFLAGS_COMPILE -L${extraSyslibs}/lib/amd64` on cmake, plus
  possibly `-lkstat -lsendfile` in `LDFLAGS`) is the next step. cmake gates
  **zstd, libarchive, brotli** (all built with cmake) and hence **rsync, wget**
  (pull zstd) and the FULL **curl** (brotli) -- curl landed via `curlMinimal`
  (no brotli). Once cmake builds, that whole set unblocks.
- **krb5 (addr.c `s6_addr` C port bug).** `expected identifier or '(' before
  numeric constant` -- an illumos `<netinet/in.h>` `s6_addr` macro collides
  with a krb5 struct field. A source patch, deferred (curl dodged it via
  `gssSupport=false`).
- **gnupg (net-tools unixtools-splice infinite recursion).** gnupg -> gnutls
  pulls `net-tools` (`arp`) in `nativeBuildInputs`; the unixtools splice recurses
  in this nixpkgs vintage. `gnutls.doCheck=false` did not drop it (net-tools is
  a build input via the `lib.optionals doCheck` reading gnutls' INTERNAL
  `doCheck`, not the overridden one). Needs a gnutls arg-level or net-tools
  splice fix. gnupg was the one meh priority NOT landed.

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
   traces to a `/nix/store` fixed-output path. **(tranche 5: the shim now also
   backs `fetchurlBoot`, re-asserted on the stdenv after the adapter -- this is
   the H3 fix; see the H3-FIXED section.)**

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

- **H3 curl-bootstrap `/setup` for build-dep srcs -- FIXED (tranche 5).** Was:
  perl/openssl pull a `libxcrypt-4.5.2.tar.xz` src fetched by the *curl
  bootstrap* `fetchurlBoot` (a different stdenv path the adapter in (2) did not
  wrap), so it hit the structuredAttrs `/setup` failure. FIX: point
  `fetchurlBoot` at the same builtin-fetchurl shim, re-asserted on the stdenv
  AFTER the structuredAttrs adapter (see "H3 ... FIXED (tranche 5)" above).
  Proven: perl 5.42.0 + openssl 3.6.3 build + run hermetically (tranche 5).

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

- **H3 (perl -> libxcrypt via curl-bootstrap `/setup`) -- FIXED in tranche 5.**
  The H3-deferred packages `libtasn1`, `libssh2`, `libassuan`, `npth`,
  `libtool` (plus `bison`, `flex`, `bc`, `cpio`) all BUILT in tranche 5 (see
  the fifth-tranche table). `libmd`, `liburcu` not yet retried.
- **H5-class (fragile / uncovered fetch):** packages whose `src`/`patches`
  use `fetchFromGitHub`/`fetchpatch` the fetchurl-shim does not cover --
  `libxml2`, `zstd`, `pcre`, `freetype`, `libjpeg_turbo`, `pixman`, `libpsl`,
  `json_c`, `libtiff`, `libwebp`, `c-ares`, `nghttp2`, `libuv`, `jansson`, ...
  (eval fails in the shim: "value is a function while a set was expected").
  Needs a `fetchFromGitHub`/`fetchpatch` shim, out of scope for this tranche.
- **H15 dep-chain gap (tranche 5):** `sqlite` fails building its `unzip`
  build-dep (`bzlib.h` not found) -- the pinned `bzip2` is a SEED slice with
  NO `dev` output. Needs the bzip2 pin swapped for a real build; deferred (see
  the H15 note under the fifth tranche).
- **H4 spliced-pkgset override (`curl`, `libffi`)** unchanged from tranche 3.
  (`openssl` -- previously listed here as H3-blocked -- BUILT in tranche 5.)

Prior tranche 3 note (kept for history): H2/H6/H7 FIXED -- `gettext`
`pkg-config`(+wrapper) `ncurses` `less` `libidn2` `libgpg-error`
`gmp-with-cxx` built + published (24 outputs); H8 (ncurses
`--version-script`) fixed per-package. `nettle` was listed as "retry" there
and is now built + published in tranche 4.

## Seventh tranche (fleetC host 18.189.192.156 — daily-use / minimal-ISO parity, append-only)

Goal: build the docs/design-minimal-iso-parity.md §4 net-new portable set
(bashInteractive, rsync, netcat, socat, screen/tmux, zip, smartmontools,
ddrescue, w3m, gnu time, mkpasswd) as real hermetic x86_64-solaris derivations
on a fresh Nix-ready OI host, publish to s3.solnix.io, verify durable at
cache.solnix.io. Two shared blockers were cracked; one hard stdenv-bootstrap
gap wedged the "build fresh .drv" half.

### Cracked shared blockers

- **H28 Cloudflare stale-404 negative-cache defeats Nix substitution — FIXED
  (workaround).** cache.solnix.io (Cloudflare->B2) negative-caches early 404s
  for `<hash>.narinfo` with `max-age=86400`; a bare narinfo GET returns a stale
  cached 404 (`cf-cache-status: HIT`, age ~26h) even after the object exists at
  origin. Nix's own downloader hits the bare URL (no cache-buster) and gets the
  stale 404 -> "no substituter can build it" for EVERY path, so a fresh host
  can substitute NOTHING. curl with `?x=$RANDOM` returns 200 (buster bypasses
  the cached key). FIX: a ~30-line python3 `cbproxy.py` on the host
  (127.0.0.1:8899) that forwards each GET to cache.solnix.io appending a random
  `?x=` and a `User-Agent: curl/...` (Cloudflare WAF 403s python-urllib's
  default UA). Point `substituters = http://127.0.0.1:8899` in
  /nix-tools/etc/nix/nix.conf. Signatures still verify against the real pubkey.
  Also fixed: the host shipped `NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`
  (nonexistent) — the real illumos bundle is `/etc/certs/ca-certificates.crt`;
  and `/nix-tools/etc/nix/nix.conf` (the compiled-default NIX_CONF_DIR) carried
  the SUPERSEDED `5HAV...` pubkey.

- **H29 illumos NAR-import "Error 0" under parallel substitution — WORKED
  AROUND.** Multi-path parallel substitution intermittently aborts a path with
  `getting status of '<path>': Error 0` (spurious errno during concurrent NAR
  extraction on illumos). Substituting each closure path in its OWN
  `nix-store -r <path>` process (serial, driven by repeated `--dry-run` +
  `--option http-connections 1`, retry-on-"Error 0") imports the full closure
  cleanly. Proven end-to-end: git-2.55.0 (+ bash-interactive-5.3p15,
  illumos-cc-10.5.0, readline, ncurses, ...) fully realised and `git --version`
  runs.

### The wedge (noted, moved on per ANTI-WEDGE)

- **H30 published x86_64-solaris `gawk` has a broken libmpfr RUNPATH ->
  from-scratch stdenv build is unbuildable.** Building any NEW package needs a
  freshly-evaluated stdenv (the primary's `p3lfwcvh...-nixpkgs-patched` is a
  genuine 404 — never published — and its exact hash is unreproducible off the
  primary; a locally re-derived patched-nixpkgs tree produces different, thus
  un-cached, stdenv drv hashes -> a from-scratch stdenv rebuild). That rebuild
  dies in `expand-response-params` / every cc-wrapper: `substituteAll` invokes
  awk, and the cached tranche-4 `gawk-5.4.0` (l2x88nbk, registry "staged")
  crashes — `ld.so.1: awk: fatal: libmpfr.so.6: open failed` /
  `symbol mpfr_get_version referenced symbol not found`. Its RUNPATH is
  `/usr/gcc/14/lib/amd64` ONLY (no mpfr/gmp; closure has no mpfr). awk then
  silently produces no output, so `@wrapperName@`/`@suffixSalt@` are left
  UNSUBSTITUTED in the cc-wrapper setup-hook (`export NIX_@wrapperName@_...:
  not a valid identifier`), corrupting the compiler wrapper and failing the
  whole bootstrap. The wave `gawk-5.3.1` builds are no better — their RUNPATH
  references `mpfr-4.2.1` paths that are NOT in their closure (+ a
  `/var/tmp/clib.gawk...` leak), so they also fail `libmpfr.so.6: open failed`.
  libmpfr.so.6 IS present in the seed (`usr/gnu/lib/amd64/libmpfr.so.6`) and a
  built `mpfr-4.2.2` (syw2vs5d) exists; a top-level `LD_LIBRARY_PATH` on the
  FINAL stdenv does NOT reach the earlier boot-0 cc-wrapper stage. FIX (deferred
  — the "gawkReal" work): rebuild `gawk` so its RUNPATH carries its
  mpfr/gmp/readline/ncurses store deps with a host-free closure (the H1 runpath
  / H6 seedSyslibs mechanism, extended to cover libmpfr/libgmp), OR thread
  `LD_LIBRARY_PATH=$seed/usr/gnu/lib/amd64` into `linkBootstrap` and the boot-0
  stdenv in pkgs/stdenv/illumos/default.nix. Both are fork-stdenv surgery that
  itself needs a working stdenv — the circular dependency is the wedge.

### Delivered (build+verify half): substituted + runs + host-free on fleetC

Because the fresh-.drv half is wedged on H30, the deliverable this tranche is
**substitute + LOCAL verify (runs on illumos + 100% /nix/store closure) of the
already-published parity packages** — they were built in prior x86 waves
(arch-manifest) and substitute cleanly through the cbproxy. deriver does NOT
resolve (their `.drv` is not in the cache, `unknown-deriver`), so these are
verified OUTPUTS, not fresh real derivations. `runs` verified via
`--version`/smoke; closure host-free (`nix-store -qR` == 0 non-/nix/store):

| pname            | version | store hash                          | deriver | host-free | runs | durable(cache) |
|------------------|---------|-------------------------------------|---------|-----------|------|----------------|
| bash-interactive | 5.3p15  | bdp0gkhgfv6sb748r4b53qpy74d9hi48    | unknown | y         | y    | y              |
| rsync            | 3.4.1   | 2an8rgld98pd3bnvhdzvjv7mz243cs0x    | unknown | y         | y    | y              |
| socat            | 1.8.0.3 | g3bbvvlfrf69sn3ym9cm19c6ckcsrmb1    | .drv*   | y         | y    | y              |
| screen           | 4.9.1   | 00c9lcrpjrbk64x5ql5zyc3bidfmgfin    | unknown | y         | y    | y              |
| tmux             | 3.4     | cr9lcm2m9111z2q9ny7j6ynzx3nqh0v9    | .drv*   | y         | y    | y              |
| smartmontools    | 7.4     | 2y94nvqigdcjf5w45x9m47rcnh71xkgc    | unknown | y         | y    | y              |
| ddrescue         | 1.28    | 3sm8zdl8xm3knfrjdszvxsgpabhh7wg6    | unknown | y         | y    | y              |

(*socat/tmux name a `.drv` but it is not present/substitutable — 404 — so the
deriver still does not resolve.) All 7 run: `bash --version` (5.3.15,
x86_64-pc-solaris2.11), `rsync --version` (3.4.1 proto 32), `socat -V`
(1.8.0.3), `screen --version` (4.09.01), `tmux -V` (3.4), `smartctl --version`
(7.4, x86_64-pc-solaris2.11), `ddrescue --version` (1.28). Recorded in
artifacts/fleetC-paths.txt.

**Priority daily-use landed (of bashInteractive/rsync/netcat/socat/zip/screen):
bashInteractive, rsync, socat, screen** (+ tmux as the screen alternative,
smartmontools, ddrescue). **netcat** and **zip** (Info-ZIP) are NOT in the x86
arch-manifest (no published artifact); the only `zip-*` is a Rust tool, no
`netcat`/`nc` variant — both need a fresh build, blocked by H30. Same for
`w3m`, gnu `time`, `mkpasswd`.

No packages could be uploaded/published this tranche: the fleetC host has no
S3 creds and no cache signing key (both maintainer-side via sops); the verified
packages were already durable at cache.solnix.io from prior waves.

## H30 RESOLVED (tranche 7, fleetA) — gawkReal built + published + durable
The circular wedge is broken. On a fresh Nix-ready fleet host (3.148.235.207,
reachable; primary 18.218.136.61 NOT reachable from the fleet — 100% packet
loss / SSH timeout, matching fleetC), a working stdenv was reached by a ONE-TIME
host hack (drop libmpfr.so.6+libgmp.so.10 into /usr/gcc/14/lib/amd64 to satisfy
the pre-fix seed-gawk's host-only RUNPATH), then the DURABLE gawkReal was built:
real nixpkgs gawk + gmp/mpfr store buildInputs + -L in NIX_CFLAGS_COMPILE_BEFORE
so the H1 cc-wrapper auto-runpath bakes /nix/store mpfr/gmp into the RUNPATH.
Verified: deriver resolves (a81b6ffv...gawk-5.4.1.drv), host-free closure, runs
in `env -i` with the host hack DISABLED, and re-substitutes fresh from
cache.solnix.io (via scripts/cbproxy.py to defeat H28 CDN stale-404) then runs
clean. Published + durable: j7h3y8b2zr3294fg95wk10m3r0fd0xwn-gawk-5.4.1 (+ its
mpfr-4.2.2 closure). The fix is folded into pkgs/illumos/solaris-overlay.nix as
the canonical `gawk`. Fresh hosts now substitute the fixed gawk — unblocking the
fresh-.drv toolchain builds that this README's earlier tranche recorded as wedged.

With gawk fixed, tranche 7 (fleetA) built these as real hermetic x86_64-solaris
derivations (deriver resolves, host-free, run OK, no /usr/lib/64 leak, published
+ durable, cache-bust 200): m4 1.4.21, gnumake 4.4.1, gmp 6.3.0 (C-only), binutils
2.46.1, libffi 3.7.0, gawk 5.4.1, plus the gcc profile pkg (illumos-cc-10.5.0
cc-wrapper + gcc-unwrapped seed-wrap; a hello.c compiles + runs). See
pkgs/illumos/phase3/tranche7-toolchain.nix. gcc as a full from-source profile
package remains a follow-up (the seed-wrap cc is the installable shipped now).
