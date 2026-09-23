# Image acceptance tests — the lessons, as code

`scripts/image-acceptance-test.sh` runs against every built install image before it
ships. Each check captures a defect we hit (usually on real X1 hardware) so an older
fix cannot silently regress. `make-iso-usb.sh` runs the suite automatically at the end
of every build (set `IMG_ACCEPT_STRICT=1` to make a failure abort the build).

## How to run

    scripts/image-acceptance-test.sh artifacts/install-media/usb-image-<date>-<tag>/
    scripts/image-acceptance-test.sh <dir> --boot      # + QEMU boot phase
    scripts/image-acceptance-test.sh --selftest        # prove the checks CAN fail

STATIC checks mount the boot_archive (need the illumos build node's lofiadm + mount -F
ufs; they SKIP gracefully elsewhere, e.g. the Linux dev box, where only the git-blob
comparison runs). The BOOT phase needs qemu.

## The checks and the lessons they guard

| check | lesson / incident |
|---|---|
| **console-login is stock ttymon** (not repointed to solnix-console-login) | tui5 repointed console-login at a raw-/dev/console shell (auto-login); the X1 hid keyboard flood drowned the prompt → no login. Stock ttymon coexists with the noise. |
| **`/etc/system` sets `hid:hid_errlevel`** | The X1's internal keyboard has an unparseable HID report descriptor; `hid` retries forever and floods /dev/console. `hid_errlevel=0` suppresses the L1 spam. |
| **`/etc/resolv.conf` is empty** (no nameserver) | The media inherited the EC2 build host's resolv.conf (VPC resolver 10.0.0.2); on a home network that stale resolver poisoned DNS until hand-fixed. Scrubbed at build; DHCP fills it at install. |
| **CA bundle present at `ssl-cert-file`** (≥20 certs) | The X1 flake eval died at 2/9 with "problem with the SSL CA cert" — the conditional CA copy shipped a missing/stale bundle, so nix could not verify the github: fetch. Now non-optional + fail-loud at build. |
| **`solnix-zap` present + `#!/sbin/sh`** | A failed install left a SUSPENDED/FAULTED rpool that recurred across reboots (auto-imported from a stale zpool.cache). solnix-zap bakes the clean-slate recovery (export ghost, clear cache, labelclear, 4K dd) into one command. |
| **shipped `solnix-install` sha == git HEAD blob** | committed ≠ shipped: the tui2 image shipped an installer built BEFORE a committed fix (same-commit-as-deliverables made it LOOK present). Verify the actual shipped binary matches HEAD. |
| **`/etc/solnix-autoinstall` absent** | A stray autoinstall marker would wipe a disk unattended; a normal installer image must be interactive. |
| **runnability: every staged ELF's NEEDED libs present, transitive + ABI-matched** | dig/curl/nslookup shipped but died at exec (`libidn2`/`libcares`/... "open failed"). The first gate walked binaries' DIRECT NEEDED only — a staged LIBRARY's own NEEDED (libcurl→libcares) was never checked (the openssl second-order trap). Also ABI: a 32-bit lib was satisfying a 64-bit binary's NEEDED. The check is a transitive, ABI-aware fixed-point over binaries AND libs. |
| **boot_archive raw size < 816,119,808** | The X1 EFI firmware refused an oversized (859MB) uncompressed boot_archive; the loader stages it into a bounded region. 700MB is the working cap under this hard limit. |
| **(boot) QEMU reaches a login prompt** | End-to-end: the media actually boots to a usable stock login (QEMU has a PS/2 keyboard, so no hid flood — the prompt is the check). |

## Known gaps (honest — not faked)

- **curl/dig/nix exec-RUN in a booted image** needs an expect-driven interactive login; today their runnability is proven STATICALLY (NEEDED-closure). An expect exec check is a future addition, tracked here rather than claimed.
- **The hid quieting cannot be QEMU-verified** (QEMU has no HID flood); it is source-reasoned against illumos-gate `hid.c` (`hid_errlevel` gates the L1 "Invalid Report Descriptor" printf).
- **The mount-guard / diverted-store / suspended-pool install-flow fixes** are installer *logic*, not image *contents* — they are verified by the shipped-sha check (the fix is IN the installer) plus reasoning through the exit paths; the true test is a real install, which the acceptance suite cannot run.

## Adding a new check

When a new defect is found on hardware:
1. Add a check in `static_checks` (or `boot_checks`) that FAILS on the defect, with a
   comment citing the incident.
2. Make sure `selftest()`'s defective fake root triggers it (or add the trigger), so
   the check is proven non-vacuous — **a check that cannot fail proves nothing**.
3. Add a row to the table above.
