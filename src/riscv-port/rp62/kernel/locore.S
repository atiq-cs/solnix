/*
 * locore.S -- illumos riscv64 machine-dependent kernel entry.
 *
 * R-P30 headline: the kernel is LINKED + EXECUTES at HIGH VA
 * (KERNEL_DMAP_BASE + 0x80200000).  It is LOADED at physical 0x80200000 (the
 * ELF LMA, where OpenSBI jumps the S-mode payload).  So _start runs FIRST at
 * PHYSICAL 0x80200000 in bare mode (satp=0), position-independently (medany
 * PC-relative addressing computes the PHYSICAL address of every high-linked
 * symbol, because runtime PC and link-time PC differ by exactly the same
 * KERNEL_DMAP_BASE offset that separates the symbol's physical and virtual
 * addresses).  _start:
 *
 *   mask S-mode interrupts, claim the boot hart, set a PHYSICAL gp+sp, zero
 *   BSS (physical writes), call hat_earlyboot() (builds the Sv39 boot tables:
 *   a low identity window to survive the satp flip + the kernel HIGH map +
 *   the direct-map + the DRAM window + MMIO -- but does NOT enable paging),
 *   write satp + sfence.vma (paging ON), then JUMP PC to the HIGH VA of
 *   _start_high.  From _start_high on, the kernel runs purely at high VA:
 *   reload gp+sp to the high link addresses, install stvec, call mlsetup ->
 *   main.  main() then DROPS the low identity map entirely (hat_drop_identity),
 *   so the kernel runs with ONLY the high R^X kernel map + the direct-map.
 *
 * S-MODE ENTRY CONTRACT (OpenSBI fw_dynamic -> S-mode payload on qemu virt):
 *   Privilege : Supervisor.  a0 = hartid, a1 = dtb (phys).  satp = 0 (bare).
 *   sstatus.SIE clear.  Entry runs at the PHYSICAL load address 0x80200000.
 *
 * CRIB PROVENANCE: the "run at the physical load address, build page tables,
 * enable paging, jump to the high-half virtual _start" trampoline is the Linux
 * arch/riscv/kernel/head.S relocate_enable_mmu + setup_vm idiom + the i86pc/
 * aarch64 boot-map-then-jump-to-KERNELBASE transition; the "mask ints, claim
 * boot hart via amoswap, set sp, clear BSS, install stvec, call mlsetup" shape
 * is the R-P2..R-P16 uts/riscv64 locore.S (this repo) + uts/i86pc/ml/locore.s;
 * the S-mode entry register contract + physical 0x80200000 payload address is
 * the OpenSBI + qemu-virt boot convention.
 */

#include "assym.h"

/* KERNEL_DMAP_BASE (mmu_riscv.h) -- the low->high VA offset. */
#define	DMAP_BASE	0xffffffc000000000

/* R-P57: max DTB bytes we copy out of BSS's way (qemu-virt's is ~6 KiB). */
#define	SAVED_DTB_MAX	(64 * 1024)

	.section .text.start, "ax", @progbits
	.globl	_start
	.type	_start, @function
_start:
	/* Enter with S-mode interrupts off per the contract; be explicit. */
	csrci	sstatus, 0x2		/* clear sstatus.SIE (bit 1) */
	csrw	sie, zero		/* mask all S-mode interrupt sources */
	csrw	sscratch, zero		/* R-P25: sscratch==0 while in the kernel */

	/*
	 * We run at PHYSICAL 0x80200000, paging OFF.  Set gp to the PHYSICAL
	 * __global_pointer$ (medany `la` computes PC-relative -> physical) so
	 * any gp-relative access in the C bootstrap resolves; reloaded to the
	 * HIGH gp in _start_high after paging is on.
	 */
.option push
.option norelax
	la	gp, __global_pointer$
