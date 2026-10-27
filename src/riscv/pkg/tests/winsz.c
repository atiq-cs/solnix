/* winsz -- print the controlling tty's rows and cols (TIOCGWINSZ), as `stty size` does. */
#include <stdio.h>
#include <sys/ioctl.h>
int
main(void)
{
	struct winsize w;

	if (ioctl(0, TIOCGWINSZ, &w) != 0)
		return (1);
	printf("%u %u\n", w.ws_row, w.ws_col);
	return (0);
}
