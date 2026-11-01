/* newlib's <regex.h> uses off_t without including <sys/types.h>. */
#include <sys/types.h>
#include_next <regex.h>
