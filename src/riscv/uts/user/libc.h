/*
 * libc.h — solnix riscv64 minimal libc slice (R-P10 gate 2).
 *
 * This is the DECLARATIONS half of a genuine, separately-compiled libc for the
 * solnix riscv64 userland: the sources live in libc.c and are archived into
 * libc-riscv.a. Unlike the R-P9 header-only libu.h (every stub `static inline`,
 * recompiled into each program), R-P10 links each program against a real .a:
 * one crt0 (_start), one copy of the syscall stubs, malloc-over-brk, and a
 * small string/stdio set (write/read/printf/strlen/memcpy). This is the shape
 * of an illumos libc slice — the first freestanding libc on illumos-RISC-V.
 *
 * Syscall ABI matches kernel syscall.c (riscv Linux-ABI subset):
 *   a7 = number, a0..a5 = args, ecall, a0 = return (negative = -errno).
 */
#ifndef _LIBC_H
#define _LIBC_H

typedef unsigned long size_t;

/* Syscall numbers — must match kernel syscall.c. */
#define SYS_getpid  172
#define SYS_close   57
#define SYS_read    63
#define SYS_write   64
#define SYS_exit    93
#define SYS_brk     214
#define SYS_fork    220
#define SYS_execve  221
#define SYS_wait4   260
#define SYS_openat  56
#define SYS_cowreport     500
#define SYS_preemptreport 501

#define O_RDONLY 0

/* Raw syscall + thin POSIX-ish wrappers (defined in libc.c). */
long __sys(long n, long a0, long a1, long a2, long a3);
long write(int fd, const char *b, size_t n);
long read(int fd, char *b, size_t n);
int  open(const char *path, int flags);
int  close(int fd);
int  getpid(void);
int  fork(void);
int  execve(const char *path, char *const argv[], char *const envp[]);
int  waitpid(int pid, int *status, int opt);
void _exit(int status) __attribute__((noreturn));

/* string.h slice. */
size_t strlen(const char *s);
void  *memcpy(void *d, const void *s, size_t n);
void  *memset(void *d, int c, size_t n);
int    strcmp(const char *a, const char *b);

/* malloc over brk (bump allocator; free() is a no-op). */
void *malloc(size_t n);
void  free(void *p);

/* stdio slice: real printf (%s %d %u %x %c %%), puts, and a decimal helper. */
int  printf(const char *fmt, ...);
int  puts(const char *s);
void putdec(unsigned long v);

/* solnix diagnostics (kernel-side reports). */
void cowreport(void);
long preemptreport(void);
/* CPU burn loop, no syscalls (proves preemption slices two spinners). */
void spin(unsigned long n);

int main(int argc, char **argv);

#endif /* _LIBC_H */
