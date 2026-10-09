/*
 * OpenBSD <sys/ucred.h>, included by drm's linux/capability.h for the
 * credential type behind suser(). Shadows illumos <sys/ucred.h>, which is
 * the userland ucred_t interface and, under _KERNEL, includes <c2/audit.h>
 * from outside the installed proto. The kernel credential on illumos is
 * cred_t from <sys/cred.h>.
 */
#ifndef _OBSD_COMPAT_SYS_UCRED_H
#define _OBSD_COMPAT_SYS_UCRED_H
#include <sys/cred.h>
#include <obsd_prelude.h>
#endif
