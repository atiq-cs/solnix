/*
 * test_c1c.c - userland self-check for the C1c pure logic that has no kernel
 * dependency: the dma-fence signal-once flag machine, the ww_mutex ticket
 * compare (older-ctx -> wait, younger-ctx -> EDEADLK), and the dma_resv
 * shared-fence array growth. Re-implements only the arithmetic/branches under
 * test and asserts them; NOT a substitute for booting the driver.
 *
 *   cc -o test_c1c test_c1c.c && ./test_c1c
 *
 * This is the smallest thing that fails if signal becomes non-idempotent, the
 * wound/wait comparison inverts (which would deadlock or livelock real GPU
 * submission), or the resv array grows too small.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#define DMA_FENCE_FLAG_ENABLE_SIGNAL_BIT 0
#define DMA_FENCE_FLAG_SIGNALED_BIT      1
#define EDEADLK  45
#define EALREADY 149

/* mirror of drm_dma.c fence_test_and_set: set bit, return prior value. */
static int
test_and_set(unsigned *flags, unsigned bit)
{
	unsigned mask = 1u << bit;
	int was = (*flags & mask) != 0;
	*flags |= mask;
	return (was);
}

/* mirror of dma_fence_signal_locked: signal returns 0 first time, -EINVAL after. */
static int
fence_signal(unsigned *flags)
{
	if (test_and_set(flags, DMA_FENCE_FLAG_SIGNALED_BIT))
		return (-22);	/* -EINVAL */
	return (0);
}

/*
 * mirror of ww_mutex_lock's ctx-vs-ctx decision when a mutex is held by
 * another context: older owner (lower ticket) -> wait (0); younger owner
 * (higher ticket) -> -EDEADLK; same ctx -> -EALREADY.
 */
static int
ww_decide(uint64_t owner_ticket, uint64_t my_ticket, int same_ctx)
{
	if (same_ctx)
		return (-EALREADY);
	if (owner_ticket < my_ticket)
		return (0);		/* older owner: wait it out */
	return (-EDEADLK);		/* younger owner: back off */
}

/* mirror of dma_resv_reserve_shared array growth. */
static uint32_t
resv_grow(uint32_t count, uint32_t max, uint32_t add)
{
	uint32_t need = count + add;
	uint32_t newmax;
	if (need <= max)
		return (max);
	newmax = max ? max : 4;
	while (newmax < need)
		newmax *= 2;
	return (newmax);
}

int
main(void)
{
	/* --- fence: signal is one-shot --- */
	unsigned flags = 0;
	assert(fence_signal(&flags) == 0);	/* first signal succeeds */
	assert(flags & (1u << DMA_FENCE_FLAG_SIGNALED_BIT));
	assert(fence_signal(&flags) == -22);	/* second is a no-op error */

	/* enable-signal bit is independent + idempotent. */
	unsigned f2 = 0;
	assert(test_and_set(&f2, DMA_FENCE_FLAG_ENABLE_SIGNAL_BIT) == 0);
	assert(test_and_set(&f2, DMA_FENCE_FLAG_ENABLE_SIGNAL_BIT) == 1);
	assert((f2 & (1u << DMA_FENCE_FLAG_SIGNALED_BIT)) == 0);

	/* --- ww_mutex wound/wait ticket ordering --- */
	/* I am ticket 5. Owner ticket 3 (older) -> I wait (0). */
	assert(ww_decide(3, 5, 0) == 0);
	/* Owner ticket 9 (younger) -> I back off (-EDEADLK). */
	assert(ww_decide(9, 5, 0) == -EDEADLK);
	/* I already own it -> -EALREADY. */
	assert(ww_decide(5, 5, 1) == -EALREADY);

	/* --- dma_resv shared array growth --- */
	assert(resv_grow(0, 0, 1) == 4);	/* first reserve -> 4 */
	assert(resv_grow(4, 4, 1) == 8);	/* full -> double */
	assert(resv_grow(4, 4, 20) == 32);	/* big add -> next pow2 >= 24 */
	assert(resv_grow(2, 8, 3) == 8);	/* fits -> unchanged */

	printf("C1c logic self-check: PASS\n");
	return (0);
}
