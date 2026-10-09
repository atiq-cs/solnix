/* OpenBSD config(8) count header: no intagp on the illumos build unless
 * -DNINTAGP=1 is passed (the probe measures both configurations). */
#ifndef NINTAGP
#define NINTAGP 0
#endif
