# Feature roadmap candidates

What solnix could support beyond today's base, written 2026-11-15 by up1. For each: where the code
comes from (paths are in **our gate pin `faf916e60c`** unless another source is named; checked with
`git cat-file -e`), the NixOS option it maps to (checked in the nixpkgs flake on werk,
`/nix/store/42h7k7nz90k8hi5qd9mr2ijnfvbircz4-source/nixos/modules`), licence, size and what it
needs first. The sources are described in docs/illumos-upstreams.md.

Size: **S** = days (module + package around code already in the pin); **M** = weeks (porting a
component from a fork, or a new driver of moderate size); **L** = months (new kernel subsystem,
hardware bring-up, or a large syscall surface).

Rule from AGENTS.md: take NixOS's answer and depart only where illumos can't do the same. Each row
names the NixOS option the solnix module should mirror.

## Virtualization and containers

| Feature | illumos source | NixOS counterpart | Licence | Size | Depends on |
|---|---|---|---|---|---|
| **bhyve VMs** (`bhyve`, `bhyvectl`, `libvmmapi`, `vmm`) | pin: `cmd/bhyve`, `lib/libvmmapi`, `uts/intel/io/vmm` | `virtualisation.libvirtd` (for the QEMU/KVM role); `microvm.nix` (community) for declared VMs | CDDL + BSD-2 (FreeBSD-derived bhyve) | S (package) / M (declarative `virtualisation.bhyve.vms.<name>` module) | UEFI firmware package (OmniOS `bhyve-fw`), VT-x/AMD-V on the host (metal EC2 or arnold) |
| **bhyve-branded zones** (VM inside a zone: jail + resource caps) | brand: illumos-joyent `lib/brand/bhyve`, or OmniOS `omniosorg/pkg5 src/brand/bhyve` (not in the pin, which has only `ipkg labeled sn1 solaris10`) | `containers.<name>` (nixos-containers) as the isolation analog | CDDL | M | bhyve VMs; a zone module (`solnix.zones.<name>`); OmniOS's brand is the smaller port |
| **PCI passthrough (ppt)** | pin: `uts/intel/io/vmm/io/ppt.c`, `cmd/pptadm` | `boot.kernelParams` `vfio-pci.ids=` + `virtualisation.libvirtd` hostdev | CDDL/BSD-2 | S | bhyve; IOMMU; the device must not be bound to a native driver (`/etc/ppt_matches`) |
| **viona** (in-kernel virtio-net for bhyve) | pin: `uts/intel/io/viona` | `virtio_net` + `vhost_net` (implicit in libvirtd/QEMU) | CDDL | S (on with bhyve) | bhyve; a VNIC per guest (Crossbow) |
| **propolis** as the Firecracker-equivalent microVM (docs/design-microvm-bhyve.md) | github.com/oxidecomputer/propolis | `microvm.nix` (`microvm.vms`) / Firecracker | MPL-2.0 | M | bhyve; a propolis rev whose `bhyve-api` matches our vmm ioctl ABI ("running on recent illumos bits is required", propolis README); Rust toolchain (we have one) |
| **libvirt bhyve driver** (virt-manager, `virsh`: the maintainer's nix-config installs `libvirt` and `qemu` in home-manager `_mixins/console`) | libvirt `src/bhyve` | `virtualisation.libvirtd.enable`, `programs.virt-manager.enable` | LGPL-2.1 (libvirt) | M | libvirt's meson enables the driver only when `host_machine.system() == 'freebsd'`, so it needs a port to illumos `bhyvectl`/`libvmmapi` naming, plus our patch or an upstream one. bhyve VMs first |
| **LX-branded zones** (run Linux binaries unchanged; MUST-HAVE, docs/roadmap.md 2026-10-10) | illumos-omnios `lib/brand/lx` + `uts/common/brand/lx` (OmniOS carries LX on a near-stock gate) or illumos-joyent (also needs `io/vnd`) | none in NixOS (Linux runs Linux natively); nearest is `containers.<name>` | CDDL | L | zone module; an LX image source (TritonDataCenter/lx-images); FreeBSD's linuxulator as a design check |
| **Docker-compatible containers** | LX zones + an OCI front end; SmartOS's `sdc-docker` (MPL-2.0, active 2026-09) shows the model | `virtualisation.docker`, `virtualisation.podman` (the maintainer's nix-config sets `virtualisation.docker.storageDriver` on floki and meh) | MPL-2.0 / Apache-2.0 | L | LX zones; overlay networking; a ZFS-clone image store |
| **Native zones as a declarative module** (`ipkg`/`sparse` brand, resource controls: `capped-cpu`, `capped-memory`, `zone.max-lwps`) | pin: `cmd/zonecfg`, `lib/libzonecfg`, `cmd/rcap`, `cmd/zonestat`; vmadm (smartos-live) for the JSON-spec design | `containers.<name>` (`config`, `privateNetwork`, `bindMounts`) | CDDL | M | solnix already has a `solnix` brand for the builder zone (modules/config/community/builder-zone.nix): generalise it |
| **Nix per-build sandboxing via zones** (close `sandbox = false`, modules/config/nix.nix:102) | zones (pin) + Nix's `sandbox` hook, a new illumos backend in Nix | `nix.settings.sandbox` (NixOS sets `true`, nix-daemon.nix) | LGPL-2.1 (Nix) + CDDL | L | fast zone create/destroy (a ZFS-clone zone root per build), or a cheaper per-build privilege-limited process plus a chroot. The builder zone today is one zone for all of a builder's builds |

