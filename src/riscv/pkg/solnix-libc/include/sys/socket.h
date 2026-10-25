/* rvlogin: sockets for the solnix riscv64 kernel (uts/uproc.c + inet.c). Linux-riscv syscall
 * numbers; illumos socket TYPE values (SOCK_DGRAM 1, SOCK_STREAM 2), as the kernel takes them. */
#ifndef _SYS_SOCKET_H
#define	_SYS_SOCKET_H
#include <sys/types.h>
#include <sys/uio.h>
typedef __socklen_t socklen_t;
typedef unsigned short sa_family_t;
struct sockaddr { sa_family_t sa_family; char sa_data[14]; };
struct sockaddr_storage { sa_family_t ss_family; char __ss_pad[126]; } __attribute__((aligned(8)));
struct linger { int l_onoff, l_linger; };
struct msghdr { void *msg_name; socklen_t msg_namelen; struct iovec *msg_iov; int msg_iovlen;
	void *msg_control; socklen_t msg_controllen; int msg_flags; };
#define	AF_UNSPEC 0
#define	AF_UNIX 1
#define	AF_LOCAL AF_UNIX
#define	AF_INET 2
#define	AF_INET6 26
#define	PF_UNSPEC AF_UNSPEC
#define	PF_UNIX AF_UNIX
#define	PF_INET AF_INET
#define	PF_INET6 AF_INET6
#define	SOCK_DGRAM 1
#define	SOCK_STREAM 2
#define	SOCK_RAW 4
#define	SOL_SOCKET 0xffff
#define	SO_REUSEADDR 0x0004
#define	SO_KEEPALIVE 0x0008
#define	SO_LINGER 0x0080
#define	SO_ERROR 0x1007
#define	SO_SNDBUF 0x1001
#define	SO_RCVBUF 0x1002
#define	SO_PRIORITY 0x1022
#define	SHUT_RD 0
#define	SHUT_WR 1
#define	SHUT_RDWR 2
#define	MSG_PEEK 0x2
#define	MSG_DONTWAIT 0x80
#define	MSG_NOSIGNAL 0x200
#define	SOMAXCONN 128
int socket(int, int, int);
int socketpair(int, int, int, int[2]);
int bind(int, const struct sockaddr *, socklen_t);
int listen(int, int);
int accept(int, struct sockaddr *, socklen_t *);
int connect(int, const struct sockaddr *, socklen_t);
int shutdown(int, int);
int getsockname(int, struct sockaddr *, socklen_t *);
int getpeername(int, struct sockaddr *, socklen_t *);
int setsockopt(int, int, int, const void *, socklen_t);
int getsockopt(int, int, int, void *, socklen_t *);
ssize_t send(int, const void *, size_t, int);
ssize_t recv(int, void *, size_t, int);
ssize_t sendto(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
ssize_t recvfrom(int, void *, size_t, int, struct sockaddr *, socklen_t *);
#endif
