# cmake on x86_64-illumos

What it took to get `cmakeMinimal` building **from source** on illumos-x86_64,
which fix is actually load-bearing (not the one the campaign notes credit), and
an honest list of what is still blocked.

Status: **`cmakeMinimal` builds from source, runs, and is a genuine
`ELFOSABI_SOLARIS` / `EM_AMD64` binary -- and real cmake-built packages now build
through it** (`zstd` 1.5.7 and `brotli`, from the committed tree, substituters
off). Two fixes were needed, both now in the repo files listed below. The
`-lkstat`/`-lsendfile` link problem the campaign notes name as the blocker was
**already solved** in the committed tree and is not what was in the way.
The full `cmake` attr still does not complete, for a reason unrelated to cmake
(see "Still blocked"). Everything below was measured on one `c5.4xlarge`,
AMI `ami-014c4aaccd37b2356`, kernel `illumos-68259130da`.

## Changed files (not committed -- the orchestrator commits)

| file | change |
|---|---|
| `solnix-pkgs/pkgs/os-specific/illumos/phase3/fetchurl-shim-qmvlnvf0.nix` | CA-bundle sentinel fix (`/no-cert-file.crt`), one guard in the shared download helper |
| `solnix-pkgs/pkgs/os-specific/illumos/phase3/tranche-entry-224.nix` | H38 restored on **both** `cmakeMinimal` and `cmake`: neuter `cmInstrumentation::GetDynamicSystemInformation` on kernels without `SYS_spawn`, with a loud-fail guard |

## Final verification, committed tree only, no node-local overlays

```
cmakeMinimal -> /nix/store/d53j9rvl43jvfhcgirp0w6ks6xhqxlyy-cmake-minimal-4.3.4   rc 0
  postPatch log: illumos SYS_spawn(143)-absent fix applied to Source/cmInstrumentation.cxx
  cmake --version -> cmake version 4.3.4
  elfdump -e      -> ei_osabi ELFOSABI_SOLARIS, e_machine EM_AMD64
zstd   -> rc 0, /nix/store/cd7y7a7hcfrak3il685g0samck3dpmww-zstd-1.5.7-bin
  zstd --version -> *** Zstandard CLI (64-bit) v1.5.7, by Yann Collet ***   (RUNS)
brotli -> rc 0
zstd build rate AFTER the fix: 4/4 pass, 0 "Bad System Call"   (was 0/6 before)
```

## The headline result

```
/nix/store/cwrvhn7bb35qrh9gcfcjq7k0d7ff02gk-cmake-minimal-4.3.4
  drv /nix/store/8glrld1ycvjm0hif2jz2slp241cy0n21-cmake-minimal-4.3.4.drv
```

| check | result |
|---|---|
| builds from source, substituters off | **YES** (`nix-build -A cmakeMinimal --option substitute false`) |
| runs | **YES** -- `cmake --version` -> `cmake version 4.3.4` |
| genuine illumos ELF | **YES** -- `elfdump -e`: `ei_osabi ELFOSABI_SOLARIS`, `ei_abiversion EAV_SUNW_CURRENT`, `e_machine EM_AMD64` |
| the H26 libs resolve | **YES** -- `elfdump -d` NEEDED lists `libkstat.so.1` **and** `libsendfile.so.1` |
| `extraSyslibs` reaches the link | **YES** -- RUNPATH records `...-illumos-extra-syslibs/lib/amd64` and `...-illumos-seed-syslibs/lib/amd64` |
| configures a real project | **YES** -- configures zstd's own `build/cmake` tree, exit 0, with the build's exact flag array |
| output path is in a binary cache | **NO** -- 404 on `cache.solnix.io` and `cache.nixos.org`; it must be published |
| **reproducible** | **YES** -- a second independent `nix-build` lands on the **identical** path `cwrvhn7bb35qrh9gcfcjq7k0d7ff02gk`, rc 0 |

Cost of the build: the `cmakeMinimal` closure is **48 `.drv` / 52 output paths**;
only **10** were warmable from cache, so **42 were built from source** on the node.

## Two premises that did not survive measurement

### 1. "Nothing wires `extraSyslibs` into `cmakeMinimal`" -- false for the committed tree

