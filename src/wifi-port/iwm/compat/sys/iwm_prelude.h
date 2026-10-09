/*
 * Forced-include prelude for the iwm translation unit: the shared iwx/
 * net80211 prelude plus the few OpenBSD <sys/cdefs.h> spellings iwm uses
 * that iwx does not.
 */
#ifndef _IWM_PRELUDE_H
#define _IWM_PRELUDE_H
#include "../../../net80211-openbsd/compat/sys/n80211_symrename.h"	/* first */
#include <sys/iwx_prelude.h>

/* OpenBSD <sys/cdefs.h> branch hints (if_iwm.c:4911). */
#ifndef __predict_false
#define __predict_false(e)	__builtin_expect(((e) != 0), 0)
#define __predict_true(e)	__builtin_expect(((e) != 0), 1)
#endif
#endif /* _IWM_PRELUDE_H */
