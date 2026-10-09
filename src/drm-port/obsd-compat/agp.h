/* OpenBSD config(8) count header: no agp on the illumos build unless
 * -DNAGP=1 is passed (the probe measures both configurations). */
#ifndef NAGP
#define NAGP 0
#endif
