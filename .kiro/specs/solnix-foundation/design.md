# Foundation Spec — Design (Phase 0–1)

How we satisfy `requirements.md`. Decisions and the reasoning behind them.
Cross-refs: `.kiro/steering/illumos-domain.md`, `nix-conventions.md`.

## Big picture

Two boundaries define the whole design:

```
  [illumos host: stage0]            [Linux builder: everyday]
  build illumos-gate  ─── seeds ──▶ nixpkgs-fork stdenv (x86_64-illumos)
  build nix (fork)                     │
  produce seed toolchain               ▼
                                    pkgs.illumos.* world
                                         │
                                    evalModules (forked eval-config)
                                    + smf init module + nixos-compat
                                         │
                                    make-be image  ──▶ QEMU boot ──▶ smoke test
```

Stage0 is a one-time (per toolchain bump) illumos-native step. Everything after
R4 runs as normal Nix, cross from Linux.

## D1 — Stage0 (R1, R2)

- Provision the illumos host with a scripted, versioned recipe (pin the OmniOS/OI
  release). Prefer a zone or VM image we can rebuild, not a pet.
- Build illumos-gate per upstream docs; capture the env file and exact commit.
- Extract seed artifacts into a tarball with a manifest (paths + hashes) that the
  nixpkgs-fork bootstrap consumes. Treat this like nixpkgs' bootstrap-tools seed.
- Nix fork: start from the nixbsd `cppnix` approach; port the minimum for illumos
  (paths, syscalls, sandbox). Document every patch. **Open question:** can we
  avoid a nix fork by using an illumos-packaged nix? Investigate before forking.

## D2 — RUNPATH model (R3)

- Write a `fixupPhase` hook that runs the Solaris linker with `-R <store paths>`
  and verifies with `elfdump -d` that `RUNPATH`/`RPATH` and `NEEDED` resolve into
  the store.
- No `crle`, no `/var/ld/ld.config` dependency, no patchelf. If post-link RUNPATH
  edits are unavoidable, use `elfedit` — budget for it being clumsier than
  patchelf.
- **Open question:** does illumos `ld.so.1` honor `$ORIGIN` the way we need for
  relocatable store closures? Spike this in P0.3.

## D3 — nixpkgs fork: platform + world (R4)

- Decide the canonical platform tuple once (`x86_64-illumos` vs a `-solaris`
  kernel + `illumos` variant) in `lib/systems`; document in `nix-conventions.md`.
- Model the world as **fine-grained derivations** (nixbsd's `pkgs.freebsd.*`
  pattern): `illumos.libc`, `illumos.sys`, `illumos.ld`, `illumos.rtld`, plus
  individual base tools. Compose into `system-path`. Avoid one monolithic world
  derivation — it kills incremental rebuilds.
- illumos source consumed upstream; carry only `patches/` + build tweaks. Do not
  fork illumos-gate.
- CTF: reproduce `ctfconvert`/`ctfmerge` as build inputs. Expect this to be
  fiddly — it is coupled to the object format and the illumos toolchain.

## D4 — Evaluator & compat (R5)

- Copy NixOS `lib/eval-config.nix` near-verbatim (nixbsd does). Provide
  `lib.solnixSystem` as the eval entrypoint; expose `solnixConfigurations.<name>`
  as the nixosConfigurations analog.
- `nixos-compat.nix`: accept-and-ignore `systemd.*`, `boot.loader.grub`, and other
  Linux-only options so upstream modules type-check. Grow this lazily — only stub
  what an evaluated module actually touches.
- `module-list.nix` pulls unmodified nixos modules by store-path reference; a
  `solnix/` overlay list names the forked replacements.

## D5 — SMF init module (R6)

- `smf.services.<name>` options → generate an XML manifest (deps, methods,
  properties, restart) + method script. This is the analog of nixbsd's
  `freebsd-rc.nix`; study that file's shape and mirror it.
- Activation script: `svccfg import` each manifest, then `svcadm` to bring the
  target milestone online. `svc.startd` + `svc.configd` come from the world
  (`pkgs.illumos.*`).
- **Open question:** manifest import at activation vs. baking `repository.db` at
  build time. Start with import-at-activation (simpler, matches illumos norms);
  optimize later only if boot time demands it. `ponytail:` naive import first,
  precompiled repo only if measured too slow.

## D6 — Image + boot (R7)

- `make-be.nix`: create `rpool`, a BE dataset `rpool/ROOT/<gen>`, lay down the
  toplevel + `/nix/store` inside it, install the illumos `loader` (UEFI), run
  `bootadm update-archive` to build the `boot_archive`.
- Reuse nixbsd's `make-disk-image.nix` machinery for the GPT/ESP/partitioning
  parts where OS-agnostic; the ZFS-BE + loader + boot_archive parts are new and
  illumos-specific.
- Target UEFI QEMU first (simplest, matches loader's UEFI path).

## D7 — Cross-build (R8)

- Thread `config.nixpkgs.buildPlatform = <linux system>` into the eval so a Linux
  builder cross-produces `x86_64-illumos`, exactly as nixbsd threads its builder.
- Keep `closureInfo` GC roots; expect huge closures and long builds.

## D8 — Smoke test (R9)

- QEMU boot the image headless; assert over serial console that
  `svcs -x` is empty and the target milestone is online; run a store-linked test
  binary and check its output. One script, no framework.

## Sequencing note

P0.1 (stage0) and P0.3 (RUNPATH) are the kill-risks — prototype both before
writing any nixpkgs-fork platform code. If stage0 can't produce usable seeds, the
whole approach needs rethinking before further investment.
