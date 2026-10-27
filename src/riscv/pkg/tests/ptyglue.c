/*
 * ptyglue.c -- rvtty3c: the pty through libc (posix_openpt, grantpt, unlockpt, ptsname, tcgetattr/tcsetattr,
 * cfmakeraw, TIOCGWINSZ via ioctl, ttyname). Prints PTYGLUE PASS / PTYGLUE FAIL <why>.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define	F(w) do { printf("PTYGLUE FAIL %s\n", w); return (1); } while (0)

int
main(void)
{
	int m, s;
	char *n, b[8];
	struct termios t;
	struct winsize w = { 24, 80, 0, 0 }, g;

	if ((m = posix_openpt(O_RDWR | O_NOCTTY)) < 0) F("posix_openpt");
	if (grantpt(m) != 0 || unlockpt(m) != 0) F("grantpt/unlockpt");
	if ((n = ptsname(m)) == NULL || strncmp(n, "/dev/pts/", 9) != 0) F("ptsname");
	if ((s = open(n, O_RDWR | O_NOCTTY)) < 0) F("open slave");
	if (!isatty(s) || ttyname(s) == NULL || strcmp(ttyname(s), n) != 0) F("isatty/ttyname");
	if (tcgetattr(s, &t) != 0) F("tcgetattr");
	t.c_lflag |= ICANON | ECHO;
	t.c_oflag |= OPOST | ONLCR;
	if (tcsetattr(s, TCSANOW, &t) != 0) F("tcsetattr canon");
	if (write(m, "hi\n", 3) != 3 || read(s, b, sizeof (b)) != 3 || memcmp(b, "hi\n", 3) != 0) F("canon line");
	if (read(m, b, sizeof (b)) != 4 || memcmp(b, "hi\r\n", 4) != 0) F("echo with ONLCR");
	cfmakeraw(&t);
	if (tcsetattr(s, TCSAFLUSH, &t) != 0 || tcgetattr(s, &t) != 0 || (t.c_lflag & (ICANON | ECHO))) F("cfmakeraw");
	if (ioctl(m, TIOCSWINSZ, &w) != 0 || ioctl(s, TIOCGWINSZ, &g) != 0 || g.ws_row != 24 || g.ws_col != 80) F("winsize");
	printf("PTYGLUE PASS %s %ux%u\n", n, g.ws_row, g.ws_col);
	return (0);
}
