# aa64nix: an aarch64 solnix AMI whose nix and tools are real derivations

Track aa64nix, 2026-10-26. Account kiwi (437803535746), us-west-2. Kernel: aa64f b2, unchanged
(docs/aarch64-serror-result.md). Brief: /scratch/solnix/briefs/aa64nix.md.

## Route: native on c6g.metal, bootstrapped from braich gcc14 (route.md has the evidence)

Cross-building (a) would have given nothing for free: of nix-src.nix's 15 deps, the cache's 83 aarch64
outputs hold only a static zlib. Five (boost, libarchive, editline, libgit2, toml11) have no aarch64 cross
entry at all. The cross waves are static-only, and no cross C++ shared library had ever run on aarch64. So the box
builds itself, the way x86 bootstrapped from its IPS seed:

1. stage0: braich (pkg.omnios.org/bloody/braich) developer/gcc14 plus nix's C deps, laid over the aa64f-b2
   image with gate files winning. nix 2.24.15 goes into /opt/nixboot. Bootstrap only, never shipped.
2. That nix builds `pkgs/illumos/aarch64/default.nix` (`system = "aarch64-solaris"`): gcc 14.3.0 from
   richlowe/gcc il-14_3_0-arm64 (upstream gcc has no aarch64-solaris target; the fork already carries OmniOS's
   0032 _TS_ERRNO patch), then zlib, openssl, the whole nix-src.nix chain, git, the tools, and a system toplevel.
   They use the same recipes as x86 (mk-src-pkg.nix, nix-src.nix, bsdfetch.nix, nvi2.nix, db1.nix), with an
   `aarch64 = true` text rewrite. All x86 drv hashes are unchanged (nix 8czyjrv4, gcc 50l700gr, zlib j3l30q6x,
   openssl 5da6dih6, bsdfetch 26xjlj3f).

## Fixes found (each measured)

| symptom | mechanism | fix |
|---|---|---|
| every C++ throw on the image calls terminate | the image's /lib/libgcc_s.so.1 (Oct 21 braich-root copy) is an older unwinder. A/B: new libgcc_s + old libstdc++ = OK; old libgcc_s + new libstdc++ = abort | the image gets the store gcc's libgcc_s |
| `R_AARCH64_TLSDESC_* relocation not currently supported` (libnixutil.so) | the illumos aarch64 ld has no TLSDESC | `-mtls-dialect=trad` (the arm64-gate harness's target flag) |
| undefined `__aarch64_ldadd4_acq_rel` etc. | outline atomics live in static libgcc.a, which this shared link does not pull | `-mno-outline-atomics` (harness pair) |
| illumos `elfedit` segfaults on libstdc++ | GNU strip 2.43.1 zeroes `.SUNW_ldynsym` sh_link on aarch64. Unstripped: OK; elfedit then strip: OK | aarch64 builders rewrite RUNPATH before stripping |
| `undefined macro: AC_DEFINE` from autoreconf | aclocal had no pkg.m4, so PKG_CHECK_MODULES leaked unexpanded | `-I` pkgconf's aclocal dir |
| `cannot guess build type` | config.guess predates aarch64-solaris | `--build=aarch64-unknown-solaris2.11` |
| openssl 3.4.0 has no target | (none upstream) | `solaris64-aarch64-gcc` conf (as solnix-pkgs wave4) |
| mkfs pcfs: `/boot/pmbr` missing, then "bogus" | mkfs_main.c verify_bootblkfile wants a jump opcode + 0x55AA | a synthetic sector, only for that mkfs, then removed |

## What booted

Image 1 (nix + curl + git + tree; raw 35f2c8de): 3 of 3 fresh c6g.metal launches pass checks 1-4. Those are
b1 and b2 from the kiwi AMI ami-00feb41451bdaea81, and sa1 from the solnix-ami copy ami-03bcedf8daedd79df.
- 1: `nix (Nix) 2.24.15`, an aarch64 ELF at /nix/store/79ds37sw..-nix-2.24.15 (deriver vbkdpcia..-nix-2.24.15.drv).
- 2: /run/current-system -> /nix/var/nix/profiles/system -> system-1-link -> /nix/store/z87z9zfz..-solnix-system-aarch64,
  deriver q54w62az..drv.
- 3: `scripts/ami-registry-check.sh` gives REGISTRY_FETCH_OK 9ba643493e75, with no /usr/bin/git on the image, so the
  store git was used. Negative control on m1: with no git on PATH it prints REGISTRY_FETCH_FAIL "revspec '26.11' not found".
- 4: a local nix-build of a trivial derivation outputs `aarch64`, and its deriver is a .drv.
Image 2 (all eleven tools, raw 91cdc529): 2 of 2 fresh launches (c1, c2) pass checks 1-4. toolrun.sh got 10/11 RUN OK
on both; wget failed TLS verify 2/2. Mechanism: the store openssl's OPENSSLDIR is /etc/openssl, and the image had no
/etc/openssl/cert.pem.
Image 3 = image 2 + /etc/openssl/cert.pem -> the store CA bundle (raw 7a675b71). This is the deliverable,
**solnix-ami ami-07fbc4867d02c9b2b** (us-west-2, private). From the solnix-ami copy, 2 of 2 fresh launches (d1, d2) pass
checks 1-4, and toolrun.sh got 11/11 RUN OK (curl wget fetch git tree top htop nano vi nvi man). Negative control on d1:
removing the link gives wget rc=5, restoring it gives rc=0.
Boot rate over all 7 aa64nix launches: 7/7 reached ssh on cycle 2 (the boot-archive self-reboot is cycle 1, about 20 min
to ssh). x86 note, unverified: x86's openssl has the same --openssldir=/etc/openssl, and nothing in modules/ creates
/etc/openssl/cert.pem, so check `wget https://...` on the x86 DP AMI.

## Not done / remaining

- The module-system toplevel (`solnixConfigurations.*` with modules/system/activation) is not built for aarch64.
  activation/default.nix hard-codes i86pc/amd64 paths, and there is no aarch64 world/early/stock/kernel slice. This
  toplevel is pkgs/illumos/aarch64/system.nix: a real derivation with sw/bin + etc/nix, no SMF generation, no
  switch-to-configuration. The base OS under /usr is still the aa64f gate image (pkg/braich), not store slices.
- install-be/generations: one generation, laid in by aa64nix-img.sh (store copy + `nix-store --load-db`, as
  NixOS's make-disk-image does). There is no `solnix-rebuild`.
- nix is single-user (no nixbld users, no nix-daemon SMF service). man is the gate's /usr/bin/man reading
  sw/share/man.
- Kernel: still aa64f b2 with its observers (console after consconfig still goes through the aa64e observer).
  Not touched here.
- stage0 shortcut: mk-src-pkg's aarch64 path names the stage0 box's /opt/nixboot and /opt/ooce (pkgconf,
  autoconf-archive, cmake), as x86 names the OI host. Upgrade: make them store build tools.
