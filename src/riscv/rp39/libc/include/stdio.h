#ifndef _STDIO_H
#define _STDIO_H
#include <stddef.h>
#include <stdarg.h>

#define BUFSIZ 1024
#define EOF (-1)

typedef struct __FILE FILE;
struct __FILE {
	int	fd;
	int	flags;		/* __F_WR | __F_ERR | __F_EOF */
	char	*buf;
	size_t	bufsz;
	size_t	bufn;		/* bytes currently buffered */
};
#define __F_WR	0x1
#define __F_ERR	0x2
#define __F_EOF	0x4

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

int fputc(int c, FILE *f);
int putc(int c, FILE *f);
int putchar(int c);
int fputs(const char *s, FILE *f);
int puts(const char *s);
size_t fwrite(const void *p, size_t sz, size_t n, FILE *f);
int fflush(FILE *f);
int fprintf(FILE *f, const char *fmt, ...);
int printf(const char *fmt, ...);
int vfprintf(FILE *f, const char *fmt, va_list ap);
int snprintf(char *s, size_t n, const char *fmt, ...);
void __stdio_flush_all(void);	/* run at exit(): flush every stream */
#endif
