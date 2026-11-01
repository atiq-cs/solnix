/* kbdrestore: put the console keyboard/mouse back after a compositor (illumos conskbd/consms are SHARED with the console:
 * a KIOCTRANS(TR_UNTRANS_EVENT) left behind garbles the console, conskbd.c never resets it on close).
 * usage: kbdrestore [-q]   -q only prints the current modes. Sets KIOCTRANS TR_ASCII + KIOCSDIRECT 0 on /dev/kbd (the console's) and
 * VUIDSFORMAT VUID_FIRM_EVENT on /dev/mouse (consms's boot default, consms.c:297; measured 1 on a fresh boot). */
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/kbd.h>
#include <sys/kbio.h>
#include <sys/vuid_event.h>
int main(int argc, char **argv) {
	int q = argc > 1 && !strcmp(argv[1], "-q"), rc = 0, t = -1, f = -1;
	int k = open("/dev/kbd", O_RDONLY | O_NONBLOCK);
	if (k < 0) { fprintf(stderr, "kbdrestore: /dev/kbd: %s\n", strerror(errno)); rc = 1; }
	else {
		if (ioctl(k, KIOCGTRANS, &t) != 0) t = -1;
		printf("kbd trans was %d (TR_ASCII %d, TR_UNTRANS_EVENT %d)\n", t, TR_ASCII, TR_UNTRANS_EVENT);
		int a = TR_ASCII, d = -1, z = 0;
		if (!q && ioctl(k, KIOCTRANS, &a) != 0) { fprintf(stderr, "kbdrestore: KIOCTRANS: %s\n", strerror(errno)); rc = 1; }
		/* directio is conskbd-global: 1 sends keys to /dev/kbd, 0 to the console (conskbd.c conskbd_override_kbtrans) */
		if (ioctl(k, KIOCGDIRECT, &d) != 0) d = -1;
		printf("kbd directio %d\n", d);
		if (!q && ioctl(k, KIOCSDIRECT, &z) != 0) { fprintf(stderr, "kbdrestore: KIOCSDIRECT: %s\n", strerror(errno)); rc = 1; }
		close(k);
	}
	int m = open("/dev/mouse", O_RDONLY | O_NONBLOCK);
	if (m >= 0) {
		if (ioctl(m, VUIDGFORMAT, &f) != 0) f = -1;
		printf("mouse format was %d (VUID_NATIVE %d, VUID_FIRM_EVENT %d)\n", f, VUID_NATIVE, VUID_FIRM_EVENT);
		int n = VUID_FIRM_EVENT;
		if (!q && ioctl(m, VUIDSFORMAT, &n) != 0) { fprintf(stderr, "kbdrestore: VUIDSFORMAT: %s\n", strerror(errno)); rc = 1; }
		close(m);
	}
	return rc;
}
