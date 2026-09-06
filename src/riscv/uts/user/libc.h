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
#define SYS_lseek   62
#define SYS_pipe2   59
#define SYS_dup3    24
#define SYS_sync    81
#define SYS_remount 502
#define SYS_kill    129
#define SYS_rt_sigaction 134
#define SYS_rt_sigreturn 139
#define SYS_setgid  144
#define SYS_setuid  146
#define SYS_getuid  174
#define SYS_cowreport     500
#define SYS_preemptreport 501
/* The scanout seam (docs/riscv64-scanout-seam.md): the /dev/fb node's ioctls
 * and the mmap that hands the compositor the framebuffer. */
#define SYS_ioctl   29
#define SYS_mmap    222
/*
 * poll(2). The riscv Linux ABI has no plain poll slot, only ppoll (73), so the
 * kernel takes 73 with poll's flat millisecond timeout (see kernel syscall.c).
 */
#define SYS_poll    73
#define SYS_clock_gettime 113
#define CLOCK_REALTIME  0
#define CLOCK_MONOTONIC 4    /* the illumos value */

/*
 * AF_UNIX sockets. A Wayland compositor is a UNIX-socket server before it is
 * anything else, so this is the syscall set that gates a compositor -- no IP
 * stack involved. sendmsg/recvmsg take a FLAT fd array rather than a struct
 * msghdr + cmsghdr chain: the cmsghdr walk belongs in libsocket (illumos puts it
 * in __xnet_sendmsg), not in the kernel.
 */
#define SYS_socket     198
#define SYS_socketpair 199
#define SYS_bind       200
#define SYS_listen     201
#define SYS_accept     202
#define SYS_connect    203
#define SYS_setsockopt 208
#define SYS_getsockopt 209
#define SYS_sendmsg    211
#define SYS_recvmsg    212

#define AF_UNIX      1
#define SOCK_STREAM  2
#define SOL_SOCKET   0xffff
#define SO_TYPE      0x1008

/*
 * sockaddr_un, the illumos shape: a 2-byte family then a 108-byte path. The
 * kernel's bind/connect read the path from offset 2, so this layout is ABI, not
 * convention.
 */
struct sockaddr_un {
	unsigned short sun_family;
	char sun_path[108];
};

#define O_RDONLY 0
#define O_WRONLY 0x1
#define O_RDWR   0x2
#define O_CREAT  0x40

/* mmap protection/flags. The device-mapping path ignores prot (the scanout
 * framebuffer is always shared read-write), but userland and any Rust FFI
 * binding still spell them out, so define the usual values. */
#define PROT_READ  0x1
#define PROT_WRITE 0x2
#define MAP_SHARED 0x1
#define MAP_PRIVATE 0x2
/*
 * MAP_ANON IS 0x100 ON illumos -- NOT Linux's 0x20. A Rust binary built with the
 * Linux value already tripped over this once here. The kernel refuses 0x20
 * explicitly rather than treating it as a file mapping, so the mistake is
 * diagnosable, but get it right on this side.
 */
#define MAP_ANON   0x100
#define MAP_ANONYMOUS MAP_ANON
#define MAP_FAILED ((void *)-1L)

/*
 * poll(2). struct pollfd is the POSIX shape (int fd; short events; short
 * revents) and IS the kernel ABI -- the kernel copyin/copyouts this array
 * directly, so the layout is contract, not convention.
 */
struct pollfd {
	int   fd;
	short events;
	short revents;
};

#define POLLIN     0x0001
#define POLLPRI    0x0002
#define POLLOUT    0x0004
#define POLLERR    0x0008
#define POLLHUP    0x0010
#define POLLNVAL   0x0020
#define POLLRDNORM 0x0040
#define POLLWRNORM POLLOUT

/* Signals (subset). */
#define SIGINT   2
#define SIGKILL  9
#define SIGCHLD  17
#define SIG_DFL  ((void (*)(int))0)
#define SIG_IGN  ((void (*)(int))1)

/* Raw syscall + thin POSIX-ish wrappers (defined in libc.c). */
long __sys(long n, long a0, long a1, long a2, long a3);
/* 6-argument form: mmap needs a4 (fd) and a5 (offset), which __sys cannot
 * reach. Kept separate so the common 4-arg path stays as cheap as it was. */
long __sys6(long n, long a0, long a1, long a2, long a3, long a4, long a5);
int  ioctl(int fd, int req, void *arg);
void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off);
/*
 * poll -- timeout in milliseconds; 0 = scan and return immediately, negative =
 * block until something is ready. Returns the number of ready descriptors, 0 on
 * timeout, -1 on error.
 */
int  poll(struct pollfd *fds, unsigned long nfds, int timeout);
/* Anonymous memory: fresh zeroed private pages. What every allocator wants. */
void *mmap_anon(size_t len);
/* gethrtime-equivalent for tests that must prove a poll actually blocked. */
unsigned long monotonic_ms(void);
long write(int fd, const char *b, size_t n);
long read(int fd, char *b, size_t n);
int  open(const char *path, int flags);
int  close(int fd);
int  getpid(void);
int  fork(void);
int  execve(const char *path, char *const argv[], char *const envp[]);
int  waitpid(int pid, int *status, int opt);
void _exit(int status) __attribute__((noreturn));

/* R-P11: signals, credentials, seekable I/O. */
long lseek(int fd, long off, int whence);
int  kill(int pid, int sig);
int  setuid(unsigned int uid);
int  setgid(unsigned int gid);
int  getuid(void);
void (*signal(int sig, void (*handler)(int)))(int);
int  sigaction_h(int sig, void (*handler)(int));

/* R-P12: pipes, fd duplication, on-disk FS sync/remount. */
int  pipe(int fds[2]);
int  dup2(int oldfd, int newfd);
int  sync_fs(void);
int  remount_fs(void);

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

/*
 * AF_UNIX socket wrappers. These are the shapes libsocket's __xnet_* entry
 * points sit directly on top of (see docs/riscv64-libc-rust-abi-gap.md).
 * sendmsg_fds/recvmsg_fds are deliberately NOT sendmsg(2)/recvmsg(2): they take
 * the flat fd array the kernel ABI uses, and a real libsocket wraps them with the
 * struct msghdr + cmsghdr walk.
 */
int  socket(int domain, int type, int protocol);
int  socketpair_un(int fds[2]);
int  bind_un(int fd, const char *path);
int  listen_un(int fd, int backlog);
int  accept_un(int fd);
int  connect_un(int fd, const char *path);
int  getsockopt_int(int fd, int level, int name, int *val);
long sendmsg_fds(int fd, const void *buf, unsigned long n, const int *fds,
    int nfds);
long recvmsg_fds(int fd, void *buf, unsigned long n, int *fds, int maxfds,
    int *nfds_out);

int main(int argc, char **argv);

#endif /* _LIBC_H */
