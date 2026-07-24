# Design: How solnix builds `pkgs.illumos.*` (build-strategy decision)

Status: decision doc. Recommends a strategy for producing real `pkgs.illumos.*`
derivations (libc, ld, ld.so.1, kernel, base tools, and eventually the world)
given that the SEED toolchain binaries are illumos ELF and **cannot execute on
the Linux build machine**. Evidence cited against the fork checkout
`~/ws/nixpkgs-solnix` (branch `solnix-x86_64-solaris`, base `7f81d69cb`,
head `c52af7521`) and the live OI build host (`illumos-960edb1c89`).

TL;DR: **Hybrid, native-anchored.** Build the gate-derived "world" (libc, sys,
ld, rtld, base tools) **natively on illumos** via a Nix daemon on the OI host,
slice the proto into fine-grained derivations, and cache everything to
solnix.io. Cross-compile only *simple leaf packages* from Linux later, once a
cross-gcc for solaris exists. Do **not** try to cross-build illumos-gate itself
from Linux — the gate's own build machinery is illumos-native and does not
cross.

---

## The decision, precisely

`pkgs.illumos.*` derivations that come from **illumos-gate source** (libc, sys,
ld, rtld, the CTF-bearing kernel, base tools) are built **natively on an illumos
Nix builder**. Derivations that are **ordinary autotools/CMake leaf packages**
(third-party userland: later Phase-2 breadth) can be **cross-built from Linux**
once we stand up a cross-gcc, but that is not on the Phase-1 critical path.

This is a hybrid, but the *anchor* is native-on-illumos, because the crux risk
(below) makes pure cross a dead end for the gate.

---

## Current state (what already works — don't re-litigate it)

Facts from the fork and progress log, verified:

- **lib.systems**: `x86_64-solaris` wired (commit `18218269f`). `nix eval` proves
  `examples.x86_64-illumos` → `config=x86_64-unknown-solaris2.11`, `isSunOS=true`,
  `libc=illumos-libc`, `linker=solaris`, `useLLVM=false`, `kernel.name=solaris`.
- **Seed** exists and is verified (T0.3): 118 MB `seed.tar.zst`, extracted from
  the OI proto — gcc-10 prefix + Solaris `ld` + `elfdump`/`elfedit` + libc +
  siblings + crt + full `usr/include` + `ld.so.1`. A hello.c compiled with it,
  linked by the Solaris ld with a store-baked `-R` RUNPATH, ran on illumos and
  resolved libc from the seed (LD_DEBUG confirmed). No crle, no patchelf.
- **Seed FOD + wrappers** (commit `c52af7521`): `pkgs.illumos.seed` is a
  fixed-output derivation (unpack-only; builds on Linux). `pkgs.illumos.{libc,
  binutils-unwrapped,gcc-unwrapped,bintools,cc}` wrap the seed slices, and
  `bintools-wrapper/ld-solaris-wrapper.sh` translates GNU→Solaris flags
  (`-rpath`→`-R`, `-dynamic-linker`→`-I`). The `ccFlagsDump` self-check (8/8)
  passes on Linux, and the *translated flags* were confirmed on illumos to
  compile+link+run (raw `-dynamic-linker` is rejected by Solaris ld — proving
  the `-I` translation is load-bearing).

**Consequence:** the Nix→Solaris-toolchain *flag generation* is already correct
and runs on Linux. What is unproven is where the *actual compilation of gate
source* happens. That is this document's decision.

The key limitation, from the fork's own comment in
`pkgs/os-specific/illumos/default.nix`:

> "The slices are plain symlink/copy views into the seed store path. They are
> NOT rebuilt and NOT relocated here (the seed binaries are illumos ELF and only
> run on illumos)."

and `pkgs/stdenv/default.nix:66` still selects `x86_64-solaris = stagesNix`
(impure native), not a pure illumos stdenv. So today nothing actually *builds*
gate source through Nix on any platform. That is the gap.

---

## Option A — Cross-compile from Linux

Build a cross-gcc that runs on `x86_64-linux` and emits `x86_64-solaris` code,
using the seed's libc+headers as the target sysroot; then `pkgs.illumos.*` are
normal `pkgsCross.x86_64-solaris` derivations, buildable on cheap Linux CI.

### A.1 Can nixpkgs build a cross-gcc for solaris today?

**The plumbing dispatches correctly, but the gcc solaris flags are on the wrong
platform predicate.** Evidence:

- `pkgs/stdenv/default.nix:53`: when `crossSystem != localSystem`, nixpkgs
  selects `stagesCross`. `pkgs/stdenv/cross/default.nix:127` shows the CC for a
  non-LLVM, non-special target is `buildPackages.gcc` — a real cross-gcc built on
  the build platform, with `libcCross` as the target libc. This is the generic,
  well-trodden Nix cross path. So *structurally* a solaris cross-gcc is reachable.
- **But** the Solaris-specific gcc configure flags are gated on
  `hostPlatform.isSunOS`, not `targetPlatform.isSunOS`:
  `pkgs/development/compilers/gcc/common/configure-flags.nix:270` —
  `++ lib.optionals hostPlatform.isSunOS [ ... "--with-gnu-as" "--without-gnu-ld"
  ... ]`. A cross-gcc *targeting* solaris is built on Linux
  (`hostPlatform=linux`), so it would **miss** `--with-gnu-as --without-gnu-ld`
  and try to build against GNU ld, which is wrong for illumos.
  `pkgs/development/compilers/gcc/common/pre-configure.nix:23` has the same
  `hostPlatform.isSunOS && hostPlatform.is64bit` gating for the `lib/amd64`
  rpath fixups.
- `platform-flags.nix` has **no** solaris/SunOS entry at all (grep: 0 matches).
- `gcc/default.nix:363` special-cases `hostPlatform.system == "x86_64-solaris"`
  (`CC = "gcc -m64"`) — again native-host, not cross-target.

**Verdict:** nixpkgs cannot build a correct `x86_64-unknown-solaris2.11`
cross-gcc today. It needs the solaris configure block re-gated to fire on
`targetPlatform.isSunOS` for the cross case (and a `libcCross = pkgs.illumos.libc`
with an `incdir` passthru — which the fork's `illumos.libc` slice already
exposes: `incdir="/usr/include"`, `libdir="/usr/lib/amd64"`). This is a moderate,
tractable nixpkgs patch — *not* the blocker. **The blocker is A.2.**

### A.2 The crux: does illumos-gate SOURCE cross-build? (No.)

Even with a working cross-gcc, the illumos *source* (libc, kernel) cannot be
cross-built from Linux, because the gate's build machinery is a set of
**illumos-native binaries and conventions**, not portable tools:

- **`dmake`** (Sun distributed make) drives the gate. Confirmed on host:
  `/usr/bin/dmake`. The gate hard-forces `DMAKE_MODE=parallel` in `nightly.sh`
  (progress log: this leaked target CPPFLAGS and forced the `wrapmake -m serial`
  workaround). dmake is a SunPro-derived make, not a portable build tool.
- **CTF is mandatory and illumos-native.** `ctfconvert`/`ctfmerge` live at
  `/opt/onbld/bin/i386/` (confirmed on host). The kernel build *fails* without
  CTF merge (progress log documents the ctfmerge uniquify race at length). CTF is
  coupled to the object format and generated by illumos binaries in `onbld`.
- **The Solaris link-editor + mapfiles + `elfsign` + `pkgmogrify`** are all
  illumos binaries in the gate flow (confirmed on host: `/usr/bin/ld`,
  `/usr/bin/elfsign`, `/usr/bin/pkgmogrify`). Symbol versioning is done via
  mapfiles the Solaris `ld` reads; GNU ld cannot substitute.
- The steering doc `illumos-domain.md` states this as settled fact:
  "Cross-building the whole gate from Linux is NOT a supported path and is not
  known to work end-to-end. Do not plan as if it does." And `product.md` lists
  as a honesty rule: "Do not claim cross-from-Linux works for stage0 — it does
  not today."

To cross-build the gate from Linux you would have to first cross-build (or
port to Linux) `dmake`, `ctfconvert`/`ctfmerge`, the Solaris `ld`, `elfsign`,
`pkgmogrify`, the mapfile tooling, and then get the gate's makefiles to target a
cross toolchain — an open-ended porting project of the entire illumos build
system. That is not Phase-1 work; it is arguably a multi-year effort with no
upstream support.

### A.3 Why the nixbsd/FreeBSD precedent does NOT transfer here

nixbsd/FreeBSD *does* cross-build FreeBSD from Linux — there is even
`pkgs/stdenv/freebsd/make-bootstrap-tools-cross.nix`
(`release-cross.nix:300`: `freebsdTools = import
../stdenv/freebsd/make-bootstrap-tools-cross.nix { system = "x86_64-linux"; }`).
**But that works because FreeBSD's build system is portable and self-hosting:**

- FreeBSD builds with **`bmake`** (portable BSD make) via
  `pkgs/os-specific/bsd/setup-hook.sh` — a bash setup-hook that runs on Linux.
