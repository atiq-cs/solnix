#ifndef _STDLIB_H
#define _STDLIB_H
#include <stddef.h>
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
void *malloc(size_t n);
void free(void *p);
void *calloc(size_t nmemb, size_t sz);
void *realloc(void *p, size_t n);
void exit(int status);
void _exit(int status);
int atexit(void (*fn)(void));
char *getenv(const char *name);
void abort(void);
int atoi(const char *s);
long atol(const char *s);
long strtol(const char *s, char **endp, int base);
#endif
