/*
 * HCI event framing for ugen interrupt-IN (solnix, new code).
 *
 * ugen(4D) delivers an interrupt-IN endpoint as a byte stream: it pulls
 * successive USB packets together into one buffer, so packet boundaries are lost.
 * libusb callers expect one HCI event per interrupt transfer. An HCI event is
 * self-delimiting (code, length, length bytes), so we rebuild the boundaries
 * from the stream.
 */
#include <string.h>
#include "ugen_evq.h"

void
ugen_evq_init(struct ugen_evq *q)
{
	q->len = 0;
}

/* Room left for ugen_evq_push (the caller reads that much from the fd). */
size_t
ugen_evq_room(const struct ugen_evq *q)
{
	return (sizeof (q->buf) - q->len);
}

void
ugen_evq_push(struct ugen_evq *q, const uint8_t *p, size_t n)
{
	if (n > ugen_evq_room(q))
		n = ugen_evq_room(q);
	memcpy(q->buf + q->len, p, n);
	q->len += n;
}

/*
 * Pop one complete event into out[size].
 * Returns its full length (2 + param length), 0 if no complete event is queued
 * yet, or -1 if size is too small: that event is dropped, *full gets its
 * length, and out holds its first size bytes.
 */
int
ugen_evq_pop(struct ugen_evq *q, uint8_t *out, size_t size, size_t *full)
{
	size_t elen;

	if (q->len < 2)
		return (0);
	elen = 2 + (size_t)q->buf[1];
	if (q->len < elen)
		return (0);
	*full = elen;
	memcpy(out, q->buf, elen < size ? elen : size);
	memmove(q->buf, q->buf + elen, q->len - elen);
	q->len -= elen;
	return (elen <= size ? (int)elen : -1);
}
