/* rvsrv: the four string functions lwIP calls, for the freestanding kernel (lwip/port/libk.c). */
#ifndef _RVSRV_STRING_H
#define	_RVSRV_STRING_H
#include <stddef.h>
void *memcpy(void *, const void *, size_t);
void *memmove(void *, const void *, size_t);
void *memset(void *, int, size_t);
int memcmp(const void *, const void *, size_t);
size_t strlen(const char *);
int strncmp(const char *, const char *, size_t);
#endif
