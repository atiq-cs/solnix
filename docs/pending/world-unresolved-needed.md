# World outputs that fail the publish gate (unresolved NEEDED, host RUNPATH)

Measured on dixi (solnix-3), 2026-10-09, while choosing which paths of dixi's
closure may go to cache.solnix.io. The gate run on every candidate path:

- every RUNPATH/RPATH entry is under /nix/store (or $ORIGIN);
- `env -i ldd` resolves every NEEDED, and only into /nix/store;
- every /nix/store/<hash> string in the NAR is the path itself or a declared reference.

Negative control: a copy of git's binary with its RUNPATH changed to /usr/lib (elfedit)
reports RUNPATH-BAD, NEEDED-BAD and DANGLING. An unmodified copy placed outside its
store path reports dangling=7. The gate can fail.

Three world outputs fail it. Every userland-linked package references
illumos-userland through its RUNPATH, so these failures also block publishing
bash, coreutils, gnugrep, gnused, findutils, diffutils, gettext, git, tmux, libevent,
openssh, htop, top-htop, illumos-vi and home-manager. The fix goes in the world,
not in the cache: the gate is not waived.

| output | store path | result |
|---|---|---|
| illumos-userland | /nix/store/73687v4yabr70dckk36ljliq67788558-illumos-userland | elf=2341 needed_bad=56 runpath_bad=1 |
| illumos-kernel | /nix/store/4mwiwlhmhg1jdkb76m4bp1wfyg3qmzmz-illumos-kernel | elf=3 (+598 relocatable modules) needed_bad=2 |
| illumos-stock-etc-var | /nix/store/p6n12nby8jwz89j5blzig5h8d38m04vl-illumos-stock-etc-var | elf=4 runpath_bad=4 needed_bad=4 |

All three are built from gate proto /nix/store/s7zkx8nx5sfxixmyqmlnrybrrh14jkmb-illumos-gate-proto
(prebuilt, gate rev ac45d71fc2), so a fix changes the world hash and joins the same
full rebuild as mk-src-pkg-guardfix.diff and gate-iconv-modules-gap.md.

## Why the world's own check did not catch this

`pkgs/illumos/mk-proto-world.nix` has three gaps. All three were read from the
builder, and their effects were measured on the output:

1. **The ldd pass records failures but never fails the build.** It writes
   `$out/.world/ldd-bad` and a summary, and exits 0. The shipped world has
   `ldd_bad_lines=1080` across 55 files (`$out/.world/summary`). This document lists
   the same 55 files plus libkcfd (item 3).
2. **Relocation covers only objects with NEEDED or SONAME.** `usr/lib/inet/ppp/minconn.so`
   has neither: it is a plugin that resolves pppd's symbols at dlopen time. So it
   keeps the gate's build RUNPATH `/usr/gcc/10/lib`, a host path. It is the only
   object in the world with that shape (measured: every .so with a RUNPATH and no
   NEEDED/SONAME).
3. **The ldd pass skips objects without NEEDED.** `lib/libkcfd.so.1` has no NEEDED.
   It is a filter (`SUNW_FILTER pkcs11_softtoken.so.1`), and the filtee lives in
   `usr/lib/security/`, which is not one of the `link_flat` dirs. So the filter
   resolves through `RUNPATH .../lib-32:.../lib-64` to nothing. cryptosvc is online
   on dixi and kcfd is not running.

Fix for the gaps (in mk-proto-world.nix, same rebuild):
- relocate every ELF ET_DYN/ET_EXEC that has a DT_RUNPATH/DT_RPATH, not only those
  with NEEDED|SONAME, so minconn.so gets `$RP`;
- add `usr/lib/security` and `usr/lib/security/amd64` to the `link_flat` dirs so
  pkcs11_softtoken.so.1 (and pkcs11_kernel.so.1) resolve as filtees;
- check filters too (`SUNW_FILTER`/`SUNW_AUXILIARY`), not only NEEDED;
- **fail the build when `.world/ldd-bad` is non-empty** once the DROP list below is
  applied. Keep an explicit `allowUnresolved` list, as mk-proto-slice already has,
  rather than a silent record.

## The 56 ELFs in illumos-userland

