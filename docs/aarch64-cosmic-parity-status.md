# aarch64 solnix — COSMIC/GTK4 parity + build-farm-animal — session report

Node: **i-0c94705fd4d3f3768** (fresh, launched this session) @ **3.138.61.121**, us-east-2a,
m5.4xlarge, AMI ami-0978836610527a836 (canonical). Key = `~/.ssh/id_ed25519` (task said
`chiuso-key.pem`; the real key per `.infra/fleet-chiuso.env` is `~/.ssh/id_ed25519`).
Triple: aarch64-unknown-solaris2.11 (cross-built from x86_64-solaris).

Old node i-077fdfc58bcdec41f (3.139.85.63 -> stop/start -> 13.59.165.214) went HARD-impaired
(cold-boot DHCP lottery, ~10 reboots + a stop/start all missed). Launched a fresh node from the
canonical AMI (up first boot). Old node LEFT for the orchestrator (still impaired; terminate or
retry-reboot).

---

## 1. fetchurl-shim TOML zeroed-hash trap — FIXED (y) + pango/gtk4 EVAL clean on aarch64 (y)

**Root cause (confirmed on the node):** the node's AMI-baked `/root/fetchurl-shim.nix` (lineage
`p3lfwcvh`) used `sha256 = args.hash or args.sha256` at two sites (lines 91, 145). fetchPypi passes
BOTH `sha256="<real>"` AND an empty `hash=""` — the attr `hash` EXISTS, so `or` never falls through
and picks `""` -> a zeroed `sha256:0000...` fixed-output hash -> `hash mismatch` on `toml-0.10.2.tar.gz`
(got `13z6rff86bzdpl094x0vmfvls779931xj90dlbs9kpfm138s3gdk` = the real hash). Blocked pango / gdk-pixbuf
/ gtk4 eval on BOTH platforms.

**Fix:** added a `pickHash` helper (first NON-EMPTY of hash/sha256) and routed both sha256 selections
through it. Applied to the node's shim; re-eval confirmed the `0000...` mismatch is GONE.

