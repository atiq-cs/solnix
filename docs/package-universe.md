# Package universe: Hipster + OmniOS/SmartOS/Tribblix delta

Answers the "how many packages / what else to target / what's beyond Hipster"
questions. Numbers from docs/registry/hipster-packages.tsv (10,608-row inventory).

## Hipster (our primary upstream) — the numbers

| Status        | Count | Notes |
|---------------|-------|-------|
| **current**   | **5,920** | live packages — the real build target |
| renamed       | 485   | alias FMRIs -> current (not separate builds) |
| incorporation | 8     | version-lock meta-pkgs (not software) |
| obsolete      | 4,194 | dead/superseded — DO NOT build |
| **total rows**| 10,608 | the full IPS catalog we inventoried |

**Real target ≈ 5,920 current packages** (of which 5,371 userland, 503 osnet,
plus l10n/ips/install/cde/xvm). The "6,413 active" = current+renamed; renamed are
aliases so the build target is the 5,920 current.

## Beyond Hipster — other illumos distros' unique packages worth targeting

Hipster has the BROADEST IPS set, but each fork ships things Hipster doesn't.
Worth adding to the target universe (Phase 3 breadth):

### SmartOS / illumos-joyent (the biggest delta)
- **bhyve** — the illumos bhyve port (hardware VM). *Now also in OI, but SmartOS
  is the reference impl.* HIGH value (Phase 3 core-Solaris item).
- **KVM** — SmartOS-only illumos KVM port (NOT mainline). Verify before scoping;
  bhyve is the better long-term bet.
- **LX-branded zones** — run Linux ELF binaries. In-gate (from Joyent) but SmartOS
  exercises it most. HIGH value.
- **vmadm / imgadm** + the SmartOS VM/image tooling (JSON-driven zones/VMs).
- **pkgsrc** — SmartOS's primary userland is **pkgsrc** (NetBSD's), NOT IPS. That's
  a WHOLE SEPARATE ~20k-package universe (see below).

### OmniOS
- **Kayak** installer + **OmniOS-specific packaging** (they use IPS too, leaner set).
- Mostly a SUBSET of Hipster for userland, but their LTS/stable curation +
  server-focused extras (some networking/storage bits) differ.
- **ooce** (OmniOS Extra) publisher — a curated extra-packages repo; some pkgs
  packaged there but not in Hipster.

### Tribblix
- The **SPARC** build (our S1 source!) — Tribblix is the main live sparc illumos.
- **zap** package manager + Tribblix "overlays"; some retro/niche pkgs.

### The big one: pkgsrc (SmartOS + others)
- pkgsrc is a cross-platform source packaging system (NetBSD) with **~20,000
  packages**, many building on illumos. SmartOS ships pkgsrc binaries.
- This DWARFS the IPS set. DECISION: solnix packages natively via Nix (our
  mk-userland-pkg), so we target the SOFTWARE pkgsrc packages (upstream tarballs)
  directly, not pkgsrc-the-tool. But pkgsrc's illumos patch set is a GOLD MINE of
  "how to build $X on illumos" fixes — mine it for our heavy-tool patches.

## Recommendation
1. Finish the 5,920 Hipster current set (in progress: 2,004 cached).
2. Add the SmartOS core-virt delta (bhyve/LX-zones/vmadm) as Phase-3 features
   (not just packages — kernel/zone features).
3. Mine pkgsrc's illumos patches to unblock our heavy-tool tail (cmake/git/tmux).
4. OmniOS ooce + Tribblix zap: low-priority package-gap fill after Hipster is done.