.option pop

	/*
	 * Claim boot-hart status atomically.  Only the first hart to swap 1
	 * into hart_claimed proceeds; any others park.  Preserves a0/a1.
	 * (la gives the PHYSICAL address of hart_claimed -- correct pre-paging.)
	 */
	la	t0, hart_claimed
	li	t1, 1
	amoswap.w.aq t2, t1, (t0)
	bnez	t2, park

	/* Establish the boot stack (PHYSICAL, full-descending, 16-aligned). */
	la	sp, boot_stack_top
	andi	sp, sp, ~15

	/*
	 * R-P62: record the ACTUAL physical load address.  `la _start` is
	 * medany PC-relative, so with paging off it yields the physical address
	 * _start actually loaded at (whatever OpenSBI/u-boot placed us at).  The
	 * C boot path reads this to confirm the load base matches the link base
	 * (0x80200000) -- on the K1 the fw_payload must land the kernel there.
	 * `la boot_load_pa` is likewise physical here, so the store is to the
	 * real .data slot pre-paging.
	 */
	la	t0, _start
	la	t1, boot_load_pa
	sd	t0, 0(t1)

	/*
	 * R-P57: SAVE THE DTB before zeroing BSS.  The firmware passes the DTB
	 * pointer in a1 (phys); on qemu-virt it lands at ~0x82200000, which is
	 * INSIDE this kernel's BSS span -- so the BSS-zero loop below would wipe
	 * it.  Copy it now (paging off, identity: a1 is directly readable) into
	 * saved_dtb[], which lives in .data (NOT zeroed by the BSS loop).  Read
	 * the FDT header: magic @ +0 must be 0xd00dfeed (big-endian) and
	 * totalsize @ +4 (big-endian) is the byte count; cap to the buffer size.
	 * fdt_discover() then parses saved_dtb instead of the clobbered a1.
	 */
	beqz	a1, .Ldtb_done		/* no DTB pointer */
	lwu	t2, 0(a1)		/* raw magic word (little-endian load) */
	/* byte-swap t2 -> big-endian value in t3 */
	andi	t3, t2, 0xff
	slli	t3, t3, 24
	srli	t4, t2, 8
	andi	t4, t4, 0xff
	slli	t4, t4, 16
	or	t3, t3, t4
	srli	t4, t2, 16
	andi	t4, t4, 0xff
	slli	t4, t4, 8
	or	t3, t3, t4
	srli	t4, t2, 24
	andi	t4, t4, 0xff
	or	t3, t3, t4		/* t3 = magic in native order */
	li	t4, 0xd00dfeed
	bne	t3, t4, .Ldtb_done	/* not an FDT -- skip the copy */
	lwu	t2, 4(a1)		/* raw totalsize (little-endian load) */
	andi	t3, t2, 0xff
	slli	t3, t3, 24
	srli	t4, t2, 8
	andi	t4, t4, 0xff
	slli	t4, t4, 16
	or	t3, t3, t4
	srli	t4, t2, 16
	andi	t4, t4, 0xff
	slli	t4, t4, 8
	or	t3, t3, t4
	srli	t4, t2, 24
	andi	t4, t4, 0xff
	or	t3, t3, t4		/* t3 = totalsize (bytes) */
	li	t4, SAVED_DTB_MAX
	bgeu	t3, t4, 3f		/* cap totalsize to the buffer size */
	j	4f
3:	mv	t3, t4
4:
	la	t5, saved_dtb		/* phys dest (paging off) */
	mv	t6, a1			/* phys src */
	li	t0, 0			/* bytes copied */
5:	bgeu	t0, t3, 6f
	lbu	t1, 0(t6)
	sb	t1, 0(t5)
	addi	t5, t5, 1
	addi	t6, t6, 1
	addi	t0, t0, 1
	j	5b
6:
	/* record that a valid DTB was saved (store the copied length). */
	la	t5, saved_dtb_len
	sw	t3, 0(t5)
