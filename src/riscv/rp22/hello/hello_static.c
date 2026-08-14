/*
 * hello_static.c -- a statically-linked riscv64-solaris hello that talks to
 * the (future) illumos riscv64 kernel through the write(2)/exit(2) syscall
 * stubs of the R-P22 minimal libc.  Linked with the R-P20 crt (crt1/crti/crtn)
 * + libc_syscall.o; NO dynamic linker, NO ld.so.1 -- so it is a complete,
 * self-contained EM_RISCV ELF64 ET_EXEC that runs the moment the riscv64
 * illumos kernel syscall path (R-P8/R-P9) is live.
 */

typedef unsigned long size_t;
typedef long ssize_t;

extern ssize_t write(int, const void *, size_t);
extern void exit(int);

static size_t slen(const char *s)
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
	    "hello from static riscv64-solaris (illumos write(2)/exit(2) ABI)\n";
	(void) argc; (void) argv; (void) envp;
	write(1, msg, slen(msg));
	return (0);
}
