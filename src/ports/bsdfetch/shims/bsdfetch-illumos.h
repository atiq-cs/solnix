/*
 * bsdfetch-illumos.h -- force-included (-include) into every libfetch/fetch(1) unit.
 * Supplies the few FreeBSD-isms illumos lacks; everything else (err.h, paths.h,
 * getprogname, strlcpy, reallocf, asprintf, getline, MSG_NOSIGNAL, __unused) is
 * in illumos libc and headers already.
 */
#ifndef BSDFETCH_ILLUMOS_H
#define BSDFETCH_ILLUMOS_H

#define __EXTENSIONS__ 1
#include <sys/types.h>
#include <sys/ccompile.h>
#include <sys/param.h>
#include <limits.h>		/* PATH_MAX (fetch.h) */
#include <netdb.h>		/* MAXHOSTNAMELEN (fetch.h) */
#include <signal.h>

/* FreeBSD <sys/cdefs.h> C++ linkage brackets, used by fetch.h. */
#ifndef __BEGIN_DECLS
#ifdef __cplusplus
#define __BEGIN_DECLS extern "C" {
#define __END_DECLS }
#else
#define __BEGIN_DECLS
#define __END_DECLS
#endif
#endif

/* FreeBSD-only errno values; libfetch maps them in a switch, never sets them. */
#include <errno.h>
#ifndef EAUTH
#define EAUTH 80001
#endif
#ifndef ENEEDAUTH
#define ENEEDAUTH 80002
#endif

/* poll(2) "wait forever". */
#include <poll.h>
#ifndef INFTIM
#define INFTIM (-1)
#endif

/* <sys/cdefs.h> __DECONST: drop const from a pointer (iovec bases, SNI host). */
#ifndef __DECONST
#define __DECONST(type, var) ((type)(uintptr_t)(const void *)(var))
#endif

/* BSD u_int32_t. */
#include <inttypes.h>
#ifndef u_int32_t
typedef uint32_t bsdfetch_u_int32_t;
#define u_int32_t bsdfetch_u_int32_t
#endif

/*
 * BSD sockaddrs carry their own length (sin_len, ss_len); illumos's do not. ftp.c is
 * patched (patches/ftp-no-sa-len.patch) to call BSDFETCH_SALEN(&sa) where it read
 * sa.ss_len, and to drop the one sin_len store.
 */
#include <sys/socket.h>
#include <netinet/in.h>
#define BSDFETCH_SALEN(ss) ((socklen_t)(((const struct sockaddr *)(ss))->sa_family == AF_INET6 ? \
	sizeof (struct sockaddr_in6) : sizeof (struct sockaddr_in)))

/* tcsetattr TCSASOFT (ignore the c_cflag bits): no illumos equivalent; fetch(1) uses it only
 * to turn echo off for a password prompt, where plain TCSAFLUSH/TCSANOW is the same. */
#ifndef TCSASOFT
#define TCSASOFT 0
#endif

/* <sys/stat.h> ALLPERMS. */
#ifndef ALLPERMS
#define ALLPERMS (S_ISUID | S_ISGID | S_ISVTX | S_IRWXU | S_IRWXG | S_IRWXO)
#endif

/* funopen(3): shims/funopen.c. */
#include <stdio.h>
FILE *funopen(const void *, int (*)(void *, char *, int), int (*)(void *, const char *, int),
    fpos_t (*)(void *, fpos_t, int), int (*)(void *));

/* <sys/param.h> MAXLOGNAME: login-name buffer size (FreeBSD 33). illumos LOGNAME_MAX is 32. */
#ifndef MAXLOGNAME
#define MAXLOGNAME 33
#endif

/* FreeBSD <netinet/in.h>: the largest valid port number. */
#ifndef IPPORT_MAX
#define IPPORT_MAX 65535
#endif

/* FreeBSD <sys/cdefs.h> annotations. */
#ifndef __FBSDID
#define __FBSDID(s)
#endif
#ifndef __printflike
#define __printflike(f, a) __attribute__((__format__(__printf__, f, a)))
#endif
#ifndef __dead2
#define __dead2 __attribute__((__noreturn__))
#endif
#ifndef nitems
#define nitems(x) (sizeof (x) / sizeof ((x)[0]))
#endif

/*
 * SO_NOSIGPIPE: FreeBSD's per-socket "no SIGPIPE on write". illumos has no such
 * option; libfetch only sets it best-effort (return value ignored), and fetch(1)
 * ignores SIGPIPE itself, so a no-op option level is safe. -1 makes setsockopt
 * fail with ENOPROTOOPT, which libfetch discards.
 */
#ifndef SO_NOSIGPIPE
#define SO_NOSIGPIPE -1
#endif

/* setproctitle(3): cosmetic progress in ps(1); illumos has none. */
#define setproctitle(...) do { } while (0)

/* SIGINFO (^T status): not on illumos; fetch(1) only installs a handler for it. */
#ifndef SIGINFO
#define SIGINFO SIGUSR1
#endif

#endif
