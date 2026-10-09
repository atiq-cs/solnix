/*
 * test_vm.c -- obsd_vm.c's physical registry and uao allocator, in
 * userland (-DOBSD_USERTEST, test/obsd_vmshim.h). Exit 0 = all PASS.
 *   PHYS_TO_VM_PAGE(VM_PAGE_TO_PHYS(pg)) == pg for uvm_pglistalloc pages,
 *     uao pages and physload ranges (i915 reads i915->pgs[i] of the
 *     aperture as an array: PHYS_TO_VM_PAGE(base)[i] must be page i);
 *   an unregistered address gives NULL; freed pages are unregistered;
 *   uao_create zeroes, uvm_obj_wire hands back the pages in offset order,
 *     data written through one page's kva is read back through
 *     PHYS_TO_VM_PAGE -> kva; uao_reference/uao_detach count refs;
 *   no kmem left outstanding after everything is freed.
 * Negative control: -DOBSD_VM_SABOTAGE makes the AVL compare exact-pfn
 * only, so a lookup inside a physload range must FAIL.
 */
#include "../obsd_vm.c"

long ushim_kmem_outstanding;
static int fails;
/* evaluates c exactly once (it may allocate) */
#define CHECK(c, what) do { int _ok = (c); \
	printf("%s %s\n", _ok ? "PASS" : "FAIL", what); \
	if (!_ok) fails++; } while (0)

int
main(void)
{
	struct pglist pl;
	struct vm_page *pg;
	struct uvm_object *uo;
	int ok, n, i;
	long base;

	obsd_vm_init();
	base = ushim_kmem_outstanding;

	/* 1. 16 scattered pages: each registered, zeroed */
	TAILQ_INIT(&pl);
	CHECK(uvm_pglistalloc(16 * PAGESIZE, 0, (paddr_t)-1, PAGESIZE, 0, &pl,
	    16, UVM_PLA_ZERO) == 0, "uvm_pglistalloc 16 pages");
	ok = 1; n = 0;
	TAILQ_FOREACH(pg, &pl, pageq) {
		int a = PHYS_TO_VM_PAGE(VM_PAGE_TO_PHYS(pg)) == pg;
		int b = PHYS_TO_VM_PAGE(VM_PAGE_TO_PHYS(pg) + 123) == pg;
		int z = *(volatile char *)obsd_page_kva(pg) == 0;

		if (!(a && b && z))
			printf("  page %d pa %llx: base %d +123 %d zero %d\n", n,
			    (unsigned long long)VM_PAGE_TO_PHYS(pg), a, b, z);
		ok &= a && b && z;
		n++;
	}
	CHECK(ok && n == 16, "PHYS_TO_VM_PAGE round trip (page base and +123), zeroed");
	CHECK(PHYS_TO_VM_PAGE(0x123456789000ULL) == NULL,
	    "unregistered address -> NULL");
	pg = TAILQ_FIRST(&pl);
	{
		paddr_t pa = VM_PAGE_TO_PHYS(pg);

		uvm_pglistfree(&pl);
		CHECK(PHYS_TO_VM_PAGE(pa) == NULL, "freed page unregistered");
	}

	/* 2. a physload'd device range (aperture-like, 512 pages) */
	uvm_page_physload(0x4000000, 0x4000000 + 512, 0x4000000,
	    0x4000000 + 512, 0);
	pg = PHYS_TO_VM_PAGE(ptob(0x4000000));
	ok = pg != NULL;
	for (i = 0; ok && i < 512; i++)
		ok &= PHYS_TO_VM_PAGE(ptob(0x4000000 + i)) == &pg[i] &&
		    pg[i].phys_addr == ptob(0x4000000 + i);
	CHECK(ok, "physload range: PHYS_TO_VM_PAGE(base)[i] is page i (512)");
	CHECK(PHYS_TO_VM_PAGE(ptob(0x4000000 + 512)) == NULL,
	    "one past the range -> NULL");

	/* 3. uao: 33 MB (a 3840x2160 XRGB8888 dumb buffer), wire, rw */
	uo = uao_create(3840 * 2160 * 4, 0);
	CHECK(uo != NULL && uo->uo_npages == 8100, "uao_create 3840x2160x4 -> 8100 pages");
	TAILQ_INIT(&pl);
	CHECK(uvm_obj_wire(uo, 0, ptob(8100), &pl) == 0, "uvm_obj_wire whole object");
	ok = 1; i = 0;
	TAILQ_FOREACH(pg, &pl, pageq) {
		char *va = obsd_page_kva(pg);

		ok &= pg->offset == (voff_t)ptob(i) && va[0] == 0 && va[4095] == 0;
		va[7] = (char)(i * 31);
		i++;
	}
	CHECK(ok && i == 8100, "wired pages in offset order, zero-filled");
	ok = 1; i = 0;
	TAILQ_FOREACH(pg, &pl, pageq) {
		struct vm_page *p2 = PHYS_TO_VM_PAGE(VM_PAGE_TO_PHYS(pg));

		ok &= p2 == pg && ((char *)obsd_page_kva(p2))[7] == (char)(i * 31);
		i++;
	}
	CHECK(ok, "data written via kva read back via PHYS_TO_VM_PAGE");
	uvm_obj_unwire(uo, 0, ptob(8100));
	uao_reference(uo);
	uao_detach(uo);
	CHECK(uo->uo_refs == 1, "uao_reference + uao_detach: still referenced");
	pg = TAILQ_FIRST(&pl);
	{
		paddr_t pa = VM_PAGE_TO_PHYS(pg);

		uao_detach(uo);
		CHECK(PHYS_TO_VM_PAGE(pa) == NULL, "last uao_detach frees + unregisters");
	}
	CHECK(uvm_obj_wire(&(struct uvm_object){ 0 }, 0, PAGESIZE, &pl) == EINVAL,
	    "uvm_obj_wire on a non-uao object -> EINVAL");
	CHECK(ushim_kmem_outstanding - base ==
	    (long)(512 * sizeof (struct vm_page) + sizeof (struct obsd_pgchunk) +
	    sizeof (struct obsd_pfnent)),
	    "no kmem leaked (only the physload range remains)");

	printf("%s: %d failure(s)\n", fails ? "FAIL" : "PASS", fails);
	return (fails != 0);
}
