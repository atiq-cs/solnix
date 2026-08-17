/* solnix: <sys/prctl.h> shim. ROCclr os_posix.cpp uses it only for
   prctl(PR_SET_NAME, name) -- cosmetic thread naming. illumos has no prctl;
   define PR_SET_NAME and a no-op prctl so the call compiles + degrades to a
   no-op (thread names are a debugging nicety, not a compute path). */
#ifndef SOLNIX_SYS_PRCTL_H
#define SOLNIX_SYS_PRCTL_H
#define PR_SET_NAME 15
static inline int prctl(int op, ...) { (void)op; return 0; }
#endif