**IMPORTANT — this was already fixed in the fork.** The fork's active shims
(`fetchurl-shim-egret-lineage.nix`, `fetchurl-shim-qmvlnvf0.nix`) ALREADY carry the identical
`pickHash` fix (committed `034043d`, "Now unblocked (30 python3Packages built)"). The trap persisted
only because the NODE's canonical AMI ships a STALE pre-fix `/root/fetchurl-shim.nix`. So the real
build-farm action item: **the canonical builder AMI bakes an out-of-date fetchurl-shim** — re-bake the
AMI (or have node bootstrap copy the fork's shim) so nodes don't reintroduce the trap.

Captured the fixed node shim to the fork at
`pkgs/os-specific/illumos/phase3/fetchurl-shim-node-p3lfwcvh.nix` (reference).

**aarch64 EVAL now CLEAN through the full GTK4 spine** (all -> valid .drv):
glib, graphene, gobject-introspection (as `-wrapped` inside gtk4), pango, gdk-pixbuf, gtk4, libadwaita.

---

## 2. aarch64-solaris GTK4-spine cross tails (persisted to aarch64-overlays/, orchestrator commits)

Eval-clean required these NEW cross tails (all in `aa-toolkit-fixes-overlay.nix` = TARGET crossOverlay,
and `aa-native-toml-overlay.nix` = native buildPackages), back-ported from the x86 findings:

TARGET (`aa-toolkit-fixes-overlay.nix`):
- **pango**: `x11Support=false` + drop `FONTCONFIG_FILE` (makeFontsConf unconditionally pulls
  dejavu_fonts.minimal -> fontforge -> libtiff -> sphinx -> cargo -> gcc15 -> null-bintools assert).
- **cairo**: filter libxext/libxcb/... from buildInputs AND propagatedBuildInputs (cairo's package.nix
  forces `x11Support ? ... || true`, so `.override` can't turn X off; the xorg mirror is unreachable
  from illumos -> eval-time fetch timeout).
- **libtiff**: drop `sphinx` nativeBuildInput + the `doc` output (sphinx -> cargo -> gcc15 -> bintools).
- **gtk4**: `dropXGst` filter of the UNCONDITIONAL `++ [ libice libsm libxi libxrandr gst-plugins-*
  ... ]` buildInputs block (patched-in, not gated) + vulkanSupport/cupsSupport off.
- **libadwaita**: drop `appstream` buildInput (appstream -> systemd -> llvmPackages.clang -> cc-wrapper
  null-libc bintools assert; Linux-only chain).
- **xz**: `fixLibtoolPrint` (see build section).
- **tcl**: fix the `-lmd -lmp` leak from the native wire (aarch64 syslib shim) — but tcl is otherwise
  sidestepped via sqlite.
- **sqlite**: drop `tcl` nativeBuildInput + `--disable-tcl` (tcl doesn't cross-build cleanly:
  compat/mkstemp.c missing `<string.h>`).

NATIVE (`aa-native-toml-overlay.nix`) — the pins the prior session used were node-local x86 builds,
GONE on this fresh node, so the native toolchain was rebuilt from source (see section 3):
- gettext (libintl empty-pipe crack + syslib -L), texinfo, help2man (syslib wire), cmakeMinimal
  (3-layer crack), perlPackages.LocaleGettext (libintl -L/-R), plus the toml target repin.

Also: **cairo src seeded** — `cairographics.org` is unreachable from the node; found the release
tarball at `ftp.osuosl.org/pub/blfs/conglomeration/cairo/cairo-1.18.4.tar.xz` (hash matches),
`nix-store --add-fixed`'d it so builtins.fetchurl finds the FOD.

---

## 3. aarch64-solaris GTK4-spine leaves BUILT (EM_AARCH64)

**15 EM_AARCH64 aarch64-unknown-solaris2.11 libraries** cross-built + gcrooted this session
(elfdump `e_machine: EM_AARCH64`), up from 4 in the prior session:

    xz/liblzma.so.5   readline.so.8   bzip2   mpdecimal(+cxx)   ncurses.so.6
    libiconv.so.2     zlib.so.1       pcre2   libffi.so.8       expat.so
    gdbm-lib          openssl (libcrypto/libssl.so.3)

Key cross blockers CRACKED to get here (each a real illumos-cross wall):

- **xz (the documented glib blocker)**: target xz's generated libtool set `ECHO="print -r --"`
  (Solaris ksh builtin) but nixpkgs runs libtool under bash -> `print: command not found` ->
  shared-lib compile dies. FIX: `fixLibtoolPrint` (postConfigure substituteInPlace libtool
  `'print -r --'` -> `'printf %s\n'`). liblzma.so.5 = EM_AARCH64.

- **native gettext libintl empty-pipe wall** (was PINNED; pin gone): gettext-runtime/intl libtool had
  `global_symbol_pipe=""` (illumos nm undetected by configure) -> `$NM objs |  | sed` (empty middle
  pipe) -> "syntax error near |" + empty libintl export -> gettext tools undefined libintl_*.
  intl/libtool REGENERATES during make so post-patching didn't stick. FIX (preConfigure, autoconf
  cache var persists through regeneration): `export lt_cv_sys_global_symbol_pipe="sed -n -e
  's/^[0-9a-fA-F]* \([BDTR]\) \(.*\)$/\1 \2/p'"` + `NM="gnm -p"`. Also `-L/lib/amd64 -L/usr/lib/amd64`
  (conftest linked -lmd/-lmp/-luutil/-lnvpair/-lidmap/-lavl not found). gettext-1.0 BUILT.