## Networking

| Feature | illumos source | NixOS counterpart | Licence | Size | Depends on |
|---|---|---|---|---|---|
| **TUN/TAP driver** (so Tailscale gets a real interface; today services.tailscale runs userspace-only, so local programs can't reach the tailnet without its SOCKS/HTTP proxy) | OmniOS `omnios-build/build/tuntap` (1.3.3, "based on the Universal TUN/TAP Driver"); OmniOS's tailscale package depends on it | `services.tailscale.interfaceName` (a TUN name; "userspace-networking" opts out of TUN) | **GPL-2.0** (its LICENSE file): an out-of-tree kernel module, kept as a separate package, never linked into a CDDL file | S-M | the kernel module build lane, and a tailscale with illumos TUN code. Upstream tailscale has none: `net/tstun/tun.go` is `//go:build ... !solaris && !illumos` and `tstun_stub.go` covers illumos; tailscale/wireguard-go `tun/` has no illumos file. OmniOS builds tailscale from **github.com/nshalman/tailscale** (BSD-3-Clause; omnios-extra build.sh: "Use nshalman fork until it is fully upstreamed"), where branch `sunos-1.104` is v1.104.4 plus one commit, "illumos/solaris support rebased onto v1.104.0". solnix packages upstream 1.98.10 (pkgs/illumos/cli/go-tools.nix) |
| **WireGuard** | none in-kernel; wireguard-go (MIT) in userspace over TUN | `networking.wireguard.interfaces`, `networking.wg-quick` | MIT | M | TUN/TAP; wireguard-go illumos tun backend |
| **OpenVPN** | omnios-extra `build/openvpn` | `services.openvpn.servers` | GPL-2.0 | S | TUN/TAP |
| **IPMP** (IP multipathing) | pin: `inet/ip/ipmp.c`, `cmd/cmd-inet/usr.sbin/ipmpstat` | `networking.bonds` (closest Linux analog) | CDDL | S | solnix-netd module learns `ipmp` groups |
| **Link aggregation (802.3ad)** | pin: `uts/common/io/aggr`, `dladm create-aggr` | `networking.bonds` | CDDL | S | solnix-netd |
| **VLANs** | pin: `dladm create-vlan` | `networking.vlans` | CDDL | S | solnix-netd |
| **VNICs / etherstubs / flows** (Crossbow) | pin: `uts/common/io/mac`, `cmd/dladm`, `cmd/flowadm` | `networking.macvlans`, `networking.bridges` | CDDL | S | solnix-netd; needed by every zone/VM row above |
| **VXLAN overlay** | pin: `uts/common/io/overlay`, `lib/varpd` (illumos-joyent adds more varpd plugins) | `systemd.network` netdev `Kind=vxlan` (no `networking.vxlans`) | CDDL | M | VNICs; a varpd lookup plugin (direct or files) |

## Storage

| Feature | illumos source | NixOS counterpart | Licence | Size | Depends on |
|---|---|---|---|---|---|
| **SMB 3 server** (in-kernel) | pin: `uts/common/fs/smbsrv`, `cmd/smbsrv` (incl. `smbadm`) | `services.samba` | CDDL | S-M | idmap, a declarative share module, firewall ports |
| **NFS server** | pin: `uts/common/fs/nfs`, `cmd/fs.d/nfs/nfsd`, `lib/libshare` | `services.nfs.server.exports` | CDDL | S | ZFS `sharenfs` or `/etc/dfs/dfstab` rendered from Nix |
| **iSCSI target (COMSTAR)** | pin: `uts/common/io/comstar`, `cmd/stmfadm`, `cmd/itadm` | `services.target` (LIO) | CDDL | M | zvols; an stmf config renderer |
| **ZFS auto-snapshots and replication** | sanoid/syncoid (GPL-3.0), zrepl (MIT; in omnios-extra), znapzend (GPL-3.0; in omnios-extra) | `services.zfs.autoSnapshot`, `services.sanoid`, `services.syncoid`, `services.zrepl`, `services.znapzend` | per tool | S | perl or Go runtime (have); SMF periodic or cron |
| **ZFS native encryption at boot** | pin: `fs/zfs/dsl_crypt.c` | `boot.zfs.requestEncryptionCredentials` | CDDL | S-M | a key prompt in early boot (illumos loader or SMF) |
| **OpenZFS feature parity** (20 pool features missing in the pin, docs/illumos-upstreams.md) | OpenZFS via the gate's import stream | `boot.zfs.package` | CDDL | L (upstream illumos work) | upstream; until then, create pools with a compat set older than openzfs-2.4 |

## Observability and debugging

| Feature | illumos source | NixOS counterpart | Licence | Size | Depends on |
|---|---|---|---|---|---|
| **FMA** (fault management: `fmd`, `fmadm`, `fmdump`) | pin: `cmd/fm` | `hardware.rasdaemon`, `services.smartd` | CDDL | S | SMF service enabled by default, plus a notify hook |
| **DTrace USDT probes in packages** (PostgreSQL `--enable-dtrace`, also Node, Python, Perl) | pin: `uts/common/dtrace`, `lib/libdtrace`, `dtrace -G` | `programs.bcc`, `programs.systemtap` (Linux tracers); nixpkgs postgresql has no dtrace flag | CDDL | S per package | `dtrace -G` callable from stdenv (it post-processes objects); a `withDtrace` override convention |
| **mdb / kmdb** | pin: `cmd/mdb`, `cmd/mdb/intel/kmdb` | `environment.enableDebugInfo` + gdb | CDDL | S | debug info (solnix has `debug-info.nix`) |
| **Crash dumps** | pin: `cmd/dumpadm`, `cmd/savecore`; solnix has `solnix.dumpadm` and `solnix.coreadm` | `boot.crashDump.enable` (misc/crashdump.nix), `systemd.coredump` | CDDL | S (done in part) | dump zvol sizing (scripts/test-dump-size.sh) |

## Security

| Feature | illumos source | NixOS counterpart | Licence | Size | Depends on |
|---|---|---|---|---|---|
| **RBAC and privileges for SMF services** (`method_context` with `privileges=`, `user=`, `limit_privileges`) | pin: SMF, `lib/libsecdb`, `cmd/ptools/ppriv` | `systemd.services.<n>.serviceConfig` (`DynamicUser`, `CapabilityBoundingSet`, `NoNewPrivileges`, `ProtectSystem`) | CDDL | M | the `smf.services.*` module (T1.11) gains a hardening attr set; a per-service audit of what each needs |
| **Trusted Extensions** (labeled zones, MAC) | pin: `lib/brand/labeled`, `cmd/tsol` | none (`security.apparmor` and SELinux are the nearest) | CDDL | L | zones module; label_encodings; little demand. Low priority |
| **Secure Boot** | none: the illumos loader has EFI headers but no shim/signing chain in the pin (no shim or SBAT files) | `boot.loader.limine.secureBoot`, lanzaboote (community, GPL-3.0) | — | L | a signed loader, key management, signed kernel and modules |
| **Audit** | pin: `cmd/auditd` | `security.auditd`, `security.audit` | CDDL | S | audit classes from Nix |

## Desktop and laptop

| Feature | illumos source | NixOS counterpart | Licence | Size | Depends on |
|---|---|---|---|---|---|
| **Suspend/resume** (S3; S0ix) | pin: `uts/common/cpr`, `uts/i86pc/cpr` (S3 only, and old); `cmd/power`. On the public roadmap as T7.5 ("not started") | `powerManagement.enable`, `services.logind` lid actions | CDDL | L | per-driver quiesce/resume for i915/amdgpu (src/drm-port), iwx, nvme, xhci; S0ix needs new ACPI LPI support |
| **Backlight** | none in the pin (no backlight driver); the i915 port (src/drm-port) owns the panel | `hardware.acpilight`, `brightnessctl` | — | M | drm-port backlight property, a COSMIC-facing D-Bus shim like solnix-power |
| **Fingerprint** | none | `services.fprintd` | LGPL-2.1 (fprintd/libfprint) | M | USB generic access (ugen) for libfprint; PAM module |
| **Webcam** | pin: `uts/common/io/usb/clients/video` (usbvc, UVC) | `hardware.ipu6` (Intel IPU6 laptops) | CDDL | M | V4L2 compatibility layer for PipeWire/apps; the X1 Gen 5 camera may be IPU6 (not UVC): **unverified** |
| **Bluetooth** | none in the pin; solnix work in progress (src/ports/bluetooth, docs/design-bluetooth.md; roadmap T7.3) | `hardware.bluetooth` | — | L | AX211 firmware load (done per T7.3), HCI transport, a BlueZ-compatible D-Bus API |
| **PipeWire audio** | pin: `audio_oss.c` (OSS-compatible API); FreeBSD port `audio/pipewire-spa-oss` = shkhln/pw-oss | `services.pipewire` | MIT | M | pw-oss ported from FreeBSD OSS to illumos OSS |
| **NVIDIA hybrid (PRIME offload)** | src/drm-port/nvidia-drm, nvidia-oss | `hardware.nvidia.prime.offload` | NVIDIA OSS kernel modules: MIT/GPL-2.0 dual | L | T6.2 (NVIDIA runtime, in progress); the i915 side (done) |

## Developer and PostgreSQL

| Feature | illumos source | NixOS counterpart | Licence | Size | Depends on |
|---|---|---|---|---|---|
| **PostgreSQL built with DTrace** | `--enable-dtrace` in PostgreSQL's configure; pin `dtrace -G` | `services.postgresql.package` override | PostgreSQL licence | S | the DTrace USDT row |
| **pgfarm on zones** (one PostgreSQL per zone with resource caps, ZFS clone per branch) | zones + ZFS; solnix has `modules/config/pgfarm.nix` | `services.postgresql`, `containers.<name>` | — | M | native zones module |
| **bhyve-based CI VMs (falcon)** | oxidecomputer/falcon (MPL-2.0) | `nixosTests` (QEMU) | MPL-2.0 | M | propolis |

## Distribution

| Feature | illumos source | NixOS counterpart | Licence | Size | Depends on |
|---|---|---|---|---|---|
| **Automatic upgrades** | solnix-rebuild + boot environments (beadm) | `system.autoUpgrade` (`flake`, `dates`, `allowReboot`) | — | S | a timer (SMF periodic or cron) and a rule for when to reboot into the new BE |
| **Upstream tracking** | `scripts/upstream-watch.sh` (this change) | none (nixpkgs uses r-ryantm) | — | S (done) | a weekly cron on a build host |
| **Graphical install image** | roadmap T7.2 ("not started") | `installer/cd-dvd/installation-cd-graphical-*.nix` | — | M | COSMIC session (T7.1 done) |

## Next 5

1. **Native zones as a declarative module, with VNICs, etherstubs and flows (Crossbow) in solnix-netd.**
   The maintainer keeps asking for zones and Crossbow. LX, docker, bhyve-branded zones, pgfarm and
   build sandboxing all need it first. The code is all in the pin, and the builder-zone brand
   already shows how to do it. Size M.
2. **TUN/TAP (OmniOS tuntap) plus a kernel-mode Tailscale.** It fixes a gap the maintainer hits
   daily: on solnix, programs can't reach the tailnet without the userspace proxy. It also unlocks
   WireGuard and OpenVPN. The driver is packaged and maintained by OmniOS. Size S-M. Two things to
   check first: the GPL-2.0 module needs its own package, and Tailscale has no illumos TUN code
   upstream. OmniOS ships it from Nahum Shalman's fork (`nshalman/tailscale`, one rebased
   "illumos/solaris support" commit on v1.104.4), so solnix would package that fork or wait for it
   to land upstream.
