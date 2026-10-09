/* OpenBSD config(8) count header: no bios on the illumos build unless
 * -DNBIOS=1 is passed (the probe measures both configurations). */
#ifndef NBIOS
#define NBIOS 0
#endif
