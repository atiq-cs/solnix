# RISC-V (riscv64) port — STATUS

**Phase reached: R-P25** (the R-P24 booting illumos-riscv64 kernel GROWN with
the SYSCALL/EXEC path so the FIRST riscv64-solaris userland PROCESS runs, all
boot-verified under `qemu-system-riscv64 -machine virt`: the kernel builds a
fresh **user address space** [a per-process Sv39 root that shares the kernel
high half -- identity kernel-text gigapage + the direct-map -- and carries
private 4 KiB leaf tables for the user segments, `hat_user_new`/`hat_user_map`],
**execs** the R-P22 static hello ELF embedded in the kernel image [`exec_elf.c`
walks the PT_LOAD program headers, maps+copies each segment into freshly
page-aligned frames, and builds the psABI initial stack argc/argv/envp/auxv],
enters **U-mode** [`rv_user_enter`: `sret` with `sstatus.SPP=0`+SPIE+SUM,
`sepc`=user `_start`, the user `sp`, the user `satp`], and services the
process's OWN **write(2)/exit(2)** syscalls through the R-P22/23 trap path [a
U-mode `ecall` traps to `_u_trap_entry`, which swaps to the lwp kernel stack via
`sscratch`, then `rv_trap_dispatch` -> `rv_syscall` reads `a7`=nr/`a0..a5`=args
and returns in `a0`; `SYS_write=4` routes the buffer to the SBI console,
`SYS_exit=1` `rv_klongjmp`s control back to the kernel]. Boot proof: the process
prints its OWN line `hello from riscv64-solaris userland process` and exits
`exit(0)` [`wrote 44 bytes via its own write(2)`], then the kernel continues --
this is the first riscv64-solaris userland process, vs R-P22's bare-metal
payload / R-P23's kernel-only) -- DONE (all three sub-tasks + the R-P24
regression, re-runnable proof `rp25/rp25-milestone-check.sh`).

R-P24 (the R-P23 booting illumos-riscv64 kernel GROWN
toward genunix, four subsystems each boot-verified under `qemu-system-riscv64
-machine virt`: **Sv39 virtual memory** -- `hat_boot_init` builds the 3-level
Sv39 boot page table [identity map keeps the kernel live across mmu-enable +
a high direct-map kpm window], writes `satp` [MODE=8] + `sfence.vma`, and the
kernel KEEPS EXECUTING in virtual address space [`paging enabled (Sv39):
satp=0x8000000000080224`, direct-map probe reads the kernel's own `_start`
through the high VA]; a **periodic clock** -- the SBI timer [`sbi_set_timer` @
100 Hz] delivered as a Supervisor Timer Interrupt through the R-P23
`rv_trap_dispatch` -> `rv_interrupt` -> `rv_timer_intr`, ten ticks counted;
the **qemu-virt PLIC** -- init + enable UART0 [IRQ 10] + claim/complete an
external interrupt [source id 10 claimed + completed], reached through the
direct-map; and the **genunix on-ramp** -- a first-fit `kmem_alloc` over a
16 MiB boot heap + a `page_t` seed [`page_create`] + a single-thread
dispatcher `rv_swtch` into an idle loop on a fresh kmem stack with the clock
ticking) -- DONE (all four sub-tasks, re-runnable proof
`rp24/rp24-milestone-check.sh`).

R-P23 (the FIRST BOOTING illumos-riscv64 kernel -- an
illumos-MD kernel skeleton built with the NATIVE `riscv64-unknown-solaris2.11`
toolchain that boots under `qemu-system-riscv64 -machine virt` via OpenSBI and
prints a SunOS banner via SBI: `locore _start` -> set `stvec` -> `mlsetup`
(trap self-test: a deliberate S-mode breakpoint dispatched through the R-P22.3
`rv_trap_dispatch` + resumed via `sret`) -> `main()` banner -> known halt (SBI
shutdown); a REDUCED riscv64 `ld.so.1` runtime relocation engine that resolves
`R_RISCV_RELATIVE` + `R_RISCV_JUMP_SLOT` at runtime under qemu and calls
through the bound GOT slot; and a REAL native `ld` driver (`ldmin`) that links
a real EM_RISCV object THROUGH the sgs backend -- `ld_config_target(EM_RISCV)`
selection + `machrel.riscv.c` -- producing relocated `.text` byte-identical to
GNU ld, no GNU ld in the reloc path) -- DONE (all three sub-tasks, re-runnable
proof `rp23/rp23-milestone-check.sh`).

R-P22 (the sgs EM_RISCV backend SELECTED by a real gate-shaped
`ld_config_target()` -> `ld_targ_riscv` so the illumos native link path drives
the reloc pass through `machrel.riscv.c` not GNU ld; the FIRST EXECUTING
riscv64-solaris code -- a freestanding EM_RISCV hello that RUNS on
`qemu-system-riscv64 -machine virt` via OpenSBI and prints, plus a STATIC
illumos-ABI hello (crt + a minimal `write(2)`/`exit(2)` libc); and a larger
genassym-driven MD partial-link -- 6 units (locore/swtch/cpu/trap-dispatch/
clock/mmu) -> one EM_RISCV `unix_riscv64.o` that full-links with every reloc
resolved) -- DONE (all three sub-tasks, re-runnable proof
`rp22/rp22-milestone-check.sh`).
R-P21 (gate sgs `machrel.riscv.c` htab pairing + `libgcc_s.so.1` + first DYNAMIC
hello + genassym MD partial-link),
R-P20 (sgs %pcrel pairing + GOT/PLT alloc, csu crt + first hello ELF, larger uts
unit), R-P19 (riscv64-solaris toolchain finished + sgs MACH descriptor + first
EM_RISCV uts object), R-P18 (toolchain TARGET retarget + krtld/sgs reloc
coverage), R-P17 (cross toolchain + BSD psABI/ISA headers) and R-P1..R-P16
(kernel bring-up) are below / in `docs/design-riscv-port.md`.

---

## R-P24 — grow the booting kernel toward genunix (Sv39 paging + clock + PLIC + kmem/page/dispatcher on-ramp)

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils + `qemu-system-riscv64 -machine virt` with
OpenSBI v1.7. R-P24 extends the R-P23 native-toolchain booting kernel skeleton
(`rp24/kernel/`, a superset of `rp23/kernel/`) with four subsystems, each
boot-verified under qemu -- Sv39 paging, a periodic clock, the qemu-virt PLIC,
and a minimal genunix on-ramp (kmem/page/dispatcher). Proof:
`rp24/rp24-milestone-check.sh` (rebuild + reboot, all four green, re-runnable).

Boot flow now: `locore _start` -> `mlsetup` (trap self-test) -> `main`:
`hat_boot_init` (Sv39 ON) -> banner -> `startup_kmem`/`page_setup` -> `plic_init`
+ claim -> `clock_init` -> `dispatch_onramp` (swtch into the idle loop with the
clock ticking) -> known halt.

### R-P24.1 Sv39 virtual memory — DONE
- **The kernel turns on Sv39 paging and keeps executing in virtual address
  space.** `rp24/kernel/{mmu_riscv.h, hat_boot.c, mach_mmu.S}`:
  `hat_boot_init()` builds the first Sv39 page table (a single level-2 root,
  `boot_l2[512]`, page-aligned in BSS so its PA == link address pre-paging),
  IDENTITY-maps the low 4 GiB with 1 GiB gigapage leaves (V|R|W|X) so the PC/sp/
  gp stay valid the instant `satp` flips, ALSO installs a high direct-map
  (`KERNEL_DMAP_BASE = 0xffffffc000000000` + pa -> pa, gigapage leaves) as the
  kpm window, then `rv_set_satp(MAKE_SATP(root))` writes `satp` (MODE=8=Sv39,
  root PPN) + `sfence.vma`. Because the kernel is identity-mapped the next fetch
  after the `csrw satp` still resolves -> the kernel keeps running.
- **Boot proof** (`rp24/kernel/qemu-boot.log`): the line AFTER the satp write:
  ```
  [R-P24.1] enabling Sv39 paging (3-level, 39-bit VA)...
  paging enabled (Sv39): satp=0x8000000000080224 -- kernel now executing in virtual address space
    satp readback     : 0x8000000000080224
    direct-map probe  : 0x1040107310017073 (word @ dmap+0x80200000)
  ```
  `satp=0x8000_0000_0008_0224` = MODE 8 (Sv39) | root PPN 0x80224 (root PA
  0x80224000). The direct-map probe reads the kernel's own `_start`
  (`csrci sstatus,2` 0x10017073 ; `csrw sie,zero` 0x10401073) through
  `KERNEL_DMAP_BASE + 0x80200000` -- proving the high mapping translates, not
  just the identity one.
- **Scope (honest)**: gigapage identity + direct-map is the BOOT map (keeps the
  low addresses live across mmu-enable + gives a kpm window); it is not yet the
  per-segment kernel-text/data mapping with proper R^X permissions, and there
  are no 4 KiB leaf tables / `hat_memload` yet. R-P25 relocates kernel
  text/data into the high VA, drops the identity map, and adds leaf-level
  mapping.
- **CRIB**: `hat_boot_init` building a boot root + identity-mapping the kernel +
  installing a direct-map + `satp`+`sfence.vma` is this repo's R-P3.2 Sv39 boot
  map + R-P5 `hat_riscv.c hat_boot_init` + i86pc `hat_kbootmmu`/`hat_kern_setup`;
  the Sv39 PTE encoding (PPN[53:10]<<10 | V|R|W|X|A|D|G), the gigapage-leaf rule,
  the 3-level VA[38:12] split, and `satp` MODE=8 are the RISC-V privileged spec;
  the "keep the low identity map live across mmu-enable" trick is the i86pc/
  aarch64 boot-map idiom.

### R-P24.2 clock + timer interrupts — DONE
- **A periodic S-mode timer interrupt ticks through the R-P23 trap path.**
  `rp24/kernel/clock_riscv.c`: `clock_init()` arms the SBI timer
  (`sbi_set_timer(rdtime + period)`, 100 Hz over the 10 MHz qemu-virt timebase),
  unmasks `sie.STIE`, sets `sstatus.SIE`. Each Supervisor Timer Interrupt
  (scause = INT | 5) routes `stvec -> _trap_entry -> rv_trap_dispatch` (the
  R-P22/23 full-GPR trap frame) -> `rv_interrupt` (main.c, decodes scause) ->
  `rv_timer_intr` (counts a tick, re-arms; masks STIE on the last tick).
- **Boot proof**: ten ticks counted + printed by the idle loop:
  ```
    clock tick 1
    ...
    clock tick 10
  [dispatcher] idle loop counted 10 clock ticks; on-ramp proven
  ```
- **CRIB**: the "arm SBI set_timer, take STIP, re-arm for a periodic tick"
  cadence is the RISC-V SBI spec `sbi_set_timer` + the R-P22.3 `rv_clock_intr` +
  the R-P4.2 cyclic-clock contract; STIE/SIE unmask + the scause==5 timer decode
  are the RISC-V privileged spec; `rv_trap_dispatch` is R-P22.3/R-P23.

### R-P24.3 PLIC (external interrupt controller) — DONE
- **The qemu-virt PLIC is initialized and an external interrupt is
  claimed/completed.** `rp24/kernel/plic.c`: `plic_init()` sets UART0 (IRQ 10)
  priority > 0, enables it for the hart-0 S-mode context (ctx 1), drops the
  threshold to 0; `plic_provoke_uart()` sets the ns16550a THRE interrupt-enable
  so qemu asserts IRQ 10; `plic_claim()` reads the claim register (returns the
  pending source id) and `plic_complete()` writes it back (EOI). The PLIC is
  reached through the high direct-map (`KERNEL_DMAP_BASE + 0x0C000000`), proving
  the direct-map is usable for MMIO after paging.
- **Boot proof**:
  ```
  [R-P24.3] PLIC: init + claim an external interrupt (UART0 IRQ10)
    PLIC claim        : source id 10 -- claimed + completed (external interrupt handled)
  ```
  Source id 10 == UART0. `rv_interrupt` also handles scause==9 (S-external) by
  claim/complete, so a live external interrupt routes through the trap path too.
- **CRIB**: the PLIC register map (priority @ base+4*src, enable bitmap @
  base+0x2000+0x80*ctx, threshold/claim @ base+0x200000+0x1000*ctx) + the "set
  priority, enable for context, drop threshold, claim, complete" flow are the
  RISC-V PLIC spec + this repo's R-P4.3 PLIC contract; the qemu-virt base
  0x0C000000 + UART0=IRQ10 + S-mode context numbering are the qemu virt board.

