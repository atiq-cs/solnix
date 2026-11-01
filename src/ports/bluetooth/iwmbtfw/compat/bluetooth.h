/* FreeBSD <bluetooth.h> subset: bdaddr_t only (solnix compat, new code). */
#ifndef _SOLNIX_COMPAT_BLUETOOTH_H
#define	_SOLNIX_COMPAT_BLUETOOTH_H
#include <stdint.h>
typedef struct {
	uint8_t	b[6];
} __attribute__((packed)) bdaddr_t;
#endif