- FreeBSD uses **LLVM** (`useLLVM = isFreeBSD`), and **lld speaks GNU-compatible
  flags**, so the generic `ld-wrapper.sh` works with almost no change.
- FreeBSD re-expresses its world as fine-grained slices of `freebsd-src`
  (`pkgs/os-specific/bsd/freebsd/pkgs/libc/package.nix` etc.) that each build a
  piece with `bmake` — no FreeBSD-native binary is required to build them.

illumos has none of these portability properties: dmake (not bmake), GCC + a
**non-GNU Solaris link-editor** (which is *why* `ld-solaris-wrapper.sh` had to
exist), mandatory CTF via illumos binaries, and mapfile-based versioning. The
BSDs never faced our problem; the precedent's *mechanism* (fine-grained slices,
staged seed bootstrap) transfers, but its *cross-from-Linux* property does not.

**Option A conclusion:** viable for ordinary leaf packages after a cross-gcc
patch; **not viable for the gate-derived world** (libc/sys/ld/rtld/base-tools)
without porting the entire illumos build system to Linux. Reject as the Phase-1
anchor.

---

## Option B — Build natively on illumos with Nix

Run the Nix daemon on the OI EC2 host, do a real native stdenv bootstrap from
the seed (the seed binaries *do* run on illumos), and build `pkgs.illumos.*`
natively — matching how illumos-gate actually builds.

### B.1 Is there a working Nix port for illumos/Solaris?

- **nixpkgs does not build `nix` for `x86_64-solaris` today.** `stdenv` for
  x86_64-solaris is still `stagesNix` (impure native), so there is no pure stdenv
  to build `nix` against, and no cached `nix` for solaris.
- **Prior art exists but is old/partial.** Nix historically listed Solaris as a
  supported platform (the `x86_64-solaris`/`i686-solaris` doubles predate this
  project — that is *why* `ld-solaris-wrapper.sh` and the gcc solaris flags are
  already in-tree). There is community history of Nix on SmartOS/illumos and on
  pkgsrc-based Solaris, but nothing current and cache-backed.
- **The realistic path mirrors nixbsd's `cppnix` fork:** expect to build a Nix
  daemon on illumos from source (the seed toolchain can compile it), carrying a
  small patch set for illumos-isms (procfs, `/proc` layout, ELF handling in the
  build hook, sandbox differences). nixbsd needed exactly this for FreeBSD; the
  steering doc `nix-conventions.md` already budgets for a "`nix` fork (if
  needed)". This is Phase-0 task **P0.2**, still open.

### B.2 How hard is standing up nixd on the OI host?

Moderate, and mostly one-time:

1. Compile Nix from source on the OI host using the seed gcc-10 (or the host's
   `/usr/gcc/10`) — its deps (boost, sqlite, curl, libsodium, etc.) are either in
   OI's IPS set or build from source. This is bootstrap-only tooling, so using
   the host's `pkg` for build prereqs is explicitly allowed (`product.md`
   "Bootstrap exception").
2. Configure `/nix` on a ZFS dataset, run `nix-daemon` under SMF (a tiny manifest
   — we already have the SMF init design in `design-smf-init.md`).
3. Expect to patch: the build sandbox (illumos has zones/privileges, not Linux
   namespaces — likely run with reduced/no sandbox initially), ELF RUNPATH
   handling (already solved: `elfedit`, not patchelf — proven in T0.3), and any
   `x86_64-solaris` gaps in the daemon.

Downside, as stated in the task: builds run on illumos EC2 (slower/costlier than
Linux CI). **This is mitigated entirely by the cache** — see below.

**Option B conclusion:** the correct anchor. It matches how the gate builds,
reuses the proven seed + elfedit + Solaris-ld work, and the one hard part
(Nix-on-illumos, P0.2) is a bounded one-time port with clear prior art.

---

## Recommendation (hybrid, native-anchored)

**Anchor everything gate-derived on native illumos builds; slice the proto;
cache aggressively; cross-build only simple leaves from Linux later.**

Concretely, three tiers:

### Tier 1 — Native on illumos (the world, Phase 1 critical path)

`pkgs.illumos.{libc, sys, ld, rtld, base-tools}` are built **on the OI Nix
builder**. Two sub-strategies, pick per component:

