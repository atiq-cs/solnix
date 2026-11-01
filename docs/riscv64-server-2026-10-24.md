# The riscv64 uts kernel as a server on qemu virt: 64 harts, 64 GiB, an IPv4 stack (rvsrv, 2026-10-24)

The goal was to turn the uts kernel (`src/riscv/uts`, after rvsh 3a646b8) from a desktop-scale toy into a headless
server on `qemu-system-riscv64 -machine virt`: many harts, lots of RAM, and a real network. Everything was built and
booted on lixr under qemu 10.2.1 (`~/scratch/rvpkg/bin/qemu-system-riscv64`). floki was used for editing and copying
only. Nothing on lixr was installed, rebooted or reflashed. The ping test ran inside an unprivileged `unshare -rn`
namespace, so it touched no host network state.

Kernel diff vs floki HEAD 6bf1cc4: `/scratch/solnix/rvsrv/uts.diff`. The vendored lwIP is not in the diff: all 119
files are byte-identical to upstream 2.2.1 (`lwip-vendor.check`). The changed and new files are under `files/`, and
the harness is under `harness/`. Bank: `~/solnix-bank/riscv/2026-10-24-rvsrv/`.

## Summary

| Step | Before (HEAD) | After (`unix-final`) | Control | Rate |
|---|---|---|---|---|
| 1 baseline | gates 8/8, check-all green; max -smp 16, max -m 2G (1 GiB managed) | - | - | 1 boot per point (rvsh has 4/4 on identical sources) |
| 2 SMP | -smp 17: only 16 online; -smp 32/64: PANIC `boot hart N >= MAXCPU 16` whenever OpenSBI picks hart >= 16 (2/4 at -smp 64) | -smp 32 and 64: all harts online, A/B + SMP selftest OK, 0 dispatcher flakes | -smp 1: 4/4 | 6/6 at -smp 64 and 32 (s2), 4/4 again on the final kernel |
| 3 RAM | -m 3G..16G: load page fault in `fdt_get_memory`; -m 2G manages 1012 of 2048 MB | -m 16G and 64G boot; free count = DTB RAM minus each listed reservation, exactly (bound 0 pages); pages above 4 GiB read back | -m 1G unchanged except −183 pages (the step-2 stack pool and the DTB reservation); sabotage build detects aliased RAM | 4/4 at 64G, 16G and 1G; 4/4 at -smp 64 -m 64G |
| 4 network (see OPEN below) | no IP stack; vionet TX frames malformed (wrong header size), RX never answered | lwIP 2.2.1: DHCP lease, ping, UDP echo, TCP echo 100 sequential + 10 concurrent byte-exact, from the host | no NIC: `socket()` ok, `connect`/`sendto` = −101 ENETUNREACH; ping to an unused address 0/3 | 4/4 for each test |
| 5 login | - | plan only (`docs/riscv64-sshd-plan.md`) | - | - |

Gates TP SOCK POLL PORT FP FB MINIWL NEWLIBTEST passed 8/8 on every boot of every kernel. rvsh's check-all (8 suites,
91 checks) was all green after every step: base, s2, s3, s4 and final.

**Scale proof** (`logs/net-f-big.log`, `unix-final`), one boot at -smp 64 -m 64G with the network up:
* 64 online;
* 16773991 frames (65523 MB) managed, free 16413542 EXACT, high-RAM 62 pages OK;
* DHCP lease;
* from the host, TCP 100 sequential + 10 concurrent byte-exact, guest `served 110 connections, 0 bad`.

Maximum reached: **-smp 64** (qemu virt's limit) and **-m 64G** (a `memory-backend-ram,reserve=off` backend, since
lixr has 31 GB and no swap; the guest touches only a few pages). One combined boot at -smp 64 -m 64G ran with the
network up and served the full TCP test. On 8 TCG harts: about 14 s to login at -smp 64 -m 128M and about 50 s at
-smp 64 -m 64G. Most of the 64G time is page_init walking 16.7 M page_t entries.

