/* hcitest: shared constants (solnix, new code). */
#ifndef _SOLNIX_HCITEST_H
#define	_SOLNIX_HCITEST_H

/* btconfig's inquiry: INQUIRY_LENGTH 10 s -> 10 * 100 / 128 = 7 (x 1.28 s), 10 responses */
#define	HT_INQ_LEN	7
#define	HT_INQ_MAX	10

/* exit codes: each failure path has its own, so a test can name the path it expects */
#define	HT_RC_OK	0
#define	HT_RC_USAGE	2
#define	HT_RC_XPORT	3	/* transport or fixture could not be opened */
#define	HT_RC_ENABLE	4	/* unit did not come up (gate refused, init timeout, transport) */
#define	HT_RC_EMPTY	5	/* inquiry completed with no device */
#define	HT_RC_INQUIRY	6	/* inquiry refused (Command Status) or never completed */
#define	HT_RC_FIXTURE	7	/* the core finished but did not consume the transcript exactly */
#define	HT_RC_SELFTEST	8

struct xport;
int raw_record(const struct xport *, int inquiry);

#endif