- **native cmake-minimal 3-layer crack** (was PINNED; pin gone):
  (1) C++11 detection: bootstrap RUNS the conftest but `libstdc++.so.6` not on run path ->
      "Compiler is not in a mode aware of C++11". FIX: preConfigure `LD_LIBRARY_PATH=/usr/gcc/10/lib/amd64`.
  (2) bootstrap-cmake final link: `-lkstat -lsendfile` not found. FIX: `NIX_LDFLAGS +=
      -L/lib/amd64 -L/usr/lib/amd64`.
  (3) self-hosted build archiver: `Error running link command: no such file or directory` on
      `libcmsys_c.a` — the store `binutils/bin/ar` is a RELATIVE symlink cmake's libuv posix_spawn
      fails to exec on illumos. FIX: `-DCMAKE_AR=/usr/bin/ar -DCMAKE_RANLIB=/usr/bin/ranlib`.
  cmake-minimal-4.3.4 BUILT (100%).

- **cmake libstdc++ downstream SIGKILL**: the built cmake's RUNPATH points at a bootstrapLibs dir
  lacking libstdc++.so.6, so downstream tools that RUN cmake (zstd) got
  "ld.so.1: cmake: fatal: libstdc++.so.6: open failed" -> SIGKILL/137. NODE-LEVEL FIX (build-farm
  config): `crle -64 -u -l /usr/gcc/10/lib/amd64` (adds gcc-10 libstdc++ to the default 64-bit
  runtime search path; persists in /var/ld/64/ld.config). zstd then built.

- **native texinfo / help2man**: same libmd/libmp/-lnsl H6 syslib gap -> "cannot create executables".
  FIX: `wireSyslibs` (+ broadened to `-L/lib/amd64 -L/usr/lib/amd64` for the transitive
  libavl/libsec/uutil/nvpair that libintl.so NEEDs). Both BUILT.

- **native perl LocaleGettext**: "gettext in -lintl... no" (libintl transitive syslib NEEDs). FIX:
  `-L/-R${gettext}/lib -L/lib/amd64`. BUILT.