### R-P24.4 toward the dispatcher / genunix — DONE (minimal on-ramp)
- **A boot heap + `kmem_alloc` + a `page_t` seed + a single-thread dispatcher
  `swtch` into an idle loop.** `rp24/kernel/{startup.c, mach_swtch.S}`:
  - `startup_kmem()` + `kmem_alloc()/kmem_free()`: a first-fit allocator over a
    16 MiB BSS boot heap (split + coalesce). Boot proof:
    `kmem heap: 16777192 bytes; kmem_alloc(4096)=0x80226018 kmem_alloc(256)=0x80227030`
    then `kmem_free ok; inuse now 0 bytes`.
  - `page_setup()`/`page_create()`: a flat `page_t` array (pfn + inuse) seeding
    the VM page layer over an 8 MiB managed window. Boot proof:
    `page_t layer: 2048 frames managed; page_create()=0x88000000`.
  - `dispatch_onramp()` + `rv_swtch` (mach_swtch.S, save/load callee-saved +
    ra/sp + satp, `sfence.vma`, `ret`): builds an idle `kthread_t` on a fresh
    16 KiB kmem stack, `swtch`es the boot CPU into `idle_loop` (which `wfi`s and
    counts clock ticks), then `swtch`es back. Boot proof:
    ```
    [dispatcher] built idle kthread (fresh 16K kmem stack); swtch -> idle
    [dispatcher] idle thread running on its own stack; entering idle loop with clock ticking
    ... clock tick 1..10 ...
    [dispatcher] swtched back to boot context; dispatcher round-trip complete
    ```
    A thread running on a kmem-allocated stack, entered by a real context
    switch, in the idle loop with the clock ticking -- the genunix on-ramp.
- **Scope (honest, per the anti-wedge directive)**: this is the REDUCED seam --
  a first-fit boot heap (not the slab `kmem_cache`/vmem), a flat `page_t` array
  (not the page hash + freelists), a two-context hand `swtch` (not the full disp
  queues / `thread_create`/`setrun`). It proves the on-ramp end to end; R-P25
  grows it into the real allocator + page layer + dispatcher.
- **CRIB**: the `startup()`/`startup_memlist`/`startup_kmem` decomposition +
  the heap-then-kmem-then-page-then-dispatcher order is illumos uts/common/os
  `startup.c` + i86pc `startup.c`; the first-fit kmem + `page_t` seed are the
  R-P5.1/R-P5.2 page/kmem contracts (reduced from slab/vmem to a bump-split
  heap); `rv_swtch` (save callee-saved + ra/sp + satp, sfence, ret) is the
  R-P5.4 / R-P21 `mach_swtch.S` switch body (RISC-V LP64 callee-saved s0..s11;
  NetBSD riscv `cpu_switch.S` idiom), trimmed of the lofault/genassym coupling
  for the minimal seam.

### `/root/riscv-port/rp24/` contents
`kernel/{locore.S, mach_trap.S, mach_clock.S, mach_mmu.S, mach_swtch.S,
mmu_riscv.h, clock_riscv.h, plic.h, assym.h, sbi.h, sbi.c, hat_boot.c,
clock_riscv.c, plic.c, startup.c, main.c, kernel.lds, build-kernel.sh, *.o,
unix.elf, qemu-boot.log}` (the grown kernel); `rp24-milestone-check.sh` (all
four sub-tasks, rebuild+reboot, re-runnable green). Repo copies under
`src/riscv/rp24/`.

### Next: R-P26
1. **fork(2)/exec(2)/wait(2)** -- a real process table + `lwp`/`proc` structs,
   copy the parent AS (or COW), a general `exec` that opens the ELF from a
   filesystem (vs the embedded `.incbin`) and hosts the R-P23.2 `ld.so.1`
   engine for the DYNAMIC hello (interp + aux vector already scaffolded here).
2. **More syscalls + errno ABI** -- `open/read/close/brk/mmap`, the SunOS
   error-return convention (the R-P22 libc returns `a0` verbatim today), the
   full `<sys/syscall.h>` table driving `rv_syscall`, and per-lwp trap state.
3. **Full HAT + real dispatcher** (carried from R-P24): relocate kernel
   text/data into the high VA + drop the identity map + `hat_memload`/`hat_unload`
   + R^X kernel permissions; vmem/`kmem_cache`; the page hash + freelists;
   `thread_create`/`setrun`/disp queues; SMP secondaries via SBI HSM.

---

## R-P25 -- the kernel syscall/exec path so a userland PROCESS runs (U-mode entry + write/exit syscalls + a minimal static-ELF exec)

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` = `riscv64-unknown-solaris2.11`) + the
R-P17 `riscv64-unknown-elf` binutils + `qemu-system-riscv64 -machine virt` with
OpenSBI v1.7. R-P25 extends the R-P24 native-toolchain booting kernel
(`rp25/kernel/`, a superset of `rp24/kernel/`) with the syscall/exec path and
runs the R-P22 static hello AS A PROCESS. Proof: `rp25/rp25-milestone-check.sh`
(rebuild the userland hello + the kernel + reboot; the three R-P25 sub-tasks +
the four R-P24 subsystems all green, re-runnable).

Boot flow now: the R-P24 flow (`hat_boot_init` Sv39 ON -> banner -> kmem/page ->
PLIC -> clock -> `dispatch_onramp` idle-loop round-trip) THEN
`run_user`: `exec_user` (build a user AS + map the embedded static ELF + a user
stack) -> `rv_ksetjmp` a kernel return point -> `rv_user_enter` (`sret` to
U-mode) -> the process runs its OWN `write(2)` then `exit(2)`, the `exit`
syscall `rv_klongjmp`s back into the kernel -> known halt.

### R-P25.1 U-mode entry + trap-based syscalls -- DONE
- **The kernel enters U-mode and services `ecall` syscalls from the userland
  process.** `rp25/kernel/{mach_uentry.S, mach_trap.S, main.c}`:
  - `rv_user_enter(struct uproc *)` (`mach_uentry.S`): install the user
    address space (`csrw satp` + `sfence.vma`), set `sscratch` = the lwp kernel
    trap stack top, program `sstatus` [clear `SPP` -> return to U, set `SPIE`
    so interrupts are enabled in U, set `SUM` so the kernel syscall handler may
    read/write the user buffer], set `sepc` = user `_start`, load the user
    `sp`, and `sret`.
  - **trap-from-U kernel-stack swap** (`_u_trap_entry`, `mach_uentry.S`, now the
    `stvec` landing pad): `csrrw sp, sscratch, sp` atomically swaps the user
    `sp` for the kernel trap-stack top when trapping from U (in the kernel
    `sscratch`==0, so a kernel trap swaps back and keeps its own `sp`), then
    falls into `rv_trap_dispatch`. The dispatcher stashes the swapped-out `sp`
    in the frame `R_SP` slot, resets `sscratch`=0 while in the kernel, and on
    the way out reloads the user `sp` + re-arms `sscratch` if returning to U
    (`sstatus.SPP`==0), keeps `sscratch`=0 if returning to S.
  - `rv_syscall(struct regs *)` (`main.c`): the illumos riscv64 ABI dispatcher
    -- `a7`=syscall number, `a0..a5`=args, result in `a0`. `SYS_write`(4) routes
    `buf[0..n)` to the SBI console and returns `n`; `SYS_exit`(1) records the
    status, restores the kernel `satp`, and `rv_klongjmp`s back to `run_user`.
  - `rv_ksetjmp`/`rv_klongjmp` (`mach_uentry.S`): a minimal `label_t` so the
    kernel enters U-mode and gets control back on `exit(2)` (the process does
    not "return").
- **Boot proof** (`rp25/kernel/qemu-boot.log`):
  ```
  [R-P25] sret -> U-mode; the process now runs and makes its OWN syscalls:
  ----- userland process output -----
  hello from riscv64-solaris userland process
  ----- end userland process output -----
  [R-P25] the userland process called exit(0); wrote 44 bytes via its own write(2). Kernel continues.
  ```
- **CRIB**: the `sscratch`-holds-kernel-stack-in-U / `csrrw` swap-on-trap /
  `sscratch`==0-in-kernel idiom is the RISC-V privileged-spec trap convention
  (xv6-riscv `usertrap`/`uservec`/`kernelvec`, BSD riscv `cpu_trap`); the
  `sret` to U with `SPP=0`+`SPIE`+`SUM`+`sepc`+user `sp` is the privileged spec
  `sret` semantics + the illumos `lwp_rtt`/exec user-return; the `a7`=nr /
  `a0..a5`=args / return-in-`a0` dispatch + `SYS_write=4`/`SYS_exit=1` are the
  illumos syscall trap (`os/syscall.c`) + the native `<sys/syscall.h>` (the
  same ABI the R-P22 `libc_syscall.s` emits); `rv_ksetjmp`/`rv_klongjmp` are the
  illumos `on_fault`/`label_t` idiom + the RISC-V LP64 callee-saved set.

### R-P25.2 the R-P22 static hello RUNS as a userland PROCESS -- DONE
- **The static hello runs in U-mode and makes its own syscalls -- the first
  riscv64-solaris userland process.** `rp25/user/{hello.c, build-user.sh}` +
  `rp25/kernel/{user_elf.S, main.c run_user}`:
  - `rp25/user/hello.c` is the R-P22.2b static hello given the R-P25 message,
    linked static with the R-P20 crt (`crt1/crti/crtn`) + the R-P22 minimal
    libc (`libc_syscall.o`: `write(2)`/`exit(2)` via `ecall`) into an EM_RISCV
    `ET_EXEC` (`hello_user`, entry `0x10160`, two PT_LOAD segments).
  - `user_elf.S` embeds that ELF in the kernel `.rodata` via `.incbin`
    (`user_elf_start`/`user_elf_end`) -- no filesystem needed to get the process
    bytes (the anti-wedge substrate).
  - `run_user()` (`main.c`) execs it into a fresh user AS, `rv_ksetjmp`s a
    kernel return, `rv_user_enter`s to U-mode; the process's `_start` reads
    `argc/argv/envp` off the initial stack, calls `main`, `write(1, msg, len)`
    [`ecall` -> kernel `rv_syscall` -> SBI console], returns, and `_start`
    calls `exit(0)` [`ecall` -> kernel -> `rv_klongjmp` back].
- **Boot proof**: the process's OWN `write(2)` output
  `hello from riscv64-solaris userland process` appears between the
  `----- userland process output -----` markers, then `exit(0)` and the kernel
  continues (see R-P25.1 log). The output is produced by the userland process's
  own `write(2)`, not the kernel.
- **CRIB**: embedding an init/user payload in the kernel image via `.incbin`
  (vs a root filesystem) is the classic linked-in-init bring-up idiom (Linux
  initramfs-in-kernel); the static hello + its `write/exit`-via-`ecall` libc is
  the R-P22.2b hello_static.

### R-P25.3 toward a real exec (map the static ELF PT_LOAD segments) -- DONE (reduced)
- **A minimal `exec` maps a static ELF into a fresh user AS + builds the aux
  vector.** `rp25/kernel/{exec_elf.c, hat_user.c, proc_riscv.h, startup.c}`:
  - `hat_user_new()` (`hat_user.c`) allocates a fresh Sv39 user root and copies
    the kernel high half (indices 1..511: the identity kernel-text gigapage for
    VA >=1 GiB + the direct-map) so a trap taken from U keeps the kernel mapped;
    index 0 (VA 0..1 GiB, where the static ELF links at `0x10000`) is left
    private for the user leaf subtree.
  - `hat_user_map(root, va, pa, perms)` walks/creates the level-1 + level-0
    tables and installs a 4 KiB leaf (`PTE_U` | R/W/X from the phdr flags |
    A|D). All page tables + user frames come from `kmem_alloc_page()`
    (`startup.c`) -- a PAGE-ALIGNED wrapper over the first-fit `kmem_alloc`
    (page tables and satp roots MUST be 4 KiB aligned; the first-fit heap only
    guarantees 16-byte alignment -- the alignment fix that made the user satp
    switch stop faulting).
  - `exec_user(struct uproc *)` (`exec_elf.c`) validates the ELF64 header
    (magic, EM_RISCV, ET_EXEC), walks the PT_LOAD program headers, maps + copies
    each segment (zeroing the `p_memsz > p_filesz` bss tail), maps a 16 KiB
    user stack just below `0x40000000`, builds the psABI initial stack
    (`argc`=1, `argv[0]`="hello", NULL, envp NULL, auxv `AT_PAGESZ`/`AT_ENTRY`/
    `AT_NULL`), allocates the lwp kernel trap stack, and returns `u_satp`/
    `u_entry`/`u_sp`/`u_kstack_top`.
- **Boot proof**:
  ```
  [R-P25] exec: loading the embedded static hello into a fresh user address space
    user entry VA     : 0x0000000000010160
    user sp (argv)    : 0x000000003fffffa0
    user satp         : 0x8000000000080233
  ```
- **Scope (honest, per the anti-wedge directive)**: REDUCED exec -- one static
  ELF embedded via `.incbin` (no filesystem/`open`), eager copy of the segments
  into kmem frames (no demand paging / COW), a fixed-size user stack, a minimal
  aux vector (`AT_PAGESZ`/`AT_ENTRY`/`AT_NULL`), a single lwp, `exit` unwinds via
  a `label_t` longjmp (no process table / `wait`). It is toward the general
  `gexec`/`elfexec`; R-P26 opens the ELF from a filesystem + hosts `ld.so.1` for
  the dynamic hello and adds fork/exec/wait.
- **CRIB**: the "walk the program headers, map+copy each PT_LOAD, zero the bss
  tail, set the entry, build the aux vector" shape is the illumos exec
  `mapelfexec`/`elfexec` + BSD `exec_elf64_imgact`; the initial-stack layout
  (argc, argv[], NULL, envp[], NULL, auxv[], AT_NULL) is the RISC-V psABI
  program-startup + the illumos `exec_args`; the "user AS = kernel high half
  shared + private user leaf tables" split is the illumos `hat`/`as_t` /
  i86pc kernel-vs-user hat separation; the 3-level Sv39 walk + PTE encoding are
  the RISC-V privileged spec.

### `/root/riscv-port/rp25/` contents
`kernel/{locore.S, mach_trap.S, mach_clock.S, mach_mmu.S, mach_swtch.S,
mach_uentry.S, user_elf.S, mmu_riscv.h, clock_riscv.h, plic.h, proc_riscv.h,
assym.h, sbi.h, sbi.c, hat_boot.c, hat_user.c, exec_elf.c, clock_riscv.c,
plic.c, startup.c, main.c, kernel.lds, build-kernel.sh, user_hello.bin, *.o,
unix.elf, qemu-boot.log}` (the grown kernel); `user/{hello.c, build-user.sh,
hello_user, *.o}` (the userland process); `rp25-milestone-check.sh` (all three
sub-tasks + the R-P24 regression, rebuild+reboot, re-runnable green). Repo
copies under `src/riscv/rp25/`.

---

## R-P23 — FIRST BOOTING illumos-riscv64 kernel (native toolchain) + reduced ld.so.1 reloc engine + real native ld

Substrate: fred v3 (root@52.88.62.49), the R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` reports `riscv64-unknown-solaris2.11`) +
the R-P17 `riscv64-unknown-elf` binutils + the native OpenIndiana gcc 14.3.0
with libelf/gelf (for the native `ld` driver) + `qemu-system-riscv64` with
OpenSBI v1.7 (`/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin`). As in
R-P22 this host has only full-system `qemu-system-riscv64 -machine virt` (no
user-mode qemu, no `<nixpkgs>`), so everything that RUNS is an OpenSBI-booted
S-mode payload on the virt board. Proof: `rp23/rp23-milestone-check.sh` (all 3,
re-runnable green).

