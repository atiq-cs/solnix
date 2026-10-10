/*
 * i915_drmioc.h -- translate a DRM ioctl command as userland sends it on
 * solnix into the command OpenBSD's drm (drm_ioctl.c drmioctl) expects.
 *
 * Userland: solnix's libdrm and Mesa are built with the Linux _IOC
 * encoding (radv/build-libdrm.sh, anv/linux-ioctl-compat.h), because the
 * illumos <sys/ioccom.h> encoding has an 8-bit size field. Linux:
 *	bits 31:30 direction  1 = WRITE (user -> kernel, copyin)
 *	                      2 = READ  (kernel -> user, copyout)
 *	bits 29:16 size (14 bits), 15:8 type ('d'), 7:0 nr.
 * OpenBSD (sys/ioccom.h) and illumos use the BSD layout:
 *	IOC_IN 0x80000000 (copyin), IOC_OUT 0x40000000 (copyout),
 *	IOC_VOID 0x20000000 (no argument); size 28:16 on OpenBSD (13 bits,
 *	IOCPARM_MASK 0x1fff), 23:16 on illumos (IOCPARM_MASK 0xff).
 * So a Linux _IOW (0x4...) has the bit OpenBSD reads as IOC_OUT, and a
 * Linux _IOR (0x8...) the bit it reads as IOC_IN: the two are swapped,
 * and _IO is 0 instead of IOC_VOID. _IOWR is 0xc... in all three.
 *
 * OpenBSD's sys_ioctl does the copyin/copyout from the IOC_IN/IOC_OUT
 * bits of the command before calling the driver with a kernel buffer, and
 * refuses a size over IOCPARM_MAX (PAGE_SIZE) with ENOTTY; the cdev
 * wrapper in i915_illumos.c plays that role, driven by this translation.
 *
 * Header-only so test/test_drmioc.c checks the same code the module runs.
 */
#ifndef _I915_DRMIOC_H
#define _I915_DRMIOC_H

#define I915_LIOC_DIR(c)	(((c) >> 30) & 3u)
#define I915_LIOC_SIZE(c)	(((c) >> 16) & 0x3fffu)
#define I915_LIOC_TYPE(c)	(((c) >> 8) & 0xffu)
#define I915_LIOC_WRITE		1u
#define I915_LIOC_READ		2u

#define I915_OIOC_VOID		0x20000000u
#define I915_OIOC_OUT		0x40000000u
#define I915_OIOC_IN		0x80000000u
#define I915_OIOC_SIZEMASK	0x1fffu
#define I915_IOC_MAXSIZE	4096u	/* OpenBSD IOCPARM_MAX = PAGE_SIZE */

struct i915_ioc {
	uint32_t	ocmd;	/* the OpenBSD-encoded command */
	uint32_t	size;	/* argument bytes */
	int		in;	/* copyin before the call */
	int		out;	/* copyout after a successful call */
};

/* 0, or ENOTTY for anything that is not a DRM ('d') command OpenBSD's
 * sys_ioctl would accept. */
static inline int
i915_ioc_xlate(uint32_t lcmd, struct i915_ioc *x)
{
	uint32_t dir = I915_LIOC_DIR(lcmd), size = I915_LIOC_SIZE(lcmd);

	if (I915_LIOC_TYPE(lcmd) != 'd' || size > I915_IOC_MAXSIZE)
		return (25);	/* ENOTTY, the same value on illumos and OpenBSD */
	if (dir == 0 && size != 0)
		return (25);
#ifdef I915_DRMIOC_SABOTAGE
	/* negative control: read the Linux bits as if they were BSD ones */
	x->in = (dir & I915_LIOC_READ) != 0;
	x->out = (dir & I915_LIOC_WRITE) != 0;
#else
	x->in = (dir & I915_LIOC_WRITE) != 0;
	x->out = (dir & I915_LIOC_READ) != 0;
#endif
	x->size = size;
	x->ocmd = (x->in ? I915_OIOC_IN : 0) | (x->out ? I915_OIOC_OUT : 0) |
	    (dir == 0 ? I915_OIOC_VOID : 0) |
	    ((size & I915_OIOC_SIZEMASK) << 16) | (lcmd & 0xffffu);
	return (0);
}

#endif /* _I915_DRMIOC_H */
