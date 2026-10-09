/* OpenBSD config(8) count header: no drm on the illumos build unless
 * -DNDRM=1 is passed (the probe measures both configurations). */
#ifndef NDRM
#define NDRM 0
#endif
