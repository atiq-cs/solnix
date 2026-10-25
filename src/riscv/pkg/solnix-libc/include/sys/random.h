/* rvlogin: getrandom(2) = the kernel's virtio-rng (uts/viornd.c, syscall 278); ENOSYS without a device. */
#ifndef _SYS_RANDOM_H
#define	_SYS_RANDOM_H
#include <sys/types.h>
#define	GRND_NONBLOCK 1
#define	GRND_RANDOM 2
ssize_t getrandom(void *, size_t, unsigned int);
int getentropy(void *, size_t);
#endif
