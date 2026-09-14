# The installer image is mostly *not* Nix — the gap, measured

The maintainer's question: *"Shouldn't all these things installed in the image be installed via Nix and live
on nix-ified paths? Isn't that the point?"*

**Yes. And today the image is largely hand-copied from an OpenIndiana AMI.** That is the honest state, and it
is worth writing down precisely rather than defending.

## What the image actually is

`scripts/oi-make-livecd.sh` contains **84 lines of hand-maintained path lists** — `usr/bin/which`,
`usr/sbin/df`, `usr/openssl/1.0/lib/libssl.so.1.0.0` and so on — copied out of the running AMI into a UFS
ramdisk. **Zero `/nix/store` paths** are staged for the base userland. Only `/nix-tools224` (Nix itself) is
nix-shaped, and even that is a relocatable tarball rather than a derivation closure.

Every bug this campaign has hit in that machinery is a *direct consequence* of that design:

| bug | root cause |
|---|---|
| `vi` died — `libmapmalloc.so.1` missing | hand-maintained library allowlist |
| `/dev` had 0 of 13 nodes | hardcoded 12-name allowlist |
| `df` a dangling symlink | target not in the path list |
| `openssl` unrunnable | **second-order** dangling symlink, lib tree not staged |
| `reboot`/`poweroff` absent | `[ -e ] &&` silently skipped missing links |

A Nix closure has none of these failure modes, because **the closure is computed, not remembered**. Every one
of those bugs is "a human forgot an entry in a list".

## Why it is not already Nix — the real blocker

Measured against `docs/registry/hipster-packages.tsv` (10,608 rows):

**Available as derivations:** `openssl` (43 hits), `which` (61), `curl` (8), `git` (20), `less` (2),
`nvi` (4 — though its `ncurses-6.6` 404s in our cache).

**NOT available, because they are illumos *core-OS*, not separately packaged:**

| tool | lives in |
|---|---|
| `df` | `SUNWcsu` core |
| `useradd`, `passwd` | `cmd/oamuser`, core-os |
| `reboot`/`halt`/`poweroff` | `cmd/halt` — one binary, `argv[0]` links |
| `zpool`, `zfs` | the kernel's own userland |
| `svcadm`, `svccfg` | SMF |
| the kernel | `platform/i86pc/kernel/amd64/unix` |

So an installer image **cannot be 100% Nix today**, because illumos's core userland is not yet a set of
derivations. That is the gap the north star ("solnix must be EXACTLY Nix") demands we close, and it is a
larger piece of work than any single image fix.

## The machinery already exists — and is honest about being incomplete

`pkgs/illumos/gate.nix` builds the gate proto as a store path, and its own header says what it is:

> *"The eventual goal (design §1.5) is a fixed-output derivation that RUNS the proven
> `scripts/oi-gate-build.sh` recipe inside Nix (~90 min…). That is deferred: the gate is already built at
> `/code/illumos-gate/proto/root_i386`, so for this iteration we INGEST the existing proto…"*

`mk-userland-pkg.nix` and `mk-illumos-component.nix` are the slicing machinery. So the design is right and the
**ingest shortcut** is what leaves us hand-copying.

## What should change, in order

1. **Stop growing the hand-maintained lists.** Every new entry is future silent breakage. The `ldd` closure and
   the exec-time gate were the right instinct — they replace *remembering* with *computing* — but they are
   patches on the wrong substrate.
2. **Make `gate.nix` a real FOD** that runs `oi-gate-build.sh`, so the kernel and core userland become a
   derivation instead of an ingest.
3. **Slice the proto into component derivations** via `mk-userland-pkg.nix`: `illumos-core-utils` (`df`, `ls`…),
   `illumos-oamuser` (`useradd`, `passwd`), `illumos-halt` (with its `argv[0]` links), `illumos-smf`, `illumos-zfs`.
4. **Build the ramdisk from a closure**, not a path list: name the top-level derivations, let Nix compute the
   closure, copy `/nix/store` into the image. Dangling symlinks and missing libraries become *impossible*
   rather than *gated against*.
5. **Then** the installer's own tools are `/nix/store/...`-resolved, and `/usr/bin` is symlinks into the store —
   the NixOS shape.

## Honest cost

Step 2 alone is the 90-minute gate build wrapped as an FOD with a pinned `outputHash` — a day or two of work,
mostly fighting build impurity. Steps 3–4 are the real project: every core tool needs its dependency closure
established, and illumos's userland has circular build-time relationships that `pkg` papers over.

**This is the right direction and it is not a quick fix.** The current image ships because it works, not
because it is right. Every gate added to `oi-make-livecd.sh` this campaign is a symptom of the shortcut, and
the fix is to delete the path lists entirely — not to guard them better.

---

## CONFIRMED on hardware, 2026-09-13

The maintainer booted image `l2`, found **`/nix` empty** and `ldd /usr/bin/ls` showing no nix-ified paths, and
asked whether this is really a Nix-style illumos. **It is not.** Measured from the shipped 461,373,440 B ramdisk:

| | |
|---|---|
| ELF binaries staged | **1,368**, all hand-copied from the OpenIndiana AMI |
| `/nix` | **empty** |
| nix itself | `/nix-tools224` — a relocatable tarball, not a closure |
| `ldd /usr/bin/ls` | resolves to `/lib/*` because that is where the file came from |

⚠️ **The 74 `/nix/store` paths in the image are residue, not a closure.** I checked what they *are* rather than
counting them: `hello-2.10`, `chromium-unwrapped-86`, `libXdamage-1.1.5`, `libpfm-4.11.0` — **Linux** packages,
left as strings in build logs. Counting occurrences would have let me report "136 hits" as if the image were
nixified. That is the byte-grep-as-inventory error, third occurrence.

⚠️ **And the review had already been done.** `docs/design-nixos-iso-methodology.md` was written *one turn
earlier*: it records that NixOS's minimal ISO is 21 lines, that its content is `storeContents = [
system.build.toplevel ]` with the closure **computed**, and that the fix here is *"delete the path lists, not
guard them better."* Then `l2` was built with all 84 lines of path lists intact.

**`l2` is a good OpenIndiana installer** — the interactive prompts, root-password hardening, `/home` layout and
autofs fix are real. **It is not solnix-as-Nix**, and describing it as such would be overclaiming.
