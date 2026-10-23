#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
int main(int argc, char **argv, char **envp) {
	struct timespec a, b;
	printf("hello argc=%d argv0=%s PATH=%s\n", argc, argv[0], getenv("PATH") ? getenv("PATH") : "(null)");
	if (clock_gettime(CLOCK_MONOTONIC, &a) || clock_gettime(CLOCK_REALTIME, &b)) { puts("HELLO FAIL clock"); return 1; }
	printf("HELLO PASS mono=%ld.%03ld\n", (long)a.tv_sec, a.tv_nsec / 1000000);
	return 0;
}
