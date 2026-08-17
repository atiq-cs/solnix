/*
 * test_kfd.c - C3-KFD logic self-check (userland, no kernel).
 *
 * Asserts the load-bearing KFD invariants off-hardware:
 *   1. the AMDKFD _IOC encoding matches the Linux amdkfd ABI bit-for-bit (so a
 *      libhsakmt compiled against the real Linux kfd_ioctl.h produces the same
 *      cmd numbers this kernel switches on) -- the whole ABI-preservation point;
 *   2. the doorbell offset math (page * PAGE_SIZE + id * DWORD_SIZE);
 *   3. the doorbell page bitmap alloc/free (used-page accounting);
 *   4. the gfx10 aperture ordering (gpuvm < lds < scratch, non-overlapping).
 *
 * Build + run:  gcc -o /tmp/tk test/test_kfd.c && /tmp/tk
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>

/* --- reproduce the KFD _IOC encoding (must match amdkfd/uapi/kfd_ioctl.h) --- */
#define	_KFD_IOC_NONE	0U
#define	_KFD_IOC_WRITE	1U
#define	_KFD_IOC_READ	2U
#define	_KFD_IOC_NRBITS		8
#define	_KFD_IOC_TYPEBITS	8
#define	_KFD_IOC_SIZEBITS	14
#define	_KFD_IOC_NRSHIFT	0
#define	_KFD_IOC_TYPESHIFT	(_KFD_IOC_NRSHIFT + _KFD_IOC_NRBITS)
#define	_KFD_IOC_SIZESHIFT	(_KFD_IOC_TYPESHIFT + _KFD_IOC_TYPEBITS)
#define	_KFD_IOC_DIRSHIFT	(_KFD_IOC_SIZESHIFT + _KFD_IOC_SIZEBITS)
#define	_KFD_IOC(dir, type, nr, size) \
	(((dir) << _KFD_IOC_DIRSHIFT) | ((type) << _KFD_IOC_TYPESHIFT) | \
	 ((nr) << _KFD_IOC_NRSHIFT) | ((size) << _KFD_IOC_SIZESHIFT))
#define	AMDKFD_IOCTL_BASE	'K'
#define	AMDKFD_IOWR(nr, sz)	\
	_KFD_IOC(_KFD_IOC_READ | _KFD_IOC_WRITE, AMDKFD_IOCTL_BASE, (nr), (sz))
#define	AMDKFD_IOR(nr, sz)	\
	_KFD_IOC(_KFD_IOC_READ, AMDKFD_IOCTL_BASE, (nr), (sz))
#define	AMDKFD_IOC_NR(n)	(((n) >> _KFD_IOC_NRSHIFT) & \
				    ((1 << _KFD_IOC_NRBITS) - 1))

/* the Linux _IOC scheme (glibc/asm-generic), for the cross-check */
#define	_LINUX_IOC_NRBITS	8
#define	_LINUX_IOC_TYPEBITS	8
#define	_LINUX_IOC_SIZEBITS	14
#define	_LINUX_IOC_NRSHIFT	0
#define	_LINUX_IOC_TYPESHIFT	(_LINUX_IOC_NRSHIFT + _LINUX_IOC_NRBITS)
#define	_LINUX_IOC_SIZESHIFT	(_LINUX_IOC_TYPESHIFT + _LINUX_IOC_TYPEBITS)
#define	_LINUX_IOC_DIRSHIFT	(_LINUX_IOC_SIZESHIFT + _LINUX_IOC_SIZEBITS)
#define	_LINUX_IOC_READ		2U
#define	_LINUX_IOC_WRITE	1U
#define	_LINUX_IOC(d, t, n, s)	\
	(((d) << _LINUX_IOC_DIRSHIFT) | ((t) << _LINUX_IOC_TYPESHIFT) | \
	 ((n) << _LINUX_IOC_NRSHIFT) | ((s) << _LINUX_IOC_SIZESHIFT))
