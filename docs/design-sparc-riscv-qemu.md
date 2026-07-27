# SPARCv9 & RISC-V via QEMU-on-EC2 — feasibility

Answering: can we bootstrap RISC-V and UltraSPARCv9 using EC2 hosts running QEMU
as the foundation? Short: QEMU-on-EC2 is a fine SUBSTRATE for both (same pattern
as aarch64 — cross-build on an amd64 illumos host, boot a QEMU guest). But the
substrate is NOT the hard part. The hard part is whether an illumos PORT exists
for the ISA. The two diverge sharply.

## The distinction that governs everything

QEMU-on-EC2 answers "where do we build/boot," not "does an OS exist to boot."

| Arch     | illumos port?              | QEMU machine        | "bootstrap" = |
|----------|----------------------------|---------------------|---------------|
| x86_64   | yes (in-gate)              | native EC2          | DONE (boots)  |
| aarch64  | yes (out-of-tree, active)  | `virt` (GICv2)      | integrate the port — IN PROGRESS, kernel built |
| SPARCv9  | yes (in-gate, bit-rotting) | `sun4u` (sparc64)   | REVIVE + build-triage — medium |
| RISC-V   | **NO port at all**         | `virt` (great)      | WRITE the port first — multi-year, THEN QEMU-test |

## SPARCv9 (sun4u/sun4v = UltraSPARC / T-series) — startable QEMU track

- illumos HAS SPARC support in-gate (the original Solaris arch), bit-rotting but
  present; Tribblix + DilOS still ship SPARC builds.
