#ifndef _SYS_SYSTEMINFO_H
#define _SYS_SYSTEMINFO_H
/* Reduced <sys/systeminfo.h>: the SI_* selectors coreutils uname.c queries. */
#define SI_MACHINE      5
#define SI_ARCHITECTURE 6
#define SI_PLATFORM     513
#define SI_HW_PROVIDER  8
long sysinfo(int command, char *buf, long count);
#endif