## 1. Baseline (HEAD 6bf1cc4)

* Kernel lixr `~/scratch/rvsrv/unix-base`. Gates 8/8 at -smp 4 -m 128M. check-all x1 green: libc 5, zlib 3,
  sbase 31, dash 16, ncurses 2, less 3, vfd 3, fs 28.
* -smp 1, 8 and 16: 8/8, all harts online.
* -smp 17: 8/8, but 16 online. `start_secondaries` loops `h < MAXCPU`, so hart 16 is never started.
* -smp 32: OpenSBI elected boot hart 22. `[PANIC] boot hart 22 >= MAXCPU 16 in start_secondaries`, 0/8.
* -smp 64: whether it boots depends on the boot-hart lottery. 16 online when it does.
* -m 512M, 1G and 2G: 8/8. At 2G, `clamping managed RAM to the boot identity gigapage end 0xc0000000`: 1012 MB
  managed out of 2048.
* -m 3G, 4G, 8G and 16G: `load page fault` at `sepc=fdt_get_memory`, with `stval = RAM end − 2 MiB + 1`. qemu puts
  the DTB 2 MiB below the top of RAM. The boot map has identity gigapages only at 0x0, the kernel's 0x80000000 and
  the K1 window at 0xc0000000. At 2G the DTB happens to land in the K1 window (0xffe00000), which is the only reason
  2G works.

The brief describes "the physical allocator manages only up to the end of the boot identity gigapage". That is
correct, and past 2 GiB the failure is earlier: the kernel cannot even read its DTB.

## 2. SMP: MAXCPU 64

**The change.**
* `NCPU 64` (with `MAXCPU NCPU`) in `uts/sys/machtypes.h` and `uts/riscv64/sys/machtypes.h`. This is now the one
  definition. It was 8 there, while main.c and proc.c each had a private `#define MAXCPU 16`.
* main.c and proc.c `#include <sys/machtypes.h>`. `-Iriscv64` was added to build-unix.sh and to the k1, k3 and
  scanout scripts.
* `secondary_stacks` moved from a hand-counted `.skip 16384 * 15` in locore.S to a C array in main.c,
  `char secondary_stacks[(MAXCPU - 1) * SECONDARY_STACK_SIZE]`, so the pool cannot drift from the hart limit.
  `nm` shows 0xfc000 bytes, which is 63 stacks. curthread and idlethread are 0x200 bytes each, which is 64 slots.
* proc.c `_Static_assert(MAXCPU <= 64)`, because `idle_harts` and the SBI IPI hart_mask are one `unsigned long`.
* `user/porttest.c`: the pset_info upper bound goes from 16 to 64 (a fifth copy of MAXCPU, in userland). Only
  porttest was rebuilt (`user/rebuild-porttest.sh`, native gcc 15.2), and it was spliced into `user_elfs.h` and
  `rootfs.img`. The other embedded ELFs are unchanged.

**Result** (`unix-s2`, `logs/rates-s2.out`):
* -smp 64: 6/6 boots 8/8, `cpus online: 64 (1 boot + 63 secondary)`, porttest reports 64, `[disp] thread A/B
  context-switch OK`, `[smp] OK: thread ran on hart N`, 0 `context-switch FAILED`, 0 corrupt-scause parks. The boot
  harts were 23, 15, 9, 5, 8 and 40: the lottery is fully exercised.
* -smp 32: 6/6.
* -smp 4: 4/4.

**Control.** -smp 1 passed 4/4. As a negative control, unix-base at -smp 64 over 4 boots gave 2/4 with only 16
online and 2/4 with the MAXCPU panic.

The A/B race in `docs/riscv64-ab-selftest-race.md` is already fixed at HEAD: `thread_ab_selftest` runs before
`smp_dispatch_open`. It held at 64 harts in every boot, 0 failures across 18 boots at -smp 64.

## 3. RAM: all of DRAM managed

