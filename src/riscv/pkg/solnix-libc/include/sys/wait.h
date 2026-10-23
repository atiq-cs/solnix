/*
 * newlib's <sys/wait.h> lacks wait3. In the solnix kernel wait options are
 * IGNORED (uts/uproc.c proc_waitpid): WNOHANG blocks. See glue.c waitpid.
 */
#include_next <sys/wait.h>
#ifndef _SOLNIX_SYS_WAIT_EXTRA
#define	_SOLNIX_SYS_WAIT_EXTRA
struct rusage;
pid_t wait3(int *, int, struct rusage *);
#endif
