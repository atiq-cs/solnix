/*
 * stdio.c -- solnix riscv64 libc buffered standard I/O.  Three predefined
 * streams (stdin/stdout/stderr), byte + block writes buffered through a
 * per-stream buffer flushed to the fd via write(2), and a minimal printf family
 * (%s %c %d %i %u %x %X %p %ld %lu %lx, field width, zero-pad, and the .prec
 * precision on %s -- e.g. %.*s, used by ls abformat_init) covering what the
 * coreutils usage()/diagnostics text and the %b month-format precompute need.
 *
 * CRIB PROVENANCE: the FILE-with-a-flush-buffer model + fwrite/fputc/fflush
 * contract is C89 stdio (illumos libc stdio/_iob); the vfprintf conversion loop
 * is the canonical minimal-printf reference (a switch over the conversion char
 * emitting via the stream), deliberately a subset -- no floating point, no
 * positional args.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static char __out_buf[BUFSIZ];
static char __err_buf[BUFSIZ];
/*
 * R-P53: stdin needs a real read buffer.  Through R-P52 __stdin had buf=NULL /
 * bufsz=0, so __refill() did read(0, NULL, 0) -> 0 -> instant EOF: cut/paste
 * over a pipe read nothing and emitted nothing.  Give stdin a BUFSIZ fill
 * buffer so getc(stdin)/fread(stdin)/getndelim2 actually pull bytes from the
 * fd (the pipe read end init dup2s onto fd 0).
 */
static char __in_buf[BUFSIZ];

static FILE __stdin  = { 0, 0,        __in_buf,  BUFSIZ, 0 };
static FILE __stdout = { 1, __F_WR,   __out_buf, BUFSIZ, 0 };
static FILE __stderr = { 2, __F_WR,   __err_buf, 1,      0 };	/* unbuffered */

FILE *stdin  = &__stdin;
FILE *stdout = &__stdout;
FILE *stderr = &__stderr;

/* the list of buffered streams flushed at exit(). */
static FILE *__streams[] = { &__stdout, &__stderr };

int
fflush(FILE *f)
{
	if (f == (void *)0) {
		__stdio_flush_all();
		return (0);
	}
	if (f->bufn > 0) {
		ssize_t w = write(f->fd, f->buf, f->bufn);
		f->bufn = 0;
		if (w < 0) {
			f->flags |= __F_ERR;
			return (EOF);
		}
	}
	return (0);
}

void
__stdio_flush_all(void)
{
	unsigned i;
	for (i = 0; i < sizeof(__streams) / sizeof(__streams[0]); i++)
		(void) fflush(__streams[i]);
}

int
fputc(int c, FILE *f)
{
	if (f->flags & __F_STR) {		/* snprintf memory target */
		if (f->buf != (void *)0 && f->bufsz > 0 &&
		    f->bufn < f->bufsz - 1)
			f->buf[f->bufn] = (char)c;
		f->bufn++;		/* true length, even past the cap */
		return (c & 0xff);
	}
	if (f->buf == (void *)0 || f->bufsz == 0) {	/* unbuffered fd */
		char b = (char)c;
		if (write(f->fd, &b, 1) != 1) {
			f->flags |= __F_ERR;
			return (EOF);
		}
		return (c & 0xff);
	}
	f->buf[f->bufn++] = (char)c;
	if (f->bufn >= f->bufsz || c == '\n')	/* line/full flush */
		if (fflush(f) == EOF)
			return (EOF);
	return (c & 0xff);
}

int putc(int c, FILE *f) { return (fputc(c, f)); }
int putchar(int c)       { return (fputc(c, stdout)); }

int
fputs(const char *s, FILE *f)
{
	while (*s)
		if (fputc(*s++, f) == EOF)
			return (EOF);
	return (0);
}

int
puts(const char *s)
{
	if (fputs(s, stdout) == EOF)
		return (EOF);
	return (fputc('\n', stdout));
}

size_t
fwrite(const void *p, size_t sz, size_t n, FILE *f)
{
	const unsigned char *b = p;
	size_t total = sz * n, i;
	if (sz == 0 || n == 0)
		return (0);
	for (i = 0; i < total; i++)
		if (fputc(b[i], f) == EOF)
			return (i / sz);
	return (n);
}

/* --- minimal printf family --- */
static void
__emit_str(FILE *f, const char *s, int width, int left, int prec)
{
	int len;
	int pad;
	if (s == NULL)
		s = "(null)";
	len = (int)strlen(s);
	if (prec >= 0 && prec < len)	/* precision truncates a string */
		len = prec;
	pad = width - len;
	if (!left)
		while (pad-- > 0)
			fputc(' ', f);
	for (int i = 0; i < len; i++)
		fputc(s[i], f);
	if (left)
		while (pad-- > 0)
			fputc(' ', f);
}