The committed `tranche-entry-224.nix` wires it explicitly: `NIX_LDFLAGS` and
`NIX_CFLAGS_COMPILE` both get `-L${extraSyslibs}/lib/amd64`, plus
`-lkstat -lsendfile`, plus `CMAKE_LIBRARY_PATH`, plus
`-DCMAKE_AR/RANLIB/STRIP=${illumosRanlib}/bin/*`, plus the gcc C++ `-R`. The
built binary's RUNPATH proves the wiring reaches the link.

The most likely explanation for the earlier "byte-identical error before and
after" is that it was measured against a **different entry file**. The sibling
`tranche-224-node-FIXED.nix` carries a materially weaker `cmakeMinimal` block:
`-DCMAKE_RANLIB=${coreutils}/bin/true`, no `gccCxxLR`, no `illumosRanlib`. A
node-local `/root/tranche-224.nix` pointing at that copy would reproduce the old
error exactly, no matter what `extraSyslibs` did.

### 2. `extraSyslibs` is **not** the load-bearing fix -- the stdenv-wide `-L` is

Four controls, each a real `nix-build` with a real exit status:

| control | removed from `cmakeMinimal` | rc | verdict |
|---|---|---|---|
| `mustfail` | nothing; **added** `-lsolnix_no_such_library` | 100 | FAILS as required -> the instrument can report failure |
| `nc1` | `-L${extraSyslibs}/lib/amd64`, `-lkstat`, `-lsendfile` | 0 | **still builds** |
| `nc2` | `nc1` **plus** `-L/lib/amd64 -L/usr/lib/amd64` | 100 | fails with the documented error |
| `nc3` | **only** `extraSyslibs` `-L` + `CMAKE_LIBRARY_PATH` (kept `/lib/amd64`) | 0 | **still builds** |

`nc2`'s output is the H26 error, reproduced on demand:

```
ld: fatal: library -lkstat: not found
ld: fatal: library -lsendfile: not found
ld: fatal: file processing errors. No output written to cmake
error: builder for '/nix/store/s3iqj3dawr6ra9s20f7rj198695aanzg-cmake-minimal-4.3.4.drv' failed with exit code 9
```

So what actually unblocks the link is the **stdenv-wide `fixAttrs`
`-L/lib/amd64 -L/usr/lib/amd64`** that `tranche-entry-224.nix` puts on *every*
derivation, together with the global `LDFLAGS`/`CXXFLAGS`
`-R/usr/gcc/14/lib/amd64` (commit `d194522`) that lets the bootstrap's C++ probe
**run**. The mechanism, observed rather than assumed: the base platform already
ships bare link-editor stubs, so a plain `-lkstat` resolves from `/lib/amd64`
once that `-L` is on the line:

```
/lib/amd64/libkstat.so    -> libkstat.so.1
/lib/amd64/libsendfile.so -> libsendfile.so.1
/lib/amd64/libmd.so       -> libmd.so.1
```

The earlier notes were reasonable **when written**: the blanket `-L` lands in
`d194522`, and before that the per-package `extraSyslibs` `-L` was the only
source of the search path. Keep `extraSyslibs` -- it is the hermetic store-path
route to the same libs and supplies the `find_library()` /
`CMAKE_LIBRARY_PATH` hint that cmlibarchive's `CHECK_CRYPTO` needs -- but it
should no longer be described as the thing that unblocks cmake.

## The recursion escape (understand this before touching `cmakeMinimal`)

The cycle is real:

```
freetype/brotli/fontconfig/libjpeg/pixman
  -> from-source seed -> zstd -> cmake -> cmakeMinimal
  -> extraSyslibs -> seedSyslibs -> seed        (infinite recursion)
```

The escape in the committed overlay is that `seedSyslibs` is sourced from
**`final.stdenv.cc.cc.src`** -- the *already-unpacked* seed tree, a fixed store
path produced by an earlier stdenv stage whose unpacker is the seed's **bundled**
`tar`+`zstd`, not a from-source cmake-built `zstd`. Anchoring on the from-source
seed derivation instead reintroduces the cycle immediately. This held: eval is
clean and `cmakeMinimal` instantiates without recursion.

## Fix applied here: a real bug in the committed `fetchurl-shim`

Observed on zstd's `source.drv` and on three `source.drv` in the full-`cmake`
build (`776l6z7s...`, `cig3hbwc...`, `m2sbhygv...` -> `libarchive-3.8.8` ->
`cmake-4.3.4`):

```
curl: The file '/no-cert-file.crt' provided to --cacert does not exist
curl: option --cacert: is badly used here
fetchurl-shim: all urls failed for source
```

