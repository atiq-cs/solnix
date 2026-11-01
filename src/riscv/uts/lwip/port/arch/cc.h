/*
 * rvsrv: lwIP arch port for the illumos riscv64 uts kernel (freestanding, LP64,
 * little-endian). gcc's freestanding <stddef.h>/<stdint.h>/<limits.h> supply
 * the types; diagnostics go to the SBI console; an assertion parks the hart
 * with its message on screen (the kernel's panic idiom).
 */
#ifndef LWIP_ARCH_CC_H
#define	LWIP_ARCH_CC_H

#define	LWIP_NO_INTTYPES_H	1
/*
 * No <limits.h> either: a hosted gcc's limits.h chains to the C library's
 * (glibc stubs-lp64.h is absent on lixr's lp64d Linux gcc, which broke the
 * soft-float K1/K3 payload builds). Without SSIZE_MAX, lwIP typedefs ssize_t
 * itself instead of pulling in <unistd.h>.
 */
#define	LWIP_NO_LIMITS_H	1
#define	INT_MAX			__INT_MAX__
#define	LWIP_NO_CTYPE_H		1
#define	X8_F	"02x"
#define	U16_F	"hu"
#define	S16_F	"hd"
#define	X16_F	"hx"
#define	U32_F	"u"
#define	S32_F	"d"
#define	X32_F	"x"
#define	SZT_F	"lu"
#define	BYTE_ORDER	LITTLE_ENDIAN

extern void inet_diag(const char *msg);
extern void inet_assert(const char *msg, const char *file, int line);
extern unsigned int inet_rand(void);

#define	LWIP_PLATFORM_DIAG(x)	do { inet_diag("[lwip] diag\n"); } while (0)
#define	LWIP_PLATFORM_ASSERT(x)	inet_assert((x), __FILE__, __LINE__)
#define	LWIP_RAND()		((u32_t)inet_rand())

#endif	/* LWIP_ARCH_CC_H */
