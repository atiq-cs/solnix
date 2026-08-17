/*
 * getopt.h -- gnulib getopt.h stand-in for the solnix coreutils build.  Declares
 * the getopt/getopt_long interface (option struct, no_argument, optarg/optind)
 * that cat.c's option loop uses; the implementation is in getopt.c.
 */
#ifndef CU_GETOPT_H
#define CU_GETOPT_H

#define no_argument       0
#define required_argument 1
#define optional_argument 2

struct option {
	const char *name;
	int has_arg;
	int *flag;
	int val;
};

extern char *optarg;
extern int optind;
extern int opterr;
extern int optopt;

int getopt(int argc, char *const argv[], const char *optstring);
int getopt_long(int argc, char *const argv[], const char *optstring,
    const struct option *longopts, int *longindex);

#endif /* CU_GETOPT_H */