Root cause in `phase3/fetchurl-shim-qmvlnvf0.nix`:

```sh
_ca="${NIX_SSL_CERT_FILE:-${SSL_CERT_FILE:-/nix-tools224/ca-bundle.crt}}"
```

Nix exports `NIX_SSL_CERT_FILE=/no-cert-file.crt` as a **sentinel** meaning "no
bundle". That value is non-empty, so `:-` never falls through, and `curl` aborts
during **argument validation, before any network I/O**. The failure therefore
*looks* like a dead mirror and is not -- which is exactly why it survived.

The fix picks the first candidate that actually **exists** (`[ -f ]`), and if
none does, runs `curl` with no `--cacert` at all rather than with a path that
cannot work; it also echoes the chosen bundle so the choice is visible in the
build log instead of silent. One guard in the shared helper, so every caller is
fixed at once. Verified: the log now reads
`fetchurl-shim: CA bundle = /nix-tools224/ca-bundle.crt` and the fetch proceeds.

## Still blocked -- honest list

### A. The full `cmake` attr does not complete

Two blockers, **neither of them in cmake**:

**A1 -- the split-debug hook needs tools this AMI does not have.**

```
error: builder for '/nix/store/pdb3al3whz74xrqpskhf9ij0dkxncz77-ncurses-6.6.drv'
       failed to produce output path for output 'debug' at
       '/nix/store/3rf230gmp3kyq1jf3x7qq4vmznnvs8f5-ncurses-6.6-debug'
```
cascading through `readline` -> `bash-interactive` -> `libtool` ->
`make-shell-wrapper-hook` -> `autoreconf-hook` -> `libuv` -> `patchutils` ->
`cmake-4.3.4`.

`tranche-entry-224.nix`'s split-debug overlay (`coreDebug = ["ncurses" "readline"]`)
hardcodes three host tools. Verified on the node:

| tool | state |
|---|---|
| `/usr/bin/elfedit` | present |
| `/usr/gnu/bin/objcopy` | ⚠️ **CORRECTED: it IS packaged.** Absent on the FRESH base AMI (where this was measured), but present on a provisioned build host, provided by **`developer/gnu-binutils`**. The fix is an `pkg install`, not a port -- materially cheaper than this row originally implied. Original note follows: **absent, and not packaged** -- `pkg search basename:objcopy` returns nothing from the OI hipster publisher, and the store's own `binutils` is the illumos seed bintools (`ar as elfdump elfedit gas ld mcs nm`), no `objcopy` |
| `/usr/bin/sha1sum` | **absent** (no `gsha1sum` either). Native equivalent exists and works: `/usr/bin/digest -a sha1` |

`solnix-separate-debug-info.sh` swallows every `objcopy` failure with
`2>/dev/null || true` / `|| continue`, so with `objcopy` missing it emits
**nothing** and the declared `debug` output stays empty. This is the "missing GNU
tool fails silently" hazard again, and it blocks `ncurses` for **every**
consumer, not just cmake. Confirmed not a cmake problem: with
`ncurses`/`readline`'s `debug` output dropped (node-local diagnostic) the build
walks straight past `ncurses` and the only remaining failures were the fetches
above.

Two ways forward, neither attempted here: rewrite the hook against tools that
exist on illumos (`digest -a sha1` for the build-id; `elfedit`/`mcs` instead of
`objcopy`, which is the hard part), or gate the split-debug overlay on the tools
being present so it degrades to no `debug` output instead of an empty one.

Note the `libuv` `-lkstat` `checkPhase` failure the brief predicted was **never
reached** -- `libuv` appears only as "1 dependencies ... failed", inherited from
`ncurses`. The committed `libuv ... doCheck = false` presumably already handles it,
but that is **untested here**.

### B. RESOLVED -- `SYS_spawn` (143) is absent on this kernel -> SIGSYS

Once the `--cacert` bug is fixed, zstd's source fetches and unpacks, and the
build dies in `configurePhase`:

```
/nix/store/cwrvhn7bb35qrh9gcfcjq7k0d7ff02gk-cmake-minimal-4.3.4/nix-support/setup-hook:
  line 7: 360554 Bad System Call            cmake "$cmakeDir" "${flagsArray[@]}"
error: builder for '/nix/store/h78gjxiiybhaj69rdfsdrd1ak4l5dpd6-zstd-1.5.7.drv' failed with exit code 140
```

