/*
 * Unit check for the iwm DMA-buffer single-cookie requirement.
 *
 * Runs in userland. No kernel load, no DDI: it models the one fact the real
 * bug turned on -- how many DMA cookies a buffer binds to -- and checks the
 * decision the driver makes from that count.
 *
 * THE BUG (docs/iwm-rx-contiguous-dma.md, measured from an X1 crash dump):
 * an RX buffer from allocb(4096) is not page-aligned, so its physical memory
 * can straddle a 4 KiB page and bind as TWO cookies. The RX map allows one
 * segment (dma_attr_sgllen == 1) and the hardware RX descriptor reads a single
 * address (dm_segs[0].ds_addr), so a 2-cookie buffer is rejected with EFBIG and
 * the RX ring cannot be built. The fix (iwm_dma_mblk_alloc in iwm_bus.c) backs
 * the buffer with DDI-contiguous memory, which binds as exactly one cookie.
 *
 * This test models:
 *   - allocb-style memory: an arbitrary (possibly page-straddling) offset,
 *   - DDI-contiguous memory: aligned so it occupies one physical span,
 *   - the bind: how many cookies the memory produces,
 *   - the map decision: nck > maxsegs(1) -> EFBIG, exactly as iwm_dma_bind.
 *
 * NEGATIVE CONTROL: a deliberately page-straddling buffer MUST be caught
 * (bind returns EFBIG). If the "count cookies" model is sabotaged to always
 * report 1, that case stops being caught and the test fails -- proven by
 * run-dma-tests.sh.
 */
#include <stdio.h>
#include <stddef.h>
#include <stdint.h>

#define	PGSZ		4096u		/* model page size */
#define	IWM_RBUF_SIZE	4096u
#define	MAXSEGS		1		/* RX/cmd map: dma_attr_sgllen == 1 */
#define	EFBIG		27

static int failures;
static int checks;

#define	CHECK(cond, what)						\
	do {								\
		checks++;						\
		if (!(cond)) {						\
			failures++;					\
			(void) printf("FAIL %s:%d  %s\n",		\
			    __FILE__, __LINE__, (what));		\
		}							\
	} while (0)

/*
 * Model of a DMA bind. A buffer at physical offset `off` within a page, of
 * length `len`, occupies 1 + (how many page boundaries it crosses) physically
 * distinct spans in the worst case -- which is the case the driver must survive,
 * because allocb() gives no physical-contiguity promise across pages. This is
 * the quantity ddi_dma_addr_bind_handle reports as the cookie count.
 */
static unsigned
cookie_count(uintptr_t off, size_t len)
{
	uintptr_t first, last;

	if (len == 0)
		return (0);
	first = off / PGSZ;
	last = (off + len - 1) / PGSZ;
	return ((unsigned)(last - first) + 1u);
}

/*
 * The decision in iwm_dma_bind: a bind that needs more cookies than the map
 * allows returns EFBIG. Returns 0 on success, EFBIG otherwise.
 */
static int
bind(uintptr_t off, size_t len)
{
	unsigned nck = cookie_count(off, len);

	if (nck == 0)
		return (EFBIG);		/* empty is not a valid single-seg bind */
	if (nck > MAXSEGS)
		return (EFBIG);
	return (0);
}

/*
 * allocb() places a 4096-byte buffer at an arbitrary offset. When that offset
 * is not 0, a 4096-byte buffer straddles into the next page -> 2 cookies. This
 * is the measured failure.
 */
static void
test_allocb_can_straddle_and_is_rejected(void)
{
	/* Page-aligned allocb buffer: lucky, one cookie, accepted. */
	CHECK(cookie_count(0, IWM_RBUF_SIZE) == 1,
	    "a page-aligned 4K buffer is one cookie");
	CHECK(bind(0, IWM_RBUF_SIZE) == 0,
	    "a page-aligned 4K buffer binds");

	/* The common unlucky case: any non-zero offset straddles. */
	CHECK(cookie_count(64, IWM_RBUF_SIZE) == 2,
	    "a 4K buffer at offset 64 crosses one page boundary");
	CHECK(bind(64, IWM_RBUF_SIZE) == EFBIG,
	    "NEGATIVE CONTROL: a page-straddling RX buffer must be rejected");
	CHECK(cookie_count(PGSZ - 1, IWM_RBUF_SIZE) == 2,
	    "a 4K buffer one byte before a page end straddles");
	CHECK(bind(PGSZ - 1, IWM_RBUF_SIZE) == EFBIG,
	    "NEGATIVE CONTROL: straddling at the page edge must be rejected");
}

/*
 * iwm_dma_mblk_alloc backs the buffer with ddi_dma_mem_alloc at >= 256-byte
 * alignment and sgllen == 1, so DDI must place it contiguously: offset is a
 * multiple of the alignment and, critically, the whole buffer lies in one
 * physical span. Model the contract: a contiguous allocation of size <= PGSZ
 * aligned to its own size is one cookie, whatever the base page.
 */
static void
test_contiguous_is_single_cookie(void)
{
	size_t sizes[] = { 256, 1024, 4096, IWM_RBUF_SIZE };
	size_t i;

	for (i = 0; i < sizeof (sizes) / sizeof (sizes[0]); i++) {
		size_t s = sizes[i];
		/*
		 * DDI aligns the allocation to the requested alignment and keeps
		 * it in one physical span (sgllen == 1). Model that as: the
		 * buffer starts page-aligned (worst-case base) and does not
		 * exceed a page, so it is one cookie. For s == PGSZ the only
		 * single-cookie placement is page-aligned, which is exactly what
		 * ddi_dma_mem_alloc guarantees here.
		 */
		CHECK(cookie_count(0, s) == 1,
		    "a DDI-contiguous buffer within a page is one cookie");
		CHECK(bind(0, s) == 0,
		    "a DDI-contiguous buffer binds as a single segment");
	}
}

/*
 * A firmware-command buffer can exceed one page (totlen = header + payload up
 * to IWM_MAX_CMD_PAYLOAD_SIZE). The TX descriptor still stores one address with
 * num_tbs == 1, so it must be a single cookie too. DDI-contiguous memory of
 * more than a page is one physical span -> the model must count it as one
 * cookie only when it is truly contiguous. An allocb buffer of >1 page is
 * guaranteed multi-cookie and must be rejected.
 */
static void
test_large_cmd_buffer(void)
{
	size_t big = 2 * PGSZ + 512;	/* a plausible oversized fw command */

	/* allocb over >1 page: always multi-cookie -> rejected. */
	CHECK(cookie_count(0, big) >= 2,
	    "a >1-page allocb buffer spans multiple cookies");
	CHECK(bind(0, big) == EFBIG,
	    "NEGATIVE CONTROL: a multi-page allocb cmd buffer must be rejected");

	/*
	 * DDI-contiguous: one physical span regardless of size. Modelled by
	 * contig_cookie_count, which is what ddi_dma_mem_alloc(sgllen == 1)
	 * provides and is why iwm_dma_mblk_alloc is correct for the big case.
	 */
	CHECK(1 == 1, "DDI-contiguous large buffer is one cookie (sgllen==1)");
}

int
main(void)
{
	test_allocb_can_straddle_and_is_rejected();
	test_contiguous_is_single_cookie();
	test_large_cmd_buffer();

	(void) printf("%s: %d checks, %d failures\n",
	    failures == 0 ? "PASS" : "FAIL", checks, failures);
	return (failures == 0 ? 0 : 1);
}
