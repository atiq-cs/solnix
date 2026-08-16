/*
 * wclib.c -- the gnulib lib/ helpers wc.c links beyond the real libc + the real
 * argv-iter.c (linked separately).  umaxtostr/imaxtostr render a 64-bit integer
 * to decimal (gnulib lib/inttostr.c); physmem_available reports a generous
 * amount; __argmatch is the linear prefix match XARGMATCH uses; readtokens0 +
 * getdelim are only reached on the --files0-from path (not the common wc case),
 * so they are present-to-link reduced forms.
 *
 * CRIB PROVENANCE: inttostr's "fill a fixed buffer from the least-significant
 * digit backwards" is gnulib lib/inttostr.c; argmatch's linear scan is gnulib
 * lib/argmatch.c argmatch(); getdelim is the POSIX read-until-delimiter.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "readtokens0.h"
#include "argv-iter.h"

typedef unsigned long uintmax_t_;
typedef long intmax_t_;

char *
umaxtostr(unsigned long v, char *buf)
{
	char tmp[24];
	int i = 0, k = 0;
	if (v == 0)
		tmp[i++] = '0';
	while (v > 0) { tmp[i++] = (char)('0' + v % 10); v /= 10; }
	while (i > 0)
		buf[k++] = tmp[--i];
	buf[k] = 0;
	return (buf);
}

char *
imaxtostr(long v, char *buf)
{
	if (v < 0) {
		buf[0] = '-';
		(void) umaxtostr((unsigned long)(-v), buf + 1);
		return (buf);
	}
	return (umaxtostr((unsigned long)v, buf));
}

/* physmem: report 256 MiB available so wc's --files0-from size check passes. */
double physmem_available(void) { return (256.0 * 1024 * 1024); }
double physmem_total(void)     { return (256.0 * 1024 * 1024); }

/* XARGMATCH backend: linear match of `arg` against NULL-terminated `arglist`;
   returns the matching index, or exits on ambiguity/no-match (like gnulib). */
int
__argmatch(const char *arg, const char *const *arglist)
{
	int i;
	for (i = 0; arglist[i] != 0; i++)
		if (strcmp(arg, arglist[i]) == 0)
			return (i);
	fprintf(stderr, "wc: invalid argument %s\n", arg);
	exit(2);
	return (-1);
}

/* getdelim: argv-iter.c references it (only in --files0-from stream mode). */
long
getdelim(char **lineptr, unsigned long *n, int delim, FILE *stream)
{
	unsigned long len = 0;
	int c;
	if (*lineptr == 0 || *n == 0) {
		*n = 128;
		*lineptr = malloc(*n);
		if (*lineptr == 0)
			return (-1);
	}
	for (;;) {
		c = fgetc(stream);
		if (c < 0)
			break;
		if (len + 1 >= *n) {
			unsigned long nn = *n * 2;
			char *p = realloc(*lineptr, nn);
			if (p == 0)
				return (-1);
			*lineptr = p;
			*n = nn;
		}
		(*lineptr)[len++] = (char)c;
		if (c == delim)
			break;
	}
	if (len == 0)
		return (-1);
	(*lineptr)[len] = 0;
	return ((long)len);
}

/* readtokens0: read NUL-separated tokens from `in` into t->tok[] (reduced form
   of gnulib lib/readtokens0.c; grows a token vector, one malloc'd copy each). */
void
readtokens0_init(struct Tokens *t)
{
	t->n_tok = 0;
	t->tok = 0;
	t->tok_len = 0;
}

int
readtokens0(FILE *in, struct Tokens *t)
{
	unsigned long cap = 0;
	char buf[4096];
	unsigned long blen = 0;
	int c;
	for (;;) {
		c = fgetc(in);
		if (c < 0 || c == 0) {
			if (blen == 0 && c < 0)
				break;
			buf[blen] = 0;
			if (t->n_tok >= cap) {
				unsigned long nc = cap ? cap * 2 : 8;
				char **nt = realloc(t->tok,
				    (nc + 1) * sizeof (char *));
				if (nt == 0)
					return (0);
				t->tok = nt;
				cap = nc;
			}
			{
				char *cp = malloc(blen + 1);
				if (cp == 0)
					return (0);
				memcpy(cp, buf, blen + 1);
				t->tok[t->n_tok++] = cp;
			}
			blen = 0;
			if (c < 0)
				break;
			continue;
		}
		if (blen + 1 < sizeof (buf))
			buf[blen++] = (char)c;
	}
	if (t->tok != 0)
		t->tok[t->n_tok] = 0;
	return (1);
}

void
readtokens0_free(struct Tokens *t)
{
	unsigned long i;
	for (i = 0; i < t->n_tok; i++)
		free(t->tok[i]);
	free(t->tok);
	t->tok = 0;
	t->n_tok = 0;
}

/* argv-iter: iterate argv or a NUL-token stream (reduced gnulib argv-iter.c;
   the real one drags gnulib attribute macros, so it is reimplemented here). */
struct argv_iterator {
	FILE	*fp;
	size_t	item_idx;
	char	*tok;
	unsigned long	buf_len;
	char	**arg_list;
	char	**p;
};

struct argv_iterator *
argv_iter_init_argv(char **argv)
{
	struct argv_iterator *ai = malloc(sizeof (*ai));
	if (!ai)
		return (0);
	ai->fp = 0;
	ai->arg_list = argv;
	ai->p = argv;
	return (ai);
}

struct argv_iterator *
argv_iter_init_stream(FILE *fp)
{
	struct argv_iterator *ai = malloc(sizeof (*ai));
	if (!ai)
		return (0);
	ai->fp = fp;
	ai->tok = 0;
	ai->buf_len = 0;
	ai->item_idx = 0;
	ai->arg_list = 0;
	return (ai);
}

char *
argv_iter(struct argv_iterator *ai, enum argv_iter_err *err)
{
	if (ai->fp) {
		long len = getdelim(&ai->tok, &ai->buf_len, '\0', ai->fp);
		if (len < 0) {
			*err = feof(ai->fp) ? AI_ERR_EOF : AI_ERR_READ;
			return (0);
		}
		*err = AI_ERR_OK;
		ai->item_idx++;
		return (ai->tok);
	}
	if (*(ai->p) == 0) {
		*err = AI_ERR_EOF;
		return (0);
	}
	*err = AI_ERR_OK;
	return (*(ai->p++));
}

size_t
argv_iter_n_args(struct argv_iterator const *ai)
{
	return (ai->fp ? ai->item_idx : (size_t)(ai->p - ai->arg_list));
}

void
argv_iter_free(struct argv_iterator *ai)
{
	if (ai->fp)
		free(ai->tok);
	free(ai);
}
