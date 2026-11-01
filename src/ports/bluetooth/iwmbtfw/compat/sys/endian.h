/*
 * FreeBSD <sys/endian.h> subset for the vendored iwmbtfw (solnix compat, new code).
 * illumos <endian.h> has the htole/letoh family; FreeBSD also has the
 * alignment-free le16dec/le32dec/le32enc used on firmware buffers.
 */
#ifndef _SOLNIX_COMPAT_SYS_ENDIAN_H
#define	_SOLNIX_COMPAT_SYS_ENDIAN_H

#include <endian.h>
#include <stdint.h>

/*
 * illumos declares htole16 etc. as functions, but upstream uses them in static
 * initializers, which need constant expressions. x86 and aarch64 are little-endian.
 */
#if BYTE_ORDER != LITTLE_ENDIAN
#error "iwmbtfw compat: little-endian hosts only"
#endif
#define	htole16(x)	((uint16_t)(x))
#define	htole32(x)	((uint32_t)(x))
#define	le16toh(x)	((uint16_t)(x))
#define	le32toh(x)	((uint32_t)(x))

static inline uint16_t
le16dec(const void *pp)
{
	const uint8_t *p = pp;

	return ((uint16_t)(p[0] | (p[1] << 8)));
}

static inline uint32_t
le32dec(const void *pp)
{
	const uint8_t *p = pp;

	return ((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	    ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}

static inline void
le32enc(void *pp, uint32_t v)
{
	uint8_t *p = pp;

	p[0] = v & 0xff;
	p[1] = (v >> 8) & 0xff;
	p[2] = (v >> 16) & 0xff;
	p[3] = (v >> 24) & 0xff;
}

#endif
