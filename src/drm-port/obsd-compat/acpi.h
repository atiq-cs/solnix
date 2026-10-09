/* OpenBSD config(8) count header: no acpi on the illumos build unless
 * -DNACPI=1 is passed (the probe measures both configurations). */
#ifndef NACPI
#define NACPI 0
#endif
