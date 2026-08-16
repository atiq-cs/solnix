/*
 * systrap.h -- the riscv64 illumos syscall trap idiom for the solnix libc.
 *
 * The kernel's rv_syscall dispatcher (uts riscv64) uses the illumos syscall
 * ABI: a7 = syscall number, a0..a5 = arguments, result in a0.  A negative a0
 * on return is -errno (the reduced SunOS error-return convention); the libc
 * wrappers negate it into the global errno and return -1.
 *
 * CRIB PROVENANCE: the SYSTRAP macro shape (load the trap number, ecall,
 * result in a0) is the illumos libc SYSTRAP idiom (usr/src/lib/libc/<isa>/
 * sys) reduced to inline asm; the SYS_* numbers match the kernel's
 * <sys/syscall.h>-style table in main.c rv_syscall.
 */
#ifndef _SYS_SYSTRAP_H
#define _SYS_SYSTRAP_H

#define SYS_exit	1
#define SYS_read	3
#define SYS_write	4
#define SYS_open	5
#define SYS_close	6
#define SYS_brk		17
#define SYS_stat	18
#define SYS_lseek	19
#define SYS_getpid	20
#define SYS_fstat	28
#define SYS_execve	59
#define SYS_wait	107
#define SYS_mmap	115
#define SYS_fork	142
#define SYS_getcwd	223
#define SYS_uname	224
#define SYS_kill	232
#define SYS_pipe	235
#define SYS_mkdir	236
#define SYS_getdents	237
#define SYS_dup		241
#define SYS_dup2	242
#define SYS_unlink	244
#define SYS_rename	245
#define SYS_mount	246
#define SYS_chdir	247
#define SYS_waitpid	248
#define SYS_rmdir	252

static inline long
__systrap0(long nr)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0");
	__asm__ __volatile__("ecall" : "=r"(a0) : "r"(a7) : "memory");
	return (a0);
}

static inline long
__systrap1(long nr, long p0)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = p0;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a7) : "memory");
	return (a0);
}

static inline long
__systrap2(long nr, long p0, long p1)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = p0;
	register long a1 __asm__("a1") = p1;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a7), "r"(a1) : "memory");
	return (a0);
}

static inline long
__systrap3(long nr, long p0, long p1, long p2)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = p0;
	register long a1 __asm__("a1") = p1;
	register long a2 __asm__("a2") = p2;
	__asm__ __volatile__("ecall"
	    : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2) : "memory");
	return (a0);
}

#endif /* _SYS_SYSTRAP_H */
