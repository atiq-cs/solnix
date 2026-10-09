/* OpenBSD config(8) count header: no vga on the illumos build unless
 * -DNVGA=1 is passed (the probe measures both configurations). */
#ifndef NVGA
#define NVGA 0
#endif
