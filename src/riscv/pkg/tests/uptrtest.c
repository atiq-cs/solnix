/*
 * uptrtest.c -- negative control for the syscall user-pointer range check.
 * Hands the kernel pointers into kernel slots and checks every call fails with
 * EFAULT instead of reading or writing kernel memory:
 *   write(1, KTEXT, 16)            -- would print kernel text
 *   read(pipe, K, 1)               -- would store into kernel memory
 *   pipe(K + 8)                    -- copyout of the fd pair
 *   nanosleep(K + 64, 0)           -- copyin of the timespec
 *   open(KTEXT, O_RDONLY)          -- copyin of the path string
 *   write(1, 0x7ffffff8, 16)       -- a range that crosses out of user slot 1
 * plus a positive control (the same calls on user buffers succeed).
 *   uptrtest [K]   K: hex kernel address of >= 128 zero bytes nothing uses
 * (the harness passes secondary_stacks at -smp 1). On a kernel WITHOUT the
 * check the calls go through: K must then be scratch, or the writes corrupt
 * the kernel. Default K is the kernel text, safe only on a checking kernel.
 *   prints UPTRTEST PASS or UPTRTEST FAIL <which>
 */
#include <stdio.h>
#include <stdlib.h>

#define	KTEXT	((char *)0x80200000UL)	/* the kernel image, slot 2 */
#define	EFAULT_K	14

/*
 * Raw ecall: the kernel must see exactly the pointer passed here. libc's
 * wrappers are not used because its fd layer stages some arguments (pipe's fd
 * pair) in user buffers, which would test libc, not the kernel.
 */
static long
ks(long n, long a0, long a1, long a2, long a3)
{
	register long r0 __asm__("a0") = a0;
	register long r1 __asm__("a1") = a1;
	register long r2 __asm__("a2") = a2;
	register long r3 __asm__("a3") = a3;
	register long r7 __asm__("a7") = n;

	__asm__ __volatile__("ecall" : "+r"(r0)
	    : "r"(r1), "r"(r2), "r"(r3), "r"(r7) : "memory");
	return (r0);
}

#define	K_openat	56
#define	K_pipe2		59
#define	K_read		63
#define	K_write		64
#define	K_nanosleep	101
#define	AT_FDCWD_K	(-100)	/* uproc.c AT_FDCWD_K */

static int fails;

static void
want_efault(const char *what, long r)
{
	if (r == -EFAULT_K)
		return;
	printf("UPTRTEST FAIL %s: r=%ld (want -%d EFAULT)\n", what, r,
	    EFAULT_K);
	fails++;
}

int
main(int argc, char **argv)
{
	char *k = argc > 1 ? (char *)strtoul(argv[1], 0, 16) : KTEXT;
	long ts[2] = { 0, 1000 };
	int pfd[2];
	char c = 'x';

	/* positive control: the same calls on real user buffers work */
	if (ks(K_pipe2, (long)pfd, 0, 0, 0) != 0 ||
	    ks(K_write, pfd[1], (long)&c, 1, 0) != 1 ||
	    ks(K_nanosleep, (long)ts, 0, 0, 0) != 0) {
		printf("UPTRTEST FAIL positive control\n");
		return (1);
	}
	want_efault("write(ktext)", ks(K_write, 1, (long)KTEXT, 16, 0));
	want_efault("read(k)", ks(K_read, pfd[0], (long)k, 1, 0));
	want_efault("pipe2(k+8)", ks(K_pipe2, (long)(k + 8), 0, 0, 0));
	want_efault("nanosleep(k+64)", ks(K_nanosleep, (long)(k + 64), 0, 0, 0));
	want_efault("openat(ktext)", ks(K_openat, AT_FDCWD_K, (long)KTEXT, 0, 0));
	want_efault("write(slot-crossing)", ks(K_write, 1, 0x7ffffff8L, 16, 0));
	/*
	 * Round trip through kernel memory: store a byte at k via read(pipe),
	 * then write(pipe) it from k and read it back into a user buffer. On a
	 * kernel without the check this prints LEAK: the kernel stored to and
	 * loaded from its own memory on a user's behalf.
	 */
	{
		char got = 0;

		c = 'K';
		(void) ks(K_write, pfd[1], (long)&c, 1, 0);
		(void) ks(K_read, pfd[0], (long)&got, 1, 0);	/* drain 'x' */
		(void) ks(K_write, pfd[1], (long)&c, 1, 0);
		if (ks(K_read, pfd[0], (long)k, 1, 0) == 1 &&
		    ks(K_write, pfd[1], (long)k, 1, 0) == 1 &&
		    ks(K_read, pfd[0], (long)&got, 1, 0) == 1 && got == 'K') {
			printf("UPTRTEST LEAK kernel memory at %p written and "
			    "read back through syscalls\n", (void *)k);
			fails++;
		}
	}
	if (fails == 0)
		printf("UPTRTEST PASS\n");
	return (fails != 0);
}
