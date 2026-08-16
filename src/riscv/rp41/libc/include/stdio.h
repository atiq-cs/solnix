#ifndef _STDIO_H
#define _STDIO_H
#include <stddef.h>
#include <stdarg.h>

#define BUFSIZ 1024
#define EOF (-1)

typedef struct __FILE FILE;
struct __FILE {
	int	fd;
	int	flags;		/* __F_WR | __F_ERR | __F_EOF | __F_STR */
	char	*buf;
	size_t	bufsz;
	size_t	bufn;		/* WR/STR: bytes pending/written; RD: bytes avail */
	size_t	bufpos;		/* RD: next buffered byte to hand out */
};
#define __F_WR	0x1
#define __F_ERR	0x2
#define __F_EOF	0x4
#define __F_STR	0x8		/* snprintf memory-target stream */

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
int sprintf(char *s, const char *fmt, ...);
int vsnprintf(char *s, size_t n, const char *fmt, va_list ap);

/* R-P40: read-capable FILE* family over open/read/lseek/close. */
FILE *fopen(const char *path, const char *mode);
int fclose(FILE *f);
size_t fread(void *ptr, size_t sz, size_t n, FILE *f);
char *fgets(char *s, int size, FILE *f);
int fgetc(FILE *f);
int getc(FILE *f);
int getchar(void);
long ftell(FILE *f);
int fseek(FILE *f, long off, int whence);
int feof(FILE *f);
int ferror(FILE *f);
int fileno(FILE *f);
int setvbuf(FILE *f, char *buf, int mode, size_t size);
#define _IONBF 2
#define _IOLBF 1
#define _IOFBF 0
void __stdio_flush_all(void);	/* run at exit(): flush every stream */
#endif
