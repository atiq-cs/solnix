/*
 * libc_start.c -- the C-level libc entry the crt1 _start tail-calls.  Captures
 * the environment vector into `environ` (so getenv works), runs the _init
 * (.init/.init_array constructors), calls main(argc, argv), and passes its
 * return value to exit() -- which runs the atexit hooks (coreutils registers
 * close_stdout) and flushes libc stdio before trapping SYS_exit.
 *
 * CRIB PROVENANCE: __libc_start_main's "stash environ, run ctors, call main,
 * exit(main(...))" body is the glibc/illumos libc program-startup contract
 * reduced to the pieces solnix has (no TLS setup, no __libc_csu_init array walk
 * beyond _init, no locale bootstrap).
 */
#include <stdlib.h>

extern char **environ;
extern int main(int argc, char **argv, char **envp);
extern void _init(void);	/* crti/crtn-bracketed .init constructors */

void
__libc_start(int argc, char **argv, char **envp)
{
	environ = envp;
	_init();
	exit(main(argc, argv, envp));
	/* NOTREACHED */
	for (;;)
		;
}
