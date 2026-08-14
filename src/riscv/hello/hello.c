/*
 * hello.c -- the first riscv64-solaris userland program.
 *
 * Freestanding: no libc yet (the bootstrap sysroot has crt + headers only).
 * main() computes a value and returns it; crt1.s's _start passes that to the
 * exit(2) syscall.  The point is to prove the retargeted gcc + cross as/ld can
 * turn C source into a complete, valid riscv64 Solaris ELF executable that
 * links against the new csu crt objects and libgcc.
 */

int
main(int argc, char **argv, char **envp)
{
	/* exercise a call + some arithmetic so libgcc/relocs are pulled in */
	volatile int a = argc;
	int i, sum = 42;

	for (i = 0; i < 3; i++)
		sum += a * i;

	return (sum & 0x7f);		/* exit status */
}
