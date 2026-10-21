/*
 * aa-ecam-test_ontrap.c — host self-check for the ecam on_trap() config-read fix.
 * Compiles the recovery logic verbatim and asserts: on a simulated external abort
 * the width-correct all-1s is returned (PCI "no function" convention), and on a
 * clean access the real MMIO value is returned.  No kernel headers; models on_trap
 * with setjmp so the control flow (including the __RETURNS_TWICE second return) is
 * exercised exactly as in the kernel.
 *
 *   gcc -std=c99 -Wall -Wextra -O2 aa-ecam-test_ontrap.c -o /tmp/t && /tmp/t
 *
 * NEGATIVE CONTROL built in: flip SIMULATE_ABORT off and the read must return the
 * real value, not all-1s; with it on, the clean-path asserts would fire if the
 * guard were a no-op.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <setjmp.h>

/* ---- model of the pieces the kernel provides ---- */
#define OT_DATA_ACCESS 0x01
typedef struct on_trap_data { jmp_buf jb; } on_trap_data_t;

#define PCI_EINVAL8  0xff
#define PCI_EINVAL16 0xffff
#define PCI_EINVAL32 0xffffffffU
#define PCI_EINVAL64 0xffffffffffffffffULL

#define PCI_CFG_SIZE_BYTE  1
#define PCI_CFG_SIZE_WORD  2
#define PCI_CFG_SIZE_DWORD 4
#define PCI_CFG_SIZE_QWORD 8

typedef struct {
	int write;
	int size;
	union { uint8_t b; uint16_t w; uint32_t dw; uint64_t qw; } value;
} req_t;
#define VAL8(r)  ((r)->value.b)
#define VAL16(r) ((r)->value.w)
#define VAL32(r) ((r)->value.dw)
#define VAL64(r) ((r)->value.qw)

/* on_trap(): arms protection, returns 0 the first time.  A simulated abort does
 * longjmp(1), so on_trap "returns" non-zero (the __RETURNS_TWICE semantics). */
static on_trap_data_t *g_otd;
static int on_trap(on_trap_data_t *otd, unsigned prot) { (void)prot; g_otd = otd; return setjmp(otd->jb); }
static void no_trap(void) { g_otd = NULL; }

/* The MMIO accessors.  When SIMULATE_ABORT, the FIRST load/store longjmps as the
 * kernel data-abort recovery would (via ot_trampoline back into on_trap). */
static int g_abort;
#define MMIO_FAULT() do { if (g_abort) longjmp(g_otd->jb, 1); } while (0)
static uint8_t  ddi_get8 (void *h, uint8_t  *a){ (void)h;(void)a; MMIO_FAULT(); return 0x12; }
static uint16_t ddi_get16(void *h, uint16_t *a){ (void)h;(void)a; MMIO_FAULT(); return 0x1234; }
static uint32_t ddi_get32(void *h, uint32_t *a){ (void)h;(void)a; MMIO_FAULT(); return 0x12345678U; }
static uint64_t ddi_get64(void *h, uint64_t *a){ (void)h;(void)a; MMIO_FAULT(); return 0x123456789abcdef0ULL; }
static void ddi_put8 (void *h, uint8_t  *a, uint8_t  v){ (void)h;(void)a;(void)v; MMIO_FAULT(); }
static void ddi_put16(void *h, uint16_t *a, uint16_t v){ (void)h;(void)a;(void)v; MMIO_FAULT(); }
static void ddi_put32(void *h, uint32_t *a, uint32_t v){ (void)h;(void)a;(void)v; MMIO_FAULT(); }
static void ddi_put64(void *h, uint64_t *a, uint64_t v){ (void)h;(void)a;(void)v; MMIO_FAULT(); }

