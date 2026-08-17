/*
 * freopen_safer shim -- R-P54: the reduced solnix libc has fopen/fclose/open/
 * dup2 but not freopen.  tsort (via stdio--.h) remaps freopen(file,"r",stdin)
 * to freopen_safer; it only ever redirects stdin to a named input file.  This
 * shim fopen's the file and dup2's its fd onto the target stream's fd, so the
 * existing FILE (stdin) now reads the file -- the one behaviour tsort needs.
 * Self-contained: no libc header that would collide with the gnulib includes.
 */
struct __file;
typedef struct __file FILE;

extern FILE *fopen(const char *, const char *);
extern int fileno(FILE *);
extern int dup2(int, int);
extern int fclose(FILE *);

FILE *
freopen_safer(const char *name, const char *mode, FILE *stream)
{
	FILE *nf = fopen(name, mode);
	if (nf == 0)
		return (0);
	if (dup2(fileno(nf), fileno(stream)) < 0) {
		fclose(nf);
		return (0);
	}
	fclose(nf);
	return (stream);
}
