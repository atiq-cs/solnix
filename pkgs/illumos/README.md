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
| `mk-illumos-component.nix` | slice N proto files into `$out`, relocate DT_RUNPATH with host `elfedit` | §2.3 |
| `default.nix` | wires `gate` + the `libc` slice (GATE B) | §2.4 / §2.5 |
| `../../scripts/gate-c-hello.sh` | GATE C: compile+link+run hello vs the sliced libc; LD_DEBUG proof | §5 Step D |
| `../../scripts/oi-gate-slices.sh` | host driver running all three gates | §5 |

## Run it (on the host)

```sh
# copy the three .nix + gate-c-hello.sh to /var/tmp/solnix-nix, then:
/var/tmp/solnix-nix/../scripts/oi-gate-slices.sh   # or scripts/oi-gate-slices.sh
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

## Hashes discovered (resolves design §1 TODO placeholders)

- gate proto-src (`builtins.path`) NAR: `sha256:1nw4pd2kdr9f3ndyfyf1r9jr2432r9nsw9n8zbxwa4crg650dj1l`
  (base32: `1nw4pd2kdr9f3ndyfyf1r9jr2432r9nsw9n8zbxwa4crg650dj1l`) — pins the
  proto bytes; use this as the fork FOD `outputHash` for the ingest variant, or
  as `builtins.path`'s `sha256`.
- gate `$out`: `/nix/store/y9d8x07cnxp9pyhb75v8bsd50cv6h98w-illumos-gate-proto`
- libc slice NAR: `sha256:18vl1fl5795iz3h6k6kr5ppvni4rc97m9icgz6i7svf64lswfglm`
  (content-stable across builder edits; only the store path prefix moves)

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

## Remaining work

- Full gate-in-a-derivation FOD (design §1.5): run `oi-gate-build.sh` inside Nix
  (~90 min, host-impure inputs). The ingest here proves the store-path model;
  the FOD is the reproducible-from-source upgrade.
- More slices via `mkIllumosComponent`: `rtld` (`ld.so.1`), `ld` (`+deps=[libc]`,
  absolute-store-path RUNPATH cross-dep test), `sys` (kernel + CTF-survives-slice
  check), `base-tools` (svc.startd et al., `ldd`-clean closure).
- `system-path` buildEnv union (design §4.2) → make-be image (P1.5).
- Grow-in-place still to verify on the biggest cross-dep objects (`/usr/bin/ld`,
  multi-lib base-tools) — libc/siblings already pass.