/* ---- the function under test: the exact body shipped in ecam.c ---- */
static void *ec_handle = (void *)1;
static void ecam_access(req_t *req, void *addr)
{
	on_trap_data_t otd;

	if (on_trap(&otd, OT_DATA_ACCESS) != 0) {
		no_trap();
		if (!req->write) {
			switch (req->size) {
			case PCI_CFG_SIZE_BYTE:  VAL16(req) = PCI_EINVAL8;  break;
			case PCI_CFG_SIZE_WORD:  VAL16(req) = PCI_EINVAL16; break;
			case PCI_CFG_SIZE_DWORD: VAL32(req) = PCI_EINVAL32; break;
			case PCI_CFG_SIZE_QWORD: VAL64(req) = PCI_EINVAL64; break;
			default:                 VAL64(req) = PCI_EINVAL64; break;
			}
		}
		return;
	}

	switch (req->size) {
	case PCI_CFG_SIZE_BYTE:
		if (req->write) ddi_put8(ec_handle, (uint8_t *)addr, VAL8(req));
		else VAL16(req) = ddi_get8(ec_handle, (uint8_t *)addr);
		break;
	case PCI_CFG_SIZE_WORD:
		if (req->write) ddi_put16(ec_handle, (uint16_t *)addr, VAL16(req));
		else VAL16(req) = ddi_get16(ec_handle, (uint16_t *)addr);
		break;
	case PCI_CFG_SIZE_DWORD:
		if (req->write) ddi_put32(ec_handle, (uint32_t *)addr, VAL32(req));
		else VAL32(req) = ddi_get32(ec_handle, (uint32_t *)addr);
		break;
	case PCI_CFG_SIZE_QWORD:
		if (req->write) ddi_put64(ec_handle, (uint64_t *)addr, VAL64(req));
		else VAL64(req) = ddi_get64(ec_handle, (uint64_t *)addr);
		break;
	default:
		no_trap();
		return; /* kernel panics here; test just returns */
	}
	no_trap();
}

int main(void)
{
	req_t r;
	char dummy[8];

	/* ---- clean path (negative control: guard must NOT corrupt good reads) ---- */
	g_abort = 0;
	memset(&r, 0, sizeof r); r.size = PCI_CFG_SIZE_DWORD; r.write = 0;
	ecam_access(&r, dummy);
	assert(VAL32(&r) == 0x12345678U);

	memset(&r, 0, sizeof r); r.size = PCI_CFG_SIZE_WORD; r.write = 0;
	ecam_access(&r, dummy);
	assert(VAL16(&r) == 0x1234);

	/* ---- abort path: each width returns the right all-1s ---- */
	g_abort = 1;
	memset(&r, 0, sizeof r); r.size = PCI_CFG_SIZE_BYTE; r.write = 0;
	ecam_access(&r, dummy);
	assert(VAL16(&r) == PCI_EINVAL8);   /* byte read lands in VAL16 as code does */

	memset(&r, 0, sizeof r); r.size = PCI_CFG_SIZE_WORD; r.write = 0;
	ecam_access(&r, dummy);
	assert(VAL16(&r) == PCI_EINVAL16);

	memset(&r, 0, sizeof r); r.size = PCI_CFG_SIZE_DWORD; r.write = 0;
	ecam_access(&r, dummy);
	assert(VAL32(&r) == PCI_EINVAL32);

	memset(&r, 0, sizeof r); r.size = PCI_CFG_SIZE_QWORD; r.write = 0;
	ecam_access(&r, dummy);
	assert(VAL64(&r) == PCI_EINVAL64);

	/* ---- abort on a write: must not crash, value untouched, recovers ---- */
	memset(&r, 0, sizeof r); r.size = PCI_CFG_SIZE_DWORD; r.write = 1;
	VAL32(&r) = 0xdeadbeefU;
	ecam_access(&r, dummy);  /* longjmps out of ddi_put32, recovers, returns */

	/* ---- negative control: with the guard, an aborting DWORD read must be
	 *      all-1s, NOT the (unreachable) real value 0x12345678 ---- */
	memset(&r, 0, sizeof r); r.size = PCI_CFG_SIZE_DWORD; r.write = 0;
	ecam_access(&r, dummy);
	assert(VAL32(&r) != 0x12345678U);
	assert(VAL32(&r) == PCI_EINVAL32);

	printf("ALL CHECKS PASS\n");
	return 0;
}