**The change.**
* main.c reads `/memory` **before** paging. In Bare mode the DTB is reachable wherever it is.
* `hat_boot_init` identity-maps every DRAM gigapage R/W (no X, no U) in the root slots that do not already hold a
  leaf, except the two user slots (1 = 0x40000000, newlib packages; 3 = 0xC0000000, uts user text, fb, mmap and
  stack).
* `hat_as_newroot` copies every non-user slot, so `(T *)pa` dereferences keep working on a process satp. The user
  walkers (`walk_leaves`, `cow_share`, `freeuser`) visit only user slots.
* New `hat_phys_identity`, `hat_dram_end`, `hat_user_range_ok` and `hat_peek_highva`.
* `as_map` (ELF), `as_grow` (brk) and `as_anon_map` (mmap) refuse a range outside one user slot. With GiBs of RAM,
  a large brk would otherwise walk into the kernel slot and hit `hat_as_map`'s panic, because page_alloc no longer
  fails first.
* fdt.c: new `fdt_get_reserved`, covering the blob, the rsvmap and `/reserved-memory` regs.
* vm_page.c `page_init`:
  * frees only pages that are identity-mapped in every AS and not firmware-reserved;
  * prints the accounting and checks it two independent ways (arithmetic and a free-list walk);
  * runs a high-RAM self-test: one page per GiB above 4 GiB, 512 PA-unique words written through the identity map,
    read back through it and through a fresh KERNELBASE 4 KiB mapping (an independent page-table walk).
* startup.c: the boot-gigapage clamp is gone.

**Shortcuts** (marked `shortcut:` in the code):
* qemu PA 0xC0000000..0xFFFFFFFF falls in user slot 3, so that 1 GiB is a hole.
* No DRAM above 256 GiB PA.
* The page_t array must fit the identity run at the kernel, about 170 GiB of RAM on qemu.
* The lifts are a non-identity physmap (segkpm), moving the user regions, and a memseg page_t.

**Result** (`unix-s3`, `logs/rates-s3.out`), 4/4 at each size, identical every boot:

| -m | DTB pages | free | below watermark | page_t | slot-3 hole | fw-reserved | high-RAM test |
|---|---|---|---|---|---|---|---|
| 1G | 262144 | 257571 | 3050 | 1519 | 0 | 4 | (none above 4 GiB) |
| 16G | 4194304 | 3904547 | 3050 | 24559 | 262144 | 4 | 14 pages OK |
| 64G | 16777216 | 16413731 | 3050 | 98287 | 262144 | 4 | 62 pages OK |

Each row prints `free list: N (list walk N, expected N; EXACT, bound 0 pages)`.
* "below watermark" is OpenSBI's 2 MiB, the kernel image, its BSS (now with 1 MiB of stacks) and the boot page
  tables.
* At -smp 64 -m 64G the free count is 16413716: the DTB is 15 pages larger with 64 cpu nodes, and it is exact on all
  4 boots.
* 64G: 16774166 frames (65524 MB) managed. Before, it load-faulted.

**Control.** At -m 1G, the base kernel has physmem 259274 and free 257754; s3 has 259094 and 257571. The −180 pages
are the 1 MiB secondary_stacks of step 2 (BSS 0x80b34080 → 0x80be8080). The remaining −3 are the 4 DTB pages now
reserved, offset by one fewer page_t page.

**Negative control.** `EXTRA_CFLAGS=-DRVSRV_SABOTAGE_ALIAS` (a new build-unix.sh knob) maps GiB 5..n onto GiB 4.
At -m 16G the self-test reports `readback MISMATCH at PA 0x1400ba000 ... FAIL (12 bad)`. The test can fail, and it
catches aliased RAM.

## 4. Network: lwIP 2.2.1 over vionet

**Why lwIP.** It is BSD-3-Clause, built to run with no OS (NO_SYS=1 raw API), and has ARP, IPv4 with fragmentation,
ICMP, UDP, DHCP and RFC 793 TCP with retransmit, MSS, window management and out-of-order queueing. Writing a TCP
from scratch would be thousands of lines of corner cases; this is a port. lwIP is vendored unmodified under
`uts/lwip/` (core, ipv4, netif/ethernet and include, 119 files; source download.savannah.nongnu.org
lwip-2.2.1.zip, sha256 7b622662…6878). Our files are `lwip/port/` (lwipopts.h, arch/cc.h, compat headers, libk.c)
and `inet.c`.