### R-P23.1 the FIRST BOOTING illumos-riscv64 kernel (the headline) — DONE
- **The illumos-MD kernel skeleton, built with the NATIVE solaris toolchain,
  boots under qemu + prints a SunOS banner via SBI.** `rp23/kernel/` -- the
  illumos startup sequence compiled by the `riscv64-unknown-solaris2.11` gcc +
  linked by the R-P17 binutils into an EM_RISCV ET_EXEC kernel ELF (entry
  `_start` @ 0x80200000, zero residual relocs), booted by OpenSBI on
  qemu-virt:
  - `locore.S` (`.text.start` `_start`): mask S-mode interrupts, set `gp`,
    claim the boot hart via `amoswap.w`, set `sp = boot_stack_top`, zero BSS,
    install the real trap vector (`stvec -> _trap_entry -> rv_trap_dispatch`),
    then `call mlsetup`.
  - `mach_trap.S` (`rv_trap_dispatch`): grown from the R-P22.3 demo dispatch
    into a CORRECT full-GPR save/restore trap prologue/epilogue (x1,x3..x31 +
    sepc/sstatus/scause/stval at the struct regs offsets) so a trap taken from
    C returns transparently; dispatches by scause (interrupt / ecall 8,9 /
    other synchronous).
  - `sbi.c` (LEGACY console putchar EID 0x01, correct from any stack; SRST
    shutdown) + `main.c` (`mlsetup(hartid, dtb)` records the boot cpu, PROVES
    the trap path with a deliberate S-mode `ebreak` -- OpenSBI delegates
    breakpoints to S-mode, so it lands in `rv_trap_dispatch -> rv_trap`, which
    sets a flag + steps `sepc` past the ebreak and `sret`s back -- then
    `main()` prints the SunOS banner + subsystem status + a clean SBI
    shutdown).
  - The R-P22.3 MD units (`mach_clock.S` `rv_clock_intr`, `mach_mmu.S`
    `rv_set_satp`/`rv_tlb_flush_all`/`rv_get_satp`) link into the image too
    (present kernel MD code, exercising the full MD reloc set in the kernel
    ELF).
  Boot output (`rp23/kernel/qemu-boot.log`):
  ```
  [mlsetup] illumos riscv64 MD bring-up (R-P23)
  [mlsetup] S-mode entry from OpenSBI: hartid=0 dtb=0x000000008fe00000
  [mlsetup] trap vector installed (stvec -> _trap_entry -> rv_trap_dispatch)
  [mlsetup] trap path self-test: PASS (deliberate breakpoint dispatched + resumed)

  SunOS Release 5.11 Version solnix-riscv64 (illumos on RISC-V, native toolchain)
  Copyright (c) solnix -- first booting illumos riscv64 kernel (R-P23)

  riscv64 kernel: mlsetup complete, entering main:
    boot hart id      : 0
    devicetree        : 0x000000008fe00000
    console path      : SBI legacy console (EID 0x01)
    trap online       : yes
    toolchain         : riscv64-unknown-solaris2.11 (native EM_RISCV kernel ELF)

  [R-P23] first booting illumos-riscv64 kernel: locore -> mlsetup -> banner reached.
  [R-P23] reached the known halt; SBI shutdown.
  ```
  This is the FIRST BOOTING illumos-riscv64 kernel: the illumos MD startup path
  (locore -> mlsetup -> main banner), built with the solnix native toolchain,
  executing on emulated riscv64 hardware -- vs R-P22's standalone hello (no
  kernel entry) and vs the R-P1..R-P16 `unix` (which boots, but was built with
  the earlier BSD-substrate toolchain, not the native solaris target).
- **Scope (honest)**: a boot SKELETON. It reaches mlsetup + banner + a proven
  trap path + a known halt -- the R-P23 milestone. It does NOT yet turn on
  Sv39 paging, the phys allocator, SMP, the periodic clock, PLIC/AIA, or the
  genunix seam (all present in the R-P1..R-P16 `unix`); porting those onto this
  native-toolchain skeleton is R-P24+.
- **CRIB**: the "mask ints, claim boot hart, set sp, clear BSS, install stvec,
  call mlsetup -> main banner" shape is this repo's R-P2..R-P16
  `src/riscv/uts/{locore.S,main.c,sbi.c}` + `uts/i86pc/ml/locore.s` mlsetup ->
  main + richlowe arm64-gate `uts/aarch64/ml/locore.s`; the full-GPR trap
  frame + scause dispatch is illumos amd64 `trap.S` + the R-P3 riscv `trap.S` +
  the R-P20 genassym offsets; the S-mode entry contract (0x80200000, a0=hartid/
  a1=dtb, satp=0), SBI legacy putchar/SRST, and the breakpoint-delegated
  trap-probe are the OpenSBI + qemu-virt + RISC-V SBI/privileged specs.

### R-P23.2 REDUCED riscv64 ld.so.1 runtime relocation engine — DONE
- `rp23/ldso/rtld_riscv.c`: the CORE of illumos `ld.so.1` for riscv64 --
  `elf_reloc_riscv()`, the exact inner switch of rtld's `elf_reloc()` for the
  riscv64 load-time reloc types: `R_RISCV_RELATIVE` (B+A: relocate an absolute
  pointer for the load base), `R_RISCV_JUMP_SLOT` (bind a PLT/GOT slot to the
  resolved symbol, done eagerly as under LD_BIND_NOW), `R_RISCV_64` (S+A). Runs
  as a freestanding S-mode payload under qemu-virt: relocates a synthetic
  object at a nonzero base, binds a GOT slot to a libgcc_s-shaped symbol, CALLS
  through it, and dereferences the RELATIVE-fixed pointer. Output
  (`rp23/ldso/qemu-ldso.log`): `R_RISCV_JUMP_SLOT: PASS (GOT slot bound +
  called through)` + `R_RISCV_RELATIVE: PASS (base+addend pointer relocated +
  dereferenced)`.
- **Scope (honest, per the anti-wedge directive)**: this is the REDUCED
  milestone -- the runtime reloc math, proven end to end -- NOT the full
  process-hosted `ld.so.1`. The DYNAMIC hello does not run yet because that
  needs the kernel exec/proc/syscall path (R-P24+), ld.so.1 self-reloc +
  segment mapping + the `_rt_boot.s`/`elf_rtbndr.s` MD asm, and real riscv64
  libc/libgcc_s shared objects on a root fs. The STATIC-hello path (R-P22.2b,
  no ld.so.1) stays the supported way to run a riscv64-solaris exe once the
  kernel syscall path is live. Full path documented in `rp23/ldso/README.md`.
- **CRIB**: the `elf_reloc()` RELATIVE/JUMP_SLOT formulas are illumos
  `usr/src/cmd/sgs/rtld/common/_elf.c` + the machine-specific `rtld/<mach>/`
  reloc code (amd64/sparc shape, riscv64 on the psABI); the `R_RISCV_*` numbers
  are `uts/common/sys/elf_riscv.h` + the RISC-V psABI; the SBI substrate is the
  R-P23 kernel `sbi.c`.

