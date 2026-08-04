/* Minimal <sys/cdefs.h> for building BSD DB 1.85 on illumos (no sys/cdefs.h).
   Provides the K&R prototype macros, the BSD-sized integer aliases, and the
   BSD endian macros db.h and the access methods expect. */
#ifndef _DB1_SYS_CDEFS_H
#define _DB1_SYS_CDEFS_H

#include <sys/types.h>

#if defined(__STDC__) || defined(__cplusplus)
#ifndef __P
#define __P(protos)     protos
#endif
#ifndef __PMT
#define __PMT(protos)   protos
#endif
#define __CONCAT(x,y)   x ## y
#define __STRING(x)     #x
#else
#ifndef __P
#define __P(protos)     ()
#endif
#ifndef __PMT
#define __PMT(protos)   ()
#endif
#define __CONCAT(x,y)   x/**/y
#define __STRING(x)     "x"
#endif

#ifdef __cplusplus
#define __BEGIN_DECLS   extern "C" {
#define __END_DECLS     }
#else
#define __BEGIN_DECLS
#define __END_DECLS
#endif

#ifndef __signed
#define __signed        signed
#endif
#ifndef __THROW
#define __THROW
#endif

/* db.h re-typedefs int8_t/int16_t/int32_t unless this is set; illumos already
   defines them via <sys/int_types.h>, so suppress db.h's block and supply the
   BSD u_int*_t aliases illumos lacks. */
#ifndef __BIT_TYPES_DEFINED__
#define __BIT_TYPES_DEFINED__ 1
typedef uint8_t   u_int8_t;
typedef uint16_t  u_int16_t;
typedef uint32_t  u_int32_t;
#endif

/* BSD endian macros (illumos uses _LITTLE_ENDIAN/_BIG_ENDIAN, no BYTE_ORDER). */
#include <sys/isa_defs.h>
#ifndef LITTLE_ENDIAN
#define LITTLE_ENDIAN   1234
#endif
#ifndef BIG_ENDIAN
#define BIG_ENDIAN      4321
#endif
#ifndef BYTE_ORDER
#ifdef _LITTLE_ENDIAN
#define BYTE_ORDER      LITTLE_ENDIAN
#else
#define BYTE_ORDER      BIG_ENDIAN
#endif
#endif

#endif /* _DB1_SYS_CDEFS_H */
