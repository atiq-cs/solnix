# aarch64 gate build host: OmniOS r151058 setup runbook

How to stand up an aarch64-gate cross-build host from nothing, and the host-env
fixes `make setup` needs on OmniOS r151058. None of these are aarch64 code changes
-- they are all environmental, which is exactly why they are easy to lose and
expensive to rediscover.

**Shortcut first: you probably do not need this.** The finished toolchain is
captured as an AMI carrying both the OmniOS root and the 150G `/aarch64` build tree
(see `.infra/` for the id). Launch that and the tree is at `/aarch64` (zpool
`bpool`) with the cross compiler ready. This runbook is for when that image is
gone or must be rebuilt from a newer OmniOS.

## Host

- OmniOS **r151058** cloud image, a compute-heavy instance (a 36-vCPU class box
  builds the cross toolchain in a reasonable wall clock).
- **Put the build tree on a SEPARATE volume with `DeleteOnTermination=false`**
  (150G; `zpool` -> `/aarch64`). Non-negotiable: it makes a wedged or degraded host
  disposable, and it is what lets the tree be snapshotted independently. See
  `docs/durability-account-loss.md`.
- Prereq packages: `git gmake gcc14 onbld python-313 flex bison`.
  ⚠️ `openjdk11` and `gnu-patch` do **not** exist in r151058 -- drop them from any
  older install list.

## `make download`

Clean on r151058 (all nine source trees, ~5G). No fixes needed.

## `make setup` -- the five fixes

1. **`Makefile.master` hardcodes `/usr/gcc/10`.** It sets
   `{i386,aarch64}_GNUC_ROOT=/usr/gcc/10`, but r151058 ships gcc 14 at
   `/opt/gcc-14`, and `/usr/gcc/10` exists **lib-only** (no `bin`), so the failure
   looks like a missing compiler rather than a wrong path.
   **Fix:** `ln -s /opt/gcc-14/bin /usr/gcc/10/bin` -- a symlink, no source edit.
2. **Perl `XML::Parser` missing** -> `libbsm`'s auditxml step dies.
   **Fix:** `pkg install library/perl-5/xml-parser`.
3. **Do not override `GMPINCDIR`.** `gmp.h` lives at `/usr/include/gmp/gmp.h` and
   the harness already defaults `GMPINCDIR=/usr/include/gmp`. Passing
   `/usr/include` breaks it. (Recorded because it looks like a missing header.)
4. **`makeinfo` missing** -> binutils `doc/bfd.info` fails with `Error 127`.
   **Fix:** `pkg install text/texinfo` (lands in `/opt/ooce/bin`).
5. **Upstream harness bug in the `dtc` target.** It passes `NO_YAML=1` to `install`
   but *not* to the build, and r151058 has no libyaml.
   **Fix:** `gmake clean && gmake NO_YAML=1`. The `clean` matters -- a stale
   `dtc.o` keeps an undefined `dt_to_yaml` and the link fails even with the flag.

### Known-acceptable remaining failure

**`u-boot` fails** (wants gnutls for `mkeficapsule`). That is the QEMU/RPi4 boot
path and is **not** used by Graviton, which boots via UEFI -- so it does not block
a `unix` rebuild or a metal test. Confirm that before touching its stamp.

## Verify the toolchain before trusting it

```
aarch64-unknown-solaris2.11-gcc --version      # expect 14.3.0
aarch64-unknown-solaris2.11-as --version       # binutils 2.43.1
echo '#include <sys/types.h>' > /tmp/t.c
aarch64-unknown-solaris2.11-gcc --sysroot=<sysroot> -c /tmp/t.c -o /tmp/t.o
file /tmp/t.o                                  # ELF 64-bit LSB relocatable, aarch64
```
Stamps that should exist: `sysroot sgs binutils-gdb boot-gcc gcc perl dtc
arm-trusted-firmware barn`.

**Then snapshot + register an AMI immediately, before running nightly.** The
toolchain is the expensive artifact; the OmniOS install is the cheap half.

## Building `unix` afterwards

- **`bldenv -d -T aarch64 <gate>/env/aarch64`** -- the `-T aarch64` flag is
  mandatory. Without it `bldenv` sets `MACH` from `uname -p`, the env file's
  `if [[ ${MACH} == "aarch64" ]]` cross branch never fires, and the whole build
  silently goes `-m32 -Di386` with the host x86 assembler (which surfaces as
  bogus errors like `no such instruction: stxrb`).
- **Regenerate `assym.h`** if it is 0 bytes -- a stale empty one makes
  `dboot_srt0.S` fail on `HCR_TGE`/`ICC_SRE_EL2_EN`/`CPACR_FPEN_MASK`.
- **Re-apply the gcc-14 `CERRWARN` items** from
  `src/aarch64-arm64-gate-patches/a6-mem-plus-gcc14-build-fixes.patch`
  (`-Wno-unused-variable`, `-Wno-unused-but-set-variable`, `-Wno-empty-body`:
  upstream has them only behind `$(RELEASE_BUILD)`, and the DEBUG cross build
  needs them too).