- **1a. Wrap-and-slice the gate build (fastest to correct).** Build illumos-gate
  *inside a Nix derivation on illumos* (the derivation runs `nightly`/`bldenv` +
  `dmake` against a pinned gate source), producing the proto as the derivation
  output; then downstream fine-grained derivations (`libc`, `sys`, `ld`, `rtld`,
  per-tool) **slice the proto** and relocate ELF RUNPATH into the store via
  `elfedit`. This reuses the *entire* working gate build (dmake, CTF, Solaris ld,
  mapfiles) untouched, and only re-expresses the *outputs* as Nix packages. It is
  the lazy, correct thing: do not re-implement libc's build in Nix when the gate
  already builds it perfectly on illumos.
- **1b. From-source fine-grained (later refinement).** Where a component builds
  cleanly in isolation with `bldenv` + `dmake` on a subtree (progress log proved
  this works for `libc`, `genunix`, `unix` individually), express it as a
  standalone Nix derivation that checks out just that subtree. Migrate components
  from 1a→1b opportunistically for better caching granularity; do not block
  Phase 1 on it.

The seed + `pkgs/stdenv/illumos` staged bootstrap (design §3.3) is what makes 1b
possible and gives a *pure* stdenv; 1a can run even before the full staged
stdenv is green, because it delegates to the gate's own machinery.

### Tier 2 — Cross-built leaves from Linux (Phase 2 breadth, opportunistic)

Ordinary third-party autotools/CMake userland (Phase 2.4 breadth) can be
cross-built as `pkgsCross.x86_64-solaris` from Linux **once** the cross-gcc patch
(A.1) lands: re-gate the solaris gcc configure block on `targetPlatform.isSunOS`
and wire `libcCross = pkgs.illumos.libc` (the slice already exposes `incdir`).
These packages have no CTF/dmake/mapfile dependency, so they cross cleanly the
way any Nix cross target does. This keeps cheap Linux CI useful for the long tail
without ever touching the gate.

### Tier 3 — The cache erases the "illumos is slow/costly" objection

solnix.io hosts an S3 binary cache (`product.md`). Every expensive native
illumos build is cached and substituted, so contributors and CI *download*
libc/sys/base-tools rather than rebuilding them. The illumos builder becomes a
periodic *producer* of cache artifacts, not a per-developer bottleneck. This is
exactly nixbsd's model (its base closure is >30 GiB, cached). Where a build runs
stops mattering once its output is cached; correctness (native) wins over
locality (Linux CI).

### Why hybrid and not pure-B

Pure native-only would waste the fact that the Nix→Solaris flag generation
already runs on Linux (the wrappers, the seed FOD, `ccFlagsDump` all build on
Linux) and that leaf packages genuinely cross fine. But the *anchor* must be
native, because the gate does not cross (A.2). Hybrid captures both:
native for the world, Linux-cross for leaves, cache for everyone.

---

## Phase-1 path: get `pkgs.illumos.{libc,sys,base-tools}` into the store cheapest-correct

Ordered, each step testable before the next:

1. **[P0.2] Nix-on-illumos.** Build `nix` from source on the OI host with the
   seed/host gcc-10; run `nix-daemon` under SMF; `/nix` on ZFS. Gate: a trivial
   derivation (`runCommand "hi" {} "echo hi >$out"`) realises on illumos.
2. **[T1.1b done] Seed FOD** is already a fixed-output derivation that builds on
   any platform. Repoint its `url` from the local file to `https://solnix.io/seed/
   x86_64-solaris/seed.tar.zst` (one-line change; hash already pins bytes) so the
   illumos builder can fetch it.
3. **Gate-in-a-derivation (Tier 1a).** Write `pkgs.illumos.gate` (or
   `illumos.proto`): a derivation that, on illumos, checks out pinned
   illumos-gate (`illumos-31d3d510d0` per `illumos-domain.md`), runs the proven
   `scripts/oi-gate-build.sh` recipe (`wrapmake -m serial`, the header prereqs),
   and installs the proto area as `$out`. Coarse, big, but *correct and already
   proven to build*. Cache it.
4. **Slice the proto (Tier 1).** `pkgs.illumos.libc`, `.sys`, `.ld`, `.rtld`, and
   the base-tools set each depend on `illumos.gate`, copy their files out of the
   proto, and `elfedit` RUNPATH into the store (the T0.3-proven mechanism). Break
   the bootstrap cycle with explicit `callPackage` wiring, mirroring
   `pkgs/os-specific/bsd/freebsd/package-set.nix`.
5. **Native stdenv (design §3.3).** Bring up `pkgs/stdenv/illumos` staged
   bootstrap (seed → boot-0 → boot-1 → final) on illumos and switch
   `pkgs/stdenv/default.nix` `x86_64-solaris` from `stagesNix` to `stagesIllumos`.
   Gate: `nix build .#stdenv` on illumos builds a hello.c that links against a
   *store* libc (not the seed) and runs. This is what turns Tier-1b from-source
   slices into pure derivations.
