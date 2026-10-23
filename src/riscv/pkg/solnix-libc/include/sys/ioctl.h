/* No ioctls exist for the console in the solnix riscv64 kernel; ioctl() is ENOTTY. */
#ifndef _SYS_IOCTL_H
#define	_SYS_IOCTL_H
struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
#define	TIOCGWINSZ	0x5413
#define	TIOCSWINSZ	0x5414
#define	FIONREAD	0x541B
int ioctl(int, unsigned long, ...);
#endif
