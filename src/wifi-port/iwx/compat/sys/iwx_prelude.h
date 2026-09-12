/*
 * Forced-include prelude for compiling OpenBSD sources against illumos headers.
 *
 * Establishes the BSD scalar aliases and the queue/tree macros BEFORE any
 * OpenBSD header is parsed. Everything here is REAL (equivalent types, or
 * macro headers vendored verbatim); the stubs live in the other compat files
 * and are individually tagged.
 */
#ifndef _IWX_PRELUDE_H
#define _IWX_PRELUDE_H
#include <sys/types.h>
#include <sys/iwx_bsdtypes.h>
#include <sys/queue.h>		/* illumos: TAILQ/LIST/SLIST */
#include <sys/tree.h>		/* compat/: OpenBSD RB/RBT, absent on illumos */
#include <sys/iwx_kernel.h>	/* spl, refcnt, task, timeout, malloc, macros */
#endif
