# Foundation Spec — Tasks (Phase 0–1)

Ordered, checkable tasks. Each maps to requirements (R#) and design (D#). Do the
de-risking spikes (Phase 0) before any nixpkgs-fork breadth. amd64 only.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked

## Phase 0 — De-risk (do first, in order)

- [~] **T0.1** Script + document an illumos build host on EC2 (`numa` profile,
      us-east-2): OpenIndiana Hipster 2025.06 / illumos-31d3d510d0. Obtain or
      import an OI AMI (VM Import/Export or nested VM if none exists). Tag +
      terminate-when-idle. *(R1.1, D1)*
      → AMI built + boots on Nitro (`ami-042e009635e7af4b7`); blocked on
        login/network (OI cloudimage doesn't consume EC2 IMDS). See
        `docs/progress.md`.
- [ ] **T0.2** Build illumos-gate via `nightly.sh`; capture env file + commit;
      produce a proto area. *(R1.2, D1)*
- [ ] **T0.3** Identify + extract seed artifacts (libc, headers, illumos-gcc,
      Solaris `ld`, CTF tools) into a hashed tarball + manifest. *(R1.3, D1)*
- [ ] **T0.4** Build/run Nix on the illumos host; build one trivial derivation
      into `/nix/store`. Decide fork-vs-existing-package first. *(R2, D1)*
- [ ] **T0.5** RUNPATH spike: link a binary with Solaris `ld -R` into store paths;
      verify with `elfdump -d`; confirm `ld.so.1` resolves at runtime; test
      `$ORIGIN` relocatability. *(R3, D2)*

> **Gate 0:** a hand-built store derivation on illumos links store libc and runs.
> Do not proceed until green.

## Phase 1 — Minimal bootable amd64

### Platform & world (nixpkgs fork)
- [ ] **T1.1** Decide + document canonical platform tuple; add `x86_64-illumos`
      to `lib/systems`. *(R4.1, D3)*
- [ ] **T1.2** Bootstrap stdenv from the T0.3 seed; compile a C program against
      store libc on `x86_64-illumos`. *(R4.3, D3)*
- [ ] **T1.3** `pkgs.illumos.libc` derivation. *(R4.2, D3)*
- [ ] **T1.4** `pkgs.illumos.ld` + `illumos.rtld` (`ld.so.1`). *(R4.2, D3)*
- [ ] **T1.5** `pkgs.illumos.sys` (kernel + genunix); reproduce CTF build. *(R4.2, D3)*
- [ ] **T1.6** Minimum base tools to reach multi-user (`svc.startd`,
      `svc.configd`, `svccfg`, `svcadm`, shell, coreutils-equiv). *(R4.2, D3)*
- [ ] **T1.7** Compose the fine-grained world into `system-path`. *(R4.2, D3)*

### Evaluator & modules (solnix repo)
- [ ] **T1.8** Fork `eval-config.nix`; add `lib.solnixSystem` +
      `solnixConfigurations`. *(R5.1, D4)*
- [ ] **T1.9** `nixos-compat.nix` stubs (grow lazily). *(R5.2, D4)*
- [ ] **T1.10** `module-list.nix` + `extPath`-style pull of unmodified nixos
      modules. *(R5.3, D4)*

### SMF init
- [ ] **T1.11** `smf.services.<name>` → manifest XML + method script generator
      (mirror nixbsd `freebsd-rc.nix`). *(R6.1, D5)*
- [ ] **T1.12** Activation: `svccfg import` + `svcadm` to target milestone.
      *(R6.2, D5)*

### Image & boot
- [ ] **T1.13** `make-be.nix`: rpool + `rpool/ROOT/<gen>` + toplevel + store
      inside BE. *(R7.1, R7.3, D6)*
- [ ] **T1.14** Install illumos `loader` (UEFI) + `bootadm update-archive`
      boot_archive. *(R7.1, D6)*
- [ ] **T1.15** Reuse nixbsd `make-disk-image.nix` GPT/ESP parts. *(R7.1, D6)*

### Cross-build & config
- [ ] **T1.16** Thread `config.nixpkgs.buildPlatform`; cross-build from Linux.
      *(R8, D7)*
- [ ] **T1.17** `configurations/base` — the minimal bootable config. *(R7, R8)*

### Gate
- [ ] **T1.18** Smoke test: QEMU boot, assert `svcs -x` empty + milestone online +
      store binary runs. *(R9, D8)*

> **Gate 1:** `configurations/base` cross-builds on Linux, boots in QEMU to
> `multi-user-server`, smoke test passes. This closes the foundation spec.

## Notes
- Keep a running "verify" log for the drifting facts in `illumos-domain.md`
  (illumos-gcc version, tuple spelling, `$ORIGIN` behavior) — resolve them as the
  relevant task hits them, don't front-load research.
- If any Phase 0 spike fails, stop and revise `design.md` before continuing.
