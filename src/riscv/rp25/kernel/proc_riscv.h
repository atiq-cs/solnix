/*
 * proc_riscv.h -- R-P25 riscv64 userland-process seam: the user address space,
 * the minimal ELF loader, and the U-mode entry primitive.
 *
 * CRIB PROVENANCE: the "user AS shares the kernel high half, has its own leaf
 * tables for the user segments" split is the illumos hat as_t / i86pc kernel
 * vs. user hat separation + the RISC-V privileged spec (satp per-AS, kernel
 * mappings global); the ELF PT_LOAD walk is the illumos exec elf mapelfexec /
 * BSD exec_elf; the "sret to U with sstatus.SPP=0 + a user stack holding
 * argc/argv/envp/auxv" is the illumos exec_args / lwp_rtt handoff + the RISC-V
 * privileged spec sret semantics + the psABI program-startup stack layout.
 */
#ifndef	_RP25_PROC_RISCV_H
#define	_RP25_PROC_RISCV_H

#ifdef __cplusplus
extern "C" {
#endif

/* the user process image, built by exec_user() from the embedded ELF. */
struct uproc {
	unsigned long	u_satp;		/* user address space (satp value) */
	unsigned long	u_entry;	/* user entry VA (_start) */
	unsigned long	u_sp;		/* initial user sp (argc/argv/envp/auxv) */
	unsigned long	u_kstack_top;	/* kernel trap stack for this lwp */
};

/* build a fresh user AS + map the embedded static ELF + a user stack. */
extern int exec_user(struct uproc *up);

/* enter U-mode: sret to up->u_entry with sp=up->u_sp under up->u_satp. */
extern void rv_user_enter(struct uproc *up);

/* set sscratch (kernel trap stack top) before entering U-mode. */
extern void rv_set_sscratch(unsigned long v);

/* the embedded userland ELF image (build-kernel embeds hello_user). */
extern const unsigned char user_elf_start[];
extern const unsigned char user_elf_end[];

/* HAT-user: map one 4 KiB user page (leaf, PTE_U) into a user root table. */
extern int hat_user_map(unsigned long *root, unsigned long va,
    unsigned long pa, unsigned long perms);

/* build a fresh user root L2 sharing the kernel high half; returns root PA. */
extern unsigned long *hat_user_new(void);

#ifdef __cplusplus
}
#endif

#endif	/* _RP25_PROC_RISCV_H */