### R-P23.3 REAL native illumos `ld` (ldmin) links a real EM_RISCV object — DONE
- `rp23/gate-ld/ldmin.c`: a MINIMAL native `ld` driver that links a REAL
  EM_RISCV object through the sgs backend with NO GNU ld in the reloc path:
  (1) opens a real `.o` (assembled by the solaris toolchain) with libelf/gelf
  (libld's ELF access layer); (2) SELECTS the backend as the native ld does --
  `ld_config_target(EM_RISCV)` -> `ld_targ = ld_targ_riscv` (R-P22.1); (3)
  reads `.text` + `.rela.text` + symtab, builds the `libld` `Rel_desc[]`
  active-reloc descriptors, resolves each S; (4) drives the reloc THROUGH
  `ld_targ.t_mr.mr_do_activerelocs` (`machrel.riscv.c`); (5) emits the
  relocated `.text`.
- **Proof**: the same object linked by GNU ld at the same address diffs
  BYTE-IDENTICAL -- `auipc a5,%pcrel_hi(target)` -> `0x00000797`,
  `addi a5,a5,%pcrel_lo` -> `0x01078793`, resolving the pcrel pair to `target`
  at 0x80200010 exactly like GNU ld. The illumos backend performed the link.
- **Scope (honest)**: `ldmin` is the reloc-OUTPUT pass over one section, not
  the whole link-editor (no multi-object layout, cross-object symbol
  resolution, GOT/PLT section synthesis, dynamic section / phdr generation,
  mapfiles). It proves the part the R-P21/22 backend owns -- the riscv64 reloc
  math + backend dispatch -- runs against REAL toolchain output, not a
  synthetic image, matching GNU ld byte-for-byte. The full gate `ld` needs the
  `usr/src/cmd/sgs` tree (NOT on this host); the drop-in integration steps
  (add `machrel.riscv.c` + `ld_targ_init_riscv()` + `case EM_RISCV` +
  `libld/riscv64/` Makefile, `dmake install`) are in `rp23/gate-ld/README.md`.
- **CRIB**: the "select target by e_machine, walk SHT_RELA + symtab, build
  Rel_desc, run the backend's do_activerelocs" flow is illumos
  `usr/src/cmd/sgs/libld/common/{libld.c,relocate.c}` + `machrel.<mach>.c`;
  libelf/gelf is the illumos ELF access library; the `Rel_desc`/`Target`
  layout + the backend are the R-P21/22 sgs pieces.

### `/root/riscv-port/rp23/` contents
`kernel/{locore.S, mach_trap.S, mach_clock.S, mach_mmu.S, assym.h, sbi.c,
sbi.h, main.c, kernel.lds, build-kernel.sh, *.o, unix.elf, qemu-boot.log}`
(the BOOTING kernel); `ldso/{rtld_riscv.c, boot.S, sbi.c, sbi.h, virt.lds,
build-ldso.sh, README.md, *.o, ldso.elf, qemu-ldso.log}` (the reduced ld.so.1
reloc engine); `gate-ld/{ldmin.c, t_pcrel.s, build-gate-ld.sh, README.md, *.o,
ldmin, t_pcrel.o, {ldmin,gnu}.text.bin, gnu.elf}` (the native ld driver +
GNU-ld diff); `rp23-milestone-check.sh` (all 3, re-runnable green).
Repo copies under `src/riscv/rp23/`.

### Next: R-P24
1. **Grow the booting kernel toward genunix**: port onto the R-P23
   native-toolchain kernel skeleton the R-P1..R-P16 MD subsystems in order --
   Sv39 paging (`hat_boot_init` + the phys allocator), the periodic SBI-timer
   clock (the R-P22.3 `rv_clock_intr` is the MD half), PLIC/AIA external IRQ,
   SMP secondaries via SBI HSM, then the genunix seam (`startup()` ->
   page_t/kmem/callout/dispatcher). Boot each further under qemu-virt.
2. **riscv64 kernel syscall path so the STATIC hello RUNS as a process**: bring
   the exec/proc path online on the native-toolchain kernel (map the a.out,
   U-mode entry, the `write(2)`/`exit(2)` ecall serviced by `rv_syscall`), so
   the R-P22.2b static illumos-ABI hello runs as a real riscv64-solaris
   process. Then the exec/interp/aux-vector path lets `ld.so.1` (R-P23.2
   engine) host the DYNAMIC hello.
3. **Full gate `ld` + ld.so.1**: with the `usr/src/cmd/sgs` tree available,
   follow `rp23/gate-ld/README.md` to build a real `ld` ELF, and port the full
   `rtld/riscv64/` (wiring the R-P23.2 reloc engine in) per
   `rp23/ldso/README.md`.

---

## R-P22 — sgs ld_targ_riscv native selection + FIRST EXECUTING riscv64-solaris hello + larger MD partial-link

Substrate: fred v3 (root@52.88.62.49), the intact R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>` reports `riscv64-unknown-solaris2.11`) +
the R-P17 `riscv64-unknown-elf` binutils + the native OpenIndiana gcc 14.3.0 (for
the linker-internal selection self-test) + `qemu-system-riscv64` 11.0.2 with
OpenSBI v1.7 (`/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin`). NOTE:
this host has only `qemu-system-riscv64` (full-system, `-machine virt`) -- there
is NO user-mode `qemu-riscv64` and no `<nixpkgs>`, so the RUNNING hello is a
freestanding S-mode payload booted by OpenSBI on the virt board (the
R-P2..R-P16 substrate), not a qemu-user run. Proof: `rp22/rp22-milestone-check.sh`
(all 3, re-runnable green).

### R-P22.1 sgs ld_targ_riscv native SELECTION (retires the GNU-ld crutch) — DONE
- `rp22/sgs/target.c`: the gate-shaped Target-dispatch layer that SELECTS the
  EM_RISCV backend. `ld_targ_init_riscv()` builds a file-static `Target`
  (`ld_targ_riscv`) whose `t_m` machine descriptor carries `m_mach = EM_RISCV`,
  ELFCLASS64/ELFDATA2LSB, the RV64 page/word align, and the dynamic reloc
  constants (`R_RISCV_RELATIVE`/`COPY`/`JUMP_SLOT`/`64`/`NONE`/`NUM`), and whose
  `t_mr` machrel sub-struct points its `mr_*` function pointers at the R-P21
  `machrel.riscv.c` entry points (`reloc_table`, `ld_reloc_local`,
  `ld_do_activerelocs`, `ld_assign_got_ndx`, `ld_riscv_finish_pcrel`).
  `ld_config_target(Half mach)` is the selection function the native ld calls
  once per link: `switch (mach) { case EM_RISCV: ld_targ = *ld_targ_init_riscv();
  return 1; default: return 0; }` -- exactly the gate `libld/common/target.c` +
  `machrel.<mach>.c` `ld_targ_init_<mach>()` convention.
- `rp22/sgs/target_shim.h`: the gate `Target`/`Target_mach`/`Target_machrel`
  structs + the single `extern Target ld_targ;` global, reproduced
  field-order-faithful to `usr/src/cmd/sgs/libld/common/_libld.h` (the gate is
  not on this host) so `target.c` is a drop-in.
- **Self-test** (`rp22/sgs/target_selftest.c`, compiled + linked against
  `machrel.riscv.c` WITHOUT `-DMACHREL_SELFTEST` + `target.c`): (1)
  `ld_config_target(EM_RISCV) == 1`, `ld_targ.t_m.m_mach == EM_RISCV`, the
  `mr_*` pointers all non-NULL; (2) `ld_config_target(EM_X86_64) == 0` and the
  installed RISC-V target is not clobbered; (3) a real %pcrel_hi/%pcrel_lo pair
  driven THROUGH `ld_targ.t_mr.mr_do_activerelocs` (not a direct call)
  reconstructs `S - P` **byte-identical to GNU ld** (`0x00001797`/`0x0a878793`,
  `S-P == 0x10a8`) -- i.e. the link is driven by the illumos backend, not GNU
  ld -- PASS.
- **Scope (honest)**: this retires the GNU-ld crutch at the
  SELECTION + reloc-DISPATCH level -- the linker's per-object backend choice
  now routes EM_RISCV objects through `machrel.riscv.c` via a gate-shaped
  `ld_targ`. The gate `usr/src/cmd/sgs` tree is NOT checked out on this host,
  so we cannot rebuild the actual `ld` ELF; `target.c`/`target_shim.h` are the
  gate-faithful drop-ins that will slot straight into a real sgs tree next to
  the amd64/sparc targets (add the `case EM_RISCV` to the gate's own
  `ld_config_target()`).
- **CRIB**: `ld_targ_init_<mach>()` + the `Target` struct + the single
  `ld_targ` global + `ld_config_target()`'s e_machine switch: illumos-gate
  `usr/src/cmd/sgs/libld/common/target.c` + `machrel.amd64.c`
  `ld_targ_init_x86_64()` / `machrel.sparc.c` `ld_targ_init_sparc()`; the
  RISC-V dynamic reloc constants + LP64D/RV64 machine params: the psABI +
  `uts/common/sys/elf_riscv.h`.

### R-P22.2 FIRST EXECUTING riscv64-solaris code (RUNS on qemu) + static illumos-ABI hello — DONE
- **The headline: a riscv64-solaris hello that RUNS.** `rp22/run/` -- a
  freestanding EM_RISCV S-mode payload built with the
  `riscv64-unknown-solaris2.11` gcc + the R-P17 binutils: `boot.S` (the OpenSBI
  FW_JUMP entry: mask sie, set `gp`, set `sp = __boot_stack_top`, zero BSS,
  `call kmain`), `kmain.c` (prints via SBI legacy console_putchar EID 0x01 then
  SBI SRST shutdown), `sbi.h` (the SBI ecall interface), `virt.lds` (link at
  the qemu-virt supervisor payload address `0x80200000`). Loaded with
  `qemu-system-riscv64 -machine virt -bios opensbi...fw_dynamic.bin -kernel
  hello.elf`; OpenSBI v1.7 hands off to `0x80200000` in S-mode and the payload
  **prints, then clean-shuts-down in ~1 s** (SRST works, no timeout hang):
  ```
  hello from riscv64-solaris (R-P22)
  first executing riscv64-solaris code
  ```
  This is the FIRST EXECUTING riscv64-solaris code -- our solaris-target
  toolchain's EM_RISCV output running on emulated riscv64 hardware. Run log:
  `rp22/run/qemu-run.log`.
- **STATIC illumos-ABI hello** (`rp22/hello/hello_static.c` + `rp22/libc/`):
  the R-P22 minimal libc -- `libc_syscall.s` provides `write(2)`/`exit(2)`/
  `_syscall()` in the illumos riscv64 syscall ABI (`a7 = SYS_nr`, args in
  `a0..a5`, `ecall`; `SYS_write == 4`, `SYS_exit == 1` from the native illumos
  `<sys/syscall.h>`), archived to `libc.a`. `hello_static.c` calls `write(1,
  msg, len)` then returns; linked STATIC with the R-P20 crt (`crt1/crti/crtn`)
  + `libc.a` -> an EM_RISCV ELF64 ET_EXEC with **NO dynamic section** (no
  `ld.so.1` needed), entry `_start`, zero relocs. `write` disassembles to
  `li a7,4; ecall`, `_exit` to `li a7,1; ecall`, and `main`'s auipc/addi pcrel
  pair to `msg` is resolved -- a complete self-contained static riscv64-solaris
  exe that will run the moment the riscv64 illumos kernel syscall path
  (R-P8/R-P9) is live under `qemu-system-riscv64`. (Sidesteps `ld.so.1` per the
  anti-wedge directive; the RUNNING milestone is met by the bare-metal hello
  above, which needs no libc + no runtime linker.)
- **CRIB**: the OpenSBI FW_JUMP payload contract (S-mode entry at 0x80200000,
  `a0=hartid`/`a1=fdt`) + the qemu-virt 0x80000000 DRAM base: OpenSBI +
  qemu-virt docs; the SBI legacy console_putchar (EID 0x01) + SRST (EID
  0x53525354) + legacy shutdown (EID 0x08) ecalls: the RISC-V SBI spec; the
  `a7=nr`/`ecall` syscall stubs + `SYS_write=4`/`SYS_exit=1`: the illumos
  riscv64 syscall ABI (same trap as the R-P20 `crt1.s exit(2)`) + the illumos
  libc `SYSCALL()` csu idiom; the crt link order: R-P20.

### R-P22.3 larger genassym-driven MD partial-link — DONE
- Added THREE new genassym-driven MD units to the R-P21 set, all using the
  generated `assym.h` `regs_r_*` offsets (not open-coded numbers):
  - `rp22/uts/mach_trap.S` (`rv_trap_dispatch`): the full trap prologue that
    saves the struct-regs frame and DISPATCHES by `scause` -- interrupt (sign
    bit) -> `rv_interrupt`, ecall (cause 8/9) -> `rv_syscall` (advancing
    `sepc` past the ecall), else -> `rv_trap`; restore + `sret`.
  - `rp22/uts/mach_clock.S` (`rv_clock_intr`): the SBI-timer bottom half --
    `rdtime` + a gp-relative load of `rv_clock_period` + an SBI `set_timer`
    ecall (EID `0x54494D45` "TIME") to reprogram the deadline, then `call
    clock`.
  - `rp22/uts/mach_mmu.S` (`rv_set_satp`/`rv_tlb_flush_all`/`rv_get_satp`): the
    MMU leaves -- `csrw satp; sfence.vma` root switch + the global TLB flush.
- **Partial link** (`ld -r`) of all SIX units (R-P21 `mach_locore.o`/
  `mach_swtch.o`/`mach_cpu.o` + the three new ones) -> one EM_RISCV ET_REL
  `unix_riscv64.o` carrying the full kernel reloc set: `CALL_PLT` x7,
  `PCREL_HI20`/`LO12` pairs, `BRANCH` x8, `RVC_BRANCH`/`RVC_JUMP`, `HI20`/
  `LO12_I`/`LO12_S`, `ADD32`/`SUB32`/`SET6`/`SUB6`, `32_PCREL`, `ALIGN`/`RELAX`
  -- exactly the relocs the R-P22.1-selected `machrel.riscv.c` backend resolves.
- **Full link** with `mach_externs22.o` (`rv_trap`/`rv_interrupt`/`rv_syscall`/
  `clock` + the R-P21 stubs): `ld -Ttext=0x10000 -e rv_trap_dispatch` resolves
  EVERY reloc -> EM_RISCV ET_EXEC, zero residual relocs; disassembly shows
  `rv_trap_dispatch`'s `jal rv_trap`/`jal rv_interrupt`/`jal rv_syscall` and
  `rv_clock_intr`'s `jal clock` all resolved.
- **CRIB**: the "save regs, decode scause, dispatch interrupt/syscall/trap C
  handlers, restore, sret" shape: illumos amd64 `trap.S` + the R-P3 riscv
  `trap.S`; the SBI `set_timer` (EID "TIME") + `rdtime`: the SBI + RISC-V
  unprivileged specs + the R-P6 clock slice; the `csrw satp; sfence.vma` root
  switch + `sfence.vma zero,zero` global flush: the RISC-V privileged spec +
  the R-P7 mmu slice; the genassym offset SOURCE (assym.h): the R-P21 unit +
  the illumos uts + BSD `genassym.cf` idiom.

### `/root/riscv-port/rp22/` contents
`sgs/{target.c, target_shim.h, target_selftest.c, _libld_shim.h, reloc_riscv.h,
riscv_pcrel_htab.h, machrel.riscv.c, machrel_riscv_insn.c, target_selftest}`;
`run/{boot.S, sbi.h, kmain.c, virt.lds, hello.elf, hello.bin, qemu-run.log}`
(the RUNNING bare-metal hello); `libc/{libc_syscall.s, libc.a}`;
`hello/{hello_static.c, hello_static, crt1.o, crti.o, crtn.o}` (the STATIC
illumos-ABI hello); `uts/{mach_trap.S, mach_clock.S, mach_mmu.S,
mach_externs22.c, assym.h, *.o, unix_riscv64.o, unix_riscv64.exec}`;
`rp22-milestone-check.sh` (all 3, re-runnable green).
Repo copies under `src/riscv/rp22/{sgs/{target.c, target_shim.h,
target_selftest.c}, run/{boot.S, sbi.h, kmain.c, virt.lds, qemu-run.log},
libc/libc_syscall.s, hello/hello_static.c, uts/{mach_trap.S, mach_clock.S,
mach_mmu.S, mach_externs22.c}, rp22-milestone-check.sh}`.

### Next: R-P23
1. **Drop the sgs backend into a REAL gate sgs tree**: check out
   `usr/src/cmd/sgs`, add `machrel.riscv.c` + the `ld_targ_riscv` Target to
   `libld/common/`, add the `case EM_RISCV` to the gate's own
   `ld_config_target()`, and rebuild the actual `ld` ELF so an EM_RISCV object
   links with the native illumos linker binary (not GNU ld, and not just the
   dispatch stub).
2. **riscv64 illumos kernel syscall path so the STATIC hello RUNS**: bring the
   R-P8/R-P9 syscall table + trap dispatch (the R-P22.3 `rv_trap_dispatch` is
   the MD half) far enough that a `write(2)`/`exit(2)` ecall from the static
   hello is serviced under `qemu-system-riscv64` -- the static illumos-ABI
   hello then RUNS as a real riscv64-solaris process (vs the bare-metal SBI
   hello, which bypasses the kernel).
3. **Link a still-larger `unix` toward a bootable EM_RISCV image**: add the
   remaining R-P1..R-P16 MD units (startup, real locore, mmu/hat, plic/aia,
   virtio) to the genassym-driven partial link toward a linkable/bootable
   riscv64 `unix`, and boot it on `qemu-system-riscv64 -machine virt`.

---

## R-P21 — gate sgs machrel.riscv.c (htab pairing) + libgcc_s.so.1 (dynamic hello) + bigger MD partial-link

Substrate: fred v3 (root@52.88.62.49), the intact R-P18/19 build-tree gcc
(`build/gcc-sol-cfg3/gcc/xgcc -B<gcc>`) + R-P17 `riscv64-unknown-elf` binutils.
Crib sources on host: binutils-2.44 `bfd/elfnn-riscv.c` (pcrel pairing, PLT/GOT
layout) + `ld/` (emulation regen); illumos `/usr/gcc/*/lib/libgcc-unwind.map`
(version-script shape); the illumos sgs `machrel.amd64.c`/`machrel.sparc.c`
SHAPE (from knowledge -- gate not checked out on host) for the backend wiring.
Proof: `rp21/rp21-milestone-check.sh` (all 3, re-runnable green).

### R-P21.1 gate sgs machrel.riscv.c + real hash-table %pcrel pairing — DONE
- `rp21/sgs/machrel.riscv.c`: the R-P20 standalone pieces folded into ONE
  gate-shaped backend that compiles against a `_libld.h` shim
  (`rp21/sgs/_libld_shim.h`, field-order-faithful `Rel_desc`/`Rel_aux`/
  `Sym_desc`/`Sym_aux`/`Gotndx`/`Os_desc`/`Is_desc`/`Ofl_desc` trimmed to what
  the backend touches).  Four gate entry points, same names/roles as the
  amd64/sparc backends:
  - `ld_reloc_local()` -- per input reloc: classify via `reloc_table[]`, and if
    GOT/PLT assign the slot on the referenced `Sym_desc` (idempotent -- many
    refs share ONE slot) growing `ofl_gotcnt`/`ofl_pltcnt`;
  - `ld_assign_got_ndx()` -- find/assign a symbol's GOT slot per `Gotref`;
  - `ld_do_activerelocs()` -- the output pass: computes the RISC-V value
    (S+A, or S+A-P for PCREL) and routes flat data to a byte store, INSREL
    types to the field splice, and the %pcrel_hi/%pcrel_lo pair through the
    record-HI / defer-LO / resolve-by-HI-address model;
  - `ld_riscv_finish_pcrel()` -- resolves the deferred LOs.
- **HTAB upgrade (the R-P20 gate)**: `rp21/sgs/riscv_pcrel_htab.h` replaces the
  R-P20 O(n) list scan with a chained (open) hash table keyed by the auipc-site
  address -- power-of-two buckets, Knuth multiplicative hash, grow+rehash at
  ~0.75 load -- so a %pcrel_lo resolves O(1) even with thousands of pairs. The
  htab hangs off `Ofl_desc.ofl_riscv_pcrel` for the file being relocated.
- Self-test (`-DMACHREL_SELFTEST`): ld_reloc_local classifies + assigns
  idempotent GOT/PLT slots (2 GOT refs -> 1 slot, 2 CALL_PLT -> 1 entry;
  header-biased .plt/.got.plt offsets 32/16); ld_do_activerelocs drives a real
  `Rel_desc` set and the pcrel pair (through the htab, resolved in the finish
  pass) is **byte-identical to GNU ld** (`0x00001797`/`0x0a878793` for the
  R-P19.3 pair) reconstructing S-P; a dangling %pcrel_lo is rejected; the htab
  scales to 1000 pairs with O(1) lookup -- PASS.
- **CRIB**: `ld_reloc_local`/`ld_assign_got_ndx`/`ld_do_activerelocs`/
  `ld_perform_outreloc` SHAPE + the `Sym_desc`/`Gotndx`/`Rel_desc` field names
  from illumos-gate `usr/src/cmd/sgs/libld/common/machrel.amd64.c` +
  `machrel.sparc.c` + `include/_libld.h`; the pcrel pairing algorithm + PLT/GOT
  layout from binutils-2.44 `bfd/elfnn-riscv.c`; the RISC-V Calculation +
  immediate encodings from the psABI. (Gate not on host: the shim reproduces
  the gate structs so the backend is a drop-in for the real `_libld.h`.)

### R-P21.2 hand-linked shared libgcc_s.so.1 + first DYNAMIC hello — DONE
- The R-P20 long pole. gcc target libs are `--disable-shared` (only static
  `libgcc.a`, 138 objects). Instead of a full `--enable-shared` rebuild (needs
  a real libc for `SHLIB_LINK`), **hand-linked `libgcc_s.so.1` from `libgcc.a`
  + a GCC_3.0 version script** (`rp21/libgcc_s/libgcc_s.ver`, 214 exported
  symbols generated from the archive's defined symbols; crib: illumos
  `libgcc-unwind.map` + gcc `libgcc-std.ver.in`).
- **One binutils blocker fixed**: the R-P17 `riscv64-unknown-elf` binutils had
  `elf64lriscv` `config.has_shared = false` (bare-metal newlib leaves
  `GENERATE_SHLIB_SCRIPT` unset), so `ld -shared` errored `-shared not
  supported` (ld/lexsup.c:1365) with no `.xs` script. Regenerated ONLY that
  emulation (added `GENERATE_SHLIB_SCRIPT=yes`/`GENERATE_PIE_SCRIPT=yes` to the
  emulparams, re-ran genscripts, relinked just `ld-new`) -> `has_shared = true`
  + the shared/PIE ldscripts; installed as
  `toolchain/bin/riscv64-unknown-elf-ld-shared`. NOT a full binutils rebuild.
  Recipe in `rp21/libgcc_s/README.md`.
- `libgcc_s.so.1`: **EM_RISCV ELF64 ET_DYN**, SONAME `libgcc_s.so.1`, all 214
  symbols versioned `@@GCC_3.0` (`--allow-shlib-undefined` for the libc deps
  malloc/memcpy/memset/mprotect/... resolved from libc.so.1 at runtime).
- **Dynamic hello**: R-P20 hello.c + crt linked against `-lgcc_s` with
  `--dynamic-linker /usr/lib/ld.so.1` -> EM_RISCV, INTERP `/usr/lib/ld.so.1`,
  NEEDED `libgcc_s.so.1` -- the first DYNAMIC riscv64-solaris userland exe
  (R-P20 produced the first STATIC one).
- **CRIB**: version-script shape from illumos `/usr/gcc/*/lib/libgcc-unwind.map`
  + gcc `libgcc/libgcc-std.ver.in` (GCC_3.0 global / local *); the emulation
  regen args verbatim from `build/binutils/ld/Makefile` GENSCRIPTS.

### R-P21.3 bigger genassym-driven MD set -> EM_RISCV partial-link — DONE
- Replaced hand-maintained `.S` offsets with **genassym output**:
  `rp21/uts/riscv64/mach_swtch.S` (rv_swtch/rv_savectx: the R-P5 context switch,
  every `struct rv_context`/`label_t` field via the genassym `rv_context_c_*` /
  `LABEL_*` macros in `assym.h`, not `#define C_RA 0`) + `mach_locore.S`
  (rv_trap_entry: a trap prologue building a `struct regs` frame at the
  generated `regs_r_*` offsets). Both cross-assemble to EM_RISCV.
- **Partial link (`ld -r`)**: `mach_locore.o` + `mach_swtch.o` + `mach_cpu.o`
  (the R-P20 machdep slice) -> one **EM_RISCV ET_REL** `unix_riscv64.o`
  preserving the full kernel reloc set (CALL_PLT x3, PCREL_HI20/LO12 pairs,
  HI20/LO12, BRANCH/RVC_BRANCH, ADD32/SUB32/SET6/SUB6, 32_PCREL, RELAX/ALIGN)
  -- the milestone: a multi-object MD partial-link exercising exactly the
  relocs the R-P21.1 sgs backend resolves.
- **Full link** with `mach_externs.o` (rv_trap/rv_lofault/cpu_list/
  hart_online_mask stubs): `ld -Ttext=0x10000 -e rv_trap_entry` resolves EVERY
  reloc -> EM_RISCV ET_EXEC, zero relocs; disassembly shows `jal <rv_trap>`
  (CALL_PLT), the auipc/addi pcrel pair to `rv_lofault`, and `jal <rv_swtch>`
  all resolved.
- **CRIB**: the ASSYM/OFFSET mechanism from the R-P20 genassym unit + illumos
  `uts` genassym + BSD `sys/arch/riscv/riscv/genassym.cf`; the switch/trap-save
  bodies from the R-P3/R-P5 MD tree (RISC-V LP64 conv, NetBSD `cpu_switch.S`
  idiom); the "MD .S references C layout only through <assym.h>" discipline is
  standard illumos kernel build practice.

### `/root/riscv-port/rp21/` contents
`sgs/{_libld_shim.h, reloc_riscv.h, riscv_pcrel_htab.h, machrel.riscv.c,
machrel_riscv_insn.c (from rp20), machrel_selftest}`;
`libgcc_s/{libgcc_s.so.1, libgcc_s.so->.1, libgcc_s.ver, README.md}`;
`hello/{hello.o, crt{1,i,n}.o, hello.dyn}`;
`uts/riscv64/{genassym.c, genassym.sh, genassym.s, assym.h, mach_swtch.S,
mach_locore.S, mach_cpu.c, mach_externs.c, *.o, unix_riscv64.o,
unix_riscv64.exec, sys/*.h}`; `rp21-milestone-check.sh` (all 3, re-runnable).
Shared-capable linker installed as `toolchain/bin/riscv64-unknown-elf-ld-shared`.
Repo copies under `src/riscv/{sgs/{_libld_shim.h, reloc_riscv.h,
riscv_pcrel_htab.h, machrel.riscv.c}, libgcc_s/{libgcc_s.ver, README.md},
uts/riscv64/{mach_swtch.S, mach_locore.S, mach_externs.c, assym.h}}` +
`src/riscv/rp21-milestone-check.sh`.

### Next (from R-P21) -> delivered by R-P22
1. **Build the sgs backend inside a real (or stubbed) sgs tree** so `ld` selects
   `ld_targ_riscv` for EM_RISCV -- DONE R-P22.1 (gate-faithful `target.c`/
   `target_shim.h` stub: `ld_config_target(EM_RISCV)` selects `ld_targ_riscv`;
   the real gate-tree drop-in is R-P23.1).
2. **libc bring-up toward a self-hosting userland**: a minimal riscv64-solaris
   libc (crt + syscalls) -- DONE R-P22.2 (a static `write(2)`/`exit(2)` libc +
   the STATIC illumos-ABI hello; a bare-metal hello RUNS on qemu). Running it
   as a real process under a riscv64 illumos kernel + `ld.so.1` is R-P23.2.
3. **Grow the MD partial-link toward a linkable `unix`** -- DONE R-P22.3 (6-unit
   EM_RISCV `unix_riscv64.o`: locore/swtch/cpu/trap-dispatch/clock/mmu, full
   link resolves every reloc). A bootable `unix` image is R-P23.3.

---

## R-P20 — sgs %pcrel pairing + GOT/PLT alloc, csu crt + first hello ELF, larger uts unit

Substrate: fred v3 (root@52.88.62.49). The R-P19 install-time gcc `bin/` wrapper
was gone (only binutils symlinks + libgcc.a survived), but the R-P18/19 build
tree `build/gcc-sol-cfg3/gcc/xgcc` is intact and reports
`riscv64-unknown-solaris2.11`; drove it directly as `xgcc -B<gcc>` (no rebuild).
Crib source on host: binutils-2.44 `bfd/elfnn-riscv.c` (pcrel pairing + PLT/GOT
layout) and the R-P1..R-P16 illumos riscv64 MD tree (struct layouts for
genassym). Proof: `rp20/rp20-milestone-check.sh` (all 3).

### R-P20.1 sgs %pcrel_hi/%pcrel_lo pairing + GOT/PLT allocation — DONE
- `rp20/sgs/machrel_riscv_pcrel.c`: the RISC-V PC-relative address PAIRING.
  RISC-V splits a 32-bit pcrel address across `auipc %pcrel_hi20` and a
  following `addi/load %pcrel_lo12` that references the HI *by label* -- the
  LO's reloc symbol resolves to the AUIPC address, not the target, so its low
  12 bits must come from the SAME (S+A-P) value the HI computed. Exact binutils
  two-pass model: (1) `ld_riscv_record_pcrel_hi()` computes value=S+A-addr,
  applies the HI immediate, records `{HI_addr -> value}`; (2)
  `ld_riscv_record_pcrel_lo()` defers the LO, remembering the HI address (its
  resolved symbol value); (3) `ld_riscv_resolve_pcrel_lo()` finds the HI by that
  address and splices the HI's stored value into the LO immediate, so
  HI(rounded high20)+LO(sext low12)==S+A-P. Diagnostics (missing HI, addend on
  GOT_HI20, addend-crosses-high-part overflow) match binutils. Self-test: S-PC
  reconstruct across auipc/addi, LO resolved from recorded HI, missing-HI
  rejected, and byte-identical GNU-ld bytes `0x00001797`/`0x0a878793` for the
  R-P19.3 pair -- PASS.
- `rp20/sgs/machrel_riscv_gotplt.c`: GOT/PLT slot allocation for CALL_PLT /
  GOT_HI20 / JUMP_SLOT. RV64 layout from binutils (GOT_ENTRY_SIZE=8,
  PLT_HEADER_SIZE=32, PLT_ENTRY_SIZE=16, GOTPLT_HEADER_SIZE=16); idempotent
  per-symbol slots, header-biased offsets, `.plt/.got.plt/.got` sizing, and
  emitters for the 4-insn PLT entry stub (auipc t3 / ld t3 / jalr t1,t3 / nop)
  + the 8-insn header trampoline. Self-test: idempotent+monotonic slots,
  binutils sizes/offsets, PLT stub decodes + its pcrel hi/lo reconstructs the
  `.got.plt` target -- PASS.
- **CRIB**: `riscv_pcrel_{hi,lo}_reloc` structs + record/resolve algorithm from
  binutils-2.44 `bfd/elfnn-riscv.c` (~1962-2170, 2877-2930); PLT/GOT layout +
  `riscv_make_plt_{header,entry}` (~296-410). Gate `Rel_desc`/`Target`/htab
  wiring documented inline (this uses an O(n) list, marked as the upgrade
  point).

### R-P20.2 csu crt (crt1/crti/crtn) + first riscv64-solaris hello ELF — DONE
- `rp20/csu/{crt1,crti,crtn}.s`: riscv64 C runtime. `crt1.s` `_start`:
  terminate the frame chain, set `gp` from `__global_pointer$` (relaxation
  off), pull argc/argv/envp into a0/a1/a2 per psABI, 16-align sp, then
  `call _init; call main`, then `exit(2)` (SYS_exit=1 via `ecall`) with main's
  return -- freestanding, no libc. `crti/crtn` open/close `_init`/`_fini` (SVR4
  csu split; riscv64 addi sp,-16 / sd ra,8(sp) frame). All EM_RISCV.
- `rp20/hello/hello.c` -> `ld -static -e _start` with crt1/crti/hello/crtn +
  libgcc.a -> valid **EM_RISCV ELF64 ET_EXEC** entry `_start`, ZERO relocs.
  `_start` disassembles to gp-setup + jal _init + jal main + li a7,1;ecall; the
  gp-relative auipc/addi pcrel pair to `__global_pointer$` resolved -- the
  first riscv64-solaris userland executable.
- **full libgcc_s.so.1: NOT this phase (R-P21 long pole).** R-P17/18 gcc was
  `--disable-shared` (`enable_shared = no` in the libgcc Makefile), so
  `all-target-libgcc` only builds static `libgcc.a` (138 members, present).
  `libgcc_s.so.1` needs `--enable-shared` reconfigure + full rebuild AND a real
  libc (Solaris `SHLIB_LINK` pulls `-lc`), neither of which exists yet.
  Documented as the R-P21 gate; static libgcc.a suffices for the linkable-exe
  milestone.
- **CRIB**: initial-stack layout + a0=argc/a1=argv/a2=envp from RISC-V psABI
  "Program Startup" + glibc/newlib Scrt1; `.option norelax; lla gp,
  __global_pointer$` from psABI + gcc riscv startup; crt open/close split +
  "call _init; call main; exit" from illumos csu (amd64/aarch64 crt1.s);
  SYS_exit=1 + `ecall` from the illumos syscall convention.

### R-P20.3 larger uts unit — genassym + machdep cpu-init — DONE
- `rp20/uts/riscv64/genassym.c` + `genassym.sh`: the illumos riscv64 kernel
  asm-offset generator. MD .S (locore/trap/swtch/setjmp) reach into C structs
  by numeric offset (`sd ra,C_RA(a0)`, TF_* frame, LABEL_* in label_t), today
  hand-maintained + `_Static_assert`-guarded. genassym.c compiles the ACTUAL
  `struct regs`/`struct rv_context`/`label_t` and, via inline-asm
  `ASSYM(name, offsetof(...))` in a `.assym` section, emits the compiler's real
  offsets; `genassym.sh` extracts `assym.h`. Cross-compiled to **EM_RISCV**
  ET_REL. Generated offsets EXACTLY match the hand-maintained
  swtch.S/asm_frame.h/machtypes.h (regs_r_ra=0, regs_r_sp=8, rv_context_c_ra=0,
  c_satp=120, c_lofault=128, LABEL_SP=8, regs_SIZE=280) -- genassym validates
  (and would replace) the hand offsets. Freestanding pipeline (compiler folds
  offsetof; no runnable libc) -- the classic gate/BSD genassym trick.
- `rp20/uts/riscv64/mach_cpu.c` (+ `externs.c`): a machdep slice (per-cpu
  online, install stvec, account a switch, a dispatch table) exercising the
  load-bearing reloc set: **R_RISCV_CALL_PLT** (x2 cross-TU calls),
  **PCREL_HI20+PCREL_LO12** pairs + HI20/LO12 absolute pairs (external data via
  auipc/addi), BRANCH/RVC_BRANCH, ADD32/SUB32/SET6/SUB6. Cross-compiled to
  EM_RISCV; cross-`ld -Ttext=0x10000 -e cpu_online` with the externs stub
  resolves EVERY reloc -> EM_RISCV ET_EXEC, zero relocs; the CALL_PLT to
  `rv_swtch` and the auipc/addi pcrel pairs to
  `cpu_list`/`trap_entry`/`hart_online_mask` all disassemble resolved. The
  R-P19 mod stub grown to a multi-TU unit that links toward the kernel and
  exercises exactly the relocs R-P20.1 resolves.
- **CRIB**: the OFFSET/SIZE/ASSYM mechanism from illumos uts genassym.c +
  sys/assym.h and BSD `sys/arch/riscv/riscv/genassym.cf`; struct layouts from
  the R-P1..R-P16 MD tree (`regs.h`, `proc.c`, `sys/machtypes.h`); the
  per-cpu/stvec shape from that MD tree + the RISC-V privileged spec.

### `/root/riscv-port/rp20/` contents
`sgs/{machrel_riscv_pcrel.c, machrel_riscv_gotplt.c, machrel_riscv_insn.c
(from rp19), pcrel_selftest, gotplt_selftest}`; `csu/{crt1,crti,crtn}.s + .o`;
`hello/{hello.c, hello.o, hello.elf}`; `uts/riscv64/{genassym.c, genassym.sh,
genassym.{s,o}, assym.h, mach_cpu.c, externs.c, mach_cpu.o, externs.o,
kunit_riscv64.{o,exec}, mod_riscv64.c, sys/*.h}`; `rp20-milestone-check.sh`
(all 3, re-runnable). Crt objects also installed into
`sysroot-riscv-sol/usr/lib/{crt1,crti,crtn}.o`. Repo copies under
`src/riscv/{sgs,csu,hello,uts/riscv64}/` + `src/riscv/rp20-milestone-check.sh`.

### Next: R-P21
1. **Fold the sgs pieces into a real gate `machrel.riscv.c`** against the true
   `usr/src/cmd/sgs/include/_libld.h` `Rel_desc`/`Target` types: swap the
   standalone shims for the gate structs, wire the pcrel-pairing hash (keyed by
   `Rel_desc->rel_roffset`) + GOT/PLT allocator into `ld_do_activerelocs` /
   `ld_allocate_got` / `ld_perform_outreloc`, and build inside a real (or
   stubbed) sgs tree so `ld` selects `ld_targ_riscv` for EM_RISCV.
2. **Shared libgcc_s.so.1 (the R-P20 long pole)**: bring up a minimal
   riscv64-solaris libc (or a stub `-lc` with the symbols `SHLIB_LINK` needs),
   reconfigure gcc `--enable-shared`, complete `all-target-libgcc` to produce
   `libgcc_s.so.1`; then link a *dynamic* hello.
3. **Grow the uts unit toward a linkable `unix`/`genunix`**: replace `assym.h`'s
   hand offsets in the real `.S` files with genassym output, then cross-compile
   + link a bigger MD set (locore + swtch + trap + a machdep) as an EM_RISCV
   kernel image in the gate layout.

---

## R-P19 — riscv64-solaris toolchain finished + sgs MACH descriptor + first uts object

Substrate: fred v3 (root@52.88.62.49), the R-P18 all-gcc-solaris build tree
(`/root/riscv-port/build/gcc-sol-cfg3/`), the R-P17 `riscv64-unknown-elf`
binutils 2.44, and binutils-2.44 `bfd/` as the reloc-math crib source.

### R-P19.1 all-gcc-solaris finished + riscv64-solaris libgcc.a — DONE
- **Long-pole `make all-gcc` (riscv64-unknown-solaris2.11) finished.** Two real
  build blockers found + fixed in `gcc/config/riscv/sol2.h`
  (`rp19/config-riscv-sol2.h`, appended to R-P18's header):
  (a) the generic `config/sol2.cc` `solaris_output_init_fini()` emits
  `.init/.fini` entries via `ASM_OUTPUT_CALL`, which the RISC-V ELF backend
  never defines (only i386/sparc sol2.h do) — added an `ASM_OUTPUT_CALL` for
  RISC-V (`\tcall\t` + `assemble_name`, the `call` pseudo, R_RISCV_CALL_PLT);
  (b) `#undef MULTILIB_DEFAULTS` so the common sol2.h `{ "m64" }` wins over
  riscv/riscv.h without a redefinition warning. `cc1` links, `make all-gcc`
  exits 0, `-dumpmachine` = `riscv64-unknown-solaris2.11`, GCC 14.3.0.
- **Minimal sysroot + libgcc bootstrap** (`rp19/rp19-sysroot-libgcc.sh`,
  idempotent). The solaris triple had no in-tree binutils, so the build-tree
  `gcc/as` + `gcc/collect-ld` wrappers had empty `ORIGINAL_*_FOR_TARGET` and
  ran `exec "" -march=...` — pointed them at the R-P17 `riscv64-unknown-elf`
  as/ld (psABI is identical; only the OS triple differs) and published
  `riscv64-unknown-solaris2.11-{ar,ranlib,...}` on PATH. Added four BOOTSTRAP
  stub headers (`sys/mman.h`, `sys/types.h`, `unistd.h`, `stdlib.h`) the
  Solaris `enable-execute-stack-mprotect.c` references, plus the minimal
  `/usr/include/sys/{isa_defs,machtypes,elf_riscv}.h` sysroot (the R-P17 MD
  headers). `gmake libgcc.a` builds the 138 compiler-runtime objects (soft
  int/float, clz/ctz, muldi3, ...) — skips the Solaris gmon/profiling extra
  that needs full libc. Installed at
  `toolchain-sol/lib/gcc/riscv64-unknown-solaris2.11/14.3.0/libgcc.a` (5.6 MB,
  138 EM_RISCV members). PROOF: `rp19/rp19-toolchain-check.sh`.
- **CRIB**: `ASM_OUTPUT_CALL` shape from gcc `i386/sol2.h` + `sparc/sol2.h`,
  adapted to the RISC-V `call` mnemonic. The as/ld-wrapper + PATH bootstrap is
  standard cross-gcc practice (a target reusing another's binutils for an
  identical psABI).

### R-P19.2 sgs libld MACH descriptor + RISC-V instruction-field reloc encoders — DONE
- `rp19/machrel_riscv_insn.c`: the `FLG_RE_INSREL` encoder `ld_reloc_riscv_insn()`
  — splices a computed value into the U/I/S/B/J immediate slots of a 32-bit
  instruction (and CB/CJ/CI slots of a 16-bit RVC instruction) exactly as
  binutils `perform_relocation()` does: ENCODE the value into the field layout,
  read-modify-write `word = (word & ~dst_mask) | (enc & dst_mask)`, LE store.
  Handles HI20/LO12_I/LO12_S (+ TPREL/PCREL/GOT/TLS HI/LO variants),
  CALL/CALL_PLT (auipc U-part + jalr I-part, 64-bit splice), JAL, BRANCH,
  RVC_BRANCH/JUMP/LUI. HI/LO split via `RISCV_CONST_HIGH_PART`. Self-test
  round-trips every field type against the binutils EXTRACT macros — PASS.
- `rp19/machrel_riscv_dispatch.c`: `ld_do_reloc_riscv()` — the reloc-apply core
  the MACH descriptor + krtld `do_reloc()` reduce to. Consults the R-P18
  classification table (`sgs_reloc_table_riscv[]`), computes the RISC-V
  Calculation (S+A, or S+A-P for PC-relative), and routes INSREL types to the
  encoder, flat data types to a byte store, and link-time markers to a no-op.
  ADD/SUB/SET/SUB6 are correctly in-place modify (not overwrite), cribbed from
  binutils `riscv_elf_add_sub_reloc`. Self-test: flat64 / 32_PCREL / HI20+LO12
  pair / ADD32+SUB32 / RELAX no-op — PASS.
- `rp19/machtarget_riscv.c`: `ld_targ_riscv` — the EM_RISCV `Target` descriptor
  skeleton (Target_mach: EM_RISCV/ELFCLASS64/ELFDATA2LSB/pagesize; the M_R_*
  dynamic reloc identities: RELATIVE=3 / JUMP_SLOT=5 / COPY=4 / TLS_*64;
  null/fill func bytes) with `t_mr` wiring the classification table +
  `ld_do_reloc_riscv`. This is the record `ld_config_target()` returns for
  `e_machine == EM_RISCV`. Self-test: descriptor identity + reloc applied
  THROUGH the `t_mr.mr_do_reloc` pointer — PASS.
- **BYTE-IDENTICAL to GNU ld**: on the R-P19.3 object the INSREL encoder
  produces exactly `auipc a5,0x1 = 0x00001797` + `addi a5,a5,168 = 0x0a878793`
  for the `riscv64_boot_label` PCREL_HI20/LO12 pair — the same bytes GNU ld
  emitted, verified in `rp19-milestone-check.sh` R-P19.3d.
- **CRIB**: `ENCODE_{U,I,S,B,J}TYPE_IMM` / `ENCODE_C{B,J,I}TYPE_IMM` / `RV_X` /
  `RISCV_CONST_HIGH_PART` from binutils-2.44 `include/opcode/riscv.h`; the
  per-reloc encode dispatch + CALL `U | I<<32` packing + the RMW store +
  get/put_insn 16/32/64 LE model from `bfd/elfnn-riscv.c perform_relocation()`;
  `dst_mask == ENCODE_xTYPE_IMM(-1U)` from `bfd/elfxx-riscv.c` howto_table[];
  ADD/SUB math from `riscv_elf_add_sub_reloc`. The Target/Rel_entry/FLG_RE_*
  shape follows the illumos sgs machrel.<arch>.c convention.

### R-P19.3 first illumos uts/riscv64 EM_RISCV object — DONE
- `rp19/uts/riscv64/` gate-layout tree: `mod_riscv64.c` (a trivial loadable
  module: a `label_t` save-area store, `_init/_fini/_info`) compiled `_KERNEL`
  / freestanding against the R-P17 illumos riscv64 MD headers spliced into
  `sys/{isa_defs,machtypes,elf_riscv,feature_tests}.h`. Compile-time asserts
  pin the ISA contract (LP64, `_LITTLE_ENDIAN`, `_ALIGNMENT_REQUIRED`,
  `_MAX_ALIGNMENT==16`, `label_t == 16 XLEN slots`) so a wrong data model fails
  the BUILD.
- Built by BOTH the R-P17 `riscv64-unknown-elf` gcc AND the new
  `riscv64-unknown-solaris2.11` gcc → a valid **EM_RISCV (243) ELF64-LSB
  ET_REL** illumos kernel object. It emits exactly the reloc set this port must
  resolve: `R_RISCV_CALL_PLT(19)`, `R_RISCV_PCREL_HI20(23)`,
  `R_RISCV_PCREL_LO12_I(24)`, `R_RISCV_RELAX(51)`, plus ADD32/SUB32/SET6/SET8/
  SUB6/32_PCREL — all in-bounds in the R-P18 doreloc table, all classified +
  applied by the R-P19.2 pieces.
- **Link-apply proof**: cross-`ld -Ttext=0x80000000 -e _init` resolves every
  reloc → an EM_RISCV ET_EXEC entry 0x80000062, zero relocs remaining; the
  applied auipc/addi disassembles to `0x800010b8 <riscv64_boot_label>`.
- **CRIB**: the MD headers are the R-P17 BSD-cribbed set (NetBSD
  `sys/arch/riscv` psABI/register roles); the modlinkage/`_init/_fini/_info`
  shape is the illumos kmod convention.

### `/root/riscv-port/rp19/` contents
`machrel_riscv_insn.c`, `machrel_riscv_dispatch.c`, `machtarget_riscv.c`,
`machrel.riscv.c` + `reloc_riscv_table.h` (from R-P18), `config-riscv-sol2.h`
(updated), `rp19-milestone-check.sh` (sgs + uts proofs), `rp19-toolchain-check.sh`
(gcc + libgcc proofs), `rp19-sysroot-libgcc.sh` (idempotent bootstrap),
`uts/riscv64/{mod_riscv64.c, mod_riscv64.o, mod_riscv64.linked, sys/*.h}`,
the self-test binaries. Host toolchain:
`toolchain-sol/` (riscv64-unknown-solaris2.11 gcc + libgcc.a + bin symlinks),
`sysroot-riscv-sol/usr/include/sys/*.h`. Repo copies under `src/riscv/sgs/`,
`src/riscv/gcc/`, `src/riscv/uts/riscv64/`, `src/riscv/rp19-*.sh`.

### Next: R-P20
1. Fold the standalone `machrel_riscv_insn.c` + `machrel_riscv_dispatch.c` +
   `machtarget_riscv.c` into a real `usr/src/cmd/sgs/libld/common/machrel.riscv.c`
   against the gate `_libld.h` `Rel_desc`/`Target` types, and add the
   `%pcrel_hi`/`%pcrel_lo` pairing + GOT/PLT slot allocation the classification
   flags mark (the scaffolding this bootstrap deferred).
2. Grow the bootstrap sysroot toward a real one: build illumos csu
   (crt1/crti/crtn) for riscv64 and the minimal libc headers so
   `all-target-libgcc` completes fully (incl. the Solaris gmon/unwind extras)
   and shared objects link.
3. Cross-compile a larger uts/riscv64 unit (locore/genassym or a real driver)
   through the retargeted toolchain + the folded sgs machrel, toward a linkable
   `unix`/`genunix` in the gate layout.

---

## R-P18 — the R1 hard part: reloc coverage + the solaris triple

Three concrete sub-tasks, all landed with re-runnable proofs. Substrate: fred
v3 (root@52.88.62.49), the R-P17 toolchain (`riscv64-unknown-elf` binutils
2.44 + gcc 14.3.0) + the 58-entry `sys/elf_riscv.h`.

### R-P18.1 krtld/sgs `doreloc.c` reloc_table 12 -> 58 — DONE
- `src/riscv/uts/krtld/doreloc.c`: `reloc_table[R_RISCV_NUM]` grown from the
  12 dynamic relocs (stopped at `R_RISCV_TLS_TPREL64`) to the FULL 58-entry
  psABI table (0..57). Each entry carries `re_fsize` + `FLG_RE_*`. Data relocs
  (32/64/RELATIVE/JUMP_SLOT, TLS *64, ADD/SUB/SET 8..64, SUB6, 32_PCREL) are
  flat byte stores (real sizes, added to the `do_reloc()` value switch);
  RISC-V instruction-field relocs (BRANCH/JAL/CALL/CALL_PLT/*_HI20/*_LO12_*/
  RVC_*) + link-time markers (RELAX/ALIGN/*_ADD/GNU_VT*) are `FLG_RE_NOTSUP`
  size 0 (handled by the link-editor's instruction-field path, never the flat
  do_reloc byte writer).
- `src/riscv/uts/krtld/elf_riscv.h`: `R_RISCV_NUM` 12 -> 58 + the full type
  defines (BRANCH(16)..32_PCREL(57)), so `reloc_table[rtype]` is in-bounds for
  the CALL_PLT(19)/HI20(26)/LO12_I(27)/RELAX(51) that gcc actually emits (the
  old 12-entry table OOB-read on all four).
- **CRIB**: sizes/pc_relative/special-fn per reloc from binutils-2.44
  `bfd/elfxx-riscv.c` howto_table[] (extracted on the node); reloc numbers +
  the NOTREL/NOTSUP split convention from the existing illumos 12-entry table +
  the RISC-V psABI "Calculation" column.

### R-P18.2 gcc `riscv64-unknown-solaris2.11` triple — DONE (config + configures)
- `config.sub`: NO CHANGE — stock gcc-14.3.0 already canonicalizes
  `riscv64-unknown-solaris2.11` cleanly (proven, rc=0): both `riscv64` and
  `solaris2` are known, the combination validates.
- `gcc/config.gcc`: added the `riscv*-*-solaris2* | riscv*-*-illumos2*)` stanza
  (before `loongarch*-*-linux*`), wiring the sol2 tm_file chain
  `elfos.h ${cpu_type}/sysv4.h riscv/elf.h riscv/sol2.h ${cpu_type}/sol2.h`,
  `tmake_file += riscv/t-riscv t-sol2 riscv/t-sol2`,
  `native_system_header_dir=/usr/include`, `with_tls=trad`, forced
  `.init_array`. Delta documented in `rp18/config.gcc.riscv-solaris.md`.
- `gcc/config/riscv/sol2.h` (`rp18/config-riscv-sol2.h`): arch-solaris tm
  header — `TARGET_SUN_TLS`, undef the Newlib LIB/STARTFILE/ENDFILE from
  riscv/elf.h (the common sol2.h supplies the Solaris crt1/crti/crtn model),
  `elf64lriscv` ld emulation, ARCH64_SUBDIR "64".
- `gcc/config/riscv/t-sol2`: 64-bit-only, no-multilib stub.
- **PROOF** (`rp18/gcc-triple-proof.txt`): `configure
  --target=riscv64-unknown-solaris2.11` rc=0 AND `make configure-gcc` rc=0 —
  the gcc subdir's resolved tm_file chain contains exactly
  `elfos.h -> riscv/sysv4.h -> riscv/elf.h -> riscv/sol2.h -> config/sol2.h`,
  and `configargs.h` records the solaris triple. config.gcc fully accepts +
  elaborates the target.
- **BUILD FIXES FOUND + APPLIED** (two config.gcc corrections):
  (a) first `all-gcc` failed at `s-gtype` with "No rule to make target
  config/riscv/sysv4.h" -- `${sol2_tm_file_head}` is `elfos.h
  ${cpu_type}/sysv4.h` and riscv ships no `config/riscv/sysv4.h`; fixed by
  naming `elfos.h` directly (riscv/elf.h + elfos.h cover the SVR4/ELF base).
  (b) second `all-gcc` failed at `s-gtype` with `config/riscv/sol2.h specified
  more than once` -- `${sol2_tm_file_tail}` is `${cpu_type}/sol2.h sol2.h`, so
  the stanza's explicit `riscv/sol2.h` was a duplicate; dropped it. Final
  stanza tm_file: `elfos.h ${tm_file} riscv/elf.h ${sol2_tm_file_tail}`.
  `build/gcc-sol-cfg3/` clears configure + s-gtype with 0 errors and is
  compiling the riscv backend / cc1.
- **LONG POLE** (running, not gating this phase): the full `make all-gcc`
  rebuild-as-solaris (log `logs/gcc-sol-allgcc3.log`). libgcc needs a Solaris
  sysroot (crt + /usr/include) that does not exist yet; `all-gcc` (cc1 +
  prereqs) is compiling. R-P19 finishes libgcc once the first crt/headers exist.
- **CRIB**: the stanza shape from gcc-14.3.0's own `riscv*-*-freebsd*` /
  `riscv*-*-linux*` + the `x86_64-*-solaris2*` / `sparc*-*-solaris2*` arch
  stanzas; `riscv/sol2.h` from the richlowe/gcc arm64-gate `aarch64/sol2.h`
  pattern (the existing solnix aarch64-unknown-solaris2.11 target) + gcc
  `i386/sol2.h`.

### R-P18.3 Solaris ld (sgs) `R_RISCV_*` — DONE
- `src/riscv/sgs/machrel.riscv.c` + `reloc_riscv_table.h`: the standalone
  EM_RISCV sgs/libld reloc CLASSIFICATION table (58 entries) — the sgs-side
  companion to doreloc's byte-store table. Per reloc: GOT / PLT / PC-relative /
  TLS / instruction-field / link-time-marker flags + container size, so libld
  routes CALL_PLT (PLT), GOT_HI20 (GOT), PCREL_* (pcrel instruction field),
  RELAX (link-time marker) correctly instead of faulting on unclassified types.
  In the gate this becomes `usr/src/cmd/sgs/libld/common/machrel.riscv.c`.
- `src/riscv/uts/krtld/kobj_convrelstr.c`: `conv_reloc_RISCV_type()` extended
  from 6 names to all 58 — the reloc-name mapping sgs `ld` + krtld use for
  diagnostics. Before, CALL_PLT/HI20/LO12_I/RELAX printed as bare integers.
- **CRIB**: reloc GOT/PLT/PCREL/TLS/instruction-field classification from
  binutils-2.44 `bfd/elfxx-riscv.c` (pc_relative + special_function) +
  `bfd/elfnn-riscv.c` relocate_section dispatch + the RISC-V psABI; names from
  binutils/psABI; the `Rel_entry`/`FLG_RE_*` shape from the illumos sgs
  convention.

### R-P18.4 end-to-end reloc proof — PASS (`rp18/rp18-reloc-check.sh`, re-runnable)
Compiles C on the R-P17 cross gcc; it emits `R_RISCV_CALL_PLT(19)`,
`R_RISCV_HI20(26)`, `R_RISCV_LO12_I(27)`, `R_RISCV_RELAX(51)` (all beyond the
old 12). The script then proves each is (1) in-bounds in the 58-entry doreloc
table [old table OOB], (2) named by `conv_reloc_RISCV_type()` [old stub: 3 of 4
bare numbers], (3) classified by the sgs machrel table (CALL_PLT=PLT,
GOT_HI20=GOT, PCREL_HI20=pcrel, RELAX=link-time marker). `ALL R-P18 RELOC
PROOFS PASSED`.

### `/root/riscv-port/rp18/` contents
`doreloc.c`, `elf_riscv.h` (krtld, R_RISCV_NUM=58), `kobj_convrelstr.c`,
`machrel.riscv.c`, `reloc_riscv_table.h`, `config-riscv-sol2.h`,
`config.gcc.riscv-solaris.md`, `gcc-triple-proof.txt`, `rp18-reloc-check.sh`
(+ `verify.c`/`verify_names.c`/`verify_sgs.c`). Repo copies under
`src/riscv/uts/krtld/`, `src/riscv/sgs/`, `src/riscv/gcc/`.

### Next: R-P19
1. Finish the `make all-gcc` solaris-triple compiler build (log
   `logs/gcc-sol-allgcc.log`); then bootstrap a minimal riscv64 Solaris sysroot
   (crt1/crti/crtn + a stub `/usr/include`) so `make all-target-libgcc`
   completes and `-dumpmachine` = `riscv64-unknown-solaris2.11`.
2. Wire `machrel.riscv.c` + `reloc_riscv_table.h` into a real
   `usr/src/cmd/sgs/libld` mach descriptor (EM_RISCV dispatch) + implement the
   RISC-V instruction-field relocation encoders (B/J/U/I/S-type + RVC + the
   PCREL_HI20/LO12 pair fixup) that the `FLG_RE_INSREL` entries defer to.
3. Splice `sys/isa_defs.h` + `sys/machtypes.h` into a real `uts/riscv64` gate
   tree and cross-compile a first illumos-flavored riscv64 object with the
   solaris triple, linking it through the extended reloc handling.

---

## R-P17 and earlier (history)

## 1. Cross toolchain — BINUTILS + GCC stage-1 BUILT; EM_RISCV + reloc-coverage PROVEN.

### binutils 2.44 `--target=riscv64-unknown-elf` — DONE (~4 min)
- Source: ftp.gnu.org/gnu/binutils/binutils-2.44.tar.xz, sha256
  `ce2017e059d63e67ddb9240e9d4ec49c2893605035cd60e92ad53177f4377237` (verified).
- Built with the native OI gcc 14.3.0, `--disable-nls --disable-werror
  --disable-gdb --disable-sim --with-system-zlib`.
- Installed at `/root/riscv-port/toolchain/bin/riscv64-unknown-elf-{as,ld,
  readelf,objdump,objcopy,nm,ar,ranlib,strip,...}` (16 tools).

### EM_RISCV proof — PASS (the R1 milestone's binutils half)
`/root/riscv-port/psabi-reloc-check.sh` (runnable, re-runs the whole proof):
- cross-**as** `-march=rv64gc -mabi=lp64d` assembles a .o →
  `readelf -h` Machine = **RISC-V**, ELF64 LSB; raw `e_machine = 243`
  (**EM_RISCV**), confirmed independently by the host's own readelf.
- cross-**ld** links it → EXEC, Machine **RISC-V**, entry 0x80000000.
- objdump disassembles rv64gc incl. compressed insns + `ecall`.
- Result line: `PASS: cross-as + cross-ld produce EM_RISCV (243) objects`.

### gcc 14.3.0 stage-1 (`riscv64-unknown-elf`, rv64gc/lp64d) — DONE (~26 min)
- Source: ftp.gnu.org/gnu/gcc/gcc-14.3.0/gcc-14.3.0.tar.xz (xz-integrity verified;
  extracts to BASE-VER 14.3.0). `contrib/download_prerequisites` pulled
  gmp-6.2.1/mpfr-4.1.0/mpc-1.2.1/isl-0.24 (all OK).
- `--without-headers --with-newlib --enable-languages=c --disable-multilib
  --with-arch=rv64gc --with-abi=lp64d --disable-shared --disable-threads`.
- **illumos break hit + fixed** (the exact one design-riscv-port.md §2.3
  documents): gcc 14's in-tree **gettext** fails on illumos (gnulib
  `getlocalename_l` conflict). Fix applied: stripped the in-tree `gettext`
  symlink AND neutered the top-level Makefile `*-gettext` targets to no-ops
  (`--disable-nls` cross cc does not need gettext; `all-gcc`'s only direct prereq
  is `configure-gcc`). Rebuild via `rebuild-gcc.sh` then completed cleanly.
- **Installed**: `/root/riscv-port/toolchain/bin/riscv64-unknown-elf-gcc`
  (`-dumpmachine` = `riscv64-unknown-elf`, GCC 14.3.0) + `libgcc.a` built for
  `riscv64-unknown-elf/14.3.0` (the target backend compiled its own runtime =
  the backend works). Full toolchain 968 MB.
- **Reloc-coverage proof — PASS**: `psabi-reloc-check.sh` compiles C on the cross
  gcc, `objdump -dr`s the object, and asserts EVERY emitted `R_RISCV_*` is
  defined in `sys/elf_riscv.h`. Emitted (rv64gc, TLS LE): `R_RISCV_CALL_PLT,
  R_RISCV_RELAX, R_RISCV_TPREL_ADD, R_RISCV_TPREL_HI20, R_RISCV_TPREL_LO12_I,
  R_RISCV_TPREL_LO12_S` — all covered. Result: `PASS: every gcc-emitted R_RISCV_*
  is defined in sys/elf_riscv.h` / `ALL CHECKS PASSED`. Log:
  `artifacts/riscv-port/rp17/proof.log`.

---

## 2. illumos riscv64 MD headers (BSD-cribbed) — WRITTEN + syntax-checked

New under `src/riscv/uts/sys/` (persisted to host `/root/riscv-port/portsrc/`):

| file | what | crib provenance |
|------|------|-----------------|
| `sys/elf_riscv.h` | the **COMPLETE** RISC-V ELF psABI reloc set (0..57, `R_RISCV_NUM=58`) + ELF64 PLT/GOT machine defines. Replaces the n-hys fork's 12-entry table (which real gcc output overruns). | NetBSD `sys/arch/riscv/include/elf_machdep.h` (psABI reloc numbers are OS-independent) reconciled with GNU/binutils names |
| `sys/isa_defs.h` | the riscv64 stanza for `<sys/isa_defs.h>` — LP64D, `_LITTLE_ENDIAN`, alignment set, `_CHAR_IS_SIGNED`, `_ALIGNMENT_REQUIRED=1`, no `_MULTI_DATAMODEL`. The arch-selection block the gate must grow (like the `__amd64`/`__aarch64` stanzas). | RISC-V psABI + illumos sibling-arch stanzas; endianness/elfsize cross-checked vs NetBSD elf_machdep.h |
| `sys/machtypes.h` | `lock_t`, `label_t` (setjmp save area: ra/sp/gp/tp/s0-s11 = 16 slots), NCPU/MAXCPU. | NetBSD `reg.h` register-role block (calling convention is OS-independent) |

**Why elf_riscv.h matters (empirically shown):** a `gcc -c` on this port's own
cross toolchain emits `R_RISCV_CALL_PLT(19)`, `R_RISCV_PCREL_HI20(23)`,
`R_RISCV_PCREL_LO12_I(24)`, `R_RISCV_RELAX(51)` — **none** in the n-hys
12-reloc set. The Solaris link-editor (sgs) and krtld `do_reloc()` must know the
full table; this header supplies it. Static asserts (R_RISCV_NUM==58,
CALL_PLT==19, PCREL_HI20==23, RELAX==51, JMP_SLOT alias) PASS.

Checks run + PASS on host:
- `gcc -E -D__riscv -D__riscv_xlen=64 sys/isa_defs.h` → preprocess OK.
- `gcc -fsyntax-only relchk.c` (the elf_riscv static asserts) → PASS.
- `psabi-reloc-check.sh` → EM_RISCV proof PASS (reloc-coverage SKIP until gcc).

## 3. BSD reference mirror — `src/riscv/bsd-ref/netbsd/`

Fetched NetBSD-current `sys/arch/riscv/include/{elf_machdep,reg,mcontext,frame,
asm}.h` as reference-only crib sources (not compiled, not shipped), with a
`README.md` mapping each illumos MD file to its BSD crib. **TODO (like the
pending NetBSD-drm mirror):** obtain a pinned NetBSD-current `sys/arch/riscv`
mirror as the authoritative reference; FreeBSD `sys/riscv` is the secondary
cross-check.

---

## 4. What R-P1..R-P16 already achieved (context — DONE, in the design doc)

The kernel bring-up is remarkably far along (all under QEMU virt via the
`pkgsCross.riscv64-embedded` bare-metal toolchain, sources in `src/riscv/uts/`):
- R-P2 first `unix` S-mode banner under OpenSBI; R-P3 trap+Sv39+timer; R-P4
  SMP(HSM)+cyclic clock+PLIC+high-VA hat; R-P5 page_t/kmem/callout/dispatcher;
  R-P6..R-P12 virtio+root-mount+fork/exec/wait+shell+signals+pipes+writable FS;
  R-P13 AIA(APLIC+IMSIC); R-P14/R-P15 SpaceMiT K1 board bring-up (dw-apb-uart,
  SDHCI, flashable U-Boot→OpenSBI→solnix image); R-P16 runtime board-detect
  (ONE image boots qemu-virt AND physical K1).
- R-P16-prestage imported n-hys CDDL sources (krtld reloc engine, CMO, FDT
  of_utils, FPU ctxop, EMAC template) — `src/riscv/uts/R-P16-IMPORT-MANIFEST.md`.

## 5. QEMU-virt substrate (from design-sparc-riscv-qemu.md + design-riscv-port.md)
- `qemu-system-riscv64 -machine virt` under OpenSBI is the proven boot substrate
  (R-P2..R-P16 all gate on it). The bare-metal bring-up toolchain is nixpkgs
  `pkgsCross.riscv64-embedded` (riscv64-none-elf). The NEW `riscv64-unknown-elf`
  toolchain here (built from source on the illumos host) is the seed that R1
  re-targets to `riscv64-unknown-solaris2.11` once a sysroot exists.

---

## Next phase + how to resume

**R-P18 (toolchain target retarget) — the R1 hard part still open:**
1. Add the `riscv64-unknown-solaris2.11` OS stanza to `config.gcc`/`config.sub`
   (crib the aarch64-solaris config from richlowe/gcc) — this is the real R1
   toolchain-target work; `riscv64-unknown-elf` here is the proven starting point.
2. Teach the **Solaris link-editor (sgs)** `R_RISCV_*` relocs using the full
   table in `sys/elf_riscv.h` + the n-hys `krtld/doreloc.c` reloc engine.
   CONCRETE GAP FOUND: n-hys's `reloc_table[R_RISCV_NUM]` in
   `src/riscv/uts/krtld/doreloc.c` has only the 12 dynamic relocs and STOPS at
   `R_RISCV_TLS_TPREL64`; indexing `reloc_table[rtype]` for the CALL_PLT(19) /
   PCREL_HI20(23) / RELAX(51) that gcc emits is an OUT-OF-BOUNDS read. R-P18 must
   grow that table to the full 58 entries (formulas in the BSD `nb_elf_machdep.h`
   comments) and bump the local `krtld/elf_riscv.h` `R_RISCV_NUM` from 12 to 58
   to match `sys/elf_riscv.h`.
3. Splice the `sys/isa_defs.h` riscv64 stanza + `sys/machtypes.h` into a real
   `uts/riscv64` gate tree (they compile standalone now).

**Resume the toolchain build:**
```
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
ssh root@52.88.62.49
cd /root/riscv-port
./psabi-reloc-check.sh              # re-run the EM_RISCV proof
tail -f logs/gcc-build2.log          # gcc stage-1 progress
./rebuild-gcc.sh                     # (idempotent) finish gcc if interrupted
```

## Persisted files
- Host `/root/riscv-port/`: `toolchain/` (binutils installed), `build/`,
  `src/` (binutils+gcc tarballs+trees), `logs/`, `proof/`, `portsrc/` (the MD
  headers), `bsd-ref/netbsd/` (crib sources), `build-binutils.sh`,
  `build-gcc.sh`, `rebuild-gcc.sh`, `psabi-reloc-check.sh`, this `STATUS.md`.
- Repo `src/riscv/uts/sys/{elf_riscv,isa_defs,machtypes}.h`,
  `src/riscv/bsd-ref/{README.md,netbsd/*.h}` — for the orchestrator's commit.