.Ldtb_done:

	/*
	 * Zero BSS ( __bss_start .. __bss_end ), 8 bytes at a time.  Done at
	 * PHYSICAL addresses (paging off) BEFORE building the page tables --
	 * the boot page tables live in BSS, so they must be zeroed before
	 * hat_earlyboot populates them.
	 */
	la	t0, __bss_start
	la	t1, __bss_end
1:	bgeu	t0, t1, 2f
	sd	zero, 0(t0)
	addi	t0, t0, 8
	j	1b
2:

	/*
	 * Build the Sv39 boot tables (physical addresses throughout) and get
	 * the satp value to install.  hat_earlyboot preserves nothing but the
	 * ABI-callee-saved set; a0/a1 (hartid/dtb) are caller-saved, so stash
	 * them in callee-saved s-regs across the call.
	 */
	mv	s0, a0			/* save hartid */
	mv	s1, a1			/* save dtb */
	call	hat_earlyboot		/* a0 = satp value (paging NOT yet on) */

	/*
	 * Enable paging: write satp (Sv39, boot root) + sfence.vma.  We are
	 * identity-mapped at the low physical window, so the fetch of the very
	 * next instruction still resolves at the current (physical) PC.
	 */
	csrw	satp, a0
	sfence.vma

	/* restore hartid/dtb for mlsetup. */
	mv	a0, s0
	mv	a1, s1

	/*
	 * Jump PC to the HIGH VA of _start_high.  `la` gives the PHYSICAL
	 * address of _start_high; add KERNEL_DMAP_BASE to get its canonical
	 * high VA (physical load addr + DMAP == high link addr).  jr there:
	 * from this instruction on, PC is high and the kernel runs at high VA.
	 */
	la	t0, _start_high
	li	t1, DMAP_BASE
	add	t0, t0, t1
	jr	t0

park:
	wfi
	j	park
	.size	_start, . - _start

	/*
	 * _start_high -- the kernel now executes at HIGH VA (paging on, PC in
	 * the canonical Sv39 high half).  Reload gp+sp to the HIGH link
	 * addresses (medany `la` now computes high, since PC is high), install
	 * the trap vector, and hand off to C (mlsetup -> main).  a0=hartid,
	 * a1=dtb are live.
	 */
	.align 2
	.globl	_start_high
	.type	_start_high, @function
_start_high:
.option push
.option norelax
	la	gp, __global_pointer$	/* HIGH gp now */
.option pop
	la	sp, boot_stack_top	/* HIGH stack now */
	andi	sp, sp, ~15
	mv	tp, a0			/* R-P32: tp = hartid (per-CPU id) */

	la	t0, _u_trap_entry	/* HIGH trap trampoline */
	csrw	stvec, t0

	call	mlsetup			/* does not return */
1:	wfi
	j	1b
	.size	_start_high, . - _start_high

	/*
	 * _secondary_start -- SMP: the entry OpenSBI's HSM hart_start jumps a
	 * SECONDARY hart to, in S-mode, bare (satp=0), running at its PHYSICAL
	 * load address.  a0 = hartid, a1 = the kernel satp value we passed to
	 * sbi_hart_start.  We install that satp (turning paging on for this
	 * hart), then jump to the HIGH VA of _secondary_high.
	 *
	 * CRIB PROVENANCE: an AP entry that turns on paging then jumps to the
	 * high-half virtual continuation is Linux secondary_start_sbi +
	 * relocate_enable_mmu; the S-mode bare-mode entry register contract
	 * (a0=hartid, a1=opaque) is the SBI HSM spec.
	 */
	.align 2
	.globl	_secondary_start
	.type	_secondary_start, @function
_secondary_start:
	csrci	sstatus, 0x2		/* clear sstatus.SIE */
	csrw	sie, zero		/* mask S-mode interrupt sources */
	csrw	sscratch, zero		/* sscratch==0 while in the kernel */

	/* turn paging on for this hart with the shared kernel satp (a1). */
	csrw	satp, a1
	sfence.vma

	/* jump to the HIGH continuation (a0=hartid preserved). */
	la	t0, _secondary_high
	li	t1, DMAP_BASE
	add	t0, t0, t1
	jr	t0
	.size	_secondary_start, . - _secondary_start

	.align 2
	.globl	_secondary_high
	.type	_secondary_high, @function