- **tcl sidestepped**: tcl doesn't cross clean (compat/mkstemp.c implicit strlen, then compat/string.h
  K&R conflicts). It was only pulled by glib->python3->sqlite (sqlite's test harness). Overrode
  sqlite: drop tcl + `--disable-tcl`.

### glib itself — the remaining cross blocker (documented, > 25-tool-use grind)
After all the above, glib's remaining target dep **bash-aarch64** fails: its configure invokes the
UNWRAPPED cross gcc-seed (`x05ph9y...-gcc-unwrapped-seed`, which has no co-located `cc1`) instead of
the WRAPPED cc -> `aarch64-...-gcc: fatal error: cannot execute 'cc1': posix_spawnp: No such file`.
The WRAPPED cc compiles fine (`-c` test rc=0) and every other target lib (openssl/pcre2/xz/zlib/
ncurses/...) built through it — so this is a per-package CC-resolution tail in bash's build, not a
toolchain gap. Upgrade path: force bash's `CC`/`CC_FOR_BUILD` to the wrapped cross cc (or add a cc1
symlink into the unwrapped-seed's libexec). Also seen queued behind it: python3-3.14.6 (native) exit 1.

---

## 4. COSMIC apps on aarch64 — NOT REACHED

Gated on the glib->gtk4->libadwaita spine finishing the BUILD (eval is clean; the C-lib leaves are
EM_AARCH64; glib blocks on the bash cc1-wrapper tail above). COSMIC apps are cargo build-std
(aarch64-cross-rust.md) on top of the aarch64 GTK4/libadwaita toolkit, so they follow once glib links.

---

## 5. build-farm-animal readiness assessment

**Works today (verified this session):**
- `nix build` of a leaf is reproducible: `(import entry-aa-gtk4.nix).zlib` ->
  `/nix/store/a2ij99kn...-zlib-aarch64-unknown-solaris2.11-1.3.2` (smoke test PASS).
- Node boots reliably on the canonical AMI (ami-0978836610527a836) — this fresh node came up FIRST
  boot; the reboot-until-network recovery works for the ~70-80% cold-boot timing ceiling.
- Store on a persistent 96G ZFS pool (nixpool on vol-0ea714fc5e29e485b), 2373 paths, 6% used.

**What a persistent aarch64 build-farm-animal needs (set up this session, or to do):**
1. **Persistent store volume** — DONE: created 100G gp3 `vol-0ea714fc5e29e485b`, `zpool create nixpool`
   on it, `zfs create nixpool/nix` + `zfs set mountpoint=/nix`, rsync'd the 1193-path store over
   (tar FAILS on illumos: >100-char store names; use rsync -aH or pax). Pool is in
   /etc/zfs/zpool.cache -> auto-imports on boot. NOTE: keep the store OFF the 7.3G root ZFS slice
   (root hit 100% and WEDGED the box earlier); root is now 68%.
2. **nix build-dir off root** — DONE: nix.conf `build-dir = /tmp/nix-build` (/tmp is 58G swap-backed).
   TMPDIR=/tmp for all builds. Watch `df -h /` — a 100%-full root wedges the node.
3. **libstdc++ on the default runtime path** — DONE: `crle -64 -u -l /usr/gcc/10/lib/amd64`
   (/var/ld/64/ld.config), so native build tools (cmake) run without a per-invocation LD_LIBRARY_PATH.
   This should be baked into the builder AMI.
4. **Fresh fetchurl-shim** — the canonical AMI ships a STALE `/root/fetchurl-shim.nix` (pre-pickHash).
   Re-bake the AMI with the fork's shim, or have node bootstrap copy `pkgs/.../phase3/fetchurl-shim-
   qmvlnvf0.nix` -> `/root/fetchurl-shim.nix`.
5. **The env preamble every ssh needs** (already in the AMI): `export NIX_CONF_DIR=/nix-tools224/etc/nix
   PATH=/nix-tools224/bin:$PATH LD_LIBRARY_PATH=/nix-tools224/runtime-lib:$PATH; mount -F fd fd /dev/fd`.
6. **Build user (gburd headless)** — NOT set up (no gburd in /etc/passwd; builds ran as root). The
   nix-config gburd@solnix-arm profile is headless (console/cli only), which matches a build node.
   To do: create the gburd user + add to nix trusted-users, or keep root-only for the build daemon.
7. **The native pins are gone** — the prior session PINNED node-local gettext/cmake-minimal store
   paths; those don't survive a fresh AMI. This session replaced ALL of them with real from-source
   overrides (gettext libintl crack, cmake 3-layer crack, texinfo/help2man/perl-gettext wires) that
   build reproducibly. This is strictly better for a build-farm (no dangling pins). Bake the resulting
   store into the builder AMI/volume so subsequent builds are cache-warm.

**Verdict:** the node CAN act as an ongoing headless aarch64 build-farm-animal. Store persistence,
build-dir, and the runtime-linker config are set up. The remaining gap to a self-sufficient node is
baking the native-toolchain outputs + the fixed shim + the crle config into the canonical AMI so a
fresh cold-boot is immediately build-ready (today they rebuild from source, which works but is slow).

---

## 6. Artifacts for the orchestrator to commit

Modified (local fork `~/ws/solnix-pkgs`, all house-style, no dated/attribution comments):
- `pkgs/os-specific/illumos/aarch64-overlays/aa-toolkit-fixes-overlay.nix`
  (+ xz fixLibtoolPrint, tcl -lmd fix, sqlite --disable-tcl, pango/cairo/libtiff/gtk4/libadwaita
   X+font+appstream cross tails)
- `pkgs/os-specific/illumos/aarch64-overlays/aa-native-toml-overlay.nix`
  (+ gettext libintl empty-pipe crack, cmakeMinimal 3-layer crack, texinfo/help2man syslib wire,
   perl LocaleGettext libintl wire, broadened wireSyslibs)
- `pkgs/os-specific/illumos/phase3/fetchurl-shim-node-p3lfwcvh.nix` (NEW — captured fixed node shim;
  the fork's active shims already have the pickHash fix committed 034043d)

Node-level config (not in git; bake into the AMI): `crle -64 -u -l /usr/gcc/10/lib/amd64`;
nixpool on vol-0ea714fc5e29e485b; nix.conf `build-dir = /tmp/nix-build`.