6. **Cache.** Push steps 3–5 outputs to solnix.io S3. Contributors substitute.

**Cheapest correct Phase-1 answer:** steps 1→4 get `libc`, `sys`, and
`base-tools` into the store *without waiting on the full staged stdenv*, because
Tier 1a delegates to the gate build we already have working. Step 5 is the
quality upgrade (pure stdenv, fine-grained caching), not a Phase-1 blocker.

---

## Key risks + what to verify next

Ranked by likelihood of biting Phase 1:

1. **Nix-on-illumos (P0.2) is unstarted and gating.** *Verify:* can `nix` build
   and `nix-daemon` run on the OI host? Sandbox behaviour on illumos (no Linux
   namespaces — expect to relax the sandbox initially). This is the single open
   Phase-0 kill-risk for Option B. Prior art: nixbsd `cppnix`, historical
   Nix-on-SmartOS. **Do this first.**
2. **elfedit RUNPATH grow-in-place** on large objects (`libstdc++.so.6`,
   `cc1plus`) — if the dynamic section can't hold a longer RUNPATH, relink
   instead of edit. Partially de-risked by T0.3 (hello.c worked); *verify* on the
   biggest offenders during proto-slicing (step 4).
3. **Gate build reproducibility inside a derivation.** The gate needs a clean
   tree (`git clean -dfx`), serial dmake (`wrapmake -m serial`), and header
   prereqs (idnkit/nss/nspr/cups) — all captured in `scripts/oi-gate-build.sh`,
   but a Nix derivation adds sandbox/immutability constraints. *Verify* the gate
   builds under `nix build` with those prereqs vendored, not `pkg install`-ed at
   build time (they must be inputs). May need to package the header prereqs as
   Nix inputs first.
4. **Cross-gcc solaris patch (Tier 2, deferrable).** Re-gate the gcc solaris
   configure block on `targetPlatform.isSunOS` and wire `libcCross`. *Verify* a
   `pkgsCross.x86_64-solaris.hello` builds on Linux and runs on illumos. Not on
   the Phase-1 critical path — schedule with Phase-2 breadth.
5. **Seed↔gate drift.** Seed gcc was extracted from `illumos-960edb1c89`; the
   pinned gate source for step 3 should be `illumos-31d3d510d0` (the maintainer's
   reference per `illumos-domain.md`) — or re-pin the seed to match. *Verify* the
   seed gcc builds the pinned gate cleanly (ABI is stable+versioned, usually
   fine, but keep them close).
6. **CTF/packaging failures are out of scope — don't get nerd-sniped.** The Perl
   per-arch and msgcc IPS *packaging* failures (progress log) block only IPS
   packaging, which solnix discards (`product.md`). Tier-1a slices the **proto**,
   not IPS packages, so these do not block. Confirm the proto has everything the
   slices need (T0.3 already confirmed libc/crt/headers/ld.so.1/ld; `unix` is now
   in proto too — verified on host).

---

## Summary

| | Cross-from-Linux (A) | Native-on-illumos (B) | Chosen (hybrid) |
|---|---|---|---|
| Gate world (libc/sys/ld/rtld/base) | **No** — gate build is illumos-native (dmake/CTF/Solaris-ld); does not cross | **Yes** — matches upstream | **B (native), Tier 1** |
| Simple leaf packages | Yes, after cross-gcc patch | Yes | **A (cross), Tier 2, later** |
| Nix flag generation | Already runs on Linux (done) | n/a | reuse as-is |
| Cost/speed | cheap Linux CI | slower illumos EC2 | **cache erases it, Tier 3** |
| Blocker | port entire illumos build system to Linux (multi-year) | Nix-on-illumos port (bounded, P0.2) | P0.2 only |

**Decision:** native-anchored hybrid. Build the gate-derived world natively on
illumos (Tier 1a: wrap the gate build in a derivation, slice the proto, relocate
with elfedit; migrate to Tier-1b from-source slices opportunistically), cross
only simple leaves from Linux (Tier 2, after a small cross-gcc patch), and cache
everything to solnix.io so where it built stops mattering (Tier 3). Cheapest
correct Phase-1 path: P0.2 → repoint seed FOD → gate-in-a-derivation → slice
proto for `libc`/`sys`/`base-tools`. The pure staged stdenv is the follow-on
quality upgrade, not a Phase-1 gate.
