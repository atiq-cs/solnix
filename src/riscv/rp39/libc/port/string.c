/*
 * string.c -- solnix riscv64 libc string/memory routines.  C89 semantics.
 * CRIB PROVENANCE: standard C library string.h contract (the byte-loop bodies
 * are the canonical reference implementations, e.g. the musl/BSD libc shape).
 */
#include <string.h>

size_t
strlen(const char *s)
{
	const char *p = s;
	while (*p)
		p++;
	return ((size_t)(p - s));
}

int
strcmp(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return ((int)(unsigned char)*a - (int)(unsigned char)*b);
}

int
strncmp(const char *a, const char *b, size_t n)
{
	while (n && *a && *a == *b) {
		a++;
		b++;
		n--;
	}
	if (n == 0)
		return (0);
	return ((int)(unsigned char)*a - (int)(unsigned char)*b);
}

char *
strcpy(char *d, const char *s)
{
	char *r = d;
	while ((*d++ = *s++) != 0)
		;
	return (r);
}

char *
strncpy(char *d, const char *s, size_t n)
{
	char *r = d;
	while (n && (*d = *s) != 0) {
		d++;
		s++;
		n--;
	}
	while (n--)
		*d++ = 0;
	return (r);
}

char *
strcat(char *d, const char *s)
{
	char *r = d;
	while (*d)
		d++;
	while ((*d++ = *s++) != 0)
		;
	return (r);
}

char *
strchr(const char *s, int c)
{
	for (;; s++) {
		if (*s == (char)c)
			return ((char *)s);
		if (*s == 0)
			return ((void *)0);
	}
}

char *
strrchr(const char *s, int c)
{
	const char *last = (void *)0;
	for (;; s++) {
		if (*s == (char)c)
			last = s;
		if (*s == 0)
			return ((char *)last);
	}
}

void *
memcpy(void *d, const void *s, size_t n)
{
	unsigned char *dp = d;
	const unsigned char *sp = s;
	while (n--)
		*dp++ = *sp++;
	return (d);
}

void *
memmove(void *d, const void *s, size_t n)
{
	unsigned char *dp = d;
	const unsigned char *sp = s;
	if (dp < sp) {
		while (n--)
			*dp++ = *sp++;
	} else {
		dp += n;
		sp += n;
		while (n--)
			*--dp = *--sp;
	}
	return (d);
}

void *
memset(void *d, int c, size_t n)
{
	unsigned char *dp = d;
	while (n--)
		*dp++ = (unsigned char)c;
	return (d);
}

int
memcmp(const void *a, const void *b, size_t n)
{
	const unsigned char *pa = a, *pb = b;
	while (n--) {
		if (*pa != *pb)
			return ((int)*pa - (int)*pb);
		pa++;
		pb++;
	}
	return (0);
}
