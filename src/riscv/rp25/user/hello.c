/*
 * hello.c -- the R-P25 static riscv64-solaris userland process.  A complete,
 * self-contained EM_RISCV ET_EXEC that the R-P25 kernel execs into a user
 * address space and runs in U-mode: it makes its OWN write(2) and exit(2)
 * syscalls (ecall, illumos riscv64 ABI: a7=nr, a0..a5=args) which the kernel
 * services in rv_syscall.  This is the first riscv64-solaris userland PROCESS.
 *
 * Linked with the R-P20 crt (crt1/crti/crtn) + the R-P22 libc_syscall.o; NO
 * dynamic linker.  It is the R-P22.2b static hello, given the R-P25 message.
 *
 * CRIB PROVENANCE: the freestanding write(2)/exit(2)-via-ecall body is the
 * R-P22 hello_static; the illumos write/exit trap numbers (SYS_write=4,
 * SYS_exit=1) are the native <sys/syscall.h>.
 */

typedef unsigned long size_t;
typedef long ssize_t;

extern ssize_t write(int, const void *, size_t);
extern void exit(int);

static size_t
slen(const char *s)
{
	size_t n = 0;
	while (s[n])
		n++;
	return (n);
}

int
main(int argc, char **argv, char **envp)
{
	static const char msg[] =
	    "hello from riscv64-solaris userland process\n";
	(void) argc; (void) argv; (void) envp;
	write(1, msg, slen(msg));
	return (0);
}
