/* OpenBSD config(8) count header: no efifb on the illumos build unless
 * -DNEFIFB=1 is passed (the probe measures both configurations). */
#ifndef NEFIFB
#define NEFIFB 0
#endif