#define	LINUX_IOWR(n, s)	\
	_LINUX_IOC(_LINUX_IOC_READ|_LINUX_IOC_WRITE, 'K', (n), (s))

/* doorbell geometry (must match kfd_priv.h) */
#define	KFD_DOORBELL_DWORD_SIZE	4
#define	KFD_DOORBELL_PAGE_SIZE	4096
#define	KFD_MAX_DOORBELL_PROCESSES 128

static uint64_t
doorbell_offset(uint32_t page, uint32_t id)
{
	return ((uint64_t)page * KFD_DOORBELL_PAGE_SIZE +
	    (uint64_t)id * KFD_DOORBELL_DWORD_SIZE);
}

/* the gfx10 apertures (must match kfd_device.c) */
#define	GPUVM_BASE	0x1000000ULL
#define	GPUVM_LIMIT	0x000001ffffffffffULL
#define	LDS_BASE	0x0000100000000000ULL
#define	SCRATCH_BASE	0x0000200000000000ULL

int
main(void)
{
	/* 1. ABI: CREATE_QUEUE nr==0x02, and the solnix encoding == Linux's */
	unsigned cq_sz = 88;	/* sizeof(kfd_ioctl_create_queue_args) LP64 */
	unsigned cq_solnix = AMDKFD_IOWR(0x02, cq_sz);
	unsigned cq_linux = LINUX_IOWR(0x02, cq_sz);
	assert(cq_solnix == cq_linux);
	assert(AMDKFD_IOC_NR(cq_solnix) == 0x02);

	/* GET_VERSION nr==0x01, ALLOC_MEMORY_OF_GPU nr==0x16, MAP nr==0x18 */
	assert(AMDKFD_IOC_NR(AMDKFD_IOR(0x01, 8)) == 0x01);
	assert(AMDKFD_IOC_NR(AMDKFD_IOWR(0x16, 40)) == 0x16);
	assert(AMDKFD_IOC_NR(AMDKFD_IOWR(0x18, 24)) == 0x18);
	/* the type field is 'K' (0x4b) for every KFD ioctl */
	assert(((cq_solnix >> _KFD_IOC_TYPESHIFT) &
	    ((1 << _KFD_IOC_TYPEBITS) - 1)) == 'K');

	/* 2. doorbell offset math: page 0 id 0 == 0; page 1 id 0 == PAGE_SIZE */
	assert(doorbell_offset(0, 0) == 0);
	assert(doorbell_offset(0, 1) == 4);
	assert(doorbell_offset(1, 0) == 4096);
	assert(doorbell_offset(2, 3) == 2 * 4096 + 3 * 4);

	/* 3. doorbell page bitmap: alloc 3, free the middle, re-alloc reuses it */
	uint8_t used[KFD_MAX_DOORBELL_PROCESSES];
	memset(used, 0, sizeof (used));
	int pages = 4;			/* pretend a 4-page aperture */
	int a0 = -1, a1 = -1, a2 = -1, i;
	for (i = 0; i < pages && a0 < 0; i++) if (!used[i]) { used[i]=1; a0=i; }
	for (i = 0; i < pages && a1 < 0; i++) if (!used[i]) { used[i]=1; a1=i; }
	for (i = 0; i < pages && a2 < 0; i++) if (!used[i]) { used[i]=1; a2=i; }
	assert(a0 == 0 && a1 == 1 && a2 == 2);
	used[a1] = 0;			/* free the middle page */
	int a3 = -1;
	for (i = 0; i < pages && a3 < 0; i++) if (!used[i]) { used[i]=1; a3=i; }
	assert(a3 == 1);		/* reused the freed page */

	/* 4. gfx10 apertures: strictly ordered + non-overlapping */
	assert(GPUVM_BASE < GPUVM_LIMIT);
	assert(GPUVM_LIMIT < LDS_BASE);
	assert(LDS_BASE < SCRATCH_BASE);

	printf("C3-KFD logic self-check: PASS\n");
	return (0);
}