**Pre-existing bug found and fixed (mechanism observed).** `VIONET_HDR_LEN` was 10, the *legacy* virtio-net header.
virtio.c always negotiates VIRTIO_F_VERSION_1, and with it the header is 12 bytes (spec 1.2 §5.1.6). The evidence is
a qemu `filter-dump` pcap of unix-base: the attach ARP leaves the guest as 58 bytes with dst `ff:ff:ff:ff:52:54`,
because qemu ate 2 frame bytes as header. Every TX frame since R-P6 was malformed, and that is why "slirp may not
reply". With 12, the attach ARP is answered (`[vionet] RX frame received`), and the boot is 6 s faster, because the
RX poll no longer runs to its timeout.

**The change.**
* `inet.c`:
  * one spinlock (netlock, SIE off while held) around every lwIP call from any hart;
  * a `netd` kernel thread that polls vionet RX into lwIP and runs `sys_check_timeouts`;
  * DHCP at boot, waiting up to 3 s for the lease (`[inet] DHCP lease: 10.0.2.15 mask 255.255.255.0 gw 10.0.2.2`).
* AF_INET (2) sockets use the existing socket syscall path. `sys_socket` routes domain 2 to `inet_socket`. The
  socket index lives in `fd_sock` with `INET_SI_FLAG`, so uproc.c's fork, dup, close, read, write and poll dispatch
  on the flag, and every fd path rvsh fixed is reused. bind, listen, accept (with the peer address), connect,
  read/write, sendto (206), getsockname (204) and getpeername (205) are wired.
* `recvfrom` is **520**, not Linux's 207: in this kernel 207 is `SYS_pset`.
* vionet.c gains a 7-buffer RX ring and `vionet_rx_poll`/`vionet_tx`.
* A new connection gets its socket slot in the accept callback, so data or a FIN that arrives before `accept()` is
  buffered, not lost.
* `uts/lwip-objs.sh` is sourced by all four build scripts.

**Shortcut** (marked): a blocked socket call waits by `thread_yield`, not `sleep_on`. proc.c's `sleep_on` queues the
thread only after the caller has dropped its lock, so a `wakeup` from netd on another hart in that window would be
lost and the socket would hang forever. A cv_wait-style sleep that drops a held lock atomically fixes it.

**Result** (`unix-s4` 4/4, `logs/rates-s4.out`, and `unix-final` 4/4, `logs/rates-final.out`), all from the HOST:
* DHCP: slirp hands out 10.0.2.15 on every boot, including -smp 64.
* UDP echo through `hostfwd=udp:127.0.0.1:5556-:7`: 50/50 datagrams of 1–1400 B byte-exact, 4/4.
* TCP echo through `hostfwd=tcp:127.0.0.1:5555-:7`, guest `inettest tcpecho` (one forked child per accepted
  connection): 100 sequential connections, then 10 concurrent ones (all opened before any data is sent). Each sends
  100 B–20 KB of distinct data, half-closes, and must read it back byte-exact followed by EOF. 100/100 + 10/10,
  guest `served 110 connections, 0 bad`, 4/4.
* The first run gave 9/10 concurrent: `INET_NACCEPT 8` dropped the 9th and 10th of 10 simultaneous SYNs. Raised to
  16, and NINET to 40.
* Ping: qemu's user-net cannot forward ICMP from host to guest (hostfwd is tcp and udp only), so ping as written in
  the brief is impossible. It ran instead over `-netdev tap` inside `unshare -rn` (unprivileged, no root): tap0
  10.9.0.1/24, dnsmasq as the DHCP server, guest leased 10.9.0.58 (DHCPOFFER/DHCPACK in `logs/dnsmasq-*.log`).
  `ping -c 10` gave 10/10, 4/4. Control: ping of an unused 10.9.0.99 gave 0/3.

