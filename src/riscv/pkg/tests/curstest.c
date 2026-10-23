/*
 * curstest.c -- ncurses check. Uses newterm() on stdout with TERM=vt100 (compiled
 * in as a fallback; there is no terminfo database), draws a box, a string at a
 * known position and a reverse-video word, refreshes, ends.
 * Prints CURSTEST PASS/FAIL to stderr after endwin, so the escape bytes on
 * stdout can be compared byte-for-byte with the same program built for Linux.
 * Also checks tigetstr("cup") came from the compiled-in vt100 entry.
 */
#include <curses.h>
#include <term.h>
#include <stdio.h>
#include <string.h>

int
main(void)
{
	SCREEN *s;
	char *cup;
	int ok = 1;

	s = newterm("vt100", stdout, stdin);
	if (s == NULL) {
		fprintf(stderr, "CURSTEST FAIL: newterm(vt100) returned NULL\n");
		return (1);
	}
	cup = tigetstr("cup");
	ok &= cup != NULL && cup != (char *)-1 && strstr(cup, "%i") != NULL;
	resizeterm(24, 80);
	box(stdscr, 0, 0);
	mvaddstr(5, 10, "solnix riscv64 ncurses");
	attron(A_REVERSE);
	mvaddstr(7, 10, "REVERSE");
	attroff(A_REVERSE);
	ok &= LINES == 24 && COLS == 80;
	refresh();
	endwin();
	fprintf(stderr, "\ncurstest: LINES=%d COLS=%d cup=%s\n", LINES, COLS,
	    cup ? "yes" : "no");
	fprintf(stderr, "CURSTEST %s\n", ok ? "PASS" : "FAIL");
	return (!ok);
}
