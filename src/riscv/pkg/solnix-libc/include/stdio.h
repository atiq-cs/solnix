/* newlib 4.5.0 exports getline/getdelim only as __getline/__getdelim; glue.c adds the POSIX names. */
#include_next <stdio.h>
#ifndef _SOLNIX_STDIO_EXTRA
#define	_SOLNIX_STDIO_EXTRA
ssize_t getdelim(char **, size_t *, int, FILE *);
ssize_t getline(char **, size_t *, FILE *);
#endif
