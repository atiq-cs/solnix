/*
 * true.c -- R-P35.3: the /bin/true command.  Exits 0.  Proves the shell
 * fork+exec+wait path reaps a command's exit status (a shell can then test $?).
 */
#define	SYS_exit	1
static void exit(int s)
{
	register long a7 __asm__("a7") = SYS_exit;
	register long a0 __asm__("a0") = s;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a7) : "memory");
	for (;;)
		;
}
int main(int argc, char **argv, char **envp)
{
	(void) argc; (void) argv; (void) envp;
	exit(0);
	return (0);
}