_secondary_high:
.option push
.option norelax
	la	gp, __global_pointer$	/* HIGH gp */
.option pop
	/*
	 * R-P61: per-hart stack.  a0 = hartid (0..7).  sp = secondary_stacks
	 * base + (hartid+1)*SECONDARY_STACK_SIZE (top-of-stack for this hart's
	 * slot), so up to 8 secondaries run concurrently without stack collision
	 * (the R-P28 single shared stack only ever held one live secondary).
	 */
	la	t0, secondary_stacks
	addi	t1, a0, 1		/* slot = hartid+1 */
	li	t2, 16384		/* SECONDARY_STACK_SIZE */
	mul	t1, t1, t2
	add	sp, t0, t1		/* top of this hart's 16 KiB slot */
	andi	sp, sp, ~15
	/*
	 * R-P31.1: we landed high on the transient boot root (which still
	 * carries the low identity that let us survive the initial satp flip).
	 * Switch NOW onto the primary's identity-FREE W^X kernel root: fetch its
	 * satp (a high-VA C call on the direct-map), csrw + sfence.vma.  The W^X
	 * root maps the kernel image (high) + the direct-map, so the fetch after
	 * the satp write resolves at the current high PC -- and from here this
	 * hart runs with NO identity map, exactly like the primary.  Preserve
	 * a0=hartid in s0 across the call (hat_wxroot_satp returns in a0).
	 */
	mv	s0, a0			/* save hartid across the call */
	call	hat_wxroot_satp		/* a0 = W^X root satp (0 if not ready) */
	beqz	a0, 2f			/* if unset, keep the boot root */
	csrw	satp, a0
	sfence.vma
2:
	mv	a0, s0			/* restore hartid */
	la	t0, _u_trap_entry
	csrw	stvec, t0
	call	secondary_main		/* enters the shared scheduler */
1:	wfi
	j	1b
	.size	_secondary_high, . - _secondary_high

	/*
	 * disp_ap_entry -- per-CPU dispatch AP entry: like _secondary_start but
	 * the high continuation lands in disp_secondary_main (the per-CPU
	 * dispatcher) instead of the shared-runq secondary_main.
	 */
	.align 2
	.globl	disp_ap_entry
	.type	disp_ap_entry, @function
disp_ap_entry:
	csrci	sstatus, 0x2
	csrw	sie, zero
	csrw	sscratch, zero
	csrw	satp, a1
	sfence.vma
	la	t0, disp_ap_high
	li	t1, DMAP_BASE
	add	t0, t0, t1
	jr	t0
	.size	disp_ap_entry, . - disp_ap_entry

	.align 2
	.globl	disp_ap_high
	.type	disp_ap_high, @function
disp_ap_high:
.option push
.option norelax
	la	gp, __global_pointer$
.option pop
	la	sp, secondary_stack_top
	andi	sp, sp, ~15
	/* R-P31.1: switch onto the identity-FREE W^X root (see _secondary_high). */
	mv	s0, a0			/* save hartid across the call */
	call	hat_wxroot_satp
	beqz	a0, 2f
	csrw	satp, a0
	sfence.vma
2:
	mv	a0, s0			/* restore hartid */
	la	t0, _u_trap_entry
	csrw	stvec, t0
	call	disp_secondary_main
1:	wfi
	j	1b
	.size	disp_ap_high, . - disp_ap_high

	/*
	 * sc_ap_entry -- R-P30.2 TS/RT class-scheduler AP entry: like
	 * disp_ap_entry but the high continuation lands in sc_secondary_main
	 * (the class dispatcher) so the secondary hart schedules from the shared
	 * TS/RT class runq.
	 */
	.align 2
	.globl	sc_ap_entry
	.type	sc_ap_entry, @function
