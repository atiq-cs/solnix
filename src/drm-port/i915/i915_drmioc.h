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

/*
 * Minor numbers. illumos gives a driver a 32-bit minor (getminor); the
 * i915 module lays it out as
 *	bits 7:0   kind: I915_IL_CARD 0, I915_IL_TEXT 64, I915_IL_RENDER 128,
 *	           I915_IL_DMABUF 192 (bits 31:16 then name a dma-buf slot,
 *	           obsd_glue.c; such a minor is only ever opened from the kernel)
 *	bits 15:8  driver instance
 *	bits 31:16 clone index (0 = the node itself; open(9E) of card0 or
 *	           renderD128 returns a fresh one per open, as a clone device)
 * OpenBSD's drm_drv.c reads its own minor as (clone << CLONE_SHIFT) |
 * realminor, realminor = drm unit (+128 for render; 64..127 is refused
 * with ENXIO, so the text kind can never be mistaken for a drm node), and
 * keys each open's drm_file by the whole value. i915_il_ominor builds that
 * value; the cdev passes drm a dev_t carrying it.
 */
#define I915_IL_CARD		0u
#define I915_IL_TEXT		64u
#define I915_IL_RENDER		128u
#define I915_IL_DMABUF		192u
#define I915_IL_KIND(m)		((m) & 0xffu)
#define I915_IL_INST(m)		(((m) >> 8) & 0xffu)
#define I915_IL_CLONE(m)	((m) >> 16)
#define I915_IL_CLONE_MAX	0xffffu
#define I915_IL_MINOR(inst, kind, clone) \
	(((uint32_t)(clone) << 16) | ((uint32_t)(inst) << 8) | (kind))

static inline uint32_t
i915_il_ominor(uint32_t m, uint32_t drmunit)
{
#ifdef I915_MINOR_SABOTAGE
	/* negative control: the illumos SVR3 minor() (x & 0xff) */
	m &= 0xffu;
#endif
	return ((I915_IL_CLONE(m) << 8) |
	    (drmunit + (I915_IL_KIND(m) == I915_IL_RENDER ? 128u : 0u)));
}

#endif /* _I915_DRMIOC_H */
