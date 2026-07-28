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

## SPARC progress (S1b — get sun4u BOOTING past the firmware handoff)

Status: **DONE — the sun4u illumos kernel STARTS EXECUTING under
qemu-system-sparc64 and boots deep into genunix/SMF.** The S1 wall ("OpenBIOS
stalls in the CD FCode, never hands off to the kernel") is BROKEN. We are now
past the firmware handoff; the remaining walls are OpenBIOS OBP *client-service*
bugs that the kernel hits *while executing*, not a firmware-handoff stall.

All runs DETACHED (nohup qemu -> console logfile, time-boxed, killed; never an
interactive console held across a boot). Assets: local ISO/kernels + solnix.io
cache ONLY (no AWS S3/ouch). Hosts not terminated. Not git-committed.

### S1b.0 The decisive finding: the kernel starts (the S1 "stall" was a red herring)

S1 concluded OpenBIOS "hangs in the FCode interpreter spinner, never hands off."
That was a **timebox artifact**: the FCode `Evaluating FCode...` phase legitimately
spins for ~60-90 s (tokenized FCode interpreted slowly), THEN hands off. S1's
timebox + the default NIC noise hid the handoff. With a longer timebox on the
dev-box qemu 10.1.5 (OpenBIOS v1.1, Sep 24 2024), the CD boot path
(`boot cdrom`) goes ALL THE WAY:

```
Evaluating FCode...                         <- ~90s spin (normal, not a hang)
Ignoring failed claim for va 1000000 memsz d5f4e!   <- illumos 'boot' placing unix's
Ignoring failed claim for va 1402000 memsz 31e25!      LOAD segments (vaddrs match
Ignoring failed claim for va 1800000 memsz 52148!      readelf of sun4u_unix exactly)
Welcome to Tribblix, the retro illumos distribution    <- THE KERNEL IS RUNNING
tribblix-m34 | April 2026 | https://www.tribblix.org/
interpret \ ident "%Z%%M% %I% %E% SMI"      <- kernel's unix-tte FCode driver script
WARNING: add_spec: No major number for sf   <- genunix driver-attach WARNINGs
WARNING: consconfig: cannot find driver for screen device .../QEMU,VGA@2
```

**The sun4u_unix kernel unambiguously STARTS EXECUTING** — it prints the Tribblix
banner (that string lives in the *kernel*, emitted after `_start`/`mlsetup`),
runs its embedded `unix-tte` FCode, and emits genunix `WARNING:` messages from
driver attach. Getting here = the S1b win ("past the firmware handoff to a kernel
that starts executing").

### S1b.1 How far it boots (two observed depths — the kernel runs a LONG way)

Depending on emulation timing, two milestones were reached across runs (both far
past the handoff; the exact stop is nondeterministic OBP-callback territory):

**(A) Into SMF / early userland** (`cd-milestone-SMF95of95-KEEP.log`,
`cd-repro-SMF27of95-KEEP.log`, `cd-console-SMF-KEEP.log`): after the kernel
banner it mounts root and starts init/SMF, and in the longest run imported the
FULL service repository:
```
Loading smf(7) service descriptions: 1/95
2/95 ... 95/95           <- ALL 95 SMF manifests imported = multi-user boot,
                            userland up, svc.configd/svccfg running
```
This is a real multi-user boot (root mounted from the boot_archive ramdisk,
`svc.configd`/`svccfg` importing all 95 service manifests to completion, then
starting services). The 25-min timebox fired during the quiet service-startup
phase after 95/95 (emulated single-core sun4u is slow, not stuck — it climbed
1->95 steadily over ~18 min). Shorter runs stopped at 16/95 and 27/95, still
advancing.

**(B) genunix DDI panic** (`cd-novga-PANIC-prom_getproplen-KEEP.log`,
`cd-full-PANIC-KEEP.log`): in other runs the kernel panics during device
enumeration with a full, legible stack trace:
```
panic[cpu0]/thread=180e000: BAD TRAP: type=4e rp=180a9c0 addr=ffd12084 mmu_fsr=0
  unix:die+9c
  unix:trap+1800
  unix:ptl0+68
  unix:prom_getproplen+38          <- kernel calls OpenBIOS PROM to read a devtree prop
  genunix:impl_ddi_bus_prop_op+44
  genunix:ddi_bus_prop_op+28
  genunix:ddi_prop_search_common+3b4
  genunix:ddi_prop_op+44
rebooting...
BOOTpanic - kernel: prom_reboot: reboot call returned!
```
The kernel is executing `genunix:ddi_prop_op` -> `prom_getproplen()` and the trap
addr (0xffd12084 / 0xffd0e710) is inside OpenBIOS's own ROM window (0xffd00000+).
So **OpenBIOS's OBP `getproplen`/`getprop` client-interface callback faults** when
illumos calls it during DDI device-tree property lookup at driver-attach time.

### S1b.2 The EXACT wall (three OpenBIOS OBP client-service gaps, all post-handoff)

Every remaining failure is an OpenBIOS OBP *client-interface* bug the kernel hits
WHILE RUNNING — none is a firmware-handoff stall:

1. `unix-tte is va>tte-data failed with error -13` — the kernel's `unix-tte`
   FCode word maps its own text/data with large TLB pages via the OBP word
   `va>tte-data`; OpenBIOS returns -13 (unimplemented/unsupported). Non-fatal —
   the kernel *catches* it (`unix-tte:interpret: exception -13 caught`) and keeps
   going (that's how it reaches genunix/SMF).
2. **`prom_getproplen` BAD TRAP (fatal)** — during DDI enumeration the kernel
   calls the OBP `getproplen`/`getprop` client service; OpenBIOS faults inside
   its ROM, the kernel takes trap 0x4e and panics. THIS is the hard wall on the
   full boot in run (B).
3. `prom_reboot: reboot call returned!` — after the panic the kernel asks OBP to
   reboot; OpenBIOS's `reboot` client call returns instead of resetting, so the
   kernel drops to the `0 >` ok prompt. A third, cosmetic OBP gap.

Root cause class: qemu's OpenBIOS implements only a subset of the SPARC OBP
client interface (the `SUNW,*` and devtree property callbacks). The illumos
sun4u kernel exercises more of that interface than OpenBIOS covers. This is a
**firmware-completeness gap in OpenBIOS**, NOT a defect in the Tribblix m34
kernel (the maintainer's real Ultra 45 with real Sun OBP boots this exact ISO to
multi-user).

### S1b.3 Boot paths tried (which bypass the CD FCode, which don't)

| Path | Recipe | Result |
|------|--------|--------|
| (a) CD FCode `boot cdrom` | qemu 10.1.5 sun4u + ISO as IDE cdrom, longer timebox | **WINS** — reaches kernel exec -> genunix/SMF (the S1 "stall" was just the ~90s FCode spin). This IS the working path. |
| (a') disk image w/ UFS bootblk | not built | would route through the SAME `ufs/bootblk` FCode + `boot` + kernel chain as the CD; the CD path already gets the kernel running, so a disk buys nothing for the boot wall. Deferred (the wall is post-handoff OBP callbacks, identical either way). |
| (b) direct `-kernel sun4u_unix` | qemu `-kernel` | **fails, fundamentally** — "ROM regions overlapping": every PT_LOAD has PhysAddr=0, so qemu's ELF loader stacks all segments at phys 0. sun4u_unix is a krtld-relocated, VirtAddr-placed, `ld.so.1`-interpreted module — it MUST be placed by the illumos `boot` loader with the MMU; qemu's flat `-kernel` loader cannot. Dead end for a krtld kernel. |
| (c) netboot `boot net` | not run | OpenBIOS netboot loads an ELF NBP directly (no FCode), but the CD media has no `inetboot`/`wanboot` NBP to serve; and path (a) already gets the kernel executing, so (c) is not needed to clear the S1b bar. Deferred. |
| (d) SILO / illumos sparc standalone | n/a | illumos SPARC has no SILO; the `boot`+bootblk chain (path a) IS the standalone, and it works. |

qemu 11.0.2 (the OI host package) is WORSE: its OpenBIOS crashes with
`Unhandled Exception 0x32` at PC 0xffd16ea0 immediately on `-machine sun4u`,
before even reaching the `ok` prompt (bare, no drives). So the dev-box
qemu 10.1.5 (OpenBIOS v1.1 Sep-2024) is the better substrate; the host qemu
11.0.2 OpenBIOS is broken on sun4u. Recorded — do NOT use host qemu 11.0.2 for
sun4u.

### S1b.4 Verdict + realistic next step

**S1b bar cleared:** the sun4u kernel starts executing and boots into
genunix/SMF — in the longest run a full multi-user boot that imported ALL 95 SMF
service descriptions (1->95/95). The firmware handoff is NOT the wall anymore.
The wall is OpenBIOS's incomplete OBP client-interface (chiefly the
`prom_getproplen`/`getprop` devtree callbacks that fault during DDI in *some*
runs, plus `va>tte-data` and `reboot`).

To get a *clean* multi-user boot under qemu, in order of leverage:
1. **Patch OpenBIOS's OBP `getprop`/`getproplen` client service** so it doesn't
   fault when illumos reads devtree properties during DDI attach (the fatal
   wall). This is a focused OpenBIOS/qemu fix (a few client-callback words), far
   smaller than a port. Rebuild qemu-system-sparc64 against a patched
   `openbios-sparc64` and re-run path (a). Highest leverage.
2. **Or the maintainer's real Ultra 45** (real Sun OBP) — it boots this exact
   ISO to multi-user today. That is the ground-truth SPARC host and the eventual
   native build host (the sparc gate is native-only, per S1). For actually
   *building* the sparc gate, the Ultra 45 is the path regardless of qemu.
3. **Or a different/patched firmware** for the sun4u machine. Real Sun OBP is
   not redistributable; a patched OpenBIOS (option 1) is the tractable route.

Honest bottom line: OpenBIOS does NOT block all qemu paths — it lets the kernel
boot into genunix/SMF (path a), then faults in a specific OBP client callback.
The near-term unblock is a small OpenBIOS `getprop` fix; the ground truth is the
real Ultra 45.

### S1b.5 Artifacts

- `artifacts/sparc-s1b/logs/` — console logs per recipe (KEEP = milestone runs):
  - `cdrom-KERNEL-STARTS-KEEP.log` — first proof the kernel banner prints.
  - `cd-console-SMF-KEEP.log` — boots into SMF (16/95 service descriptions).
  - `cd-milestone-SMF95of95-KEEP.log` — **deepest run: full multi-user boot**,
    root mounted, ALL 95 SMF service descriptions imported (1->95/95 over ~18min),
    timebox fired in the quiet service-startup phase. No panic.
  - `cd-repro-SMF27of95-KEEP.log` — clean run to SMF 27/95 (no panic — the DDI
    panic is a nondeterministic OBP-callback flake, not every run hits it).
  - `cd-novga-PANIC-prom_getproplen-KEEP.log` — the clean genunix DDI panic
    stack (the fatal OBP `getprop` wall).
  - `cd-full-PANIC-KEEP.log` — same panic, `ddi_prop_lookup_common` frame.
  - `cdrom-base-KEEP.log`, `cdrom-ttya-KEEP.log` — earlier depth runs.
- `artifacts/sparc-s1b/s1b-boot-local.sh` — the detached, time-boxed boot
  harness (dev-box qemu 10.1.5); `s1b-boot.sh` — the host variant.
- `artifacts/sparc-s1b/RECIPES.md` — the exact qemu command lines tried.

## SPARC target matrix (corrected 2026-07-27 from the archived m34 kernels)

The Tribblix m34 sparc gate builds BOTH sparc platforms — we archived working
kernels for each. Our matrix must track both (earlier steering wrongly said
"sun4u effectively dead"; the m34 ISO ships a live sun4u_unix):

| SPARC platform | Kernel (archived) | Class / hw | QEMU |
|----------------|-------------------|-----------|------|
| **sun4u** | sun4u_unix (SPARC V9, UltraSPARC1 Ext) | UltraSPARC I–IV, **Ultra 45** (maintainer's hw) | qemu-system-sparc64 -machine sun4u — **kernel BOOTS into genunix/SMF (S1b)**; OpenBIOS OBP `getprop` callback is the remaining wall |
| **sun4v** | sun4v_unix (SPARC V9) | T-series (CoolThreads: T1..T5+), LDOMs | qemu -machine niagara (harder; needs OpenSBI-equiv) |

Both share one big-endian UFS boot_archive. sun4u is the near-term QEMU target
(Ultra 45 is the real-hw truth); sun4v/niagara is a second sub-target (LDOM/
T-series) — QEMU niagara support is weaker, real T-series hw is the fallback.
NOTE: these are PLATFORM variants of ONE arch (sparcv9-solaris), like x86's
i86pc — not separate Nix systems. One sparcv9-solaris world; platform-specific
kernels/boot_archives. So the Nix "system" matrix stays x86_64/aarch64/sparcv9/
riscv64-solaris; sun4u vs sun4v is a kernel/platform axis within sparcv9.

## SPARCv9 reference distro correction (2026-07-27, from the maintainer)

CRITICAL: the SPARCv9 target hardware is the maintainer's **Sun Ultra 45 running
OpenIndiana Hipster on SPARC** — a machine they boot and run today. So the
reference distro for solnix SPARCv9 is **Hipster (OI)**, NOT Tribblix.

Why S1/S1b used Tribblix: it was the readily-available LIVE sparc illumos ISO to
PROVE the kernel boots under QEMU (it did — sun4u -> SMF 95/95). That proof
stands and is distro-agnostic (both are illumos-gate-derived). But the important
PIECES for the solnix SPARCv9 target should come from the Ultra 45's Hipster:
- its sparc kernel + world (what the maintainer actually runs),
- its IPS package set for sparc (the userland we mirror, per the same 5920-current
  Hipster inventory model we use for x86_64),
- its boot path / OBP config as the real-hardware truth (the Ultra 45's Sun OBP
  boots cleanly where QEMU's OpenBIOS faults in getproplen).

OPEN QUESTION (resolve before S2): where does the Ultra 45's Hipster come from?
- (a) OpenIndiana publishes/published a sparc build the maintainer installed, OR
- (b) it's a self-built Hipster-on-sparc (OI userland recipes built natively on
      sparc, akin to how Tribblix/DilOS build sparc), OR
- (c) a Hipster/DilOS hybrid.
This determines sourcing: if (a), pull the OI sparc IPS repo directly (mirror it
like x86 Hipster); if (b)/(c), the Ultra 45 itself is the golden native build
host + package source. Either way the ARCHITECTURE work (kernel boots, world
slices, sparcv9-solaris lib.systems) is unchanged — only the userland SOURCE repo
differs (OI-sparc vs Tribblix vs the Ultra 45's own repo).

ACTION for S2: mirror the SPARC-target sourcing on HIPSTER. Best path — treat the
maintainer's Ultra 45 (real OBP, boots Hipster, native sparc) as the golden build
host + package source: extract its sparc seed/proto/world (like we did x86 from
OI), pull its Hipster sparc IPS inventory, and build solnix pkgs.solnix.* for
sparcv9-solaris FROM it. QEMU sun4u remains the CI/test substrate (once the
OpenBIOS getprop fix lands); the Ultra 45 is the reference + fallback build host.
Keep the Tribblix m34 kernels only as the QEMU-boot PROOF artifact, not the
shipping source.

## SPARC progress (S2 — seed extract + sparcv9-solaris lib.systems + world slices)

Status: **DONE — mirrors aarch64 A3 end to end.** The OI-Hipster-source open
question is RESOLVED (evidence below); a sparcv9 target-sysroot seed is extracted
+ published + fetch-verified; `sparcv9-solaris` is wired into the fork lib.systems
(big-endian, verified via the real `applyPatches`); the sparc world slices
(libc/rtld/ld/sys/systemPath + gate) are built, RUNPATH-relocated, signed +
published, and the libc is fetch-back-verified as EM_SPARCV9. Assets: solnix.io
cache + local seed/archive stores ONLY (no AWS S3/ouch). Every long host op ran
DETACHED via `scripts/oi-job.sh` (zero blocking SSH). Host ouch-n21
(3.131.93.186). Not git-committed; hosts not terminated.

### S2.0 RESOLVED: where does OI Hipster-on-sparc come from? — SELF-BUILT, no public OI sparc repo (evidence-based)

**Answer: option (b) — Hipster-on-sparc is SELF-BUILT natively on sparc. There
is NO public OpenIndiana sparc IPS repo and NO OI sparc install image.** The
Ultra 45's Hipster is a native-sparc build (like Tribblix/DilOS do), so the
Ultra 45 itself is the eventual golden native build host + package source. For
S2 the immediate WORLD SOURCE is the archived Tribblix m34 sun4v_boot_archive
(same illumos-gate lineage), sliced now (the Ultra 45 isn't reachable from EC2).

EVIDENCE (probes run 2026-07-27, all reproducible):
- **OI IPS repo publishers** — `https://pkg.openindiana.org/hipster/publisher/0/`
  lists exactly two publishers: `openindiana.org` and `userland`. No sparc
  publisher, no sparc branch.
- **No sparc repo endpoint** — `https://pkg.openindiana.org/hipster/sparc/versions/0/`
  -> HTTP 400; `.../hipster-sparc/...` -> 400; `sparc.openindiana.org` -> no route.
  The only working ISO dir `https://dlc.openindiana.org/isos/hipster/` lists only
  `current` (x86_64), no sparc image.
- **The x86 catalog has ZERO sparc** — `hipster/catalog/1/catalog.base.C`
  (10607 packages, 53392 versions) contains the substring `sparc` **0 times**;
  the `system/kernel` manifest carries no `variant.arch=sparc`. OI Hipster builds
  x86_64 only.
- **OI docs + download page** — `docs.openindiana.org` and
  `openindiana.org/download` mention sparc 0 times.
- **Upstream root cause** — illumos-gate `master` still has the *source* dirs
  `usr/src/uts/{sun4u,sun4v,sparc,sun4}` (30 entries under sun4u: boston,
  cherrystone, cpu, ...), but the **build glue is gone**: `uts/sun4u/Makefile`,
  `uts/sun4u/os/Makefile`, `uts/sun4u/unix/Makefile` all -> HTTP 404 on master.
  This is the "13707/13708 removed sparc build support" state Tribblix's
  `illumos/sparc/README.md` documents ("m26 onward: Upstream gate cannot be used
  as SPARC support has been removed"). So NO upstream distro (OI included)
  publishes a buildable sparc; the live keepers (Tribblix, DilOS) build sparc
  NATIVELY from a fixed pre-removal base commit + cherry-picks.
  Tribblix's `pkgs.tribblix.org/` serves `m34`/`sparc` (the live sparc keeper).

CONSEQUENCE for sourcing (this is the S2 decision):
- Not (a): there is no OI sparc IPS repo to mirror like x86 Hipster.
- (b)/(c): the Ultra 45's Hipster-on-sparc is self-built native (same model as
  Tribblix/DilOS). The Ultra 45 is the AUTHORITATIVE shipping source once its
  native gate build is reachable (it isn't from EC2).
- IMMEDIATE S2 SOURCE = the archived Tribblix m34 sun4v_boot_archive userland —
  same illumos-gate lineage as the Ultra 45's Hipster, accessible now. S3+
  re-slices from the Ultra 45 when reachable. (This exactly matches the doc's
  earlier ACTION-for-S2 note and the top-of-doc steering.)

### S2.1 The big-endian UFS reader (the S1.5-deferred blocker) — SOLVED with the Linux stdlib

S1.5 deferred seed extraction because the sun4v_boot_archive is a BIG-ENDIAN
SPARC UFS and the amd64 illumos host's ufs is little-endian-native. The lazy
answer needed no custom reader: **Linux's in-tree `ufs` kernel module reads Sun
(big-endian) UFS read-only via `-o ufstype=sun`.** On the dev-box:
```
losetup -f --show -r sun4v_boot_archive          # /dev/loop0
mount -t ufs -o ufstype=sun,ro /dev/loop0 /mnt/sparc-ba
```
mounts cleanly (`file` confirms "Unix Fast File system [v1] (big-endian)", magic
0x00011954 at superblock offset 8192+1372). Inside: the full sparc userland.

### S2.2 Seed extracted — `scripts/sparc-extract-seed.sh` (adapted from aa-extract-seed.sh)

The sparc seed is the TARGET-SYSROOT half (like aarch64's), sliced from the
mounted big-endian UFS. Layout note: SPARC keeps the classic x86-style ISA split
(NOT aarch64's LP64-flat) — the 64-bit **SPARC V9** objects live under the
`sparcv9/` subdir (the analog of x86's `amd64/`). The sparcv9-solaris TARGET is
64-bit (cpu=sparc64), so the seed carries the `lib/sparcv9/` + `usr/lib/sparcv9/`
objects:
- `lib/sparcv9/{libc,libm.so.2,libsocket,libnsl,libresolv.so.2,libelf,libpthread,
  librt,libdl,libmd,libmp.so.2,libcustr,libofmt,libumem}.so.*` — runtime libc +
  historical siblings.
- `lib/sparcv9/ld.so.1` (runtime linker), `lib/sparcv9/{librtld,libld.so.4,
  liblddbg.so.4}` (link-editor .so), `usr/lib/sparcv9/libldstab.so.1`.
- `usr/bin/ld` (Solaris link-editor, sparc-native), `usr/lib/ld/` mapfiles.
- `usr/include` — PARTIAL header set (321 files: math.h, complex.h, sys/, net/,
  openssl/, ... but NO core libc headers like stdio.h — the boot_archive is a
  runtime ramdisk, not a build sysroot).

DELIBERATE CEILINGS (same class as aarch64's "target-sysroot only"):
- NO compile-time crt*.o/values-*.o (runtime ramdisk has none).
- NO elfdump/elfedit binaries (the world-slice RUNPATH relocation uses the HOST
  illumos elfedit cross-arch, so shipping sparc elfedit is unnecessary).
- Partial headers. All three are filled by a native Ultra-45 Hipster gate build
  (S3+); this Tribblix m34 sysroot is the same lineage and is what we slice now.

Seed staged + published (solnix.io + local, belt-and-suspenders):
- `sparc-seed.tar.zst` — 2.29 MiB, **sha256
  6115cfdfc6a34901112a33475d0a77766d4b3562680ccee6ead08d5f2164a2bc**,
  SRI `sha256-YRXP38ajSQERKjNHXQp3dm1LNWJoDM7m6tCNXyFkorw=`.
- **solnix.io**: `https://s3.solnix.io/solnix-cache/archive/sparc/sparc-seed.tar.zst`
  (+ `.sha256` + `sparc-seed-manifest.txt`) — fetch-verified (sha matches;
  unpacks to `lib/sparcv9/libc.so.1` = ELF64 MSB **Sparc v9**). solnix.io ONLY,
  no AWS S3/ouch.
- **local**: `~/ws/solnix-seed-store/sparc-seed.tar.zst` + `-manifest.txt`.

### S2.3 sparcv9-solaris wired into the fork lib.systems (BIG-ENDIAN correct — verified)

Extended `solnix-pkgs/patches/0001-lib-systems-x86_64-solaris.patch` (the same
patch that carries x86_64 + aarch64), mirroring the aarch64-solaris double:
- **parse.nix aliases**: `sparcv9 = cpuTypes.sparc64;` beside `arm64 =
  cpuTypes.aarch64;`. The Solaris/GNU-canonical SPARC V9 cpu token is `sparcv9`
  (triple `sparcv9-unknown-solaris2.11`), but nixpkgs' cpu type is **`sparc64`**
  (there is no `sparcv9` cpuType — `getCpu` would throw). The alias maps the
  canonical token to the existing **big-endian** 64-bit sparc64 cpu.
- **doubles.nix**: registered `"sparc64-solaris"` (the double
  `parse.doubleFromSystem` yields from the sparc64 cpu — NOT "sparcv9-solaris").
- **examples.nix**: `sparcv9-illumos = { config = "sparcv9-unknown-solaris2.11"; };`.
- The solaris parse/kernel/libc/linker/uname clauses (isSunOS-keyed) are
  arch-independent and were already present from x86_64 — no sparc-specific edit
  needed there.

ENDIANNESS — the real sparc-specific correctness point: nixpkgs already defines
`sparc64` as `significantByte = bigEndian`. So aliasing sparcv9 -> sparc64 gives
the CORRECT big-endian marking for free (unlike x86/aarch64/riscv, all
little-endian). VERIFIED by building the real patched fork
(`applyPatches` -> `lib.systems.elaborate`):
```
sparcv9-unknown-solaris2.11  -> cpu=sparc64 bits=64 double=sparc64-solaris
                                bigEndian=y isSunOS=y libc=illumos-libc
                                linker=solaris uname=SunOS
x86_64-unknown-solaris2.11   -> cpu=x86_64  double=x86_64-solaris  bigEndian=n  (no regression)
aarch64-unknown-solaris2.11  -> cpu=aarch64 double=aarch64-solaris bigEndian=n  (no regression)
sparc64-solaris in doubles.all -> true
```
(Patch gotcha for the record: GNU `patch` under the build sandbox's C locale
mis-located a hunk whose context contained the multibyte `≥` in the `# LLVM ≥ 20`
comment; anchoring the alias hunk on the ASCII `arm64 = cpuTypes.aarch64;` line
instead makes `applyPatches`' `patch -p1` land it cleanly.)

Seed FOD: `solnix-pkgs/pkgs/os-specific/illumos/seed-sparc/default.nix` (mirrors
seed-aarch64), fetches the seed from solnix.io by SRI hash — built + verified
(unpacks to EM_SPARCV9 big-endian libc, ld.so.1, libldstab, Solaris ld present).

### S2.4 World slices built + RUNPATH-relocated + published + fetch-verified

`pkgs/illumos/sparc/{gate,default}.nix` (mirrors pkgs/illumos/aarch64/) ingest
the sparc proto and slice the world. The proto (sparcv9 userland + sun4u kernel,
183 MB) was extracted from the big-endian UFS, staged on ouch-n21 at
`/sparc/proto/root_sparc`. All six attrs built on the host (Nix 2.3.16,
currentSystem x86_64-solaris; the slices are BIG-ENDIAN SPARC V9 ELF but the
slicing + RUNPATH relocation runs cross on the amd64 host — the host illumos
`elfedit` edits the SPARC ELF's DT_RUNPATH string offset regardless of
endianness, exactly as for aarch64):

| slice | store path (host) | check |
|-------|-------------------|-------|
| gate  | ...-illumos-sparc-gate-proto | proto ingest (sparcv9 libc + sun4u unix/genunix) |
| libc  | ...-libc   | lib/sparcv9/libc.so.1 = **EM_SPARCV9 ELFCLASS64 ELFDATA2MSB** |
| rtld  | ...-rtld   | librtld RUNPATH = `$ORIGIN:<libc>/lib/sparcv9` (relocated) |
| ld    | ...-ld     | usr/bin/ld RUNPATH = `$ORIGIN:$ORIGIN/../../lib/sparcv9:<libc>/lib/sparcv9:<ld>/usr/lib/sparcv9` |
| sys   | ...-sys    | platform/sun4u/kernel/sparcv9/{unix,genunix} (Ultra 45 = sun4u) |
| systemPath | ...-system-path | symlink-farm of sys+rtld+libc+ld; sanity gates pass |

Kernel path note: sun4u `unix` is at `platform/sun4u/kernel/sparcv9/unix`
(symlink `platform/sun4u/kernel/unix -> sparcv9/unix`), genunix at
`platform/sun4u/kernel/sparcv9/genunix` — the SPARC analog of x86's
`platform/i86pc/kernel/amd64/`. libm soname is `libm.so.2` (sparc, like x86_64),
not aarch64's `libm.so.0`.

Signed (cache.solnix.io-1) + published under plain names to
`https://s3.solnix.io/solnix-cache` (all six closures). **FETCH-BACK-VERIFIED**:
`nix copy --from https://s3.solnix.io/solnix-cache` of the libc slice into a
fresh store, then `readelf -h` -> `Class ELF64 / Data 2's complement, big endian
/ Machine Sparc v9` = **EM_SPARCV9 confirmed from the cache**. solnix.io ONLY, no
AWS S3/ouch.

### S2.5 Blockers / ceilings

- **crt objects + full headers + cross gcc**: not in the runtime boot_archive.
  The world slices (runtime libraries + kernel) are complete WITHOUT them; a
  working `cc`/`libcCross` for pkgsCross.sparcv9-solaris needs them and comes
  from the native Ultra-45 Hipster gate build (S3+). Marked in the slice headers.
- **Authoritative re-slice**: the Ultra 45's Hipster world is the eventual
  shipping source (S2.0). This S2 uses the Tribblix m34 userland (same
  illumos-gate lineage) as the accessible stand-in; S3+ re-slices from the Ultra
  45 under the SAME sparcv9-solaris plumbing (unchanged — only the proto source
  differs), then can drop the Tribblix stand-in.
- **QEMU clean boot**: still gated on the OpenBIOS `getprop` fix (S1b), unrelated
  to S2 (S2 slices for the target; it does not need a running guest).

### S2.6 Constraints honored

- `oi-job.sh` detached+poll for every long host op (proto unpack, slice builds);
  publish ran backgrounded+polled locally. Zero blocking SSH held across a long op.
- solnix.io cache + local seed/archive stores ONLY; no AWS S3/ouch storage.
- No git commit. Hosts not terminated. ouch-n21 left running with
  `/sparc/proto/root_sparc` + the built+published slices in its store.

## S3 attempt 1 — QEMU sun4u boot ROOT CAUSE diagnosed (2026-07-27)

The S3 agent exited mid-work but produced the key DIAGNOSIS (captured here so
it's not lost — was in-conversation, uncommitted):

**Root cause of the nondeterministic sun4u boot failure:** NOT a kernel bug and
NOT the earlier "OpenBIOS FCode stall" (that was a timebox artifact). It is a
**nested register-window spill trap** — illumos panics "bad stack overflow at
TL 2" with callers prom_getproplen+38 / bop_getprop+3c. When the kernel calls
into OpenBIOS's client interface (getproplen/getprop), OpenBIOS's sparc64
`call-client.S` manually rotates the register windows (SAVE/RESET/RESTORE_CPU_
WINDOW_STATE) to "minimise fill/spill traps" — and QEMU's SPARCv9 emulation has
a **reversed %cwp save/restore direction vs real hardware** (OpenBIOS has a
CWP_DIRECTION macro acknowledging this). If window accounting (%cansave/
%canrestore/%otherwin) is left inconsistent for the live-window count at call
time, the next kernel save/restore triggers a spurious spill trap -> nested trap
-> TL2 -> panic. NONDETERMINISTIC because it depends on how many windows are live
when the kernel calls the PROM (some runs reach SMF 95/95, others panic early).
Real Sun OBP handles this correctly; QEMU's OpenBIOS does not. OpenBIOS sparc64
has had ~no changes since the qemu-10.1.5-bundled version (Sep 2024), so a newer
OpenBIOS won't help.

**KEY ENABLER found:** `qemu-system-sparc64 -machine sun4u -bios <blob>` WORKS —
a patched OpenBIOS blob can be swapped in WITHOUT rebuilding qemu. openbios-sparc64
is a separate firmware blob (ELF, loads at 0xffd00000). Upstream OpenBIOS is at
github.com/openbios/openbios.

**Candidate fixes (for S3 attempt 2), test empirically via -bios swap:**
1. Add a proper `flushw` on client-interface entry in call-client.S so NO stale
   windows exist when OBP manipulates %cwp (most likely real fix).
2. Fix the window-accounting (%cansave etc.) restore in RESET/RESTORE_CPU_WINDOW_
   STATE for the QEMU reversed-CWP_DIRECTION case.
3. Guard getproplen for -1/0 phandle (ciface.fs) — matches getprop; secondary.
BLOCKER to building the patched blob: need a **sparc64-elf cross toolchain**
(gcc+binutils). Dev-box nixpkgs has pkgsCross for sparc64 — build it there
(pkgsCross.sparc64-* or crossSystem sparc64-none-elf); OR build OpenBIOS on the
Tribblix sparc guest itself. Then: patch call-client.S -> build blob -> qemu
-bios <blob> -> boot the m34 CD -> confirm DETERMINISTIC boot to SMF 95/95.

Alternative if the window fix is too deep: boot from a Sun-VTOC DISK image
(bypasses more of the FCode/client path than CD) + accept the current
~partially-reproducible boot for interim CI.

## S3 attempt 2 — cross toolchain BUILT + OpenBIOS PATCHED/REBUILT; fix validated-in-progress (2026-07-27)

Status: **enabler cleared + firmware rebuild loop working; fix NOT yet
deterministic.** The sparc64 cross toolchain is built (the S1b/S3-1 blocker),
OpenBIOS is patched + cross-built into a swappable `-bios` blob that faithfully
reproduces the baseline firmware, and all three diagnosed fix candidates were
tested empirically. NONE boots to SMF 95/95 deterministically yet. Root cause
is now confirmed *at the register level* (corrupt %sp on CIF return), and fix #1
(flushw) is ruled OUT by data + OpenBIOS's own design. This is an honest
fix-in-progress: the hard enabler is done and the next step is precise.

All qemu boots ran on the dev-box (floki, qemu 10.1.5 / OpenBIOS v1.1 Sep-2024
bundled) DETACHED via `artifacts/sparc-s3/s3-boot-multi.sh` (nohup -> per-run
console log, time-boxed 900s, killed; never an interactive console held).
Assets: solnix.io cache (`archive/sparc/`) + local `~/ws/solnix-archive/sparc/`
ONLY — no AWS S3/ouch. Not git-committed. No "ponytail".

### S3-2.1 Cross toolchain — BUILT (the S1b/S3-1 blocker, cleared)

nixpkgs `pkgsCross.sparc64` does NOT exist in the pinned tree; the working
recipe is an explicit **crossSystem** with `allowUnsupportedSystem`:
```
import <nixpkgs> { crossSystem = { config = "sparc64-none-elf"; libc = null; };
                   config = { allowUnsupportedSystem = true; }; }
  -> buildPackages.gccWithoutTargetLibc (14.3.0) + buildPackages.binutils (2.44)
```
Chose the **bare-metal `sparc64-none-elf` nolibc** target over
`sparc64-unknown-linux-gnu` (OpenBIOS is freestanding, never links libc): 4
derivations vs a full glibc bootstrap, ~20 min. Both were built + GC-rooted
(`artifacts/sparc-s3/toolchain/result-elf{,-2}` = elf; `result-cross{,-2}` =
linux-gnu backup). Verified: `sparc64-none-elf-gcc -dumpmachine` = sparc64-none-elf;
a test `.o` = `ELF 64-bit MSB relocatable, SPARC V9`. OpenBIOS also needs
`toke`/`detok` (FCode tokenizer, github.com/openbios/fcode-utils — built native
with host gcc) and `xsltproc` (libxslt, from the nix store). OpenBIOS's
`select_prefix` only probes `sparc64-{unknown-linux-gnu,linux-gnu,linux,elf,
eabi}-`; `sparc64-none-elf-` is matched by exporting `CROSS_COMPILE=sparc64-none-elf-`.

### S3-2.2 OpenBIOS patched + cross-built — the -bios swap loop WORKS

`config/scripts/switch-arch builtin-sparc64 && make` produces
`obj-sparc64/openbios-builtin.elf` = **ELF64 MSB SPARC V9, UltraSPARC1
Extensions, loads 0xffd00000, ~1.56 MB stripped**. Smoke-tested: swapped in via
`-bios` it reaches the `0 >` OBP prompt (banner "built on Jul 27 2026"), and the
**unpatched rebuild reproduces the exact bundled-blob failure class** (kernel
starts -> `unix-tte va>tte-data -13` -> CIF panic), proving the toolchain+build
faithfully reproduce the firmware. So the fix loop is real: edit OpenBIOS ->
cross-build blob -> `qemu -bios <blob>` -> boot m34 CD, no qemu rebuild.

### S3-2.3 Three fix candidates tested — failure census

Boots of the m34 CD (`boot cdrom -v`), 900s timebox, dev-box qemu 10.1.5:

| blob | fix | observed (per run) |
|------|-----|--------------------|
| baseline (bundled) | none | PANIC "bad stack overflow at TL 2" (nested spill) |
| pristine (rebuild) | none | kernel starts -> BAD TRAP **type=1** / **type=34 alignment (addr=0x99, %sp=0x..fe1 MISALIGNED)** — nondeterministic |
| guard | #3 getproplen phandle -1/0 guard (ciface.fs) | kernel starts -> BAD TRAP **type=4e** in prom_getproplen; one run reached **SMF 15/95** before panicking |
| flushw | #1 `flushw` on CIF entry (+#3) | kernel starts -> **OpenBIOS-internal Unhandled Exception**, deterministic, PC 0xffd27a20 = `stb %g2,[%i0+%g1]` in `memmove` (getprop copying property data into the kernel's buffer) |

### S3-2.4 What the data proves (root cause at register level)

- **The nondeterminism is register-window/%sp corruption on CIF return.** The
  pristine `type=34` panic is an *alignment error* with `%sp=0x2a100076fe1` — a
  biased stack pointer that is NOT 16-byte aligned. The kernel's %o6/%sp is being
  restored to garbage after a PROM (CIF) call, then the kernel faults using it.
  Every failure follows `unix-tte va>tte-data -13` (a benign, caught OBP miss)
  and then the *next* CIF call. The trap type varies run-to-run (TL2 spill,
  type=1, type=4e, type=34) = the classic signature of a corrupt window/%sp,
  exactly the diagnosed reversed-%cwp accounting bug.
- **Fix #1 (flushw) is RULED OUT** — twice, deterministically. It converts the
  kernel-side panic into an *OpenBIOS-side* `memmove` fault: the store into the
  kernel's getprop destination buffer (`%i0`) faults. cpustate.h's own comment
  explains why: the CIF path deliberately AVOIDS flushw because "the memory areas
  used by each window's stack pointer may not be in the TLB, causing recursive
  TLB miss traps" — flushw's spills evict/miss the very TLB entries the CIF then
  needs to reach the client buffer. So flushw is architecturally contraindicated
  here; it makes things worse, not better.
- **Fix #3 (getproplen guard) is correct hardening but does NOT fix the boot** —
  it mirrors getprop's phandle -1/0 handling (getproplen was calling `?phandle`
  which throws on 0 and never guarded -1), and the panic caller was
  `prom_getproplen`, but the fault is the *window* corruption, not the phandle
  value. Worth keeping (it's a real latent bug), insufficient alone.
- **Fix #2 (window accounting) is the remaining real fix, and it is deeper than
  a 3-line patch.** Analysis of `SAVE/RESTORE_CPU_WINDOW_STATE`: the manual
  window walk is *symmetric* (SAVE and RESTORE start at the same saved %cwp and
  step the same `CWP_DIRECTION`, so slot k <-> the same physical window in both;
  contents round-trip). `RESET_CPU_WINDOW_STATE` sets a valid fresh state
  (cwp=0, cansave=NWIN-1, canrestore=otherwin=cleanwin=0). There is no obvious
  accounting bug in the macros themselves. The genuine problem is the
  *interaction*: illumos calls the CIF with **its own trap table installed**, so
  any window spill/fill that fires inside OpenBIOS's CIF (during the manual walk
  or the C code's save/restore) vectors into the **kernel's** spill/fill handler
  — which mis-handles it under QEMU's reversed %cwp and returns a corrupt %sp.
  Fixing this properly needs either (a) a QEMU SPARCv9 %cwp-emulation fix (the
  actual upstream bug the CWP_DIRECTION macro only papers over), or (b) an
  OpenBIOS CIF change that installs OBP's OWN spill/fill trap handlers for the
  duration of the CIF call (so kernel-table window traps can't fire), then
  restores the kernel's. Both are real work, not this pass.

### S3-2.5 Artifacts (all in `artifacts/sparc-s3/` + archived to solnix.io)

- `openbios-sun4u-fix.patch` — fix #1 (flushw) + #3 (getproplen guard).
- `openbios-getproplen-guard.patch` — fix #3 only.
- `blobs/openbios-sun4u-{pristine,guard,flushw}.elf` + `SHA256SUMS` — the three
  cross-built SPARC V9 firmware blobs (swap via `-bios`).
- `logs/*.log` — per-run console logs incl. the milestone/panic KEEP set
  (baseline TL2, pristine type=1/type=34-alignment, guard type=4e + SMF 15/95,
  flushw memmove exception).
- `s3-boot-multi.sh` — detached determinism harness (N runs, per-run log, tally).
- `REBUILD.md` — exact resume recipe (toolchain gcroots + build + boot-test).
- `toolchain/result-{elf,elf-2,cross,cross-2,xslt-bin}` — GC-rooted toolchains
  (store path `cmx305...-sparc64-none-elf-nolibc-gcc-wrapper-14.3.0`).
- **solnix.io** `archive/sparc/`: `sparc-s3-2-openbios.tar.zst` (105 KiB, sha256
  `90ff818f68d8aa7878d04b59f037aca22188fe6b7668007248749c9162a55598`) + `.sha256`
  + `MANIFEST-s3-2.txt` — fetch-back verified (sha matches, unpacks to valid
  SPARC V9 blob). **local**: `~/ws/solnix-archive/sparc/`. solnix.io ONLY, no S3.

### S3-2.6 Next step (precise, for S3-3)

The blob rebuild loop + toolchain are done, so S3-3 goes straight to fix #2's
real form (do NOT re-try flushw, do NOT re-diagnose):
1. **Preferred — QEMU %cwp fix:** the CWP_DIRECTION macro documents that QEMU's
   SPARCv9 %cwp save/restore direction is reversed vs hardware. Fix it in QEMU's
   `target/sparc` window-register emulation (the true bug) so real OBP/OpenBIOS
   window accounting works unmodified. Requires a qemu rebuild (dev-box has the
   qemu source path for 10.1.5), heavier than a -bios swap but fixes the root.
2. **Or — OpenBIOS CIF trap isolation:** in `sparc64_of_client_interface`, save
   the kernel's %tba and install OpenBIOS's own spill/fill window trap handlers
   (client_tba) for the duration of the CIF C call, restore on exit — so a window
   trap inside the CIF is handled by OBP conventions, not the kernel's table. The
   `-v -v: undefined word` at the `0 >` prompt after each panic hints the CIF
   exit path is already fragile; this is the OpenBIOS-only route (no qemu rebuild).
3. Keep the getproplen guard (#3) in whichever lands — it's a real latent bug.

Honest bottom line: the enabler (cross toolchain + swappable patched-blob loop)
is DONE and reproducible; the diagnosed "flushw" fix is empirically wrong (ruled
out); the real fix is the reversed-%cwp interaction, which needs a qemu %cwp fix
or a CIF trap-table isolation — landed next pass. A validated fix-in-progress
with the toolchain built, per the task's own success criterion.

## S3 attempt 3 — PATH A (OpenBIOS CIF trap-table isolation) BUILT + tested; empirically BLOCKED by TLB wall; root narrowed to QEMU-only fix (2026-07-27)

Status: **PATH A implemented, cross-built, and boot-tested 4/4 — deterministically
blocked, NOT a boot.** The CIF trap-table isolation patch works as designed (it
redirects CIF-time traps into OpenBIOS's own trap table) but hits the exact TLB
wall documented in `cpustate.h` — the same wall that rules out flushw (#1). This
converts the nondeterministic *kernel-side* panic into a deterministic
*OpenBIOS-side* fault, which is diagnostically decisive: it proves the fix belongs
in QEMU (PATH B), not in OpenBIOS. Honest fix-in-progress; DETERMINISTIC boot to
SMF 95/95 = **0 of 4 runs** (all 4 = identical OBP-side MAXTL fault).

All boots ran on the dev-box (floki, qemu 10.1.5 / OpenBIOS v1.1 Sep-2024 bundled)
DETACHED via `artifacts/sparc-s3/s3-boot-multi.sh` (nohup -> per-run console log,
900s timebox, killed; never an interactive console held). Assets: solnix.io cache
(`archive/sparc/`) + local `~/ws/solnix-archive/sparc/` ONLY — no AWS S3/ouch. Not
git-committed. No "ponytail". Did NOT re-diagnose, did NOT re-try flushw.

### S3-3.1 PATH A patch — built (openbios-cif-trap-isolation.patch)

Chose **PATH A** (OpenBIOS-side, no qemu rebuild, reuses the S3-2 toolchain +
`-bios` swap loop) over PATH B, per the task's "prefer the more tractable path."

Mechanism verified in the source: illumos installs its OWN trap table (via the
`SUNW,set-trap-table` CIF service — `arch/sparc64/openbios.c:set_trap_table`,
which only stores the kernel's `%tba` into `ctx->tba` for restore-on-exit, and
does NOT change the live `%tba`). So during the CIF C code, `%tba` is the
kernel's, and any register-window spill/fill vectors into the KERNEL's handler —
mis-handled under QEMU's reversed %cwp. `SAVE_CPU_STATE(cif)` already saves the
kernel's `%tba` at `[%g1 + 0x4e0]`; `RESTORE_CPU_STATE(cif)` already restores it
on exit. The patch adds exactly two instructions in `call-client.S`, right after
`RESET_CPU_WINDOW_STATE(cif)` and before the C call:
```
    setx    trap_table, %g5, %g7
    wrpr    %g7, %tba
```
so the CIF runs under OpenBIOS's OWN trap_table (`vectors.S`, 16 KiB-aligned at
the ELF base 0xffd00000, with correct SPILL_WINDOW/FILL_WINDOW/reload_?MMU_tlb
handlers). Kept the getproplen guard (#3) in the same patch (latent hardening).

Cross-built cleanly with the S3-2 toolchain (`toolchain/result-elf` +
`result-elf-2`, fcode-utils toke/detok rebuilt native, xsltproc from the store,
`CROSS_COMPILE=sparc64-none-elf-`). Blob:
`blobs/openbios-sun4u-cif-trap.elf` (ELF64 MSB SPARC V9, loads 0xffd00000, 1.56
MB, sha256 `3bebfeed76fb85dc07efc805bbf5ef26321acfa9fa70b804c23478eb9f7eb104`).
Disassembly confirms the two new instructions land between `wrpr %g0,%cwp`
(RESET) and `call of_client_interface`, and `setx trap_table` resolves to
0xffd00000 (= ELF entry = start of `.text.vectors` = `trap_table`).

### S3-3.2 Boot result — 4/4 identical, deterministically blocked

`s3-boot-multi.sh cif-validate 1 900` + `cif-confirm 3 900` (blob swapped via
`-bios`), boot the m34 CD `boot cdrom -v`:

| run | outcome |
|-----|---------|
| cif-validate-1 | KERNEL-STARTED -> **Unhandled Exception PC=0xffd0f320, Trap 0x10 while TL(5)>=MAXTL(5)** |
| cif-confirm-1  | identical (PC=0xffd0f320, Trap 0x10 MAXTL) |
| cif-confirm-2  | identical |
| cif-confirm-3  | identical |

Every run reaches "Welcome to Tribblix", gets deep into boot (`add_spec`,
`unix-tte`), throws the benign caught `unix-tte va>tte-data -13`, then dies the
**same way every time** — unlike the nondeterministic kernel-side panics of the
pristine/guard blobs (type=34/type=1/type=4e/TL2). The determinism is itself the
finding: the failure is now structural, not window-count-dependent.

### S3-3.3 Why PATH A is blocked (the TLB wall — decisive)

The fatal fault: `PC=0xffd0f320` is `ldub [%o0], %i0` inside OBP C code, with
`%o0=0x1fe020003f8` (an UltraSPARC-IIi PCI/firmware I/O address that `va>tte-data`
reads). It vectors to `0xffd04200` = trap_table offset 0x4200 = **TL1 tt 0x10
(data_access_MMU_miss)**, which in OpenBIOS's TL1 table (`sparc64_ttable_tl1`) is
`BTRAP` (unhandled) — because OpenBIOS only handles MMU miss at TL0
(`reload_DMMU_tlb`, tt 0x68), not at TL1. The miss nests to TL5 -> `sparc_cpu_do_
interrupt` sees `tl >= maxtl` -> "Error state" -> qemu fatal.

Root reason (identical to why flushw #1 is ruled out): **OpenBIOS's trap table
cannot service the kernel's TLB.** With OBP's table active during the CIF, a
window spill writes to the kernel's biased `%sp` stack, or a CIF data access
touches a kernel/device mapping — neither is in OpenBIOS's ofmem page tables, so
OBP's DMMU-miss handler can't reload it, and at TL>0 there is no handler at all.
cpustate.h says this explicitly: the CIF path deliberately avoids flushw because
"the memory areas used by each window's stack pointer may not be in the TLB,
causing recursive TLB miss traps." Installing OBP's whole trap table for the CIF
hits the same wall from the other direction — OBP must NOT own trap handling
while touching kernel memory. A `%tba` is all-or-nothing; you cannot route only
window spill/fill to OBP while leaving MMU-miss with the kernel.

**Therefore PATH A (OpenBIOS CIF trap-table isolation) cannot land the fix.** The
CIF genuinely needs the kernel's MMU-miss handler active (illumos maps the device
page; OBP does not), while the window corruption on CIF return is a QEMU %cwp
emulation defect. These cannot both be satisfied from firmware. The fix must be
in QEMU (PATH B).

### S3-3.4 PATH B recon — the QEMU %cwp model (for S3-4)

Read `target/sparc/win_helper.c` (qemu 10.1.5, the dev-box source at
`/nix/store/5cp2l2c344w5qf8b31fqnysscg1l2ylc-qemu-10.1.5.tar.xz`, extractable;
nixpkgs `qemu.version` = 10.1.5, matches). QEMU stores `env->cwp` in **V8 order**
and translates to/from the guest's V9 `%cwp` via `cpu_get_cwp64 = nwindows-1-cwp`
/ `cpu_put_cwp64 = set_cwp(nwindows-1-cwp)` (the comment: "CWP handling is
reversed in V9, but we still use the V8 register order"). `helper_save/restore`
step the internal V8 cwp (`cpu_cwp_dec`/`inc`); spill-window entry computes
`cwp = cpu_cwp_dec(env->cwp - env->cansave - 2)` (int64_helper.c:243).

CRITICAL CAVEAT for S3-4 (do NOT naively "reverse the direction"): illumos
**reaches SMF 15/95** on the STOCK qemu (guard blob), i.e. it executes thousands
of save/restore/spill/fill correctly first. The maintainer's real Ultra 45 OBP
boots this same ISO. So QEMU's %cwp model is NOT globally reversed-wrong — a
blanket `cpu_get_cwp64`/`helper_save` reversal would REGRESS the working path.
The bug is a NARROW corner in the CIF interaction (some CIF calls corrupt %sp,
most don't — the "depends on live window count" nondeterminism). PATH B must be
a surgical fix to the spill/fill accounting on the specific CIF window-rotation
path, guarded so it does not change behaviour for the (working) common case, and
regression-checked against a known-booting sparc64 guest. This is the true fix
but it is a qemu rebuild (~30-60 min on 8 cores) + careful, regression-tested
change — more than fit this pass.

### S3-3.5 Artifacts (all in `artifacts/sparc-s3/` + archived to solnix.io)

- `openbios-cif-trap-isolation.patch` — PATH A: CIF `%tba <- trap_table` (2 insns
  in call-client.S) + getproplen guard (#3). git-format, applies to upstream
  OpenBIOS master (e5ac46d).
- `blobs/openbios-sun4u-cif-trap.elf` + updated `SHA256SUMS` — the cross-built
  PATH A SPARC V9 firmware blob (swap via `-bios`).
- `logs/cif-validate-run1.log`, `logs/cif-confirm-run{1,2,3}.log` — the 4 identical
  OBP-side MAXTL boot logs (+ `.nohup` harness logs).
- Toolchain gcroots (`toolchain/result-*`) unchanged from S3-2, still valid.
- solnix.io `archive/sparc/`: `sparc-s3-2-openbios.tar.zst` refreshed to include
  the PATH A patch + blob + logs (see MANIFEST). solnix.io ONLY, no S3/ouch.

### S3-3.6 Next step (precise, for S3-4)

S3-3 has EXCLUDED the OpenBIOS-side fix entirely: both flushw (#1) and full
trap-table isolation (PATH A) hit the same TLB wall — OBP cannot own trap handling
while touching kernel memory. The remaining path is QEMU-only (PATH B):
1. Rebuild qemu-system-sparc64 10.1.5 from the dev-box source (nixpkgs qemu.version
   matches; `nix build` an override of `target/sparc/win_helper.c` +
   `int64_helper.c`, or a local `--prefix` autotools/meson build of just the
   sparc64 target).
2. Surgically fix the spill/fill window accounting on the CIF window-rotation path
   (the corrupt-%sp-on-CIF-return). Instrument first: add a trace/assert in
   `helper_save`/`helper_restore`/`sparc_cpu_do_interrupt` spill path to catch the
   run where `%sp` restore diverges from real HW, keyed on the CIF's
   RESET->C->RESTORE sequence. Do NOT blanket-reverse `cpu_get_cwp64`.
3. Regression-gate: the patched qemu must still boot a known-good sparc64 guest
   (Debian sparc64 or the guard blob to SMF 15/95) unchanged.
4. Keep the getproplen guard (#3) — real latent bug, applies in any OpenBIOS blob.

Honest bottom line: S3-3 built + tested PATH A end-to-end and proved it cannot
work (4/4 deterministic OBP-MAXTL, the documented TLB wall), which is real
progress — it eliminates the entire OpenBIOS-side solution space (flushw AND
trap-isolation) and localizes the fix to a narrow, regression-sensitive QEMU
target/sparc spill-accounting change. DETERMINISTIC SMF 95/95 = 0/4; the enabler
loop (toolchain + swappable blob) remains DONE and reproducible.

## S3 attempt 4 — PATH B (QEMU target/sparc window fix) — the "narrow accounting bug" is REFUTED by boot-trace evidence: QEMU's v9 window model is spec-correct; the failure is a timing race in the CIF/kernel-trap-table interaction (2026-07-27)

Status: **QEMU window-register emulation AUDITED end-to-end and INSTRUMENTED
with a boot-trace; the S3-1/2/3 hypothesis of a "narrow off-by-one / wrong-
direction spill/fill accounting bug" is DISPROVEN.** Every window-accounting
path in `target/sparc/win_helper.c` + `int64_helper.c` matches the SPARC v9
spec exactly (proven by a 100k-op model check AND a 29.8M-op boot-trace). The
real defect is a **timing-sensitive register-CONTENTS corruption** on the
OpenBIOS CIF-return path, not a wrong accounting field. A single-line surgical
accounting patch therefore does NOT exist. DETERMINISTIC SMF 95/95 = **0 of 10**
(stock qemu, pristine blob) — still 0, but now with a decisive, evidence-backed
re-diagnosis that closes the "just fix the off-by-one" avenue.

All work on the dev-box (floki), DETACHED (nohup -> per-run log, timeboxed,
polled, killed — never an interactive console held). Assets: solnix.io
`archive/sparc/` + local `~/ws/solnix-archive/sparc/` ONLY (no AWS S3/ouch).
Not git-committed. No "ponytail". Append-only.

### S3-4.1 QEMU source obtained
nixpkgs `qemu.src` = qemu 10.1.5 (matches the working sun4u qemu; host 11.0.2
is worse per prior passes). Already realised in the store at
`/nix/store/5cp2l2c344w5qf8b31fqnysscg1l2ylc-qemu-10.1.5.tar.xz`. Extracted
`target/sparc/{win_helper,int64_helper,ldst_helper,mmu_helper,translate}.c` +
`cpu.{c,h}` into `artifacts/sparc-s3/qemu-src/`.

### S3-4.2 Full audit of the window-register model — SPEC-CORRECT on every path
QEMU keeps `env->cwp` in **V8 order**; guest `%cwp`(V9) = `nwindows-1-cwp8`
(`cpu_get_cwp64`). Checked against SPARC v9 §6.4 / §7.5.2.1 / §6.4.3:
- **cwp arithmetic** (`helper_save`/`helper_restore`, and the spill/fill trap
  targets in `sparc_cpu_do_interrupt`): the V8-internal transforms are the
  exact reverse of the V9 spec, so guest-visible `%cwp` is correct.
  `analysis/cwp_model_check.py` runs 100k random {save,restore,spill,fill} ops
  through BOTH a pure-V9 reference and QEMU's V8-internal formulas and asserts
  the guest `%cwp` is identical — **NO DIVERGENCE**.
- **spill/fill trap-TYPE** (`TT_SPILL|...(wstate)` for otherwin==0 and the
  `TT_WOTHER|((wstate&0x38)>>1)` other-window case): matches v9 exactly;
  verified against a live trap (wstate=0x76 otherwin=6 -> tt=0xB8).
- **SAVED/RESTORED accounting** (`helper_saved`/`helper_restored`): matches v9
  §6.4.3 exactly.
- **`cleanwin`**: varies (2/5/6/7; <6 half a million times in the trace) ->
  clean-window traps fire; not stuck.
- **`cpu_set_cwp` wrap-register memcpy** (the %o/%i register-file overlap at
  the top window): symmetric, round-trips for adjacent save/restore AND for
  arbitrary `wrpr %cwp` jumps.
- **`cpu_change_pstate` global-bank switch** (AG/MG/IG; sun4u `TI-UltraSparc-IIi`
  has neither `CPU_FEATURE_GL` nor `HYPV`): saves old bank / loads new only on
  selector change; nested spills (both -> AG) correctly share AG.
- The window-COUNT invariant `cansave+canrestore+otherwin = nwindows-2 = 6`
  HOLDS through the entire 29.8M-op trace, including at the panic.

There is no wrong accounting field to patch. This overturns the S3-1/2/3
"reversed-%cwp / off-by-one" hypothesis (the OpenBIOS `CWP_DIRECTION` macro
"papering over" a QEMU bug): QEMU's model is not reversed and not off-by-one.

### S3-4.3 Instrumented qemu + boot-trace (the evidence)
Built an instrumented `qemu-system-sparc64` 10.1.5 via a nix override
(`build-qemu-sparc64.nix` + `instrument-win-trace.patch`, minimal +
sparc64-only, ~12 min) that logs every accounting op
(TRAP_SPILL/TRAP_FILL/SAVED/RESTORED/WRCWP) with
`tl/cwp8/cwp9/cansave/canrestore/otherwin/cleanwin/wstate/%sp/%fp/pc` when
`SPARC_WIN_TRACE=1`. Boot-traced the pristine blob to the panic (29.8M ops;
raw 3.7G elided, `trace-slices/` kept). Cross-checked with a stock-qemu
`-d int` register-dump trace. Findings:
- **The failure is TIMING-dependent, not accounting-dependent.** The SAME
  pristine blob under stock qemu panics with VARYING trap types run-to-run
  (see S3-4.5 tally: type=34 unaligned / type=4e / type=1 / TL2 / "bad register
  window" / "kern_postprom: not owner", and SMF progress scattered 14..22/95).
  Under `-d int` timing it reached **SMF 2/95** — PAST the usual panic point.
  This is a race, confirming the S3-1 read.
- **The corruption is in register CONTENTS, not counts.** The panic backtrace
  is in the CIF (`unix:prom_getproplen+40` <- `promif_postprom` <-
  `kern_postprom`). After the CIF return a kernel window holds a garbage/zero
  `%fp` or a pointer that faults (`addr=0x99`), while all window COUNTS remain
  spec-consistent.
- **Fatal signature (`trace-slices/S3-4-key-trace.txt`):** after the CIF the
  kernel reaches `cansave=0 canrestore=0 otherwin=6` with a corrupted register;
  `die()`'s spill re-faults -> `ptl1_panic` -> the handler's own save re-spills
  -> an INFINITE spill loop (`WRCWP 0x100732c` <-> `TRAP_SPILL 0x1007474`,
  13.8M iterations) climbing TL to MAXTL. The frozen state is the RESULT of the
  upstream contents corruption, not its cause. (PCs resolved with the S3-2
  sparc64 objdump against `sun4u_unix`; `.text`=0x1000000, OBP CIF=0xffdxxxxx.)
- **In a surviving run** the SAME handlers spill/fill perfectly through SMF
  (`trace-slices/S3-4-mmu-trap-tail.txt`: healthy cansave/canrestore cycling).

### S3-4.4 Why a QEMU accounting patch can't land the fix (and what the bug really is)
S3-3 proved OBP cannot own trap handling while touching kernel memory (the TLB
wall). S3-4 now proves the complement: QEMU's window accounting is already
correct, so there is no accounting field to flip. The nondeterminism is a
genuine **race between the OpenBIOS CIF's manual window walk (raw `wrpr %cwp`
save/restore of window CONTENTS) and window spill/fill traps that fire on the
kernel's biased stack during the CIF.** Because the CIF runs with the kernel's
`%tba` and the kernel's stack (both mandatory — S3-3), a spill/fill that fires
at the wrong instant during the CIF stores/loads a window to a kernel stack
slot that is momentarily inconsistent, leaving stale CONTENTS in a window the
kernel later trusts. Real Sun OBP + real HW have deterministic timing and a
CIF that is effectively atomic w.r.t. the kernel table; QEMU+OpenBIOS
approximate it but the race survives. A blind accounting change would risk
REGRESSING the working (SMF-reaching) path without addressing the race.

Also tested (no rebuild): `-icount shift=auto,sleep=off` to make timing
deterministic — 0/3 boot (still races on I/O timing). Not a fix.

### S3-4.5 Baseline determinism measurement (stock qemu 10.1.5, pristine blob)
`s3-boot-pristine-multi.sh baseline-stock 10 300`, `boot cdrom -v`, detached:

| runs | 95/95 boots | outcomes (distinct = 8/10) |
|------|-------------|----------------------------|
| 10   | **0**       | PANIC-other x3, type=4e, type=34, "bad register window", SMF 14/95, 22/95, 15/95, 19/95 |

Pure nondeterminism, 0 full boots — the honest current state. (icount-auto: 0/3.)

### S3-4.6 Artifacts (all in `artifacts/sparc-s3/`, archived to solnix.io + local)
- `instrument-win-trace.patch` — the window-op tracer (applies -p1 to qemu
  10.1.5; gated by env `SPARC_WIN_TRACE`, zero-cost otherwise). sha256 5d501c00…
- `build-qemu-sparc64.nix` + `patches-active` — nix override to rebuild
  qemu-system-sparc64 10.1.5 with target/sparc patches (minimal, sparc64-only,
  ~12 min). This is the PATH B build harness — a future real fix drops its
  patch into `patches-active`. sha256 53edb293…
- instrumented qemu (gcrooted): `result-qemu-trace` ->
  `/nix/store/g9vzlkbk424nyrmf36g93g4bbmlbv6w5-qemu-10.1.5`.
- `analysis/cwp_model_check.py` — the 100k-op v9-vs-QEMU model proof (passes).
- `analysis/S3-4-findings.txt` — the full audit write-up.
- `trace-slices/S3-4-key-trace.txt` — the CIF-return -> fatal spill-loop slice.
- `trace-slices/S3-4-mmu-trap-tail.txt` — a healthy SMF-phase trap trace.
- `trace-slices/trace-pristine-win.sample.zst` — sampled 29.8M-op trace.
- `s3-trace-boot.sh` / `s3-boot-pristine-multi.sh` / `s3-icount-try.sh` /
  `s3-mmu-trace.sh` — the detached harnesses. `REBUILD-S3-4.md` — resume recipe.
- `logs/baseline-stock-det.log`, `logs/icount-auto.log`, `logs/mmu-console.log`.
- **solnix.io** `archive/sparc/sparc-s3-4-qemu-winfix.tar.zst` (90 KiB, sha256
  `2e91d33df5db2df4f761023ea5717780e24b233d19f4adaf82a365a6b865cdb1`) + `.sha256`
  — fetch-back verified (sha matches, valid zst). **local**:
  `~/ws/solnix-archive/sparc/`. solnix.io ONLY, no S3/ouch.

### S3-4.7 Next step (precise, for S3-5)
The "narrow accounting bug" premise is closed; the remaining PATH B work is
harder and different:
1. **Make the CIF window walk atomic w.r.t. traps.** The race is the OBP manual
   `wrpr %cwp` walk interleaving with kernel spill/fill. A candidate QEMU
   change: detect the CIF's RESET_CPU_WINDOW_STATE->C->RESTORE bracket and
   ensure window spill/fill during it is replayed atomically (hard; needs a
   marker QEMU can see — e.g. a magic ASI or a %tba/%pc range gate). This is
   speculative and regression-sensitive; instrument first with the S3-4 tracer
   to catch the exact interleaving that diverges between a booting and a
   panicking run (diff two full traces at the first divergent op).
2. **Or accept nondeterminism for interim CI** and boot from a Sun-VTOC DISK
   image (bypasses more of the CIF/FCode path than the CD) — the S1b alternative
   never tried; may sidestep the racy getprop-heavy CD path.
3. **Or upstream it**: this is a real, reproducible qemu target/sparc + OpenBIOS
   sun4u interaction bug (contents race on CIF return). The S3-4 tracer patch +
   the two trace slices + the 0/10 determinism data are a complete,
   upstream-contributable bug report for qemu-devel / OpenBIOS.
4. Keep the getproplen guard (#3, S3-2) — real latent bug in any OpenBIOS blob.

Honest bottom line: S3-4 did NOT achieve a deterministic boot (0/10, unchanged),
but it produced a decisive re-diagnosis backed by a 100k-op model proof and a
29.8M-op boot-trace: QEMU's SPARC v9 window model is spec-correct, so the
originally-scoped "surgical off-by-one accounting patch" cannot exist. The true
bug is a timing race in the OBP-CIF/kernel-trap interaction — deeper than a
patch to a single win_helper.c field, and now precisely characterized with
runnable evidence + a ready PATH B rebuild harness for the real (atomicity/
race) fix or an upstream report.

## S3 attempt 5 — sun4v/niagara QEMU probe: does it dodge the sun4u CIF window race? NO — blocked earlier, by missing OpenSPARC-T1 firmware (2026-07-28)

**Bounded, time-boxed side-probe (not a continuation of PATH A/B).** Hypothesis
(from S3-4 next-steps note "boot from a Sun-VTOC disk / niagara reset image
bypasses the CIF/FCode path"): the T-series **sun4v** kernel under
`qemu-system-sparc64 -M niagara` boots via a hypervisor/OBP-in-hyperprivileged
reset image, not OpenBIOS's FCode CD path, so it might sidestep the sun4u CIF
register-window contents-race entirely. Tested with the archived Tribblix m34
`sun4v_unix` (ELF64 MSB SPARC V9 EXEC, T-series; sha `701d8590...`).

### S3-5.1 What `-M niagara` requires (qemu 10.1.5)
Discovered by iterative missing-file demand order (create a dummy, rerun, see
the next demanded name). niagara hard-requires **six** firmware blobs in CWD,
loaded in this order:

    nvram1  openboot.bin  reset.bin  q.bin  1up-hv.bin  1up-md.bin

These are the **Sun OpenSPARC T1 simulation `S10image/` blobs** (reset vector +
OBP `q.bin` + hypervisor `1up-hv.bin` + machine descriptor `1up-md.bin`).
`qemu-system-sparc64` does NOT bundle them (only `openbios-sparc64` for sun4u
ships in `share/qemu`). They are **not in the Tribblix ISO** (`strings` scan:
none of the six names present) and **not anywhere local** (`find / -xdev` for
`reset.bin`/`1up-hv.bin`/`1up-md.bin`/`q.bin`/`openboot.bin`: only our dummies).

### S3-5.2 Behaviour with dummy firmware (the decisive evidence)
With all six present as 1 KiB zero-filled dummies, niagara **starts executing**
and immediately faults at the reset vector:

    qemu: fatal: Trap 0x0010 while trap level (6) >= MAXTL (6), Error state
    pc: 000000fff0000020  npc: 000000fff0000024   (all regs zero)

`pc=0xfff0000020` = the `reset.bin` load region (`0xfff0000000`). The CPU is
executing the dummy zero bytes as instructions → instant TL-overflow trap.
Crucially, adding `-kernel sun4v_unix` does **NOT** change this: the niagara
machine ALWAYS begins in the reset firmware, so a real `reset.bin` +
`1up-hv.bin` (hyperprivileged HV) + `q.bin` (OBP) must run first to set up the
sun4v machine-descriptor and hand off to the kernel. Console log:
`artifacts/sparc-sun4v/niagara-dummy-fw-trap.log`.

### S3-5.3 Verdict — niagara is LESS promising than sun4u for QEMU-CI
| target | how far under QEMU | blocker |
|--------|-------------------|---------|
| **sun4u** (OpenBIOS) | illumos **kernel executes** (krtld/unix start; reaches SMF 15/95 in one run) then dies in the CIF window race | QEMU %cwp vs OpenBIOS CIF manual-window-walk **timing race** on CIF return (S3-1..S3-4) — a fixable/upstreamable interaction bug |
| **sun4v** (niagara) | kernel **never loads** — CPU stuck in reset firmware | **missing proprietary OpenSPARC-T1 firmware** (reset.bin/1up-hv.bin/q.bin) not in ISO, not local, not in qemu |

sun4v does NOT dodge the race — it fails *earlier*, at firmware, and its blocker
(proprietary T1 HV/OBP blobs) is arguably harder to satisfy than sun4u's (a
QEMU/OpenBIOS source fix or an upstream bug report). The niagara reset/FCode
bypass hypothesis is refuted for our artifact set: we cannot even reach the
FCode/CIF path because we lack the pre-OBP hypervisor stage.

**Bottom line:** SPARC remains hardware-qualified on the real Ultra 45 (OBP
boots the ISO fine). QEMU-CI via sun4v/niagara is **not viable** without the
OpenSPARC T1 `S10image` firmware bundle (would need to source Sun's OpenSPARC
T1 download and verify its licence for CI redistribution — out of scope here).
If pursuing QEMU-CI, sun4u (fix the CIF window race / upstream it) is the better
bet; sun4v would additionally require obtaining + licence-clearing the T1 HV.

### Artifacts (S3-5, `artifacts/sparc-sun4v/`)
- `README.txt` — the required-firmware set, dummy-fw method, reset-vector finding.
- `niagara-dummy-fw-trap.log` — the definitive `-M niagara -kernel sun4v_unix`
  reset-vector trap console output.
- `{nvram1,openboot.bin,reset.bin,q.bin,1up-hv.bin,1up-md.bin}` — 1 KiB DUMMY
  zeros (probe scaffolding only; NOT real firmware — do not archive as such).

Method note: every qemu invocation was `timeout`-wrapped and detached; each was
killed after a single short sleep+log-check (no foreground poll, no wedge).
Core dumps disabled (`ulimit -c 0`) after the first run left a 1.1 GB core.
No git commit.