`140 = 128 + 12` = SIGSYS. It is **deterministic, not flaky**: measured over **6
consecutive attempts, 6/6 failed** with rc 100 and exactly one `Bad System Call`
line each. (Worth stating explicitly, because failures in this project are
usually bursty; this one is not -- there is no clustering to report because there
is no variation.)

**The mechanism was observed, not inferred.** Four `dtrace` measurements:

1. `dtrace -l -n 'syscall::*spawn*:entry'` -> `No probe matches description`.
   **This kernel has no spawn syscall at all.**
2. `proc:::signal-send` where the signal is 12, kernel stack:
   ```
   SIGSYS to pid 361689 name=cmake sender=cmake
         genunix`tsignal+0x40
         genunix`nosys+0x17
         unix`sys_syscall+0x17d
   ```
   i.e. cmake issues a syscall *number* the kernel does not implement, and
   `nosys()` synthesises SIGSYS.
3. `fbt::nosys:entry` -> **`syscall_num=143`** (`uregs[R_RAX]=143`), and
   `bootstrapLibs/usr/include/sys/syscall.h` line 325 says
   `#define SYS_spawn 143`. So the missing syscall is **`SYS_spawn`**.
   `posix_spawn` *is* present in this libc (`T posix_spawn` in
   `/lib/amd64/libc.so.1`) -- it just does not fall back to `fork`/`exec` when
   the kernel lacks `SYS_spawn`.
4. The user stack at the trap, symbolised against the cmake binary:
   ```
   cmsys::SystemInformationImplementation::RunProcess(std::vector<char const*>)
     -> cmsysProcess_Execute
       -> kwsysProcessCleanup / kwsysProcessKill
         -> libc posix_spawn -> SYS_spawn(143) -> nosys -> tsignal
   ```

So the recorded H38 diagnosis is **confirmed in substance**: it is the cmsys
`SystemInformation` process-spawn probe, on a kernel with no `SYS_spawn`. Commit
`2e4a83b` added a `postPatch` neutering
`cmInstrumentation::GetDynamicSystemInformation` (the caller of that probe);
commit `9e958cf` **deleted** it because a later node (`fb435c17bd`) did not
reproduce the crash. **This node is `illumos-68259130da`, which does.**

One correction to the note worth carrying forward: cmake 4.3.4 contains **no
direct `posix_spawn` call** -- `grep -rln posix_spawn` over all of `Source` +
`Utilities` returns nothing. The call comes from bundled cmsys/libuv
(`nm` shows `T uv_spawn`, `cmUVProcessChain::InternalData::SpawnProcess`,
`cmInstrumentation::SpawnBuildDaemon`), which reaches libc `posix_spawn`. Any
restored patch must therefore be validated against `cmInstrumentation.cxx` as it
actually reads in 4.3.4, not against the old line numbers.

Also note the crash reproduces **only inside the nix builder**. Standalone, the
same binary configures zstd's own `build/cmake` tree successfully (rc 0),
including with the build's **exact** flag array replayed, and
`cmake --version` / `--system-information` both work. `HOME=/homeless-shelter`
is not the trigger (tested, rc 0). The most likely remaining difference is that
the instrumentation path only engages for a full generate inside the build
environment; that last step was **not** isolated.

**This blocker is now CLOSED and verified.** The `2e4a83b` early-return
`postPatch` was restored on both `cmakeMinimal` and `cmake`, keyed on text rather
than line numbers. The definition spans **two lines** in 4.3.4:

```c++
void cmInstrumentation::GetDynamicSystemInformation(double& memory,
                                                    double& load)
{
  cmsys::SystemInformation& info = this->GetSystemInformation();
```

which is why the original single-line regex silently matched nothing. The
loud-fail guard caught that immediately instead of shipping an unpatched cmake:

```
FATAL: no-spawn edit did not apply to Source/cmInstrumentation.cxx
```

With the multi-line match, from the committed tree: `cmakeMinimal` rc 0, `zstd`
rc 0 with a working CLI, `brotli` rc 0, and the zstd build passes **4/4** with
zero `Bad System Call` lines (it was **0/6** before). The disabled dynamic
sysinfo is pure telemetry (host memory + CPU load), never build-affecting, and
the edit is harmless on kernels that do implement `SYS_spawn`.

