/*
 * stdio2.c -- solnix riscv64 libc: the read-capable FILE* family (fopen/fclose/
 * fread/fgets/fgetc/getc/fseek/ftell) over the real open/read/lseek/close
 * syscalls, plus snprintf/sprintf/vsnprintf built on the existing vfprintf
 * conversion loop targeting a fixed-size memory buffer.
 *
 * A fopen'd stream is a heap-allocated FILE with its own read buffer; fread/
 * fgetc refill it from the fd via read(2); ftell/fseek track/reposition the
 * logical position (accounting for buffered-but-unread bytes) via lseek(2).
 * This is the read side the write-only R-P39 stdio lacked, so a util that
 * opens files with fopen (not just raw fds) links the real libc.
 *
 * CRIB PROVENANCE: the buffered FILE with a fill-buffer + fgetc-refills-from-fd
 * model is C89 stdio (illumos libc _filbuf/getc); snprintf redirecting the
 * vfprintf conversion loop into a bounded memory buffer is the standard
 * memory-stream trick (a FILE whose "flush" is a truncating memcpy).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* open flags matching the kernel proc_openf (proc.c): O_CREAT/O_TRUNC/O_APPEND. */
#define O_RDONLY 0x000
#define O_WRONLY 0x001
#define O_RDWR   0x002
#define O_APPEND 0x008
#define O_CREAT  0x100
#define O_TRUNC  0x200

extern int open(const char *path, int flags, ...);

FILE *
fopen(const char *path, const char *mode)
{
	int flags = O_RDONLY;
	FILE *f;
	char *rb;

	if (mode == 0)
		return ((void *)0);
	if (mode[0] == 'w')
		flags = O_WRONLY | O_CREAT | O_TRUNC;
	else if (mode[0] == 'a')
		flags = O_WRONLY | O_CREAT | O_APPEND;
	else if (mode[0] == 'r' && mode[1] == '+')
		flags = O_RDWR;
	else /* "r" */
		flags = O_RDONLY;

	int fd = open(path, flags);
	if (fd < 0)
		return ((void *)0);
	f = malloc(sizeof(*f));
	if (f == (void *)0) {
		close(fd);
		return ((void *)0);
	}
	rb = malloc(BUFSIZ);
	if (rb == (void *)0) {
		free(f);
		close(fd);
		return ((void *)0);
	}
	f->fd = fd;
	f->flags = (mode[0] == 'w' || mode[0] == 'a') ? __F_WR : 0;
	f->buf = rb;
	f->bufsz = BUFSIZ;
	f->bufn = 0;		/* WR: bytes pending; RD: bytes available */
	f->bufpos = 0;		/* RD: next byte to hand out of buf */
	return (f);
}

int
fclose(FILE *f)
{
	int r;
	if (f == (void *)0)
		return (EOF);
	if (f->flags & __F_WR)
		fflush(f);
	r = close(f->fd);
	/*
	 * Never free the standard streams: stdin/stdout/stderr are static
	 * FILEs with static buffers, so freeing them (or their buffers) would
	 * corrupt the heap -- glibc/illumos likewise never free the std streams
	 * on fclose.  gnulib's close_stdout (an atexit hook) does fclose(stdout),
	 * which routed here and called free(&__stdout).  A heap FILE (from
	 * fopen) is freed normally.
	 */
	if (f != stdin && f != stdout && f != stderr) {
		if (f->buf != (void *)0)
			free(f->buf);
		free(f);
	}
	return (r == 0 ? 0 : EOF);
}

/* refill a read stream's buffer from the fd; return bytes read (0 == EOF). */
static size_t
__refill(FILE *f)
{
	ssize_t n = read(f->fd, f->buf, f->bufsz);
	if (n <= 0) {
		f->bufn = 0;
		f->bufpos = 0;
		if (n == 0)
			f->flags |= __F_EOF;
		else
			f->flags |= __F_ERR;
		return (0);
	}
	f->bufn = (size_t)n;
	f->bufpos = 0;
	return ((size_t)n);
}

