# `pkg update` yields `libxml2.so.16` — the `--flake` build wall is a base-AMI refresh, not a packaging project

## The measurement

On `ami-0cb14e40f9355bd0c`, `pkg update` (rc=0, 365 MB, 39,514 actions, ~9 min) creates BE
`openindiana-2026:09:15`, and that BE contains:

```
/usr/lib/libxml2.so.16       -> libxml2.so.16.1.4  1,495,332 B  ELFCLASS32/EM_386   SONAME=libxml2.so.16
/usr/lib/amd64/libxml2.so.16 -> libxml2.so.16.1.4  1,677,136 B  ELFCLASS64/EM_AMD64 SONAME=libxml2.so.16
```

SONAME read with `elfdump -d`, **not inferred from the filename** — which matters, because the whole problem is a
soname that does not match its version string.

Read via `beadm mount` **without rebooting**, so the answer was obtained before risking the node. That is the
right order: a reboot into a fresh BE can fail, and then you have neither the answer nor the machine.

**So no libxml2 derivation is needed.** The registry already lists `library/libxml2@2.15.3-2026.0.0.0`, well past
the 2.14 soname reset (`LIBXML_MINOR_COMPAT=14` drops `AGE` to 0, so `CURRENT-AGE` goes 2 → 16 and no 2.13.x build
can satisfy `.so.16`). The `userland-incorporation@0.5.11-2025.0.0.31598` rejection reproduced exactly pre-update
and is lifted by the update — it was never binutils-specific.

Both ABIs are obtainable: `library/libxml2` supplies the 64-bit `.so.16`, `library/libxml2/32` the 32-bit one the
32-bit SMF stack needs.

## ⚠️ Correction: THREE srcs were missing, not one

My brief said `libxml2.so.16` was the blocker. `externalLibs` (`pkgs/illumos/default.nix:199-235`) lists six
libraries, and the old AMI was missing **three**:

| src | old AMI | after `pkg update` |
|---|---|---|
| `libxml2.so.16` | ❌ only `.so.2` (2.13.9) | ✅ |
| **`libicuuc.so.78`** | ❌ **no `libicuuc.so.*` at all** — only icu-76/77 | ✅ icu-78 78.3-2026.0.0.0 |
| **`libicudata.so.78`** | ❌ | ✅ |
| `libz.so.1` | ✅ | ✅ |
| `libstdc++.so.6` | ✅ | ✅ |
| `libgcc_s.so.1` | ✅ | ✅ |

The ICU pair was found because the agent checked **all twelve srcs** (six libs × two ABIs) rather than only the one
the brief named. Registry confirms `library/icu-78` exists. Had it checked only `libxml2`, the build would have
advanced exactly one derivation and failed again — the shape of the "fix the named symptom" trap.

The new `libxml2`'s own `NEEDED` is `libz.so.1` + `libicuuc.so.78` + `libm` + `libc`, which is precisely the
closure `externalLibs`' comment claims. **`externalLibs` should work unchanged.**

## What this changes

The `--flake` build wall was recorded as "libxml2 ≥ 2.14 must exist as a derivation before a fully-nixified core
userland is possible" — a prerequisite the roadmap did not list, identified from two independent directions
(`DT_NEEDED` across the proto, and `extraFile` in `externalLibs`).

**Both measurements were right about the dependency and wrong about the remedy.** It is an IPS package away, not a
build. The cost is a base-AMI refresh: `pkg update` → reboot → verify → rebuild the AMI → **bank it in R2**.

⚠️ Still unknown, and unaffected by this: `switch-to-configuration` has **never been executed** on a solnix
toplevel, and the previous run sighted `pkgs.bash` infinite recursion in the **solaris stdenv** blocking
home-manager's `activationPackage`. Resolving libxml2 reveals what is behind it; it does not promise the path is
clear.
