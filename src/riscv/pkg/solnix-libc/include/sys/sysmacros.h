/* dev_t helpers (newlib has none). The solnix kernel reports no device numbers. */
#ifndef _SYS_SYSMACROS_H
#define	_SYS_SYSMACROS_H
#define	major(d)	((unsigned)(((d) >> 8) & 0xfff))
#define	minor(d)	((unsigned)((d) & 0xff))
#define	makedev(a, i)	((dev_t)((((a) & 0xfff) << 8) | ((i) & 0xff)))
#endif
