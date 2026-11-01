/* HCI event framing over a ugen interrupt-IN byte stream (solnix, new code). */
#ifndef _UGEN_EVQ_H
#define	_UGEN_EVQ_H

#include <stddef.h>
#include <stdint.h>

/* Room for two maximum-size HCI events (2 + 255 bytes each). */
struct ugen_evq {
	uint8_t	buf[2 * 257];
	size_t	len;
};

void ugen_evq_init(struct ugen_evq *);
size_t ugen_evq_room(const struct ugen_evq *);
void ugen_evq_push(struct ugen_evq *, const uint8_t *, size_t);
int ugen_evq_pop(struct ugen_evq *, uint8_t *, size_t, size_t *);

#endif