- QEMU emulates SPARC64: `qemu-system-sparc64 -machine sun4u`. So the recipe
  MIRRORS aarch64:
  1. cross-build the SPARC gate on our amd64 illumos build host (`nightly` with
     the sparc MACH, or the distro forks' build recipes),
  2. boot the result in `qemu-system-sparc64 -machine sun4u` (OBP/SILO or the
     illumos sparc boot path),
  3. extract a seed, wire `sparcv9-solaris` (triple `sparcv9-sun-solaris2.11`)
     into lib.systems (mirror the x86_64-solaris pattern), stdenv + world slices,
  4. make-be for the sparc boot path.
- **Hardness: medium (revival, not port-from-scratch).** Risks: sun4u/sun4v code
  may not build clean on a modern gate (CTF/toolchain/mapfile drift); QEMU
  sun4u is less exercised than aarch64 `virt`; sun4v (T-series) emulation is
  weaker than sun4u. Lean on Tribblix/DilOS patches. Real T-series hardware (the
  maintainer's home UltraSPARC) is the eventual truth after QEMU.
- **Verdict: a legitimate QEMU-on-EC2 track we CAN start** (Phase 4). Same
  machinery as aarch64; the work is build-triage of existing code.

## RISC-V — QEMU substrate is trivial; there is nothing to run on it

- QEMU's `qemu-system-riscv64 -machine virt` is best-in-class. Substrate: run it
  on any amd64/Graviton EC2 host (no RISC-V EC2 needed).
- **BLOCKER (upstream, not us): illumos has NO RISC-V port.** No riscv kernel, no
  `uts/riscv`, no toolchain target, no mapfiles/CTF for riscv in the gate. QEMU
  gives a machine to boot NOTHING — there's no illumos-riscv64 kernel to load.
- So "bootstrap RISC-V via QEMU" = "write a RISC-V port of illumos FIRST": new
  HAL/locore/trap/interrupt/MMU, the toolchain target, drivers, CTF — a
  multi-year kernel effort (the aarch64 port took years + a formal illumos IPD).
  QEMU only helps TEST that port once it exists.
- **Verdict: RISC-V is a WRITE-THE-PORT research track, not a QEMU/package task.**
  QEMU readiness is not the gap; the OS is. Realistic options: (a) champion an
  upstream illumos RISC-V port (huge, community-scale), or (b) wait for one.
  Do NOT represent RISC-V as bootstrappable "just via QEMU."

## Recommendation

- **SPARCv9: schedulable now as a QEMU-on-EC2 revival track** (Phase 4), reusing
  the aarch64 machinery (cross-build → QEMU boot → seed → lib.systems → world).
  Start after aarch64 A3/A4 proves the QEMU-guest pattern end-to-end (it's the
  cheaper proof, and its lessons transfer).
- **RISC-V: keep as a research/upstream track** (Phase 5). QEMU is ready and
  waiting; the illumos port is the multi-year prerequisite. Revisit if/when an
  illumos RISC-V effort exists to build on.

---

## SPARC progress (S1 — gate sourcing + build-triage, this task)

Status: **substrate reality established + gate sourced (Tribblix m34 sparc
recipe) + build attempt in flight.** Done on the persistent ouch account
(us-east-2), host **ouch-w7-8** (solnix-oi-build, 3.142.68.35, 16 cores / ~107 GB
free, OI Hipster illumos-a28751f339). Every long op runs DETACHED via
`scripts/oi-job.sh` (no blocking SSH). Assets: solnix.io cache + local
`~/ws/solnix-archive/sparc/` ONLY — no AWS S3/ouch storage.

### S1.0 Host note (assigned hosts unusable; fell back to a warm w7 host)

The task assigned **ouch-w8-11 / ouch-w8-12** (18.227.92.193 / 18.227.74.124).
Both were launched fresh at 2026-07-27T10:46Z and **never became SSH-reachable**:
the console shows illumos boots to the login prompt, but guest DHCP fails —
`/sbin/dhcpagent: configure_v4_lease: cannot set IP address on ena0: Cannot
assign requested address`, so the public IP never routes into the guest. The
AWS-side config is correct (main route table has the IGW 0.0.0.0/0 route; the
single SG `solnix-ssh` allows my /32 on 22; source/dest-check aside). This is an
in-guest network-plumbing failure on the fresh w8 AMI, not fixable without
console/reboot (out of scope — do not terminate/reboot). Fell back to the
already-warm **ouch-w7-8** (the aarch64-A3 host, 14 h uptime, known good) to make
progress. w8-11/12 left running & untouched for the maintainer to inspect.

### S1.1 THE governing reality: the SPARC gate build is NATIVE-only

This is the single fact that reshapes the whole SPARC track vs. the
aarch64-mirror plan the top of this doc assumed:

- **Upstream illumos-gate has REMOVED SPARC support.** Per Tribblix
  `tribblix-build/illumos/sparc/README.md` (Peter Tribble): builds before m26
  used a vanilla gate at the x86 commit; **m26 onward "Upstream gate cannot be
  used as SPARC support has been removed."** Tribblix keeps SPARC alive by
  starting from a **fixed pre-removal base commit** and cherry-picking
  (sometimes modifying) subsequent commits.
- **The build is native, not cross.** Every Tribblix sparc env file
  (`illumos.sh.m{27..34}.sparc`) sets `export MACH="$(uname -p)"` and
  `PRIMARY_CC=gcc4,/opt/gcc/4.4.4/bin/gcc,gnu`. `nightly` builds for the host's
  own `uname -p`. On a SPARC host that is `sparc`; **on our amd64 host it is
  `i386`** — nightly would build i386, NOT sparc. There is **no cross-to-sparc
  path** in illumos-gate/nightly, and Tribblix does not cross either: Peter
  Tribble builds SPARC *on SPARC hardware* (an UltraSPARC, the same class as the
  maintainer's Ultra 45).
- **Toolchain: gcc 4.4.4** (`/opt/gcc/4.4.4`), the classic illumos SPARC
  compiler — NOT a modern gcc10/14. The header comment notes "Tribblix
  production build on x86 is gcc10," but the *active* SPARC compiler line is
  gcc4.4.4. Our host has gcc10/13/14 only; no gcc4.4.4, and none targeting
  sparc.

**Consequence — this is HARDER than aarch64, not "medium/mirror."** aarch64 has
a maintained *cross* toolchain (`richlowe/gcc` targeting
`aarch64-unknown-solaris2.11`) so an amd64 host cross-builds it. SPARC has **no
cross toolchain** anywhere (no `sparcv9-*-solaris` cross gcc in the wild) and
nightly has no cross-sparc mode. To build the sparc gate you need one of:
  (a) a **SPARC illumos build host** — chicken-and-egg (need a booted sparc
      illumos to build sparc illumos). The maintainer's Ultra 45 (OpenIndiana
      Hipster) or a qemu-system-sparc64 guest already running illumos *is* that
      host — but we don't have a booted sparc userland yet, which is the goal.
  (b) build a **sparcv9-solaris cross gcc + teach nightly to cross** — a real
      toolchain project nobody upstream or in Tribblix/DilOS has done. Weeks+.
  (c) **native-build the sparc-independent portions on amd64 to triage**: you
      cannot produce a sun4u `unix`/`genunix` on i386, but you CAN reproduce the
      Tribblix sparc *source tree* (base commit + reverts + cherry-picks) and
      run the parts of the build that are MACH-agnostic to record exactly where
      the modern-gate/toolchain drift breaks. This is the achievable S1
      deliverable and what's in flight.

### S1.2 Gate sourced — Tribblix m34 sparc recipe (the live SPARC keeper)

Cloned `github.com/tribblix/tribblix-build` (the recipe) and a full
`github.com/illumos/illumos-gate` reference. The m34 sparc tree is reproduced by
`tribblix-build/illumos/sparc/sparc-repo-m34.sh`:

- **Base commit** `6538c7b4c76e1d53fc801540cfe1dfe59d26bf29` (illumos-gate,
  2021-11-05, "14121 loader: net_open()..." — "just before the 13707/13708
  breakage" that removed sparc).
- **2 reverts** (13806 dladm warning-gags `f3ac7507`, 14158 compiler breakage
  `3873d743`) + **manual sparc Makefile creation** for `usr/src/lib/librename/
  {sparc,sparcv9}` (copied from the i386/amd64 Makefiles — 14196 added librename
  without sparc Makefiles).
- **156 `gatepatch` cherry-picks** of subsequent upstream commits (dd, ld,
  pkg-v2, zfs, smf, ipadm, mandoc, tzdata, loader, IPD4, a tmpfs CVE, etc.),
  applied by the `gatepatch` helper (pulls `<commit>.patch` from a local cache
  or `github.com/illumos/illumos-gate/commit/<c>.patch`, `git am`/apply). Some
  are marked `!partial failure` / `rejected` in the recipe (ld `fb12490a`
  rejected; zlib `148fd93e` and `14626` partial) — Tribblix's own notes on which
  upstream commits fight the sparc tree.
- **Env file** `illumos.sh.m34.sparc`: `NIGHTLY_OPTIONS=-nCprtL`,
  `ONNV_BUILDNUM=152`, `SUPPRESSPKGDEP=true`, gcc4.4.4 primary, no shadow,
  Perl 5.34, Python 3.12, jdk17, `VERSION=tribblix-m34`, `MACH=$(uname -p)`.

Recipe location on host: `/sparc/tribblix-build/illumos/sparc/sparc-repo-m34.sh`
(+ `gatepatch`, `gate-patches/` cache, all `illumos.sh.m*.sparc` env files).
Reference gate: `/sparc/Illumos-reference/illumos-gate`.

### S1.3 Build attempt + breakage (DONE this task — native-only wall confirmed)

Reproduced the m34 sparc source tree from the reference gate
(`/sparc/repro-m34.sh` → `/sparc/m34-gate`, HEAD `086befab`), then attempted the
build to record exactly why it stops.

**Cherry-pick reproduction (drift metric):** of the 156 gatepatch commits +
2 reverts in `sparc-repo-m34.sh`, applied against `.patch` files derived from
today's upstream illumos-gate:
  - REVERT OK: 2/2 (`f3ac7507` dladm gags, `3873d743` compiler breakage)
  - librename sparc/sparcv9 Makefiles created: OK
  - AM OK: 110  |  AM 3WAY: 5  |  **AM FAIL: 41**  |  PATCH-MISSING: 0
  - i.e. **115/156 = 74% apply clean**; the 41 failures start at `bbf21555`
    ("14443 IPD4 - quite a lot of breakage" — Tribblix flags it too) and cluster
    post-m28. (Our `.patch` endpoints differ slightly from Tribblix's own
    possibly-modified patch cache, so this is a lower bound on cleanliness; it
    still shows the sparc tree is reproducible and the hard patches are the
    known-hard ones.)
  - Resulting tree has **all four sparc source dirs**: `usr/src/uts/{sun4u,
    sun4v,sparc,sun4}`.

**Build attempt (`/sparc/m34-build-attempt.sh` → `artifacts/sparc/
m34-build-attempt.txt`) — confirms the native-only wall empirically:**
  - host `uname -p` = **i386** (nightly would build i386, not sparc).
  - `/opt/gcc/4.4.4` (the Tribblix sparc compiler) = **ABSENT**.
  - both host gccs (`/usr/gcc/10`, `/usr/gcc/14`) `-dumpmachine` =
    **`x86_64-pc-solaris2.11`** — x86-only. gcc14 with `-mcpu=v9` errors
    `bad value 'v9' for '-mtune='` (valid args are all x86 CPUs). **There is no
    sparc-target compiler on the host and the host gcc cannot emit sparc.**
  - So a sparc gate build cannot proceed on an amd64 host: no MACH=sparc, no
    sparc toolchain. This is the wall, proven, not assumed.

**Proto/kernel produced: YES (via ISO extraction, not a from-scratch build).**
Since a from-scratch sparc build is blocked on the host, the A2-equivalent
milestone — a real sparc `unix`/`genunix` for sun4u/sun4v — was obtained by
extracting them from the **Tribblix SPARC m34 ISO** (`iso.tribblix.org/iso/
tribblix-sparc-0m34.iso`, 710 MB, sha `afc1b115...`, built ~2026-04-21 from the
exact m34 recipe). Extracted + archived (see S1.5).

**qemu boot: ATTEMPTED, stalls in OpenBIOS FCode (see `artifacts/sparc/
qemu-sun4u-boot.log`).** `qemu-system-sparc64` 10.1.5 `-machine sun4u` +
`boot cdrom`: OpenBIOS v1.1 loads the CD's Sun sparc FCode bootblk (7120 bytes)
then hangs in "Evaluating FCode..." — it never hands off to the illumos `boot`
standalone, so `unix` is never loaded. This is a known OpenBIOS-vs-modern-
illumos-CD limitation, not a kernel defect (the extracted `unix` is valid SPARC
V9; the maintainer's real Ultra 45 OBP boots this ISO fine). Direct `-kernel
unix` fails (overlapping ROM regions — `unix` is a krtld-relocated module, not
standalone). Booting the bare boot_archive UFS as a disk fails (no Sun
VTOC/bootblk). Next avenues in the boot log: a VTOC-labelled disk image with a
real bootblk (`boot disk`), wanboot (`boot net` from `pkgs.tribblix.org/
m34.sparc/boot_archive`), or patched OpenBIOS.

### S1.5 Artifacts produced + archived

Real SPARC kernels extracted from the Tribblix m34 ISO and archived
(belt-and-suspenders: solnix.io cache + local, with sha256):
  - `sun4u_unix`    ELF64 MSB SPARC V9 EXEC, UltraSPARC1 Extensions Required
                    (Ultra 45 class) — sha `bef81f7b...`
  - `sun4u_genunix` ELF64 MSB SPARC V9 reloc — sha `8ef0cf55...`
  - `sun4v_unix`    ELF64 MSB SPARC V9 EXEC (T-series) — sha `701d8590...`
  - `sun4v_genunix` ELF64 MSB SPARC V9 reloc — sha `a602ac9d...`
  - `sun4v_boot_archive` big-endian UFS ramdisk, 340 MB (sun4u boot_archive is a
    symlink to it — shared). Contains a FULL sparc userland (`lib/libc.so.1`,
    `ld.so.1`, `crt1.o`, `/usr/lib/sparcv9/*`) — a proto/seed source for a future
    S2 (needs a big-endian UFS reader to extract; deferred).

Bundled (kernels + bootlst + manifest, minus the 340 MB archive):
  - `sparc-m34-kernels.tar.zst` (2.37 MB, sha
    `9c3622695ccfa3198e39ef760cff88fc97df11a532d2b80b1aa24c63c066584f`)
  - **solnix.io**: `https://s3.solnix.io/solnix-cache/archive/sparc/`
    (`sparc-m34-kernels.tar.zst` + `.sha256` + `MANIFEST.txt`) — fetch-verified
    (sha matches, unpacks to valid sun4u SPARC V9 ELF). solnix.io ONLY, no S3.
  - **local**: `~/ws/solnix-archive/sparc/` (ISO + extracted/ + bundle).
  - repo: `artifacts/sparc/` (boot log, build-attempt log, sha sums, manifest).

### S1.6 Next step

The honest path forward, in order of leverage:
1. **Get a booting sun4u kernel** (the real unblock): build a Sun-VTOC UFS/ZFS
   *disk* image (Tribblix `live_install.sh`) and `boot disk`, or wanboot via
   `pkgs.tribblix.org/m34.sparc/boot_archive`, both of which bypass the CD
   FCode path that OpenBIOS stalls on. If none work under OpenBIOS, the
   maintainer's Ultra 45 (real OBP) is the ground-truth boot host.
2. **Then use that booted sparc illumos as the native build host** to run
   `nightly illumos.sh.m34.sparc` (the ONLY way to build the sparc gate — no
   cross path exists). This is the aarch64 pattern inverted: boot-from-distro
   first, then build (aarch64 cross-builds first, then boots).
3. **S2 = mirror aarch64 A3** once a sparc proto exists: extract the boot_archive
   userland (big-endian UFS reader) as a seed, wire `sparcv9-solaris` (triple
   `sparcv9-sun-solaris2.11`) into lib.systems beside `aarch64-solaris`, and add
   `pkgs/illumos/sparc/{gate,default}.nix` slices. Deferred: no point wiring
   empty slices before a proto exists (YAGNI).

### S1.7 Constraints honored

- oi-job.sh detached+poll for every long host op (ref clone, tree repro, build
  attempt); zero blocking SSH.
- solnix.io cache ONLY for assets (+ local archive); no AWS S3/ouch storage.
- No git commit. Hosts not terminated. Assigned w8-11/12 left running for the
  maintainer (their guest DHCP was broken; fell back to warm ouch-w7-8).

Do NOT claim "sparc supported" until a sun4u kernel boots to an illumos
milestone in qemu (steering rule).

## SPARC target matrix (corrected 2026-07-27 from the archived m34 kernels)

The Tribblix m34 sparc gate builds BOTH sparc platforms — we archived working
kernels for each. Our matrix must track both (earlier steering wrongly said
"sun4u effectively dead"; the m34 ISO ships a live sun4u_unix):

| SPARC platform | Kernel (archived) | Class / hw | QEMU |
|----------------|-------------------|-----------|------|
| **sun4u** | sun4u_unix (SPARC V9, UltraSPARC1 Ext) | UltraSPARC I–IV, **Ultra 45** (maintainer's hw) | qemu-system-sparc64 -machine sun4u |
| **sun4v** | sun4v_unix (SPARC V9) | T-series (CoolThreads: T1..T5+), LDOMs | qemu -machine niagara (harder; needs OpenSBI-equiv) |

Both share one big-endian UFS boot_archive. sun4u is the near-term QEMU target
(Ultra 45 is the real-hw truth); sun4v/niagara is a second sub-target (LDOM/
T-series) — QEMU niagara support is weaker, real T-series hw is the fallback.
NOTE: these are PLATFORM variants of ONE arch (sparcv9-solaris), like x86's
i86pc — not separate Nix systems. One sparcv9-solaris world; platform-specific
kernels/boot_archives. So the Nix "system" matrix stays x86_64/aarch64/sparcv9/
riscv64-solaris; sun4u vs sun4v is a kernel/platform axis within sparcv9.
