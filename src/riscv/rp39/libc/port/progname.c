/*
 * progname.c -- the process program-name pointer set by set_program_name().
 * A single definition so multiple coreutils TUs linking the libc share one
 * `program_name` (the gnulib lib/progname.c symbol, here a libc-level common).
 */
char *program_name;