int
fgetc(FILE *f)
{
	if (f == (void *)0)
		return (EOF);
	if (f->bufpos >= f->bufn)
		if (__refill(f) == 0)
			return (EOF);
	return ((unsigned char)f->buf[f->bufpos++]);
}

int getc(FILE *f) { return (fgetc(f)); }
int getchar(void) { return (fgetc(stdin)); }

size_t
fread(void *ptr, size_t sz, size_t n, FILE *f)
{
	unsigned char *p = ptr;
	size_t want = sz * n, got = 0;
	if (sz == 0 || n == 0 || f == (void *)0)
		return (0);
	while (got < want) {
		if (f->bufpos >= f->bufn)
			if (__refill(f) == 0)
				break;
		size_t avail = f->bufn - f->bufpos;
		size_t take = (want - got < avail) ? (want - got) : avail;
		memcpy(p + got, f->buf + f->bufpos, take);
		f->bufpos += take;
		got += take;
	}
	return (got / sz);
}

char *
fgets(char *s, int size, FILE *f)
{
	int i = 0, c;
	if (size <= 0 || f == (void *)0)
		return ((void *)0);
	while (i < size - 1) {
		c = fgetc(f);
		if (c == EOF) {
			if (i == 0)
				return ((void *)0);
			break;
		}
		s[i++] = (char)c;
		if (c == '\n')
			break;
	}
	s[i] = 0;
	return (s);
}

long
ftell(FILE *f)
{
	long pos;
	if (f == (void *)0)
		return (-1);
	pos = lseek(f->fd, 0, 1 /* SEEK_CUR */);
	if (pos < 0)
		return (-1);
	/* subtract bytes buffered-but-not-yet-handed-out (read streams). */
	if (!(f->flags & __F_WR))
		pos -= (long)(f->bufn - f->bufpos);
	return (pos);
}

int
fseek(FILE *f, long off, int whence)
{
	if (f == (void *)0)
		return (-1);
	if (f->flags & __F_WR)
		fflush(f);
	f->bufn = 0;		/* drop any buffered read data */
	f->bufpos = 0;
	f->flags &= ~__F_EOF;
	if (lseek(f->fd, off, whence) < 0)
		return (-1);
	return (0);
}

int feof(FILE *f)   { return (f && (f->flags & __F_EOF)) ? 1 : 0; }
int ferror(FILE *f) { return (f && (f->flags & __F_ERR)) ? 1 : 0; }
void clearerr(FILE *f) { if (f) f->flags &= ~(__F_ERR | __F_EOF); }
int fpurge(FILE *f) { if (f) { f->bufn = 0; f->bufpos = 0; } return 0; }

/* --- snprintf/sprintf/vsnprintf over a bounded memory-target FILE --- */
/*
 * A string-target FILE: fputc (called by vfprintf) appends into a caller buffer
 * up to bufsz-1 bytes, tracking the would-be length in bufn.  __F_STR marks it
 * so fputc writes to memory instead of a fd.
 */
int
vsnprintf(char *s, size_t size, const char *fmt, va_list ap)
{
	FILE mem;
	mem.fd = -1;
	mem.flags = __F_STR;
	mem.buf = s;
	mem.bufsz = size;
	mem.bufn = 0;
	mem.bufpos = 0;
	(void) vfprintf(&mem, fmt, ap);
	if (size > 0) {
		size_t end = (mem.bufn < size - 1) ? mem.bufn : size - 1;
		s[end] = 0;
	}
	return ((int)mem.bufn);
}

int
snprintf(char *s, size_t size, const char *fmt, ...)
{
	va_list ap;
	int r;
	va_start(ap, fmt);
	r = vsnprintf(s, size, fmt, ap);
	va_end(ap);
	return (r);
}

int
sprintf(char *s, const char *fmt, ...)
{
	va_list ap;
	int r;
	va_start(ap, fmt);
	r = vsnprintf(s, (size_t)-1, fmt, ap);
	va_end(ap);
	return (r);
}
