/* readtokens0.h -- reduced: only tok/n_tok are touched by wc.c.  The obstack
   members the full gnulib struct carries are elided (the --files0-from path
   this reduced form serves does not need them here). */
#ifndef WC_READTOKENS0_H
#define WC_READTOKENS0_H
#include <stdio.h>
struct Tokens { size_t n_tok; char **tok; size_t *tok_len; };
void readtokens0_init(struct Tokens *t);
void readtokens0_free(struct Tokens *t);
int  readtokens0(FILE *in, struct Tokens *t);
#endif