static void
__emit_num(FILE *f, unsigned long v, int base, int uc, int neg,
    int width, int zero)
{
	char tmp[24];
	const char *dig = uc ? "0123456789ABCDEF" : "0123456789abcdef";
	int i = 0, pad;
	if (v == 0)
		tmp[i++] = '0';
	while (v) {
		tmp[i++] = dig[v % base];
		v /= base;
	}
	pad = width - i - (neg ? 1 : 0);
	if (neg && zero)
		fputc('-', f);
	while (pad-- > 0)
		fputc(zero ? '0' : ' ', f);
	if (neg && !zero)
		fputc('-', f);
	while (i--)
		fputc(tmp[i], f);
}

int
vfprintf(FILE *f, const char *fmt, va_list ap)
{
	for (; *fmt; fmt++) {
		int width = 0, zero = 0, left = 0, lng = 0, prec = -1;
		if (*fmt != '%') {
			fputc(*fmt, f);
			continue;
		}
		fmt++;
		while (*fmt == '-' || *fmt == '0') {
			if (*fmt == '-') left = 1;
			else zero = 1;
			fmt++;
		}
		if (*fmt == '*') {	/* dynamic field width from an int arg */
			width = va_arg(ap, int);
			if (width < 0) { left = 1; width = -width; }
			fmt++;
		} else {
			while (*fmt >= '0' && *fmt <= '9')
				width = width * 10 + (*fmt++ - '0');
		}
		if (*fmt == '.') {	/* precision: .* (int arg) or .N */
			fmt++;
			prec = 0;
			if (*fmt == '*') {
				prec = va_arg(ap, int);
				if (prec < 0) prec = -1;
				fmt++;
			} else {
				while (*fmt >= '0' && *fmt <= '9')
					prec = prec * 10 + (*fmt++ - '0');
			}
		}
		while (*fmt == 'l') { lng++; fmt++; }
		if (*fmt == 'z') { lng = 1; fmt++; }	/* size_t == long here */
		if (*fmt == 'j') { lng = 1; fmt++; }	/* R-P50: intmax_t == long (stat %ju/%jo/%jd) */
		if (*fmt == 't') { lng = 1; fmt++; }	/* ptrdiff_t == long */
		switch (*fmt) {
		case 's':
			__emit_str(f, va_arg(ap, char *), width, left, prec);
			break;
		case 'c':
			fputc((char)va_arg(ap, int), f);
			break;
		case 'd':
		case 'i': {
			long v = lng ? va_arg(ap, long) : (long)va_arg(ap, int);
			int neg = v < 0;
			unsigned long uv = neg ? (unsigned long)(-v)
			    : (unsigned long)v;
			__emit_num(f, uv, 10, 0, neg, width, zero);
			break;
		}
		case 'u': {
			unsigned long v = lng ? va_arg(ap, unsigned long)
			    : (unsigned long)va_arg(ap, unsigned int);
			__emit_num(f, v, 10, 0, 0, width, zero);
			break;
		}
		case 'x':
		case 'X': {
			unsigned long v = lng ? va_arg(ap, unsigned long)
			    : (unsigned long)va_arg(ap, unsigned int);
			__emit_num(f, v, 16, *fmt == 'X', 0, width, zero);
			break;
		}
		case 'o': {			/* R-P50: octal (stat mode %jo) */
			unsigned long v = lng ? va_arg(ap, unsigned long)
			    : (unsigned long)va_arg(ap, unsigned int);
			__emit_num(f, v, 8, 0, 0, width, zero);
			break;
		}
		case 'p':
			fputc('0', f); fputc('x', f);
			__emit_num(f, (unsigned long)va_arg(ap, void *), 16, 0,
			    0, width, zero);
			break;
		case '%':
			fputc('%', f);
			break;
		default:
			fputc('%', f);
			if (*fmt)
				fputc(*fmt, f);
			break;
		}
	}
	return (0);
}

int
fprintf(FILE *f, const char *fmt, ...)
{
	va_list ap;
	int r;
	va_start(ap, fmt);
	r = vfprintf(f, fmt, ap);
	va_end(ap);
	return (r);
}

int
printf(const char *fmt, ...)
{
	va_list ap;
	int r;
	va_start(ap, fmt);
	r = vfprintf(stdout, fmt, ap);
	va_end(ap);
	return (r);
}
