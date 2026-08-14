/*
 * test_c1d.c - userland self-check for the C1d pure logic that has no kernel
 * dependency: the EXECBUFFER command-stream size guard, the GET_CAPS capset
 * index-match + max-size clamp, and the SUBMIT_3D contiguous cmd+extra layout
 * arithmetic. Re-implements only the branches under test and asserts them; NOT
 * a substitute for running the driver under QEMU.
 *
 *   cc -o test_c1d test_c1d.c && ./test_c1d
 *
 * The smallest thing that fails if EXECBUFFER stops rejecting a zero/oversized
 * command buffer (a copyin overflow / OOM), the capset match returns the wrong
 * blob or over-copies past the user buffer, or the exec_extra offset math puts
 * the response over the command bytes.
 */
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

#define VIRTIO_GPU_MAX_EXECBUF	(64u * 1024 * 1024)
#define VIRTIO_GPU_MAX_CAPSET	(64u * 1024)
#define EINVAL	22
#define P2ROUNDUP(x, a)	(((x) + ((a) - 1)) & ~((size_t)(a) - 1))

/* mirror of the execbuffer size guard in virtio_gpu_ioctl_execbuffer. */
static int
execbuf_guard(uint32_t size)
{
	if (size == 0 || size > VIRTIO_GPU_MAX_EXECBUF)
		return (EINVAL);
	return (0);
}

/* mirror of the get_caps size clamp: size = min(max_size or req.size, req.size). */
static uint32_t
capset_clamp(uint32_t capset_max_size, uint32_t req_size)
{
	uint32_t size = capset_max_size;
	if (size == 0 || size > req_size)
		size = req_size;
	return (size);
}

/*
 * mirror of the capset index->id match in virtio_gpu_ioctl_get_caps: walk
 * num_capsets, return the index whose id equals the requested id, else -1.
 */
static int
capset_match(const uint32_t *ids, uint32_t n, uint32_t want)
{
	for (uint32_t i = 0; i < n; i++)
		if (ids[i] == want)
			return ((int)i);
	return (-1);
}

/* mirror of exec_extra layout: response starts after 16-aligned [cmd|extra]. */
static size_t
exec_resp_off(size_t cmd_len, size_t extra_len)
{
	return (P2ROUNDUP(cmd_len + extra_len, 16));
}

int
main(void)
{
	/* execbuffer guard: zero and oversized rejected; normal accepted. */
	assert(execbuf_guard(0) == EINVAL);
	assert(execbuf_guard(VIRTIO_GPU_MAX_EXECBUF + 1) == EINVAL);
	assert(execbuf_guard(4096) == 0);
	assert(execbuf_guard(VIRTIO_GPU_MAX_EXECBUF) == 0);

	/* capset clamp: never exceeds the user buffer; uses host max when smaller. */
	assert(capset_clamp(1024, 8192) == 1024);	/* host caps smaller */
	assert(capset_clamp(16384, 8192) == 8192);	/* clamp to user size */
	assert(capset_clamp(0, 8192) == 8192);		/* host unknown -> user */

	/* capset match: VIRGL=1, VIRGL2=2, VENUS=4 among the host's capsets. */
	uint32_t ids[] = { 1, 2, 4 };
	assert(capset_match(ids, 3, 4) == 2);		/* venus at index 2 */
	assert(capset_match(ids, 3, 1) == 0);		/* virgl at index 0 */
	assert(capset_match(ids, 3, 3) == -1);		/* gfxstream absent */

	/* exec_extra: response never overlaps the command+payload region. */
	assert(exec_resp_off(24, 0) == 32);		/* cmd only, 16-aligned */
	assert(exec_resp_off(24, 40) == 64);		/* cmd + submit stream */
	assert(exec_resp_off(16, 0) == 16);		/* already aligned */

	printf("C1d logic self-check: PASS\n");
	return (0);
}
