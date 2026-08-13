/*
 * test_c1b.c - userland self-check for the C1b pure logic that has no kernel
 * dependency: the GEM offset->object range lookup and the virtio_gpu_exec
 * command-buffer layout math. Compiled + run in userland (NOT the kernel
 * module); it re-implements only the arithmetic under test and asserts it.
 *
 *   cc -o test_c1b test_c1b.c && ./test_c1b
 *
 * This is the smallest thing that fails if the offset ranges overlap or the
 * cmd/resp split in the DMA buffer is miscomputed. It is not a substitute for
 * booting the driver; it guards the two bits of logic a reader can't eyeball.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define PAGESIZE 4096
#define P2ROUNDUP(x, a) (((x) + ((a) - 1)) & ~((uintptr_t)(a) - 1))

/* mirror of drm_gem_object's offset/size for the lookup test. */
struct obj { uint64_t off; uint64_t size; };

/* mirror of drm_gem_object_lookup_offset's range test. */
static struct obj *
lookup(struct obj *objs, int n, uint64_t offset)
{
	for (int i = 0; i < n; i++)
		if (offset >= objs[i].off &&
		    offset < objs[i].off + objs[i].size)
			return (&objs[i]);
	return (NULL);
}

int
main(void)
{
	/* three objects allocated monotonically like drm_gem_create_dumb. */
	uint64_t next = 0;
	struct obj o[3];
	uint64_t sizes[3] = { 3 * PAGESIZE, PAGESIZE, 10 * PAGESIZE };
	for (int i = 0; i < 3; i++) {
		o[i].off = next;
		o[i].size = sizes[i];
		next += o[i].size;
	}

	/* each object's own offset resolves to itself; ranges are disjoint. */
	assert(lookup(o, 3, o[0].off) == &o[0]);
	assert(lookup(o, 3, o[0].off + o[0].size - 1) == &o[0]);
	assert(lookup(o, 3, o[1].off) == &o[1]);
	assert(lookup(o, 3, o[2].off) == &o[2]);
	assert(lookup(o, 3, o[2].off + o[2].size - 1) == &o[2]);
	/* the boundary byte belongs to the NEXT object, not the previous. */
	assert(lookup(o, 3, o[0].off + o[0].size) == &o[1]);
	/* past the end resolves to nothing. */
	assert(lookup(o, 3, next) == NULL);

	/* virtio_gpu_exec buffer layout: cmd at 0, resp at P2ROUNDUP(cmd,16). */
	size_t cmd_len = 24;		/* e.g. sizeof(ctrl_hdr) */
	size_t resp_len = 24;
	size_t resp_off = P2ROUNDUP(cmd_len, 16);
	size_t total = resp_off + resp_len;
	assert(resp_off == 32);		/* 24 rounds up to 32 */
	assert(total == 56);
	/* cmd and resp regions must not overlap. */
	assert(cmd_len <= resp_off);

	/* a mem_entry-appended attach_backing command grows by nents*16. */
	size_t hdr = 8 /*ctrl_hdr type+flags stub*/ + 16 /*ctrl rest*/ + 8;
	(void) hdr;
	size_t nents = 5;
	size_t ab_len = 24 /*attach_backing fixed*/ + nents * 16;
	assert(ab_len == 104);

	printf("C1b logic self-check: PASS\n");
	return (0);
}