3. **LX-branded zones, ported from illumos-omnios.** "Run Linux binaries unchanged" is marked
   MUST-HAVE on docs/roadmap.md, and docker builds on it. Port from OmniOS rather than SmartOS:
   OmniOS carries LX without vnd or the Joyent brands, on a gate 4913 commits from master instead of
   6594. Size L. Start right after #1.
4. **bhyve VMs + viona + ppt as `virtualisation.bhyve`, then the libvirt bhyve driver.** The
   maintainer's nix-config uses libvirt and qemu. bhyve is in the pin; libvirt needs a port, because
   its driver builds only on FreeBSD. ppt is also the way to give a guest the GTX/RTX dGPU until the
   NVIDIA hybrid row (T6.2) is done. propolis follows as the microVM layer. Size M.
5. **RBAC/privileges hardening for SMF services in `smf.services.*`.** This is the systemd-hardening
   analog NixOS modules lean on (`serviceConfig.*`). It's cheap (S-M), it makes every later service
   module safer, and it's the illumos-native part of closing the `sandbox = false` gap until
   per-build zones exist.

Left out of the five, and why: COSMIC laptop work (suspend, backlight, Bluetooth) is already on
the public roadmap as T7.3 and T7.5, so it doesn't need adding. Per-build zone sandboxing is L and
needs #1 first. OpenZFS feature parity is upstream illumos work.