sc_ap_entry:
	csrci	sstatus, 0x2
	csrw	sie, zero
	csrw	sscratch, zero
	csrw	satp, a1
	sfence.vma
	la	t0, sc_ap_high
	li	t1, DMAP_BASE
	add	t0, t0, t1
	jr	t0
	.size	sc_ap_entry, . - sc_ap_entry

	.align 2
	.globl	sc_ap_high
	.type	sc_ap_high, @function
sc_ap_high:
.option push
.option norelax
	la	gp, __global_pointer$
.option pop
	la	sp, secondary_stack_top
	andi	sp, sp, ~15
	/* R-P31.1: switch onto the identity-FREE W^X root (see _secondary_high). */
	mv	s0, a0			/* save hartid across the call */
	call	hat_wxroot_satp
	beqz	a0, 2f
	csrw	satp, a0
	sfence.vma
2:
	mv	a0, s0			/* restore hartid */
	la	t0, _u_trap_entry
	csrw	stvec, t0
	call	sc_secondary_main
1:	wfi
	j	1b
	.size	sc_ap_high, . - sc_ap_high

	/*
	 * proc_ap_entry / proc_ap_high -- R-P32.1: the AP entry for the REAL
	 * proc_t dispatcher on the secondary hart.  Like sc_ap_entry, but the
	 * high continuation sets tp = hartid (the per-CPU id cpuid() reads) and
	 * lands in proc_secondary_main, which runs rv_sched_cpu(hartid) against
	 * the SHARED proc runq -- so a real process forked on hart 0 can be
	 * dispatched on hart 1.
	 */
	.align 2
	.globl	proc_ap_entry
	.type	proc_ap_entry, @function
proc_ap_entry:
	csrci	sstatus, 0x2
	csrw	sie, zero
	csrw	sscratch, zero
	csrw	satp, a1
	sfence.vma
	la	t0, proc_ap_high
	li	t1, DMAP_BASE
	add	t0, t0, t1
	jr	t0
	.size	proc_ap_entry, . - proc_ap_entry

	.align 2
	.globl	proc_ap_high
	.type	proc_ap_high, @function
proc_ap_high:
.option push
.option norelax
	la	gp, __global_pointer$
.option pop
	la	sp, secondary_stack_top
	andi	sp, sp, ~15
	/* R-P31.1: switch onto the identity-FREE W^X root (see _secondary_high). */
	mv	s0, a0			/* save hartid across the call */
	call	hat_wxroot_satp
	beqz	a0, 2f
	csrw	satp, a0
	sfence.vma
2:
	mv	a0, s0			/* restore hartid */
	mv	tp, s0			/* R-P32: tp = hartid (per-CPU id) */
	la	t0, _u_trap_entry
	csrw	stvec, t0
	call	proc_secondary_main
1:	wfi
	j	1b
	.size	proc_ap_high, . - proc_ap_high

	/*
	 * wx_ap_entry / wx_ap_high -- R-P31.1 headline AP entry.  Identical bring-
	 * up to _secondary_start/_secondary_high (start physical on the boot-root
	 * identity trampoline, jump high, switch to the identity-FREE W^X root),
	 * but the high continuation lands in wx_secondary_main, which PROVES the
	 * secondary now runs purely high-VA with NO identity map (its running satp
	 * is the W^X root; a low identity read faults) and then drains the shared
	 * runq alongside the primary.
	 *
	 * CRIB PROVENANCE: Linux riscv secondary_start_sbi (AP enables paging then
	 * switches to the final identity-free root) + illumos mp_startup (AP
	 * installs the shared kernel hat).
	 */
	.align 2
	.globl	wx_ap_entry
	.type	wx_ap_entry, @function
wx_ap_entry:
	csrci	sstatus, 0x2
	csrw	sie, zero
	csrw	sscratch, zero
	csrw	satp, a1		/* boot root: survive the initial flip */
	sfence.vma
	la	t0, wx_ap_high
	li	t1, DMAP_BASE
	add	t0, t0, t1
	jr	t0
	.size	wx_ap_entry, . - wx_ap_entry

	.align 2
	.globl	wx_ap_high
	.type	wx_ap_high, @function
