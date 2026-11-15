# illumos upstreams solnix tracks

Checked 2026-11-15 (20:00-21:45 UTC) on werk by up1, against each project's own repo, site or
release notes, through the authenticated GitHub API (`gh api`), the Bitbucket 2.0 API and shallow
clones (`--depth 50 --filter=blob:none`). "90 d" = commits on the named branch since 2026-08-17,
counted with the GitHub API's `since=` pager (every commit reachable from the branch, merges included). "Divergence" is
the GitHub compare API from **our gate pin `faf916e60c`** (illumos-gate, committed 2026-10-14
"18518 Reduce taskq and context-switch cost of zio pipe") to the fork's branch: "ahead N" = N
commits the fork has that the pin lacks; "behind M" = pin commits the fork lacks. "Fork-only" is
the same compare against today's illumos-gate master, so it counts what the fork carries that the
gate does not have. Anything I could not check is marked **unverified**.

Re-run: `scripts/upstream-watch.sh` (below) for the weekly digest. To refresh this table, re-run the `gh api`
commands in the HANDOFF of 2026-11-15 (`/tmp/up1/HANDOFF.md` on werk).

## illumos kernels and gates

| Project | Repo, branch | Maintained by (2026-11) | Last commit, 90 d | Licence | What solnix takes | Divergence from our pin | Cadence |
|---|---|---|---|---|---|---|---|
| **illumos-gate** | github.com/illumos/illumos-gate `master` | The illumos project. In the 90 days, RTIs were approved by Dan McDonald (83), Gordon Ross (74), Robert Mustacchi (32), Patrick Mooney (8) ("Approved by:" lines) | 2026-11-15 (Andy Fiddaman), 201 | CDDL-1.0 for most code, per its README; per-file exceptions (GitHub reports no SPDX id) | Everything: it's our gate. bhyve/vmm, viona, ppt, overlay/varpd, smbsrv, COMSTAR, FMA, DTrace and ZFS are all in the pin already | ahead 95, behind 0; merge base = the pin itself (2026-10-14) | **weekly** digest; rebase the pin monthly or for a security fix |
| **illumos-joyent** (SmartOS) | github.com/TritonDataCenter/illumos-joyent `master` (github.com/joyent/illumos-joyent redirects here) | The SmartOS team. smartos.org now redirects to tritoncloud.io/smartos, whose page names "Sovren Technologies, Inc. d/b/a Triton Cloud" and "the 2022 transition to independent stewardship". mnx.io says MNX Solutions bought Triton from Joyent. smartos-live commit emails are @mnx.io from 2024-01 to 2026-08 and @edgecast.io from 2025-07 to 2026-10; illumos-joyent's latest LX work (OS-8784, 2026-11-11) is @edgecast.io. **The MNX → Edgecast → Sovren chain is not confirmed by any first-party statement I found: unverified** | 2026-11-15 (merge by Toomas Soome), 247 | CDDL (gate-derived; per-file) | **LX brand** (`uts/common/brand/lx`, `lib/brand/lx`), **vnd**, the zone brands `bhyve kvm joyent joyent-minimal builder jcommon`, mdata (in smartos-live/mdata-client, MIT), the KVM driver (illumos-kvm, GPL-2.0: Linux-derived) | ahead 6688 of the pin, behind 0; fork-only vs gate master 6594 (merge base 2026-11-15: it merges the gate daily) | **weekly** for `brand/lx` and `io/vnd`; LX is a must-have (docs/roadmap.md) |
| smartos-live | github.com/TritonDataCenter/smartos-live `master` | same team | 2026-10-12 (Nahum Shalman), 3 | No top-level LICENSE; files carry MPL-2.0 headers (code search: 124 hits for "Mozilla Public"); **exact licence mix unverified** | The platform build, vmadm/imgadm design (declarative zone JSON = closest analog to a Nix zone module), the zone resource-control defaults | n/a (not a gate) | monthly |
| **illumos-omnios** (OmniOS CE) | github.com/omniosorg/illumos-omnios `master`; release branches `r151004`...`r151060` | OmniOS Community Edition Association, "a Swiss association" (omnios.org/about/about.html); board: Tobias Oetiker, Andy Fiddaman, Dominik Hassler. 90-d commits: Andy Fiddaman 43, Matthew Ahrens 14, Dominik Hassler 6 | 2026-11-12 (Dominik Hassler), 267 | CDDL | **LX on a near-stock gate** (OmniOS carries `lib/brand/lx` but not vnd or the Joyent brands: the smaller LX diff to port), bhyve/kvm zone brands (in omniosorg/pkg5 `src/brand/bhyve`, not the gate), `zadm` (GPL-3.0), LTS backports | ahead 4987, behind 0; fork-only vs gate master 4913 | **weekly** on `master`. **Per release**: r151060 = current stable (support ends 2027-11-01), r151058 = old stable (ends 2027-05-03), **r151054 = current LTS** (no end date on the page), r151056 support ended 2026-11-02 (omnios.org/releasenotes) |
| omnios-build / omnios-extra | github.com/omniosorg/omnios-build, omnios-extra `master` | same | 2026-11-13 / 2026-11-09; 281 / 238 | Repo licence CDDL; each package keeps its own | Recipes and patches: **`driver/tuntap`** (omnios-build `build/tuntap`, 1.3.3, GPL-2.0 LICENSE, last touched 2026-03-11), `ooce/tailscale` 1.104.4, which **depends on driver/tuntap** and is built from the fork github.com/nshalman/tailscale ("until it is fully upstreamed"), openvpn, qemu, zadm, znapzend, zrepl | n/a | monthly, or when we port a component they already ship |
| **oxidecomputer/illumos-gate** (Helios) | github.com/oxidecomputer/illumos-gate **`stlouis`** (the Helios README names this branch) | Oxide Computer Company | 2026-11-15 (Andy Fiddaman), 257 | CDDL | AMD platform work (`uts/oxide`: Milan/Genoa/Turin, PCIe, SMN, TSC calibration), raw zvol fixes (stlouis#1088-1094: panics and ignored errors), bhyve/viona fixes that later go upstream. 240 non-merge commits in 90 d, mostly `stlouis#NNNN` (Oxide hardware) | ahead 1130, behind 0; fork-only 1045 | **weekly**, filtered: `fs/zfs`, `io/vmm`, `io/viona`; skip `uts/oxide` unless we target AMD server boards |
| Helios distro | github.com/oxidecomputer/helios `master` (+ helios-omnios-build / helios-omnios-extra branch `helios3`) | Oxide | 2026-11-09, 6 | MPL-2.0 | How a CI-built illumos distro is assembled from consolidations; "Helios is a distribution of illumos powering the Oxide Rack" (README). Not a general-purpose target | n/a | quarterly |
| **arm64 (aarch64) port** | kernel: github.com/richlowe/illumos-gate **`arm64-gate`** (mirrored as omniosorg/illumos-omnios `arm64-gate`); bootstrap: github.com/richlowe/arm64-gate `main` | Richard Lowe, with Dominik Hassler (OmniOS); design in IPD 24 (still "predraft") | kernel 2026-11-09 (Richard Lowe), 214; OmniOS mirror 2026-11-02, 176; bootstrap 2026-08-23, 2 | CDDL | `uts/aarch64`, `uts/armv8`, the cross gcc/binutils branches (`il-14_3_0-arm64` in richlowe/gcc) and the OmniOS `braich` sysroot (pkg.omnios.org/bloody/braich). Our src/aarch64-arm64-gate-patches apply on top | ahead 1164, behind 0; fork-only 1101 | **weekly** (our aarch64 phase rides on it) |
| n-hys (Hayashi Naoyuki) ARM + RISC-V port | github.com/n-hys/illumos-gate; default `osport/v2021.07`, newest `osport/v2022.11-wip` | Hayashi Naoyuki (sole author). **Dormant**: no commit since 2022-11-17 | 2022-11-17, 0 | CDDL (docs/prior-art-n-hys-riscv.md) | `uts/riscv64`, `uts/riscv64pf/{sun20i,unleashed,virt}`, `uts/aarch64pf`: the reference our RISC-V "n-hys patch series" is cut from | `osport/v2022.11-wip` vs pin: diverged, ahead 121, behind 1947, merge base 4adf43b0b5 (2022-11-16) | **none** (frozen); re-check yearly. We carry the useful parts |
| **DilOS** | bitbucket.org/dilos/dilos-illumos4 `dilos4` ("mirror of local dilos4"); userland bitbucket.org/dilos/du4 `master` | Igor Kozhukhov (www.dilos.org: "illumos-based platform with OpenZFS, Debian userland, Zones and bhyve") | dilos4 2026-07-08 (Igor Kozhukhov), **0 in 90 d** (67 commits in 2026-06, 24 in 2026-07); du4 2024-08-25 | CDDL (its README is the gate's) | Prior art for an illumos with **OpenZFS** in place of illumos ZFS and a Debian (dpkg) userland | **unknown**: Bitbucket has no compare across repos, and the history is a squashed mirror | quarterly; drop if no commit by 2027-07 |
| **Tribblix** | github.com/tribblix/build (recipes), tribblix/tribblix-build (illumos build glue), tribblix/overlays, overlays.sparc, overlays.lx, tribblix-zones, zap | Peter Tribble | build 2026-11-15, 994 in 90 d; tribblix-build 2026-10-23, 2 | CDDL (LICENSE files in build and tribblix-build) | **SPARC**: Tribblix still ships SPARC. ISO m34; m35 (2026-09-23) is "a synthetic release with new packages atop m34" that moves SPARC from gcc7 to gcc10. The SPARC illumos build starts from a **fixed gate commit `6538c7b4c7` (2021-11-05)** plus cherry-picks and `illumos/sparc/gate-patches`, because "Upstream gate cannot be used as SPARC support has been removed" (tribblix-build illumos/sparc/README.md; sparc-repo-m34.sh last changed 2026-04-10). Hardware: LDOM on T4-1, T5140; Sun Blade 1500 "less well"; "M-series and the Ultra 25 do not work" (relnotes, m25/m26). **Ultra 45: not listed either way, unverified.** x86 builds a vanilla gate (OmniTribblix uses illumos-omnios for LX). Current x86 release m41.1 (2026-10-27) | x86: none (stock gate). SPARC: 4 years behind the gate, by design | **monthly** for the SPARC patch set, next to our src/sparcv9-gate-patches and sun (OI Hipster SPARC) |
| OpenIndiana illumos-gate fork | github.com/OpenIndiana/illumos-gate | **dead**: archived; last push 2015-05-03. OI builds illumos-gate `master` HEAD directly (oi-userland components/openindiana/illumos-gate/Makefile: `GIT_BRANCH=master GIT_CHANGESET=HEAD`) | — | — | — | — | — |

Dropped (dead), with the date of the last commit: Nexenta `illumos-nexenta` (`release-5.5-patch`,
2023-04-21); `delphix/delphix-os` (2020-04-13); `alhazred/v9os-caiman` (archived; 2018-10-30);
`alhazred/illumos-arm` (`osport/v2020.10`, 2021-11-16: an earlier copy of the n-hys tree);
`illumos/gfx-drm` (last commit 2022-01-06, none in 90 d: the gate's old DRM; we use OpenBSD's
via src/drm-port). Searched and not found: a public Tribblix fork of illumos-gate on GitHub, and an
illumos SPARC gate fork besides Tribblix's patch set.

## Userland, packaging and storage

| Project | Repo, branch | Maintained by | Last commit, 90 d | Licence | What solnix takes | Cadence |
|---|---|---|---|---|---|---|
| **oi-userland** (our userland upstream) | github.com/OpenIndiana/oi-userland `oi/hipster` | OpenIndiana; most commits in the last 100 are by Marcel Telka (44) and Andreas Wacknitz (34). Snapshot 2026.10 is the newest on openindiana.org | 2026-11-15, 1010 | Repo CDDL-1.0; components keep their own | Component patches for illumos (our recipe lanes), the SPARC IPS depot (pkg.openindiana.aurora-opencloud.org/oi-sparc, docs/sparc-hipster-host.md) | **weekly** (in the watch list: components/openindiana, developer, library) |
| **OpenZFS** | github.com/openzfs/zfs `master`; release zfs-2.4.4 (2026-08-21) | OpenZFS project | 2026-11-13, 736 | CDDL-1.0 (LICENSE: "Unless otherwise noted ... CDDL") | Feature-flag parity and fixes. illumos imports OpenZFS changes one at a time ("Imported from: OpenZFS <sha>" in gate commits). **Pool features in OpenZFS's `compatibility.d/openzfs-2.4` set that our pin's `zfeature_common.h` does not have (20):** blake3, block_cloning, block_cloning_endian, bookmark_written, device_rebuild, draid, dynamic_gang_header, fast_dedup, head_errlog, large_microzap, livelist, longname, physical_rewrite, raidz_expansion, redacted_datasets, redaction_bookmarks, redaction_list_spill, vdev_zaps_v2, zilsaxattr, zstd_compress. So a pool made with `zpool create -o compatibility=openzfs-2.4` won't import read-write on solnix; use the `compat-2021` set or older. Name differences were left out (gate `pool_checkpoint`/`fs_ss_limit` = OpenZFS `zpool_checkpoint`/`filesystem_limits`) | **monthly**, plus every OpenZFS release (watch list: zfeature_common.{c,h}) |
| **pkgsrc as SmartOS uses it** | github.com/TritonDataCenter/pkgsrc: `trunk` (sync of NetBSD), `release/trunk` (bot), quarterly `release/2025Q4` (2026-10-21; newest quarterly on the fork); `joyent/release/trunk` stopped 2022-10-12. Also pkgsrc-extra (`main`, 2026-11-11) and pkgsrc-joyent (2026-08-11) | Jonathan Perkin (all quarterly-branch commits sampled); upstream NetBSD pkgsrc (`trunk`, 7229 in 90 d) | release/2025Q4: 6 in 90 d | Framework: BSD-style (NetBSD Foundation); each package patch follows its package. **Exact SPDX of the framework not verified** | The SunOS portability patches (`patches/patch-*` in each package dir, plus `mk/platform/SunOS.mk`) for recipes that fail on illumos. Read them, don't vendor them | per-recipe, when a recipe fails: grep the matching `pkgsrc/<cat>/<pkg>/patches` first |

## BSD sources

| Project | Repo, branch | Last commit (watched paths) | Licence | What solnix takes | Cadence |
|---|---|---|---|---|---|
| **OpenBSD** | github.com/openbsd/src `master` (the official read-only mirror); 2355 commits in 90 d | `sys/dev/pci/drm` 2026-11-11; `if_iwx.c` 2026-09-19; `if_iwm.c` 2025-12-01 | `if_iwx.c` header carries an ISC notice and a BSD redistribution notice; iwm and drm per file, **not checked** | **drm** (src/drm-port: i915, amdgpu via obsd-compat), **iwx** (AX211) and **iwm** wifi (src/ports/wifi). These are code we carry | **weekly** (watch list: drm, iwx, iwm) |
| **FreeBSD** | github.com/freebsd/freebsd-src `main`; 3528 in 90 d | `sys/compat/linux` 2026-11-09 | BSD-style, per file (**SPDX not checked**) | The **linuxulator** as a design reference for LX (how a BSD kernel maps Linux syscalls), libvirt's bhyve driver (FreeBSD only), and ports: `audio/pipewire-spa-oss` = github.com/shkhln/pw-oss (MIT, 2026-09-06), "PipeWire SPA plugin implementing a FreeBSD OSS backend": the PipeWire route to illumos's OSS-compatible audio (`audio_oss.c` is in the pin) | monthly (watch list: sys/compat/linux) |
| NetBSD | (pkgsrc above) | — | BSD-style (**not checked**) | Driver substrate notes: docs/netbsd-driver-substrate.md | per need |

## Oxide userland

All four are MPL-2.0 (GitHub licence API) and Rust.

| Repo, branch | Last, 90 d | What it is | Use for solnix |
|---|---|---|---|
| github.com/oxidecomputer/propolis `master` | 2026-11-14, 27 | "VMM userspace for use with illumos bhyve"; "running on recent illumos bits is required" (README): its `bhyve-api` is tied to the vmm ioctl ABI | The microVM VMM (docs/design-microvm-bhyve.md): a Firecracker-shaped VMM that already runs on bhyve. Pin it to a propolis rev that matches our gate's vmm ABI |
| github.com/oxidecomputer/crucible `main` | 2026-11-13, 88 | "a distributed network-replicated block storage service" | Later: replicated VM disks. Not needed for a single host |
| github.com/oxidecomputer/opte `master` | 2026-11-11, 23 | Oxide Packet Transformation Engine; "the XDE kernel module runs only on Helios" | Reference only, until it builds on a stock gate |
| github.com/oxidecomputer/falcon `main` | 2026-11-06, 6 | "a Rust API for creating network topologies composed of Propolis VMs interconnected by simnet links" | A test bed for multi-VM network tests (solnix-netd, IPMP, overlay) on one host |

## Tracking it mechanically: `scripts/upstream-watch.sh`

`scripts/upstream-watch.sh` keeps one bare cache repo (`~/.cache/solnix-upstream-watch/cache.git`)
and, per watched branch, fetches only the last week of history blob-less
(`--shallow-since`, falling back to the tip alone for a dormant branch). It lists the
commits of the window that touch the paths solnix cares about; a fork lists only the commits
illumos-gate doesn't have. The default list covers the gates and forks above
(paths: `uts/common/brand`, `lib/brand`, `io/vmm`, `io/viona`, `cmd/bhyve`, `libvmmapi`, `fs/zfs`,
`common/zfs`, `io/overlay`, `io/vnd`, `io/mac`, and the arch dirs `aarch64 aarch64pf armv8
riscv64 riscv64pf sparc sun4u sun4v oxide`), plus oi-userland, smartos-live, the Tribblix SPARC
patch set, Helios, propolis, OpenZFS feature tables, OpenBSD drm/iwx/iwm and FreeBSD's
linuxulator. `-l <file>` takes another list in the same row format.

```
scripts/upstream-watch.sh -o /tmp/upstream-digest-$(date -u +%Y%m%d).md   # default: last 8 days
bash scripts/test-upstream-watch.sh                                       # fixture test, no network
```

First full run (2026-11-15, werk): 16 rows, 10 s, exit 0. The 8-day window had 19 watched gate
commits, 2 in illumos-joyent outside the gate, 3 in illumos-omnios, 10 in stlouis, 1 in arm64-gate,
29 in oi-userland and 79 in OpenBSD drm/iwx. Exit 1 means a row printed FETCH-FAILED or BAD-ROW; the
digest is still written. Run it weekly from cron on a build host (not floki), and hand the digest
to whoever owns the pin.

Unverified, and worth a look before relying on it: who owns SmartOS today (see the table); the
Ultra 45 under Tribblix SPARC; smartos-live's licence mix; the SPDX ids of the pkgsrc framework,
FreeBSD and NetBSD files, and OpenBSD's drm and iwm.
