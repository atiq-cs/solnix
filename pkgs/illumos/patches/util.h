/*
 * util.h - illumos compat shim for nvi2.
 *
 * BSD/macOS provide openpty() via <util.h>; illumos has no such header or
 * function. Implement openpty() on top of the SysV/POSIX pty interface
 * (posix_openpt/grantpt/unlockpt/ptsname), which illumos does provide.
 * nvi2 uses openpty() only for `:script` mode (running a shell in a pty).
 */

#ifndef _NVI_ILLUMOS_UTIL_H_
#define	_NVI_ILLUMOS_UTIL_H_

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <stropts.h>

static __inline int
openpty(int *amaster, int *aslave, char *name,
    const struct termios *termp, const struct winsize *winp)
{
	int master, slave;
	char *slavename;

	master = posix_openpt(O_RDWR | O_NOCTTY);
	if (master == -1)
		return (-1);
	if (grantpt(master) == -1 || unlockpt(master) == -1)
		goto fail;
	slavename = ptsname(master);
	if (slavename == NULL)
		goto fail;
	slave = open(slavename, O_RDWR | O_NOCTTY);
	if (slave == -1)
		goto fail;
	/* push the STREAMS modules that make the slave a real tty */
	(void)ioctl(slave, I_PUSH, "ptem");
	(void)ioctl(slave, I_PUSH, "ldterm");

	if (termp != NULL)
		(void)tcsetattr(slave, TCSAFLUSH, termp);
	if (winp != NULL)
		(void)ioctl(slave, TIOCSWINSZ, winp);
	if (name != NULL)
		(void)strcpy(name, slavename);

	*amaster = master;
	*aslave = slave;
	return (0);

fail:
	(void)close(master);
	return (-1);
}

#endif /* !_NVI_ILLUMOS_UTIL_H_ */
