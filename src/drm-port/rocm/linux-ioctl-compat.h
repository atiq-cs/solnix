/* Linux _IOC encoding shim for illumos -- matches drm-port/src/uapi/drm/drm.h. */
#ifndef _SOLNIX_LINUX_IOCTL_COMPAT_H_
#define _SOLNIX_LINUX_IOCTL_COMPAT_H_
#include <stdint.h>
#include <sys/types.h>
typedef int8_t   __s8;   typedef uint8_t  __u8;
typedef int16_t  __s16;  typedef uint16_t __u16;
typedef int32_t  __s32;  typedef uint32_t __u32;
typedef int64_t  __s64;  typedef uint64_t __u64;
#define _IOC_NRBITS   8
#define _IOC_TYPEBITS 8
#define _IOC_SIZEBITS 14
#define _IOC_DIRBITS  2
#define _IOC_NRSHIFT   0
#define _IOC_TYPESHIFT (_IOC_NRSHIFT + _IOC_NRBITS)
#define _IOC_SIZESHIFT (_IOC_TYPESHIFT + _IOC_TYPEBITS)
#define _IOC_DIRSHIFT  (_IOC_SIZESHIFT + _IOC_SIZEBITS)
#define _IOC_NONE  0U
#define _IOC_WRITE 1U
#define _IOC_READ  2U
#define _IOC(dir,type,nr,size) \
  (((dir)<<_IOC_DIRSHIFT)|((type)<<_IOC_TYPESHIFT)|((nr)<<_IOC_NRSHIFT)|((size)<<_IOC_SIZESHIFT))
#define _IOC_TYPECHECK(t) (sizeof(t))
#undef _IO
#undef _IOR
#undef _IOW
#undef _IOWR
#define _IO(type,nr)         _IOC(_IOC_NONE,(type),(nr),0)
#define _IOR(type,nr,size)   _IOC(_IOC_READ,(type),(nr),(_IOC_TYPECHECK(size)))
#define _IOW(type,nr,size)   _IOC(_IOC_WRITE,(type),(nr),(_IOC_TYPECHECK(size)))
#define _IOWR(type,nr,size)  _IOC(_IOC_READ|_IOC_WRITE,(type),(nr),(_IOC_TYPECHECK(size)))
#define _IOC_NR(nr)   (((nr) >> _IOC_NRSHIFT) & ((1 << _IOC_NRBITS)-1))
#define _IOC_TYPE(nr) (((nr) >> _IOC_TYPESHIFT) & ((1 << _IOC_TYPEBITS)-1))
#define _IOC_SIZE(nr) (((nr) >> _IOC_SIZESHIFT) & ((1 << _IOC_SIZEBITS)-1))
#define _IOC_DIR(nr)  (((nr) >> _IOC_DIRSHIFT) & ((1 << _IOC_DIRBITS)-1))
#endif
