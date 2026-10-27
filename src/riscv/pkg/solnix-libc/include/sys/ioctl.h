/* ioctls the solnix riscv64 kernel answers: the pty ones (illumos numbers, uts/pty.c). The console has none. */
#ifndef _SYS_IOCTL_H
#define	_SYS_IOCTL_H
struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
#define	TIOCGWINSZ	0x5468
#define	TIOCSWINSZ	0x5467
#define	TIOCGPGRP	0x7414
#define	TIOCSPGRP	0x7415
#define	TIOCGSID	0x7416
#define	TIOCNOTTY	0x7471
#define	TIOCSCTTY	0x7484
#define	FIONREAD	0x541B	/* not answered by the kernel: ENOTTY */
int ioctl(int, unsigned long, ...);
#endif
