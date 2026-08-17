/*
 * setjmp.h -- RISC-V (riscv64) jmp_buf + setjmp/longjmp for the solnix libc.
 * jmp_buf holds the psABI callee-saved set: ra, sp, s0..s11 (14 integer
 * slots, indices 0..13) followed by fs0..fs11 (12 double slots, 14..25).
 * See port/setjmp.S for the save/restore.  This reduced libc has no signal
 * mask, so sigsetjmp/siglongjmp alias setjmp/longjmp (savemask ignored).
 */
#ifndef _SETJMP_H
#define _SETJMP_H

#define _JBLEN 26		/* 14 integer + 12 fp uint64 slots */

typedef unsigned long jmp_buf[_JBLEN];
typedef unsigned long sigjmp_buf[_JBLEN];

extern int  setjmp(jmp_buf);
extern void longjmp(jmp_buf, int) __attribute__((__noreturn__));
extern int  _setjmp(jmp_buf);
extern void _longjmp(jmp_buf, int) __attribute__((__noreturn__));

/* no signal mask in this reduced libc: sigsetjmp/siglongjmp == setjmp/longjmp */
#define sigsetjmp(env, savemask)  setjmp(env)
#define siglongjmp(env, val)      longjmp((env), (val))

#endif /* _SETJMP_H */
