/* OpenBSD config(8) count header: no wsdisplay on the illumos build unless
 * -DNWSDISPLAY=1 is passed (the probe measures both configurations). */
#ifndef NWSDISPLAY
#define NWSDISPLAY 0
#endif