Still worth doing eventually, because `SYS_spawn` is missing kernel-wide and will
hit **every** `posix_spawn` user (the same class as the committed
`ninja-fork-exec-illumos.patch`, which exists for exactly this reason): teach the
bundled cmsys spawn path to fall back to `fork`+`execvp` as that ninja patch
does, or build on a kernel that implements `SYS_spawn` (`fb435c17bd` or later).
The present fix removes the *call site* rather than repairing the spawn path, so
any cmake feature that legitimately needs to spawn a helper could still trip it.

### C. Cache coverage, which is a publishing gap not a porting gap

`docs/waveA1-store-paths.txt` records a `cmakeMinimal` built in an earlier wave:
`p7dvg7h6s4c3ccbjvdpkp6jv5b6bwifx-cmake-minimal-4.3.4`. That path returns
**HTTP 404 from both** `cache.solnix.io` and `cache.nixos.org`, as do its
`zstd`, `freetype` and `fontconfig` paths. The document does say "report-only, no
publish on this node", so this is consistent rather than contradictory -- but it
means the artifacts were never banked, and "180 of cosmic-term's 339 closure
paths are uncached" is the expected consequence. **Publishing the paths, not
porting more packages, is what shrinks that number.** The path this tree
produces (`cwrvhn7bb...`) is likewise not in any cache yet.

### D. cosmic-term

`cosmic-term` **instantiates** cleanly with the committed derivation
(base entry + `rust-overlay.nix` + `cosmic/`):

```
/nix/store/kvhgrsfald37szc0hcrxxr0rz9w0v8k2-cosmic-term-1.5.0.drv
```

It was **not built** and **no binary was produced** -- do not report otherwise.
What changed is which blocker stands in the way: `cmakeMinimal` is no longer it,
and cmake-driven `configurePhase`s no longer die on `Bad System Call`. `zstd` and
`brotli` -- both members of the cmake graph the closure needs -- now build. The
remaining known obstacles for a cosmic-term binary are the `ncurses` `debug`
output gap (A1, which blocks `bash-interactive`/`libtool` and so a large slice of
the graph) and the fact that none of these paths are published, so every node
rebuilds all 42-of-52 uncached closure members from source.

Which paths cosmic-term actually needs was **not** enumerated: the closure walk
requires realising the drv, which is gated on A1. That remains open work.

## Node setup that this needs (all verified)

```
nix 2.24.15 at /nix-tools224/bin           (relocatable bootstrap tarball)
PATH=/nix-tools224/bin:/usr/gnu/bin:/usr/bin:/usr/sbin
NIX_CONF_DIR=/nix-tools224/etc/nix
LD_LIBRARY_PATH=/nix-tools224/runtime-lib  (REQUIRED -- transitive nix libs carry
                                            build-host RUNPATHs)
HOME=/root
/dev/fd mounted AND in /etc/vfstab         (else every stdenv build dies on /dev/fd/63)
pkg install library/mpfr                   (else the seed gawk cannot run
                                            substituteAll and the cc setup-hook
                                            ships unsubstituted @wrapperName@)
before each build: [ -d /homeless-shelter ] && find /homeless-shelter -delete
```

Two traps worth restating:

* **Use the committed `fetchurl-shim-qmvlnvf0.nix`, not the
  `artifacts/fan224-stage/` copy.** The entry calls
  `import fetchurlShim { inherit forkPath; }` -- it needs a *function of
  `forkPath`*. The committed file is that function; the `artifacts/` copy is a
  bare `final: prev:` overlay, and passing it fails eval with
  `error: attempt to call something which is not a function but a set:
  { fetchurl = «thunk»; fetchurlBoot = «thunk»; solnixShimFetch = «thunk»; }`.
  The committed shim also already drops the dead GNU mirrors
  (`ftpmirror.gnu.org`, `info-zip.org`) through its `liveUrl` filter.
* **`text/gnu-diffutils` does not install on this AMI**, so `/usr/gnu/bin/diff`
  may be absent and `/usr/bin/diff` prints "No differences encountered" for
  identical files. Use `cmp`.

## A methodology note that cost real time here

Three of my own intermediate results were **unfalsifiable** because I wrote

```sh
nix-build ... | tail -50
echo "RC=$?"          # this is TAIL's status -- always 0
```

Every such `RC=0` was meaningless, and it briefly made a negative control look
like it had refuted a fix that it had not tested at all. This is the same shape
as the `stat -c %s` gate that was always false. All verdicts in this document
come from a `nix-build` with **no pipeline**, cross-checked against whether the
output path exists -- plus a positive-failure control (`-lsolnix_no_such_library`,
rc 100) proving the harness can report FAIL.
