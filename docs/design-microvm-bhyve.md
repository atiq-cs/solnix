# solnix microVM story: Firecracker on illumos, and the bhyve-native alternative

Status: design note (post-stable). Written 2026-07-30. No code yet; captures the
honest answer to "does/could Firecracker run on illumos, and what would it take."

## TL;DR

- **Firecracker does not run on illumos today** and a straight port is high-cost /
  low-value. Firecracker is a Rust VMM welded to **Linux KVM** (`/dev/kvm` ioctls)
  plus Linux-only plumbing (epoll, eventfd/irqfd/ioeventfd, memfd, vsock,
  cgroups + seccomp-BPF jailer, Linux virtio conventions).
- **illumos already has the capability Firecracker delivers** via **bhyve** (modern,
  actively maintained: `system/bhyve`, `system/library/bhyve` = libvmmapi, `viona`
  fast net, virtio blk/net/scsi/9p, UEFI-EDK2 firmware) and **bhyve-branded zones**
  (`system/zones/brand/bhyve`) for isolation. An aging Joyent **KVM** port also
  exists (`driver/i86pc/kvm`, Intel-VT only, paired with `system/qemu/kvm`) but is
  the wrong horse to bet on.
- **Recommended path:** build a **Firecracker-*equivalent* microVM control plane on
  bhyve** (REST/API daemon over libvmmapi, stripped device model, PVH/direct-kernel
  fast boot, bhyve-zone jailing). Weeks-to-few-months, layered on components solnix
  already packages. This lands the *use case* (fast, minimal, API-driven, densely
  packed VMs) without porting Firecracker itself.

## Why a literal Firecracker port is the wrong move (Option A)

Firecracker assumes, pervasively:
- **Linux KVM ioctl semantics** — `KVM_CREATE_VM/VCPU`, `KVM_RUN`, `KVM_SET_USER_MEMORY_REGION`,
  `KVM_IRQFD`, `KVM_IOEVENTFD`, `KVM_SET_TSS_ADDR`, MSR/CPUID plumbing. illumos KVM
  (`driver/i86pc/kvm`) implements a *subset* and diverges in details; the modern
  illumos hypervisor is **bhyve/vmm**, not KVM.
- **Linux event/IPC**: `epoll` (illumos = event ports), `eventfd`/`irqfd`/`ioeventfd`
  (no direct analog — bhyve wires interrupts/MMIO through vmm), `memfd` guest RAM.
- **Jailer**: cgroups + namespaces + **seccomp-BPF** (illumos = zones + privileges(5)
  + `pfexec`; there is no seccomp-BPF). Firecracker's whole isolation model would be
  rewritten.
- **vsock**: Linux `AF_VSOCK`; bhyve exposes virtio-vsock differently.

Net: porting Firecracker to illumos KVM = reimplement a Linux-personality shim around
an aging, Intel-only driver Joyent themselves abandoned in favor of bhyve. Multi-
person-year, strategically backwards. **Do not do this.**

## The bhyve-native microVM control plane (Option B — recommended)

bhyve already provides the hard parts:
- **CPU virt**: VT-x/AMD-V, EPT/NPT (both Intel + AMD — unlike the KVM port).
- **Device model**: virtio-net (**viona**, in-kernel fast path), virtio-blk,
  virtio-scsi, virtio-9p, lpc/uart serial console, a small PCI root — i.e. *exactly*
  Firecracker's minimal device set already exists.
- **libvmmapi** (`system/library/bhyve`): the same VM-management API bhyve's own
  `bhyve(8)` uses — create VM, map memory, set registers, run vCPUs, wire devices.
- **UEFI-EDK2 firmware** (`system/bhyve/firmware`) for full HVM, OR a PVH/direct
  kernel-load path to skip firmware for fast boot.

What Firecracker adds *on top* — and what we'd build:
1. **A thin control daemon** (Rust or C) driving libvmmapi: a REST/JSON API
   (`PUT /machine-config`, `PUT /boot-source`, `PUT /drives/*`, `PUT /network-interfaces/*`,
   `PUT /actions {InstanceStart}`) mirroring Firecracker's surface so existing tooling/
   muscle-memory transfers.
2. **A stripped device model**: serial console + virtio-net(viona) + virtio-blk only,
   no ACPI/PCI enumeration beyond the minimum, MMIO virtio where possible → small
   attack surface + fast boot.
3. **Fast boot**: PVH / direct-kernel-boot (load the guest kernel + initramfs
   directly, skip UEFI) to approach Firecracker's sub-125ms class. bhyve already
   supports direct Linux kernel boot; the work is trimming the device probe path.
4. **Jailing via bhyve-branded zones** (`system/zones/brand/bhyve`): each microVM in
   its own zone = stronger isolation than cgroups+seccomp (separate process table,
   FS, network stack), with `privileges(5)` least-privilege. This *replaces*
   Firecracker's jailer with a better-native mechanism.
5. **Metadata / vsock**: mdata (`system/virtualization/mdata-client`, already packaged,
   Triton lineage) or a virtio-vsock guest channel for the MMDS-equivalent.

Effort: **weeks to a few months** for a usable v1, because every heavy component
(hypervisor, device model, isolation, firmware, virtio) is already in-tree. The new
code is the API daemon + fast-boot trimming + zone integration.

## Covering the use case today (Option C — free, now)

For "spin up throwaway Linux microVMs" without any new VMM:
- **bhyve HVM** already boots Linux/BSD/Windows guests.
- **LX-branded zones** (Linux-syscall emulation, in the post-stable backlog) give
  container-density Linux workloads with no VM overhead.
Between bhyve HVM and LX zones, illumos already spans Firecracker's workload space.

## solnix plan

- **Now / free (post-stable parity):** package + qualify **bhyve**, **bhyve-branded
  zones**, **viona**, **virtio** (blk/net/scsi/9p), **bhyve UEFI firmware**,
  **mdata-client**. (Already on the `docs/post-stable-backlog.md` illumos-feature list.)
  Deliverable: real hardware VMs on solnix day one.
- **Post-stable, demand-driven:** build the **bhyve microVM control plane** (Option B)
  — a Firecracker-equivalent REST daemon over libvmmapi, PVH fast-boot, bhyve-zone
  jailing, virtio-only device model. This is the honest way to "have Firecracker" on
  solnix and is a genuine differentiator (AMD-V + zones isolation, not Intel-only KVM).
- **Do not** port Firecracker onto illumos KVM (Option A).

## References (from solnix package registry)

- `system/bhyve`, `system/bhyve/firmware`, `system/bhyve/tests`, `system/library/bhyve`
- `system/zones/brand/bhyve`
- `driver/network/vioif` (VirtIO net), `driver/storage/{vioblk,vioscsi,vio9p}`,
  `driver/misc/virtio` (core), `driver/crypto/viorand`
- `driver/i86pc/kvm` (legacy Joyent KVM, Intel-VT-only) + `system/qemu/kvm`
- `system/virtualization/mdata-client` (Triton guest metadata)
- LX-branded + bhyve-branded zones: `docs/post-stable-backlog.md`
