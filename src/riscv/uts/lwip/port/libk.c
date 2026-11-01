/*
 * rvsrv: the libc string routines lwIP needs, for the freestanding kernel.
 * gcc also emits memcpy/memset calls for struct copies at -O2.
 */
#include <stddef.h>

void *
memcpy(void *d, const void *s, size_t n)
{
	unsigned char *dp = d;
	const unsigned char *sp = s;

	while (n-- > 0)
		*dp++ = *sp++;
	return (d);
}

void *
memmove(void *d, const void *s, size_t n)
{
	unsigned char *dp = d;
	const unsigned char *sp = s;

	if (dp < sp) {
		while (n-- > 0)
			*dp++ = *sp++;
	} else {
		while (n-- > 0)
			dp[n] = sp[n];
	}
	return (d);
}

void *
memset(void *d, int c, size_t n)
{
	unsigned char *dp = d;

	while (n-- > 0)
		*dp++ = (unsigned char)c;
	return (d);
}

int
memcmp(const void *a, const void *b, size_t n)
{
	const unsigned char *x = a, *y = b;

	for (; n > 0; n--, x++, y++)
		if (*x != *y)
			return (*x - *y);
	return (0);
}

size_t
strlen(const char *s)
{
	size_t n = 0;

	while (s[n] != '\0')
		n++;
	return (n);
}

int
strncmp(const char *a, const char *b, size_t n)
{
	for (; n > 0; n--, a++, b++) {
		if (*a != *b)
			return ((unsigned char)*a - (unsigned char)*b);
		if (*a == '\0')
			break;
	}
	return (0);
}

int
atoi(const char *s)
{
	int v = 0, neg = 0;

	if (*s == '-') {
		neg = 1;
		s++;
	}
	while (*s >= '0' && *s <= '9')
		v = v * 10 + (*s++ - '0');
	return (neg ? -v : v);
}
