/*
 * xport_fixture.c: a scripted controller that replays a recorded transcript
 * (solnix, new code). Time is virtual, so a 5 s timeout costs nothing.
 *
 * Transcript, one record per line ('#' starts a comment):
 *   C <hex>        a command the core must send next (opcode lo hi, len, params)
 *   E +<ms> <hex>  an event (code, len, params). It is released only after
 *                  every C line before it was matched, <ms> after the later of
 *                  the last such C and the previous E.
 * Commands are matched in file order. A command that differs from the next
 * C line fails the transport (recv/send return -1) and is reported.
 */
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "xport.h"

#define	FX_MAX	4096

struct fx_line {
	char		kind;		/* 'C' or 'E' */
	int		lineno;
	uint32_t	delta;		/* E: ms */
	uint16_t	len;
	uint8_t		b[260];
};

static struct fx {
	struct fx_line	*l;
	int		n;
	int		next_c;		/* index of the next C to match */
	int		next_e;		/* index of the next E to release */
	uint64_t	now, anchor;
	int		failed;
	char		why[200];
} fx;

static int
fx_hex(const char *s, uint8_t *b, size_t max)
{
	size_t n = 0;
	unsigned v;

	while (*s != '\0') {
		if (isspace((unsigned char)*s)) {
			s++;
			continue;
		}
		if (n == max || sscanf(s, "%2x", &v) != 1 ||
		    !isxdigit((unsigned char)s[1]))
			return (-1);
		b[n++] = (uint8_t)v;
		s += 2;
	}
	return ((int)n);
}

static int
fx_load(const char *path)
{
	char buf[1200], *p;
	FILE *f = fopen(path, "r");
	int lineno = 0, n;

	if (f == NULL)
		return (-1);
	fx.l = calloc(FX_MAX, sizeof (*fx.l));
	while (fx.l != NULL && fgets(buf, sizeof (buf), f) != NULL) {
		struct fx_line *l = &fx.l[fx.n];

		lineno++;
		if ((p = strchr(buf, '#')) != NULL)
			*p = '\0';
		for (p = buf; isspace((unsigned char)*p); p++)
			;
		if (*p == '\0')
			continue;
		if (fx.n == FX_MAX || (*p != 'C' && *p != 'E'))
			goto bad;
		l->kind = *p++;
		l->lineno = lineno;
		if (l->kind == 'E') {
			while (isspace((unsigned char)*p))
				p++;
			if (*p++ != '+')
				goto bad;
			l->delta = (uint32_t)strtoul(p, &p, 10);
		}
		if ((n = fx_hex(p, l->b, sizeof (l->b))) < 2)
			goto bad;
		l->len = (uint16_t)n;
		fx.n++;
	}
	(void) fclose(f);
	return (fx.l == NULL ? -1 : 0);
bad:
	fprintf(stderr, "fixture %s:%d: bad line\n", path, lineno);
	(void) fclose(f);
	return (-1);
}

static int
fx_open(void *a)
{
	(void) a;
	return (fx.failed ? -1 : 0);
}

static void
fx_close(void *a)
{
	(void) a;
}

static void
fx_fail(const char *fmt, int lineno)
{
	if (!fx.failed)
		(void) snprintf(fx.why, sizeof (fx.why), fmt, lineno);
	fx.failed = 1;
}

/* The next E line may be released once every C before it has been matched. */
static struct fx_line *
fx_ready_event(void)
{
	while (fx.next_e < fx.n && fx.l[fx.next_e].kind != 'E')
		fx.next_e++;
	if (fx.next_e == fx.n)
		return (NULL);
	for (int i = fx.next_c; i < fx.next_e; i++)
		if (fx.l[i].kind == 'C')
			return (NULL);
	return (&fx.l[fx.next_e]);
}

static int
fx_send_cmd(void *a, const uint8_t *p, size_t n)
{
	struct fx_line *l;

	(void) a;
	while (fx.next_c < fx.n && fx.l[fx.next_c].kind != 'C')
		fx.next_c++;
	if (fx.failed)
		return (-1);
	if (fx.next_c == fx.n) {
		fx_fail("command after the end of the transcript (last line %d)",
		    fx.n > 0 ? fx.l[fx.n - 1].lineno : 0);
		return (-1);
	}
	l = &fx.l[fx.next_c];
	if (l->len != n || memcmp(l->b, p, n) != 0) {
		fx_fail("command differs from line %d", l->lineno);
		return (-1);
	}
	fx.next_c++;
	if (fx.anchor < fx.now)
		fx.anchor = fx.now;
	return (0);
}

static int
fx_recv_evt(void *a, uint8_t *p, size_t n, int ms)
{
	struct fx_line *e;
	uint64_t at;

	(void) a;
	if (fx.failed)
		return (-1);
	if ((e = fx_ready_event()) == NULL) {
		fx.now += (uint64_t)(ms > 0 ? ms : 0);	/* nothing due: time passes */
		return (0);
	}
	at = fx.anchor + e->delta;
	if (at > fx.now + (uint64_t)(ms > 0 ? ms : 0)) {
		fx.now += (uint64_t)(ms > 0 ? ms : 0);
		return (0);
	}
	if (at > fx.now)
		fx.now = at;
	fx.anchor = fx.now;
	fx.next_e++;
	if (e->len > n) {
		fx_fail("event at line %d larger than the reader's buffer", e->lineno);
		return (-1);
	}
	memcpy(p, e->b, e->len);
	return (e->len);
}

static uint64_t
fx_now_ms(void *a)
{
	(void) a;
	return (fx.now);
}

const struct xport *
xport_fixture(const char *path)
{
	static struct xport x = {
		"fixture", fx_open, fx_close, fx_send_cmd, fx_recv_evt, fx_now_ms, NULL
	};

	memset(&fx, 0, sizeof (fx));
	fx.now = fx.anchor = 1000000;	/* nonzero: memo timestamps are not 0 */
	return (fx_load(path) == 0 ? &x : NULL);
}

int
xport_fixture_status(char *why, size_t len)
{
	if (fx.failed) {
		(void) snprintf(why, len, "%s", fx.why);
		return (-1);
	}
	for (int i = 0; i < fx.n; i++) {
		if ((fx.l[i].kind == 'C' && i >= fx.next_c) ||
		    (fx.l[i].kind == 'E' && i >= fx.next_e)) {
			(void) snprintf(why, len, "line %d not consumed",
			    fx.l[i].lineno);
			return (fx.l[i].lineno);
		}
	}
	(void) snprintf(why, len, "all %d lines consumed", fx.n);
	return (0);
}
