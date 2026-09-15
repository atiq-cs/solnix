# The solnix cache is incomplete for every shipped config, independently of libxml2

Measured on `ami-0cb14e40f9355bd0c` (`i-0b23ab91b125c8fef`), Nix 2.24.15,
against `https://cache.solnix.io`, one narinfo request per store path. This is a
**publishing gap**, and it is a different problem from the libxml2 wall — see §4
for which one blocks what.

## 1. The table

Every package `configurations/base.nix` and `configurations/dixi.nix` name, with
the HTTP code for its own narinfo and for each of its `References`:

| pkg | hash | own narinfo | broken references (404) |
|---|---|---|---|
| `coreutils` | `3wlwvk71i6dfwiq63kdakq02fig8m68p` | **404** | — |
| `file` | `7bnpc66nfnr7gvn6nfm5x42pvnzfifdv` | 200 | none |
| `gnugrep` | `d9zrp2hjgbdq8gv0b2gi46pdlq88qyp7` | 200 | none |
| `gnused` | `mky1cdsy45vkbb60qlwnhkkywnwnyhh6` | 200 | none |
| `bzip2` | `3qapqhh7ka0rjcvm4sxawjcscy82n631` | 200 | none |
| `xz` | `yc2lxizi541jv5ifja06kkl0nf936wjd` | 200 | none |
| `zlib` | `v3ifdyma44ihb9ibj0dg5v6daxamr914` | 200 | none |
| `pcre2` | `5f5vlcfg511sh4zfi6ij3zjk95f2bwyf` | 200 | none |
| `nvi` | `svbm1pzk9a2211mhw93aaa9a721kzsn3` | 200 | **`ncurses-6.6`** |
| `which` | `72787vna9g4zl9bhps4v0cf0mrs6wzis` | 200 | none |
| `gdb` | `sbxd5iyih5sgqmsdnl04k4qivqxkqg0q` | 200 | **`ncurses-6.6`, `readline-8.3p3`** |
| `git` | `4qzcgzlvi4y9hmq8qkqrs4myqsaw4dl3` | 200 | **`pcre2-10.47-dev`, `coreutils`, `openssl-3.6.3-dev`, `openssl-3.6.3`** |
| `curl` | `y7h4ih0vks8n06wandq2kv2384rgkaj6` | 200 | **`openssl-3.6.3`** |

8 of 13 are fully fetchable. 5 are not.

## 2. The failure shape, which is why this was not already known

**Only `coreutils` is itself absent.** The other four return **200 for their own
narinfo** and fail on a *reference*. So any check that asks "is this package in
the cache?" answers yes for `nvi`, `gdb`, `git` and `curl` — and the build then
fails, because Nix needs the whole closure.

`coreutils` is already recorded in this repo's own
`docs/registry/AUDIT-cache-unfetchable.tsv`. The other four are not, and could
not have been found by the same method: the audit that produced that file checked
paths, not closures.

The distinct missing paths are only four:

```
ncurses-6.6        blocks nvi, gdb
readline-8.3p3     blocks gdb
openssl-3.6.3      blocks git, curl   (+ -dev)
pcre2-10.47-dev    blocks git         (note: pcre2 ITSELF is 200; the -dev output is not)
coreutils          blocks coreutils, git
```

`pcre2` is worth singling out: the runtime output is published and the `-dev`
output is not, so a package that references `pcre2-dev` fails while `pcre2` looks
present. Multi-output derivations need every *referenced* output published, not
just the default one.

## 3. Two further traps found in the same measurement

**A third signing key.** Substitution initially failed with
`ignoring substitute for '…-illumos-seed-unpacked' … not signed by any of the keys
in 'trusted-public-keys'`. The repo knows two keys
(`5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk=`,
`8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=`); the cache is signing with a
third that appears nowhere in the tree. Confirmed by fetching the narinfo
directly — `Sig: cache.solnix.io-1:Z6Bd5wU1g9GBUUTYg3h7aG6lD4AOSnLJw+…` — and by
`require-sigs = false` making the identical fetch succeed. **Whatever key the
publisher is using needs to be recorded in the repo**, or every fresh node needs
`require-sigs=false`, which defeats the point of signing.

**`which` has four registry rows**, three `staged` and one `published`, and the
`published` one is last. Any lookup that takes the first match gets a staged path
that was never pushed. The correct filter is on the `published` column, which is
what `starter.nix` does and what a hand-written probe easily gets wrong.

## 4. ⚠️ What this blocks, and what it does not — do not conflate these

These are two independent walls and only one of them is about the cache.

| | `libxml2.so.16` | cache gaps |
|---|---|---|
| what fails | `external-libs.drv` → `base-tools.drv` → `system-path.drv` → toplevel | `nix-instantiate` cannot even force `environment.systemPackages` |
| when | at BUILD | at EVAL (`builtins.storePath` forces a substituter check) |
| fixable by publishing? | **no** | **yes** |
| fixable by editing a config? | no | yes (drop the 5 names) |

**Repairing the cache would NOT make a solnix toplevel build.** With all 13
packages fetchable, the build still stops at
`FATAL: extraFile src missing (/usr/lib/libxml2.so.16)`, because `externalLibs`
copies that soname from the build host and the AMI has only `libxml2.so.2`
(2.13.9). That is measured, not inferred: I removed the unfetchable names from
the config, the eval then succeeded, and the build reached and failed on
`external-libs.drv`.

So the ordering is:

1. **`libxml2 >= 2.14` as a real derivation** is the hard prerequisite for a
   toplevel to build at all. Nothing in the cache changes that. The soname bump
   at 2.14 is a deliberate upstream compat reset, so no 2.13.x build can ever
   satisfy `.so.16`.
2. **Publishing the four missing paths** (`ncurses-6.6`, `readline-8.3p3`,
   `openssl-3.6.3` + `-dev`, `pcre2-10.47-dev`, `coreutils`) is what lets the
   configs *evaluate* as written, and is worth doing independently — it is cheap,
   it is a publishing action rather than a porting one, and until it happens
   `base.nix` and `dixi.nix` cannot be evaluated by anyone without hand-editing
   them.

Both are real. Neither substitutes for the other.

## 5. Reproducing

`scripts/cache-completeness-audit.sh` (this measurement, as a script). It reports
per-package and per-reference codes rather than a single verdict, because a single
verdict is exactly what hid four of these five for so long.