Missing libraries group into these sets. None of them is in the gate proto, because
the gate links them from the build host's IPS packages:

- **A** D-Bus/GLib: libdbus-1.so.3, libdbus-glib-1.so.2, libglib-2.0.so.0
- **B** Net-SNMP: libnetsnmp.so.40, libnetsnmpagent.so.40
- **C** OpenSSL 1.0: libcrypto.so.1.0.0, libssl.so.1.0.0. The objects compile with
  `-DOPENSSL_API_COMPAT=10101` (cmd/bhyve/Makefile.com, cmd/cmd-inet/usr.lib/wpad/Makefile,
  lib/libkmf/plugins/kmf_openssl/Makefile.com, cmd/sendmail/src/Makefile), so the source
  builds against the 1.1.1 API, which OpenSSL 3 still provides. The `.so.1.0.0` soname
  comes from the build host's lib.
- **D** Python 3.9: libpython3.9.so.1.0
- **E** TrouSerS (TPM 1.2): libtspi.so.1
- **F** Java: libjvm.so
- **G** filtee not on the search path: pkcs11_softtoken.so.1 (it is in the world; this is a relocation fix)

Proposal key: **DROP** = add to the world's `exclude` (with its SMF manifest, if it has
one). **BUILD** = rebuild the gate object against a from-source dependency (the store
OpenSSL 3, /nix/store/5is6hcfc9s2r0gfx3v8fz7l39rg8jclw-openssl-3.4.0, which passes the
gate and ships only lib/amd64). **RELOCATION FIX** = covered by the mk-proto-world fixes
above.

| # | ELF (under the world output) | class | missing NEEDED | gate package (p5m) | proposal | group |
|---|---|---|---|---|---|---|
| 1 | usr/bin/tpmadm | 32-bit | libtspi.so.1 | SUNWcs | DROP | E |
| 2 | usr/bin/latencytop | 64-bit | libglib-2.0.so.0 | diagnostic-latencytop | DROP | A |
| 3 | usr/bin/cdrw | 32-bit | libdbus-1.so.3 | media-cdrw | DROP | A |
| 4 | usr/lib/fm/amd64/libfmd_snmp.so.1 | 64-bit | libnetsnmp.so.40, libnetsnmpagent.so.40 | service-fault-management | DROP | B |
| 5 | usr/lib/fm/libfmd_snmp.so.1 | 32-bit | libnetsnmp.so.40, libnetsnmpagent.so.40 | service-fault-management | DROP | B |
| 6 | usr/lib/fm/notify/snmp-notify | 32-bit | libnetsnmp.so.40, libnetsnmpagent.so.40 | service-fault-management-snmp-notify | DROP | B |
| 7 | usr/lib/amd64/libhal-storage.so.1.0.0 | 64-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 8 | usr/lib/amd64/libhal.so.1.0.0 | 64-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 9 | usr/lib/hal/hal-is-caller-privileged | 32-bit | libdbus-1.so.3, libglib-2.0.so.0 | service-hal | DROP | A |
| 10 | usr/lib/hal/hal-storage-cleanup-all-mountpoints | 32-bit | libdbus-1.so.3, libglib-2.0.so.0 | service-hal | DROP | A |
| 11 | usr/lib/hal/hal-storage-cleanup-mountpoint | 32-bit | libdbus-1.so.3, libglib-2.0.so.0 | service-hal | DROP | A |
| 12 | usr/lib/hal/hal-storage-closetray | 32-bit | libdbus-1.so.3, libglib-2.0.so.0 | service-hal | DROP | A |
| 13 | usr/lib/hal/hal-storage-eject | 32-bit | libdbus-1.so.3, libglib-2.0.so.0 | service-hal | DROP | A |
| 14 | usr/lib/hal/hal-storage-mount | 32-bit | libdbus-1.so.3, libglib-2.0.so.0 | service-hal | DROP | A |
| 15 | usr/lib/hal/hal-storage-unmount | 32-bit | libdbus-1.so.3, libglib-2.0.so.0 | service-hal | DROP | A |
| 16 | usr/lib/hal/hal-storage-zpool-export | 32-bit | libdbus-1.so.3, libglib-2.0.so.0 | service-hal | DROP | A |
| 17 | usr/lib/hal/hal-storage-zpool-import | 32-bit | libdbus-1.so.3, libglib-2.0.so.0 | service-hal | DROP | A |
| 18 | usr/lib/hal/hald | 32-bit | libdbus-1.so.3, libdbus-glib-1.so.2, libglib-2.0.so.0 | service-hal | DROP | A |
| 19 | usr/lib/hal/hald-addon-acpi | 32-bit | libdbus-1.so.3, libglib-2.0.so.0 | service-hal | DROP | A |
| 20 | usr/lib/hal/hald-addon-cpufreq | 32-bit | libdbus-1.so.3, libglib-2.0.so.0, libdbus-glib-1.so.2 | service-hal | DROP | A |
| 21 | usr/lib/hal/hald-addon-network-discovery | 32-bit | libdbus-1.so.3, libglib-2.0.so.0, libdbus-glib-1.so.2 | service-hal | DROP | A |
| 22 | usr/lib/hal/hald-addon-storage | 32-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 23 | usr/lib/hal/hald-probe-acpi | 32-bit | libdbus-1.so.3, libglib-2.0.so.0 | service-hal | DROP | A |
| 24 | usr/lib/hal/hald-probe-network-printer | 32-bit | libdbus-1.so.3, libnetsnmp.so.40 | service-hal | DROP | AB |
| 25 | usr/lib/hal/hald-probe-printer | 32-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 26 | usr/lib/hal/hald-probe-storage | 32-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 27 | usr/lib/hal/hald-probe-volume | 32-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 28 | usr/lib/hal/hald-probe-xkb | 32-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 29 | usr/lib/hal/hald-runner | 32-bit | libdbus-1.so.3, libdbus-glib-1.so.2, libglib-2.0.so.0 | service-hal | DROP | A |
| 30 | usr/lib/libhal-storage.so.1.0.0 | 32-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 31 | usr/lib/libhal.so.1.0.0 | 32-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 32 | usr/sbin/hal-device | 32-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 33 | usr/sbin/hal-find-by-capability | 32-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 34 | usr/sbin/hal-find-by-property | 32-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 35 | usr/sbin/hal-get-property | 32-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 36 | usr/sbin/hal-set-property | 32-bit | libdbus-1.so.3 | service-hal | DROP | A |
| 37 | usr/sbin/lshal | 32-bit | libdbus-1.so.3, libdbus-glib-1.so.2, libglib-2.0.so.0 | service-hal | DROP | A |
| 38 | usr/lib/smtp/sendmail/sendmail | 32-bit | libssl.so.1.0.0, libcrypto.so.1.0.0 | service-network-smtp-sendmail | DROP | C |
| 39 | usr/lib/inet/wpad | 32-bit | libcrypto.so.1.0.0 | service-network-wpa | BUILD | C |
| 40 | usr/lib/pool/poold | 64-bit | libjvm.so | service-resource-pools-poold | DROP | F |
| 41 | usr/lib/krb5/plugins/preauth/pkinit.so.1 | 32-bit | libcrypto.so.1.0.0 | service-security-kerberos-5 | DROP | C |
| 42 | usr/bin/rmmount | 32-bit | libdbus-1.so.3, libdbus-glib-1.so.2, libglib-2.0.so.0 | service-storage-media-volume-manager | DROP | A |
| 43 | usr/bin/volcheck | 32-bit | libdbus-1.so.3, libdbus-glib-1.so.2, libglib-2.0.so.0 | service-storage-media-volume-manager | DROP | A |
| 44 | usr/bin/volrmmount | 32-bit | libdbus-1.so.3, libdbus-glib-1.so.2, libglib-2.0.so.0 | service-storage-media-volume-manager | DROP | A |
| 45 | usr/lib/rmvolmgr | 32-bit | libdbus-1.so.3, libdbus-glib-1.so.2, libglib-2.0.so.0 | service-storage-media-volume-manager | DROP | A |
| 46 | usr/sbin/bhyve | 64-bit | libcrypto.so.1.0.0 | system-bhyve | BUILD | C |
| 47 | lib/crypto/amd64/kmf_openssl.so.1 | 64-bit | libcrypto.so.1.0.0 | system-library | BUILD | C |
| 48 | lib/crypto/kmf_openssl.so.1 | 32-bit | libcrypto.so.1.0.0 | system-library | DROP | C |
| 49 | lib/libkcfd.so.1 | 32-bit | pkcs11_softtoken.so.1 (filtee) | system-library | RELOCATION FIX | G |
| 50 | usr/lib/security/amd64/pkcs11_tpm.so.1 | 64-bit | libtspi.so.1 | system-library | DROP | E |
| 51 | usr/lib/security/pkcs11_tpm.so.1 | 32-bit | libtspi.so.1 | system-library | DROP | E |
| 52 | usr/lib/libpolkit.so.0.0.0 | 32-bit | libglib-2.0.so.0 | system-library-policykit | DROP | A |
| 53 | usr/sbin/polkit-is-privileged | 32-bit | libglib-2.0.so.0 | system-library-policykit | DROP | A |
| 54 | usr/lib/python3.9/vendor-packages/libbe_py.so | 64-bit | libpython3.9.so.1.0 | system-library-python-libbe-3 | DROP | D |
| 55 | usr/lib/python3.9/vendor-packages/solaris/misc.so | 64-bit | libpython3.9.so.1.0 | system-library-python-solaris-3 | DROP | D |
| 56 | usr/lib/python3.9/vendor-packages/zfs/ioctl.so | 64-bit | libpython3.9.so.1.0 | system-library-python-zfs-3 | DROP | D |