wx_ap_high:
.option push
.option norelax
	la	gp, __global_pointer$
.option pop
	la	sp, secondary_stack_top
	andi	sp, sp, ~15
	mv	s0, a0			/* save hartid across the call */
	call	hat_wxroot_satp		/* a0 = W^X root satp */
	beqz	a0, 2f
	csrw	satp, a0		/* switch to the identity-FREE W^X root */
	sfence.vma
2:
	mv	a0, s0			/* restore hartid */
	la	t0, _u_trap_entry
	csrw	stvec, t0
	call	wx_secondary_main
1:	wfi
	j	1b
	.size	wx_ap_high, . - wx_ap_high

	/*
	 * hart_claimed: boot-hart election flag.  In .data (init 0) so the BSS
	 * clear does not reset it after a hart has claimed.  .word matches
	 * amoswap.w.
	 */
	.section .data
	.align 2
	.globl	hart_claimed
hart_claimed:
	.word	0

	/*
	 * R-P62: boot_load_pa -- the ACTUAL physical address _start was loaded
	 * at, captured PC-relative in _start (paging off).  The kernel is LINKED
	 * at a fixed phys base (kernel.lds PADDR = 0x80200000) and, being a
	 * fully-linked non-PIE image (no R_RISCV_RELATIVE relocs; the
	 * solaris-target binutils has no -pie), its stored absolute pointers
	 * (vnode-ops vtables, dispatch tables) resolve to that link base -- so it
	 * MUST be loaded at 0x80200000.  The K1 DRAM starts at 0x0 but spans
	 * 8 GiB, so 0x80200000 is valid K1 DRAM; the K1 fw_payload/fw_dynamic
	 * places the kernel there (mk-fw-k1.sh / K1-MEMORY-MAP.md).  This global
	 * lets the C boot path READ the real load base OpenSBI handed us (not
	 * assume it) and compare it against the link base, so a mismatch is LOUD
	 * (a diagnostic) rather than a silent fault deep in boot.  .dword in
	 * .data (survives the BSS clear).
	 */
	.align 3
	.globl	boot_load_pa
boot_load_pa:
	.dword	0

	/*
	 * R-P57: saved_dtb -- a copy of the flattened device tree, taken in
	 * _start BEFORE the BSS clear (the firmware's DTB at ~0x82200000 lands
	 * inside this kernel's BSS and would otherwise be zeroed).  In .data so
	 * the BSS clear does not wipe it.  saved_dtb_len is the copied byte
	 * count (0 if no valid FDT was found in a1).  .byte 1 forces the buffer
	 * into PROGBITS .data (occupies file space, kept out of .bss).
	 */
	.align 3
	.globl	saved_dtb_len
saved_dtb_len:
	.word	0
	.align 3
	.globl	saved_dtb
saved_dtb:
	.byte	1
	.zero	SAVED_DTB_MAX - 1

	/* Boot stack: 16 KiB in BSS; boot_stack_top is the high end. */
	.section .bss
	.align 16
	.globl	boot_stack
boot_stack:
	.skip	16384
	.globl	boot_stack_top
boot_stack_top:

	/*
	 * SMP secondary stacks.  R-P28 had ONE 16 KiB stack (only one secondary
	 * was ever live at a time).  R-P61 gives 8 slots (indexed by hartid+1 in
	 * _secondary_high) so all 8 harts can run concurrently.  secondary_stack_top
	 * stays an alias for the top of the last slot for the single-secondary
	 * disp/sc/proc/wx ap-entries.
	 */
	.align 16
	.globl	secondary_stack
	.globl	secondary_stacks
secondary_stack:
secondary_stacks:
	.skip	16384 * 9		/* slot 0 unused (boot hart) + slots 1..8 */
	.globl	secondary_stack_top
secondary_stack_top:
