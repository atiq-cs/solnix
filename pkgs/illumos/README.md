# solnix illumos world — GATE A/B/C proto slicing (standalone, host-side)

Standalone Nix expressions proving the **native world-build model** on the
illumos host: ingest the illumos-gate proto as a Nix store path (GATE A), slice
+ RUNPATH-relocate libc into its own store path (GATE B), and compile+link+run a
hello-world against that sliced libc (GATE C). Implements the first proto slice
of `docs/design-gate-derivation.md` (GATES A/B/C), verified end to end on the
host `illumos-960edb1c89`, gate `ac45d71fc2`.

These are **standalone** (plain `derivation` + bash, no nixpkgs `stdenv`/`lib`)
so they iterate fast against the host's Nix 2.3.16 (`currentSystem =
x86_64-solaris`, `sandbox = false`). They map 1:1 onto the fork's
`stdenvNoCC.mkDerivation` form — see "Fork mapping" below.

## Files

| file | role | design ref |
|---|---|---|
| `gate.nix` | GATE A: ingest `/code/illumos-gate/proto/root_i386` into the store via `builtins.path` | §1 (ingest variant; full build-FOD is a TODO) |
| `mk-illumos-component.nix` | slice N proto files into `$out`, relocate DT_RUNPATH+DT_RPATH with host `elfedit` ($ORIGIN + `selfLibDirs` `$out`-absolute + `depRunpaths` cross-component) | §2.3 |
| `default.nix` | wires `gate` + `libc` + `rtld` + `ld` + `sys` + `base-tools` + `systemPath` | §2.4 / §2.5 / §4.2 |
| `../../scripts/gate-c-hello.sh` | GATE C: compile+link+run hello vs the sliced libc; LD_DEBUG proof | §5 Step D |
| `../../scripts/oi-gate-slices.sh` | host driver for GATES A/B/C (gate + libc + hello) | §5 |
| `../../scripts/oi-world-slices.sh` | host driver for the core world slices (rtld, ld, sys, base-tools, systemPath) | §5 C–G |
| `../../scripts/oi-closure.sh` | ABI-aware transitive NEEDED-closure computer for `base-tools`' `baseToolLibs` | §2.4 / risk #5 |

## Run it (on the host)

```sh
# copy the .nix + scripts to /var/tmp/solnix-nix, then:
scripts/oi-gate-slices.sh     # GATES A/B/C: gate proto + libc slice + hello
scripts/oi-world-slices.sh    # rtld + ld + sys + base-tools + systemPath, gated
```

## Verified results (host, gate ac45d71fc2)

- **GATE A PASS** — `illumos-gate-proto` store path (491M) has
  `lib/amd64/libc.so.1`, `usr/include/`, `kernel/amd64/genunix`. Deterministic:
  two builds give the same store path.
- **GATE B PASS** — `illumos-libc` slice: `libc.so.1` + all 8 siblings
  (`libm.so.2 libsocket libnsl libresolv libelf libpthread librt libdl`) carry
  DT_RUNPATH `$ORIGIN:$ORIGIN/../lib/amd64:$ORIGIN/../../lib/amd64`. The proto
  libc had **no** RUNPATH originally; `elfedit` grows the dynamic section in
  place — no relink needed (de-risks design risk #1 for libc).
- **GATE C PASS** — `hello` runs; `ldd` + `LD_DEBUG=libs` show `libc.so.1` and
  `libm.so.2` binding from `/nix/store/...-illumos-libc/lib/amd64/`, nothing from
  host `/lib`.

## Core world slices — GATES rtld/ld/sys/base-tools/systemPath (host, gate ac45d71fc2)

All five build via `default.nix` on the host and PASS their gates. Store paths +
NAR hashes below (the store *prefix* moves when a dep hash changes; the NAR
content hash is what to pin). libc is now **ABI-complete** (64-bit `lib/amd64` +
32-bit `lib`), so it grew a new hash from the GATE-B libc.

- **rtld PASS** — `illumos-rtld` = `ld.so.1` (64+32-bit) + the libs it NEEDs
  (`librtld librld liblddbg`). `elfdump` confirms SONAME `/lib/amd64/ld.so.1`,
  `file` reports "dynamic lib … runtime linker". **Proof it functions as the
  interpreter:** a hello linked with `-Wl,-I,${rtld}/lib/amd64/ld.so.1` (its
  `.interp` = the sliced rtld) **runs** and prints output — the sliced ld.so.1
  loads the program and resolves the sliced libc. (De-risks design risk #6: rtld
  relocation is safe, not a no-op-or-harm.)
- **ld PASS** — `illumos-ld` = `usr/bin/ld` (+ `usr/bin/amd64/ld` alias) +
  `libld liblddbg libumem` (lib/amd64) + `libldstab` (usr/lib/amd64); `libelf`+
  `libc` come cross-component from the libc slice. **`$out/usr/bin/ld -V` prints
  `Software Generation Utilities - Solaris Link Editors: 5.11-1.1791 (illumos)`**.
  `ldd $out/usr/bin/ld` is **fully /nix/store-clean** — `libld/liblddbg/libumem`
  from the ld store path, `libelf/libc/libm` from the libc store path, **zero**
  host `/lib` or `/usr/gcc/10` refs (the proto's host-gcc RPATH leak is scrubbed).
  This is the first real CROSS-COMPONENT store-path RUNPATH, and **elfedit
  grow-in-place held** on it.
- **sys PASS** — `illumos-sys` = `platform/i86pc/kernel/**` (incl. `amd64/unix`)
  + `kernel/**` (incl. `amd64/genunix`). Kernel objects carry no userland
  `.dynamic`, so the relocation loop skips them and CTF survives `cp -a`
  verbatim: `ctfdump genunix` reads valid CTF (`cth_magic=0xcff1`, version 2,
  447 KB string table) and BOTH `genunix` and `unix` still have a `.SUNW_ctf`
  section. (De-risks design risk #4: CTF survives slicing.)
- **base-tools PASS** — `illumos-base-tools` = SMF core (`svcs svcadm svc.startd
  init`) + `sbin/sh` + coreutils-equiv (`ls cp mv cat rm mkdir ln`) + their full
  60-lib **ABI-aware transitive** NEEDED closure. **All 32-bit** (illumos ships
  SMF 32-bit only; keeping one ABI keeps the shared RUNPATH under the `.dynstr`
  ceiling — see risk #1 below). Every tool **runs from the store path** (svcs
  lists services, exit 0; svc.startd prints usage; ls/cat/… work). **ldd-clean:**
  10/12 tools bind every dependency to `/nix/store` (only `/usr/lib/ld.so.1`,
  the `.interp` interpreter, is a standard path — that is the rtld's job, not a
  RUNPATH leak). `svcs` + `svc.startd` additionally pull **libxml2 + ICU
  (libicuuc/libicudata) + libz + libstdc++/libgcc_s**, which are **NOT in the
  gate proto at all** (third-party IPS libs, reached via `libzonecfg`/`libtopo`
  → libxml2). That is a named P1.5 gap (below), not a slicing defect: every
  proto-shipped dependency resolves to the store.
- **systemPath PASS** — `illumos-system-path` symlink-farms `sys + rtld + libc +
  ld + base-tools` into one `/usr,/lib,/sbin,/kernel,/platform` tree. Spot-check
  passes (`lib/amd64/libc.so.1`, `lib/libc.so.1`, `lib/amd64/ld.so.1`,
  `usr/bin/ld`, `lib/svc/bin/svc.startd`, `platform/i86pc/kernel/amd64/unix`,
  `kernel/amd64/genunix` all present); `ls` runs from the composed tree.
  **Deterministic:** a rebuild yields the identical store path.

### elfedit grow-in-place — design risk #1 result

**Held on every real binary we shipped.** `elfedit -e dyn:runpath` updates BOTH
DT_RUNPATH and DT_RPATH (shared string offset) by appending to `.dynstr`; no
relink was needed for `ld`, `svcs`, `svc.startd`, `init`, `ls`, or any sibling
lib. **BUT the `.dynstr` grow ceiling is real and ~500–520 chars** (measured on
ld/svcs/svc.startd/ls/init — all the same). It materialized ONCE: a base-tools
RUNPATH that carried BOTH the 32-bit AND 64-bit lib subdirs (to include the sole
64-bit tool, `ksh93`) hit **612 chars** and `elfedit` failed with
`[0: .dynstr]: String table does not have room to add string`. Fix: drop
`ksh93` and keep base-tools single-ABI (32-bit) → RUNPATH 462 chars, fits with
margin. `mk-illumos-component.nix` now makes an elfedit failure **FATAL** (drops
a `relocfail` marker checked after the loop) so a too-long RUNPATH can never
silently ship an unrelocated, host-leaking binary. Upgrade path if a future
component needs a longer RUNPATH: relink the object with a longer `-R`, or (for
the image) a single shared store lib root so paths are short.

## New store paths + NAR hashes (this iteration)

| slice | store path | NAR (sha256) |
|---|---|---|
| gate | `/nix/store/y9d8x07cnxp9pyhb75v8bsd50cv6h98w-illumos-gate-proto` | `1nw4pd2kdr9f3ndyfyf1r9jr2432r9nsw9n8zbxwa4crg650dj1l` |
| libc (ABI-complete) | `/nix/store/70fpdjgcyhv73g8fpc2g6lpzcay1k948-illumos-libc` | `0k5xfk8xwndlj306qxb40dhinfcy4g4h95vmkklp8p28p76hvqxv` |
| rtld | `/nix/store/2kdd52vrb3vidzrvjvwbwvnbcxbrrjwz-illumos-rtld` | `19na6mqjai41lkhma7lihkrfzddmcfzdx9lzzjim9qk4fh9yrzk4` |
| ld | `/nix/store/varszaizh81snsgq818qz510c1lmmw57-illumos-ld` | `0kj68a7mm0x91ip97km43li5q1bdlvafjwq5qbid548s9izk3r88` |
| sys | `/nix/store/17w6ypm5m33jwmmgg8r4799j8diir0kr-illumos-sys` | `0vw5cnc9zia73zpafzxmcz355n4jca6k5d3w0q1zxkji46nkqlvd` |
| base-tools | `/nix/store/wnrx41dm5njlhm0xzl5i87kgqf1f7cq3-illumos-base-tools` | `0y18agr19wgbbjjbbbjrmxqla8zyhqkx53jlyqmhkmq0lq4zz4z8` |
| systemPath | `/nix/store/r1pvii5amavx08a9ylnsvj60a1i1jhxl-illumos-system-path` | `0ji71rcwhzcwfb3vvcqsy4f6n87j7fb4nz724lql3kchrhf4jh3s` |

(store-path prefixes move when a dep hash — or the builder script text — changes;
the NAR **content** hash is what to pin. Verified: a comment-only edit to the
systemPath builder moved its store-path prefix but left the NAR content hash
`0ji71rcw…` identical, and every slice rebuilds to the same NAR.)

## Hashes discovered (resolves design §1 TODO placeholders)

- gate proto-src (`builtins.path`) NAR: `sha256:1nw4pd2kdr9f3ndyfyf1r9jr2432r9nsw9n8zbxwa4crg650dj1l`
  (base32: `1nw4pd2kdr9f3ndyfyf1r9jr2432r9nsw9n8zbxwa4crg650dj1l`) — pins the
  proto bytes; use this as the fork FOD `outputHash` for the ingest variant, or
  as `builtins.path`'s `sha256`.
- gate `$out`: `/nix/store/y9d8x07cnxp9pyhb75v8bsd50cv6h98w-illumos-gate-proto`
- libc slice (GATE-B, 64-bit only) NAR was `sha256:18vl1fl5795iz3h6k6kr5ppvni4rc97m9icgz6i7svf64lswfglm`;
  the current **ABI-complete** libc (64+32-bit, +libmd) NAR is
  `sha256:0k5xfk8xwndlj306qxb40dhinfcy4g4h95vmkklp8p28p76hvqxv` (see the slice
  table above for all seven).

Provenance (design risk #3): OpenIndiana gcc 10.5.0-oi-2, gate HEAD
`ac45d71fc2b04a5422e72a14b54dd1e746e7be07`, host `illumos-960edb1c89`.

## Fork mapping (`~/ws/nixpkgs-solnix/pkgs/os-specific/illumos/`)

- `gate.nix` → `pkgs/gate.nix`. Replace `derivation {}` with
  `stdenvNoCC.mkDerivation`. For Phase-1 keep the ingest, OR switch to the full
  build FOD (design §1.5): `src = fetchFromGitHub {...rev ac45d71fc2...}`,
  `buildPhase` = the `scripts/oi-gate-build.sh` recipe, `outputHash` = the
  proto-src NAR above. Add `passthru = { version = "ac45d71fc2"; }`.
- `mk-illumos-component.nix` → `pkgs/mk-illumos-component.nix`. Replace
  `derivation {}` with `stdenvNoCC.mkDerivation`; take `{ lib, stdenvNoCC,
  illumos }`; `deps` list → `depRunpaths = map (d: "${d}/lib/amd64") deps`; expose
  `passthru`.
- `default.nix` `libc` → the `libc-gate = mkIllumosComponent { name="libc"; ... }`
  entry in the existing `rec {}` block (design §2.5), with
  `passthru = { incdir = "/usr/include"; libdir = "/usr/lib/amd64"; }`.

## Corrections to the design doc (found during implementation)

1. **§2.3 elfedit source was wrong.** The design uses `${illumos.seed}/usr/bin/
   elfedit`. The seed did NOT ship elfedit's loadable modules
   (`/usr/lib/elfedit/{dyn,...}.so`), so the seed elfedit fails `no such module:
   dyn`. Use the **host** `/usr/bin/elfedit` (bootstrap tool, host-path, legal
   under `sandbox=false` and the §1.3 host-impure stance). Fix for the fork: ship
   `elfedit` + `/usr/lib/elfedit/**` in the seed, or nixify (P2). Recorded as a
   `TODO(P2)` in `mk-illumos-component.nix`.
2. **§2.3 ELF detection was too loose.** `elfdump -d` returns 0 even on non-ELF
   headers and ET_REL `.o` startup objects (no `.dynamic` section), producing a
   flood of harmless "grow-in-place?" WARNs. The real gate: elfdump output must
   contain `SONAME|NEEDED|RUNPATH|RPATH`. crt/values `.o` correctly need no
   runpath.
3. **`unix` IS in this proto** (design §2.4 / the task premise both said it was
   missing). It lives at `platform/i86pc/kernel/amd64/unix` — the PLATFORM-
   specific location, not under `kernel/`. `genunix` is at `kernel/amd64/
   genunix`. The `sys` slice takes both; no P1.5 unix gap exists for this proto.
4. **§2.4 layout drift for `ld`.** The design listed `usr/lib/{ld,ldstab,lddbg}`;
   the real proto keeps the *shared objects* in `lib/amd64/` (`libld.so.4`,
   `liblddbg.so.4`, `libumem.so.1`) with only `libldstab.so.1` in
   `usr/lib/amd64/`, and `libelf` comes from the libc slice. `libld`'s NEEDED
   set (`liblddbg libelf libc`) drives the real closure. `usr/bin/ld` reaches
   its libs via `$ORIGIN/../../lib/amd64` + a `$out/usr/lib/amd64` self-dir.
5. **§2.4 base-tools is DUAL-ABI in reality, and must be pinned to ONE ABI.**
   illumos ships SMF (`svc.startd/svcs/svcadm/init`) and most coreutils as
   **32-bit** binaries; only a handful (`ksh93`, the `usr/bin/amd64/*` diagnostic
   set) are 64-bit. A 32-bit binary resolves NEEDED from `lib/` + `usr/lib/`,
   NOT `lib/amd64/`. So the libc slice had to become **ABI-complete** (add the
   whole 32-bit `lib/` sibling set + 32-bit crt), and base-tools is kept
   **single-ABI (32-bit)** so one RUNPATH string fits the `.dynstr` grow ceiling
   (correction #6). `oi-closure.sh` is ABI-aware for exactly this reason.
6. **§2.2/risk #1: the `.dynstr` grow ceiling is ~500–520 chars.** `elfedit`
   grows the string table to hold a longer RUNPATH, but only up to the section's
   spare capacity. A 462-char RUNPATH fits every base-tool; a 612-char one (both
   ABIs) does not. `mk-illumos-component.nix` now treats an elfedit failure as
   **FATAL** (never silently ship an unrelocated, host-leaking binary).
7. **libc's own siblings are not self-contained by default.** `libnsl.so.1` and
   `libresolv.so.2` NEED `libmd.so.1`, which is NOT one of the historic libc
   siblings. Without it the sliced libnsl falls back to host `/lib/libmd.so.1`.
   Fix: add `libmd` (both ABIs) to the libc slice so it stays $ORIGIN-resolvable.

## Known gaps toward a bootable image (P1.5)

- **External non-proto libs block full store-purity for `svcs`/`svc.startd`.**
  Their closure pulls `libxml2.so.16` (via `libzonecfg`/`libtopo`/`libpool`/
  `libbrand`), which drags **ICU** (`libicuuc.so.78`, `libicudata.so.78`),
  `libz.so.1`, and `libstdc++`/`libgcc_s`. **None are in the gate proto** —
  they are third-party IPS libraries. `svccfg` (libxml2) and `svc.configd`
  (`libsqlite-sys.so.2.8.15`) were EXCLUDED from base-tools for the same reason.
  The make-be image (P1.5) must supply libxml2 + icu + zlib + a C++ runtime as
  their own store packages (fork derivations, or sliced from the matching IPS
  package) and wire base-tools' RUNPATH to them, before the SMF stack is
  fully store-pure.
- **`.interp` still points at the standard `/usr/lib/ld.so.1`** for the proto
  binaries (baked at their original link time). The sliced `rtld` is proven to
  work as the interpreter when `.interp` is rewritten to it (rtld gate), but the
  base-tools were NOT interp-rewritten — for the image, either lay the sliced
  rtld at `/usr/lib/ld.so.1` (systemPath does), or `elfedit dyn:interp` each
  binary. Not a slicing defect; an image-composition choice.

## Remaining work

- Full gate-in-a-derivation FOD (design §1.5): run `oi-gate-build.sh` inside Nix
  (~90 min, host-impure inputs). The ingest here proves the store-path model;
  the FOD is the reproducible-from-source upgrade.
- Package the external libs (libxml2/icu/zlib/libstdc++) so the SMF stack is
  fully store-pure (P1.5 prerequisite for `svcs`/`svc.startd`/`svccfg`).
- `systemPath` → make-be ZFS-root boot environment + illumos `loader` (P1.5),
  plus generated SMF manifests from `smf.nix` (T1.11).
- Flip the stdenv's `libc`/`binutils-unwrapped` from the seed slices to these
  gate slices (design §3.1 step 4); wrapper flags unchanged, only store paths.