Owning package comes from the gate's `usr/src/pkg/manifests/*.p5m` (source
/nix/store/vsnxlmf0l6x6dx3bigp6qwawnzqr0n0m-source). The class is file(1) on dixi.
Raw data: `/tmp/streamC1.WIP/world-56.tsv`, `/tmp/streamC1.WIP/world-needed.txt`
(every NEEDED/filter edge in the world) and `/tmp/streamC1.WIP/world-ldd-bad.txt`
(a copy of the world's `.world/ldd-bad`).

### Reasons, by group

- **A (HAL, rmvolmgr, cdrw, polkit, latencytop: 39 ELFs) -> DROP.** HAL is
  deprecated upstream and nothing in solnix uses it. svc:/system/hal and
  svc:/system/filesystem/rmvolmgr are disabled on dixi. NixOS removed its `hal`
  service years ago (udev/udisks replaced it), and polkit here is the 0.x libpolkit
  that only hald uses. Measured over world-needed.txt: libhal, libhal-storage and
  libpolkit are NEEDED only by files in this group. cdrw and rmmount/volcheck/volrmmount
  are HAL clients. latencytop needs glib only for its curses UI. Building D-Bus and
  GLib from source would make 39 binaries load, but they would serve no running
  service. Exclude `usr/lib/hal`, `usr/lib/libhal*`, `usr/lib/amd64/libhal*`,
  `usr/lib/libpolkit*`, `usr/sbin/{lshal,hal-*,polkit-is-privileged}`,
  `usr/lib/rmvolmgr`, `usr/bin/{rmmount,volcheck,volrmmount,cdrw,latencytop}`, and the
  manifests `lib/svc/manifest/system/hal.xml` and
  `lib/svc/manifest/system/filesystem/rmvolmgr.xml`. Revisit by building dbus + glib
  (nixpkgs has both) if removable-media automount is wanted.
- **B (FMA SNMP: 3 ELFs, plus #24 above) -> DROP.** svc:/system/fm/snmp-notify is
  disabled on dixi. No fmd plugin NEEDs libfmd_snmp (measured), so fmd itself, which
  is online, is unaffected. Exclude `usr/lib/fm/{,amd64/}libfmd_snmp*`,
  `usr/lib/fm/notify/snmp-notify` and `lib/svc/manifest/system/fm/snmp-notify.xml`.
  Building net-snmp from source is possible if SNMP traps are ever wanted.
- **C (OpenSSL 1.0 soname) -> BUILD the 64-bit objects that matter; DROP the rest.**
  - `usr/sbin/bhyve` (64-bit) and `usr/lib/inet/wpad` (wifi WPA supplicant: on an X1
    laptop it is the only path to WPA wifi) -> BUILD. The source already targets the
    1.1.1 API (`OPENSSL_API_COMPAT=10101`), so relinking against the store OpenSSL 3
    is a link-flag change in the gate build: point the gate's OpenSSL include and lib
    dirs at the store openssl (an ADJUNCT_PROTO-style override), not the host's.
    wpad is 32-bit in this proto, and the store openssl ships only lib/amd64, so either
    build wpad 64-bit or add a 32-bit openssl. Pick 64-bit: it is the gate's direction
    and avoids a second openssl.
  - `lib/crypto/amd64/kmf_openssl.so.1` -> BUILD with the same OpenSSL override. KMF
    (pktool, elfsign, IKE certs) dlopens it. The 32-bit copy -> DROP, same as nixpkgs
    keeping one ABI.
  - `usr/lib/smtp/sendmail/sendmail` -> DROP. svc:/network/smtp:sendmail and
    sendmail-client are disabled on dixi. NixOS ships no MTA by default. The one
    user, smtp-notify, executes /usr/sbin/sendmail (measured string in the binary) and
    can point at whatever MTA a config enables.
  - `usr/lib/krb5/plugins/preauth/pkinit.so.1` (32-bit) -> DROP. PKINIT preauth is
    optional for Kerberos, and the 32-bit plugin serves only 32-bit kinit. Rebuild it
    with the C override if smartcard Kerberos is needed.
- **D (Python 3.9 bindings: 3 ELFs) -> DROP.** These are beadm/zfs Python modules for
  an interpreter that is not in the world or the closure. No solnix code imports them
  (bootadm and install-be are shell). Building Python 3.9 for three modules is the
  wrong trade: if Python tooling ever needs them, build against the Python that
  ships then.
- **E (TPM 1.2 TrouSerS: tpmadm, pkcs11_tpm x2) -> DROP.** There is no tcsd service
  manifest in the world, so the stack has no daemon to talk to. TPM 1.2 is obsolete on
  current hardware: the X1 has TPM 2.0, which TrouSerS cannot drive. pkcs11_tpm is
  not in /etc/crypto/pkcs11.conf on dixi (only pkcs11_kernel and pkcs11_softtoken).
  NixOS packages trousers only as an opt-in service (services.tcsd).
- **F (poold, Java) -> DROP.** svc:/system/pools/dynamic (poold) is disabled on dixi.
  It needs a JVM in the world. Static resource pools (pooladm, libpool) do not depend
  on it.
- **G (libkcfd filter) -> RELOCATION FIX** in mk-proto-world.nix, see above. It is a
  real defect: kcfd, the userland crypto framework daemon, needs it. Verify after the
  rebuild that `ldd lib/libkcfd.so.1` resolves the filtee and that kcfd runs.

## illumos-userland: RUNPATH leak

| ELF | RUNPATH | cause | proposal |
|---|---|---|---|
| usr/lib/inet/ppp/minconn.so (32-bit) | /usr/gcc/10/lib | no NEEDED/SONAME, so mk-proto-world never relocates it (gap 2) | RELOCATION FIX: relocate every ELF with a RUNPATH. Alternatively, since it NEEDs nothing, delete the RUNPATH entry outright. |

## illumos-kernel

| ELF | NEEDED | resolves to | cause | proposal |
|---|---|---|---|---|
| boot/grub/bin/grub (32-bit) | libcurses.so.1, libc.so.1 | /lib/libcurses.so.1, /lib/libc.so.1 | RUNPATH `$ORIGIN:<kernel>/lib-32:<kernel>/lib-64`, but the kernel slice's lib-32/lib-64 are empty | DROP. This is the legacy GRUB shell. solnix boots with loader (loader.efi/gptzfsboot, in `boot/`), and the gate's system-boot-grub package is the legacy path. Exclude `boot/grub/bin` from the kernel slice's `extraPaths`. |
| boot/solaris/bin/symdef (32-bit) | libelf.so.1, libc.so.1 | /lib/... | same empty lib-32/lib-64 | BUILD-side fix: give the kernel slice `deps = [ libc world ]` (mk-proto-slice already takes deps) so its RUNPATH names libc and the world's libelf. It is a boot-archive helper the create_ramdisk/bootadm scripts may call, so it stays. If no solnix path calls it (bootadm does not name it; measured with grep on world's usr/sbin/bootadm), dropping `boot/solaris/bin` is the simpler option. |

## illumos-stock-etc-var

| ELF | RUNPATH | NEEDED resolves to | cause | proposal |
|---|---|---|---|---|
| etc/fs/ufs/mount | /usr/gcc/10/lib | libc.so.1 -> /lib | `stock` is a raw `tar` of the gate's etc/ and var/ (pkgs/illumos/default.nix); nothing relocates it | relocate |
| etc/fs/nfs/mount | /usr/gcc/10/lib | librpcsvc, libnsl, libsocket -> /lib | same | relocate |
| etc/fs/dev/mount | /usr/gcc/10/lib | libc.so.1 -> /lib | same | relocate |
| etc/fs/hsfs/mount | /usr/gcc/10/lib | libc.so.1 -> /lib | same | relocate |

These are the real mount helpers: the world's `usr/lib/fs/{ufs,nfs,dev,hsfs}/mount`
are symlinks `../../../../etc/fs/<fs>/mount` into them (measured; they resolve only
inside a BE's /etc). mount(8) tries /usr/lib/fs and then /etc/fs (cmd/fs.d/mount.c,
VFS_PATH/ALT_PATH). Dropping them breaks `mount -F ufs/nfs/hsfs`. Proposal: BUILD-side
fix. Either move the four ELFs into the world and run them through the same relocation
(and leave /etc/fs/<fs>/mount as links into the store, as NixOS links /etc entries to
the store), or run the world's elfedit/ldd pass over `stock` too. Prefer the first,
because the store then owns the binaries and /etc holds only links.

## Verification after the rebuild

Rerun the publish gate (`/tmp/streamC1.WIP/qgate.sh <path>` on an illumos host;
the script is described at the top of this file) on the new illumos-userland,
illumos-kernel and illumos-stock-etc-var. Each must report `GATE PASS`, and the
world's `.world/ldd-bad` must be empty or contain only an explicit, reviewed
allowUnresolved list.

## gcc-14.3.0 main output: shared libs under $out/lib carry no RUNPATH (found 2026-10-23, cache2 gate)

The `lib` output (gcc-14.3.0-lib, w00yl57k) is correct: its libstdc++, libgcc_s and libatomic get
`RUNPATH $lib/lib/amd64:<libc>` (gcc-src.nix) and pass the publish gate. The MAIN output (1n24r6d3) keeps its own
copies under `$out/lib{,/amd64}` with no RUNPATH: `ldd libatomic.so.1.2.0` -> `libgcc_s.so.1 => (file not
found)`. libcc1*/libcp1plugin carry RUNPATH /usr/gcc/14/lib/amd64 (the bootstrap compiler). Nothing links those
copies (the cc wrapper points at the lib output), so it breaks no program, but it fails the gate, so gcc and
gcc-wrapper are not offered to the cache. Fix at the source: in gcc-src.nix, run the same elfedit RUNPATH pass over
`$out/lib{,/amd64}/*.so*` (and rewrite libcc1* to the store), then rebuild gcc (~1 h on c5.4xlarge).

Update 2026-10-23: 631fb56 + the bin/libexec/plugin pass fixed the libatomic case and removed every /usr/gcc
RUNPATH (gate on zw75zy5y: 0 ELFs name /usr/gcc; a copy-of-gcc test compiled and ran C and C++ hello). Two NEEDEDs
still do not resolve inside the store, so the main output still fails the gate (the lib output w00yl57k/fi25qqrs and
gcc-wrapper PASS, and they are what programs use):
  - lib/gcc/*/plugin/libcc1plugin, libcp1plugin NEED libstdc++.so.6 + libgcc_s.so.1: RUNPATH should be
    `$lib/lib/amd64:<libc>` (the lib output), not only libc;
  - bin/* and libexec/* (gcc, cc1, ...) NEED libkstat.so.1, which is in illumos-libc-extra, not the libc slice:
    their RUNPATH needs libcExtra's lib/amd64 too, so gcc-src.nix needs libcExtra as an input.
Both are a one-line RUNPATH change each plus a gcc rebuild; do them when gcc itself is to be offered to the cache.
