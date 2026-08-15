/*
 * proc_riscv.h -- R-P25/R-P26 riscv64 process seam: the user address space,
 * the ELF loader, the U-mode entry primitive, and (R-P26) the saved kernel
 * context for the multiprocess dispatcher.
 *
 * CRIB PROVENANCE: the "user AS shares the kernel high half, has its own leaf
 * tables for the user segments" split is the illumos hat as_t / i86pc kernel
 * vs. user hat separation + the RISC-V privileged spec (satp per-AS, kernel
 * mappings global); the ELF PT_LOAD walk is the illumos exec elf mapelfexec /
 * BSD exec_elf; the "sret to U with sstatus.SPP=0 + a user stack holding
 * argc/argv/envp/auxv" is the illumos exec_args / lwp_rtt handoff + the RISC-V
 * privileged spec sret semantics + the psABI program-startup stack layout; the
 * struct rv_context (callee-saved + ra/sp + satp for rv_swtch) is the R-P5/
 * R-P24 riscv swtch context + the RISC-V LP64 callee-saved set.
 */
#ifndef	_RP25_PROC_RISCV_H
#define	_RP25_PROC_RISCV_H

#ifdef __cplusplus
extern "C" {
#endif

/* the user process image, built by exec_image() from an ELF. */
struct uproc {
	unsigned long	u_satp;		/* user address space (satp value) */
	unsigned long	u_root;		/* user Sv39 root table (PA == ptr) */
	unsigned long	u_entry;	/* user entry VA (_start) */
	unsigned long	u_sp;		/* initial user sp (argc/argv/envp/auxv) */
	unsigned long	u_kstack_top;	/* kernel trap stack for this lwp (R-P25) */
};

/* R-P26: the saved kernel context rv_swtch save/loads (mach_swtch.S offsets:
   c_ra=0, c_sp=8, c_s0..c_s11=16..104, c_satp=112). */
struct rv_context {
	unsigned long	c_ra;
	unsigned long	c_sp;
	unsigned long	c_s[12];	/* s0..s11 */
	unsigned long	c_satp;
};

/* build a fresh user AS + map an embedded ELF image + a user stack. */
extern int exec_image(struct uproc *up, const unsigned char *img);
/* R-P25 back-compat: exec the forker image (== exec_image(up, user_elf_start)). */
extern int exec_user(struct uproc *up);

/* enter U-mode: sret to up->u_entry with sp=up->u_sp under up->u_satp. */
extern void rv_user_enter(struct uproc *up);

/* set sscratch (kernel trap stack top) before entering U-mode. */
extern void rv_set_sscratch(unsigned long v);

/* the embedded userland ELF images (build-kernel embeds forker + execee). */
extern const unsigned char user_elf_start[];
extern const unsigned char user_elf_end[];
extern const unsigned char execee_elf_start[];
extern const unsigned char execee_elf_end[];

/* HAT-user: map one 4 KiB user page (leaf, PTE_U) into a user root table. */
extern int hat_user_map(unsigned long *root, unsigned long va,
    unsigned long pa, unsigned long perms);

/* build a fresh user root L2 sharing the kernel high half; returns root PA. */
extern unsigned long *hat_user_new(void);

/* R-P26 fork: copy every 4 KiB user leaf of src_root into dst_root (deep copy
   of the private user half; the shared kernel high half is already installed
   by hat_user_new). */
extern int hat_user_copy(unsigned long *dst_root, unsigned long *src_root);

/* R-P26 dispatcher: the scheduler loop (runs on the boot/kernel context). */
extern void rv_sched(void);
/* the asm shim a fresh proc context "returns" into (falls into the trap
   epilogue with sp = the proc's trap frame, sret's to U-mode). */
extern void rv_user_frame_ret(void);

#ifdef __cplusplus
}
#endif

#endif	/* _RP25_PROC_RISCV_H */
