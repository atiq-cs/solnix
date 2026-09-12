/*
 * BSD scalar type aliases absent from illumos headers, plus the byte-order
 * spellings the OpenBSD sources use.
 *
 * These are genuinely equivalent (u_int8_t and uint8_t are the same type on
 * both systems), so unlike the other files under compat/ this one is REAL, not
 * a stub. Kept separate from the stubs so the distinction stays visible.
 */
#ifndef _IWX_BSDTYPES_H
#define _IWX_BSDTYPES_H
#include <sys/types.h>
#include <sys/byteorder.h>

typedef uint8_t		u_int8_t;
typedef uint16_t	u_int16_t;
typedef uint32_t	u_int32_t;
typedef uint64_t	u_int64_t;

#define htole16(x)	LE_16(x)
#define htole32(x)	LE_32(x)
#define htole64(x)	LE_64(x)
#define letoh16(x)	LE_16(x)
#define letoh32(x)	LE_32(x)
#define letoh64(x)	LE_64(x)
#define le16toh(x)	LE_16(x)
#define le32toh(x)	LE_32(x)
#define le64toh(x)	LE_64(x)
#define betoh16(x)	BE_16(x)
#define betoh32(x)	BE_32(x)
#define htobe16(x)	BE_16(x)
#define htobe32(x)	BE_32(x)
#endif
