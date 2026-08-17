/* argv-iter.h -- interface to the real gnulib lib/argv-iter.c (linked). */
#ifndef WC_ARGV_ITER_H
#define WC_ARGV_ITER_H
#include <stdio.h>
struct argv_iterator;
enum argv_iter_err { AI_ERR_OK = 1, AI_ERR_EOF, AI_ERR_MEM, AI_ERR_READ };
void argv_iter_free(struct argv_iterator *);
struct argv_iterator *argv_iter_init_argv(char **argv);
struct argv_iterator *argv_iter_init_stream(FILE *fp);
char *argv_iter(struct argv_iterator *, enum argv_iter_err *);
size_t argv_iter_n_args(struct argv_iterator const *);
#endif
