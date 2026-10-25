/* rvlogin: numeric-only resolver (no DNS in the guest): getaddrinfo takes dotted IPv4 or NULL. */
#ifndef _NETDB_H
#define	_NETDB_H
#include <netinet/in.h>
struct addrinfo { int ai_flags, ai_family, ai_socktype, ai_protocol; socklen_t ai_addrlen;
	struct sockaddr *ai_addr; char *ai_canonname; struct addrinfo *ai_next; };
struct hostent { char *h_name; char **h_aliases; int h_addrtype, h_length; char **h_addr_list; };
#define	h_addr h_addr_list[0]
#define	AI_PASSIVE 0x0008
#define	AI_CANONNAME 0x0010
#define	AI_NUMERICHOST 0x0020
#define	AI_NUMERICSERV 0x0040
#define	NI_NUMERICHOST 0x0002
#define	NI_NUMERICSERV 0x0008
#define	NI_NAMEREQD 0x0004
#define	NI_MAXHOST 1025
#define	NI_MAXSERV 32
#define	EAI_AGAIN 2
#define	EAI_BADFLAGS 3
#define	EAI_FAIL 4
#define	EAI_FAMILY 5
#define	EAI_MEMORY 6
#define	EAI_NONAME 8
#define	EAI_SERVICE 9
#define	EAI_SOCKTYPE 10
#define	EAI_SYSTEM 11
int getaddrinfo(const char *, const char *, const struct addrinfo *, struct addrinfo **);
void freeaddrinfo(struct addrinfo *);
const char *gai_strerror(int);
int getnameinfo(const struct sockaddr *, socklen_t, char *, socklen_t, char *, socklen_t, int);
struct hostent *gethostbyname(const char *);
#endif