**Control.** With no NIC (no `-device virtio-net-device`): `[inet] lwIP 2.2.1 up, NO NIC`, `socket(tcp)=3`,
`socket(udp)=4`, `connect=-101`, `sendto=-101` (ENETUNREACH), `close=0,0`. 4/4.

## 5. Remote login (plan only)

No telnet was shipped. `docs/riscv64-sshd-plan.md` lists what dropbear (static, MIT, own crypto) needs, each item checked against
this tree: ptys, termios, setsid/ctty (absent), a real entropy source (absent; virtio-rng plus `getrandom` is a hard
requirement), public-key-only auth, and a host key on `/data`.

## Findings beyond the brief

1. **Security, pre-existing, not fixed here.** Syscalls dereference user pointers directly (SUM=1), and
   `copyin`/`copyout` (copy.S) check no address range, so a U-mode pointer into a kernel slot is read or written by
   the kernel. Step 3 widens the reachable set from the kernel gigapage to all DRAM. Fix before any network daemon:
   range-check against `hat_user_range_ok` in copy.S and in the direct-dereference paths.
2. vionet header length (fixed, §4).
3. `build-scanout.sh` fails to link at HEAD (`undefined k3ufs_present`, from 251854c). It fails the same way with
   this change. `build-k3-payload.sh` and `build-k1-payload.sh` build with it (unix-k3.Image 696928 B).

## OPEN: a regression that step 4 exposes (not resolved)

check-all on `unix-final` failed zlib 0/3 once: `/bin/example` takes a U-mode store page fault in newlib `_free_r+0x74`
(`sd t1,24(a6)`, with a6 a garbage free-list pointer), i.e. its user heap is corrupted. Measured by rate, zlib suite,
6 interleaved boots each (`logs/zrate*.out`):

| kernel | zlib traps |
|---|---|
| unix-s3 (no network) | 0/6 |
| unix-s4 / unix-final (lwIP + netd thread) | 2/6, 3/6 |
| unix-nonetd (lwIP + DHCP, no netd thread) | 0/6 |
| unix-cpchk (unix-final + a curproc-mismatch check at every syscall) | 3/6, **0 mismatches** |

So the trigger is the always-runnable netd thread, not lwIP's code. I tested the hypothesis "one global `curproc` is
shared by all harts and a syscall acts on the wrong process", and **it is refuted**: the detector could fire and never
did. The remaining unverified hypothesis: user state is corrupted across a timer preemption. netd keeps the runq
non-empty, so `thread_preempt` fires on every tick. If so, the bug predates this track, and any two CPU-bound processes
on one hart should hit it. Next test: `unix-s3` at -smp 1, a CPU hog plus zlib `example`.

Workaround kernel `unix-final2`: no netd by default (`-DRVSRV_NETD` restores it). A blocked socket caller polls lwIP
itself, and every idle hart polls after each wfi. Result: zlib 6/6 clean, but over 4 TCP runs the 10 concurrent
connections gave **7, 10, 10 and 8 of 10** (60 s host timeouts). 100/100 sequential was fine every run. The suspected cause, unverified: 7 RX buffers
overflow on a 10-SYN burst while nobody polls, plus slirp's SYN backoff. **Neither kernel is fully green.**
`unix-final` passes every network check 4/4 and fails zlib intermittently; `unix-final2` is the reverse.

## What is left

* The preemption heap-corruption above, then restore netd (or an RX-IRQ-driven netd) and re-run the 10-concurrent rate.
* Syscall user-pointer validation (finding 1).
* sleep_on with an atomic lock drop, so blocked sockets cost no cpu.
* A physmap for the slot-3 hole and RAM above 256 GiB.
* Interrupt-driven vionet (PLIC IRQ 5) instead of netd polling.
* setsockopt is a no-op; there is no O_NONBLOCK.
* Step 5 per `docs/riscv64-sshd-plan.md`.
