/*
 * sbi.c — illumos riscv64 SBI (Supervisor Binary Interface) layer (R-P2).
 *
 * The S-mode kernel does not touch M-mode hardware directly; it asks OpenSBI
 * (the M-mode firmware) via the SBI ecall ABI. This is the illumos-correct
 * S-mode way to reach the console, timer, IPIs, and secondary harts — the
 * riscv64 analog of the firmware/PSCI/HVC glue on other arches.
 *
 * Reference: RISC-V SBI Specification (the authority) + NetBSD sys/arch/riscv/
 * riscv/sbi.c (BSD-2 — design studied, reimplemented in illumos idiom here).
 *
 * ---------------------------------------------------------------------------
 * SBI ecall ABI
 * ---------------------------------------------------------------------------
 *   a7 = EID (extension ID)
 *   a6 = FID (function ID)          [only for the "extension" call format]
 *   a0..a5 = arguments
 *   `ecall` traps to M-mode (OpenSBI)
 *   returns: a0 = error code (sbiret.error), a1 = value (sbiret.value)
 *
 * Two console paths are implemented:
 *   1. Legacy Console Putchar  — EID 0x01, no FID, char in a0. Simplest and
 *      universally present in OpenSBI; returns only a0. This is our primary
 *      banner path for R-P2.
 *   2. DBCN (Debug Console)    — EID 0x4442434E ("DBCN"), FID 0 = console_write
 *      of a (len, addr_lo, addr_hi) buffer. The modern, non-deprecated path.
 *      We probe it via SBI Base (EID 0x10) probe_extension and use it if
 *      present, else fall back to legacy putchar. This documents the correct
 *      forward path while keeping a guaranteed-working fallback.
 * ---------------------------------------------------------------------------
 */

#include "sbi.h"

/* SBI extension IDs. */
#define	SBI_EXT_LEGACY_PUTCHAR	0x01UL		/* legacy console putchar */
#define	SBI_EXT_BASE		0x10UL		/* SBI Base extension */
#define	SBI_EXT_TIME		0x54494D45UL	/* "TIME" timer extension */
#define	SBI_EXT_HSM		0x48534DUL	/* "HSM" hart state mgmt */
#define	SBI_EXT_IPI		0x735049UL	/* "sPI" inter-processor IPI */
#define	SBI_EXT_DBCN		0x4442434EUL	/* "DBCN" debug console */

/* SBI Base (0x10) function IDs. */
#define	SBI_BASE_PROBE_EXTENSION	3UL

/* SBI TIME (0x54494D45) function IDs. */
#define	SBI_TIME_SET_TIMER		0UL

/* SBI HSM (0x48534D) function IDs. */
#define	SBI_HSM_HART_START		0UL
#define	SBI_HSM_HART_GET_STATUS		2UL

/* SBI IPI (0x735049) function IDs. */
#define	SBI_IPI_SEND_IPI		0UL

/* DBCN (0x4442434E) function IDs. */
#define	SBI_DBCN_CONSOLE_WRITE		0UL

typedef struct sbiret {
	long error;	/* a0 */
	long value;	/* a1 */
} sbiret_t;

/*
 * sbi_ecall — issue an SBI call in the modern (extension) format.
 * Clobbers per the RISC-V calling convention; a0/a1 carry the return.
 */
static sbiret_t
sbi_ecall(unsigned long eid, unsigned long fid,
    unsigned long a0, unsigned long a1, unsigned long a2)
{
	register unsigned long r_a0 asm("a0") = a0;
	register unsigned long r_a1 asm("a1") = a1;
	register unsigned long r_a2 asm("a2") = a2;
	register unsigned long r_a6 asm("a6") = fid;
	register unsigned long r_a7 asm("a7") = eid;
	sbiret_t ret;

	__asm__ __volatile__(
		"ecall"
		: "+r"(r_a0), "+r"(r_a1)
		: "r"(r_a2), "r"(r_a6), "r"(r_a7)
		: "memory");

	ret.error = (long)r_a0;
	ret.value = (long)r_a1;
	return (ret);
}

/*
 * sbi_legacy_putchar — legacy EID 0x01. Char in a0, no FID. The legacy calls
 * predate the sbiret convention; they return only a status in a0 which we
 * ignore (OpenSBI always drains the byte).
 */
static void
sbi_legacy_putchar(int ch)
{
	register unsigned long r_a0 asm("a0") = (unsigned long)ch;
	register unsigned long r_a7 asm("a7") = SBI_EXT_LEGACY_PUTCHAR;

	__asm__ __volatile__(
		"ecall"
		: "+r"(r_a0)
		: "r"(r_a7)
		: "memory");
}

/*
 * Cached probe result: -1 = not yet probed, 0 = DBCN absent, 1 = DBCN present.
 * Lives in BSS (zeroed by locore); we initialize on first use.
 */
static int dbcn_present = -1;

static int
sbi_probe_dbcn(void)
{
	sbiret_t ret;

	if (dbcn_present >= 0)
		return (dbcn_present);

	/* SBI Base probe_extension(EID=DBCN): value != 0 means available. */
	ret = sbi_ecall(SBI_EXT_BASE, SBI_BASE_PROBE_EXTENSION,
	    SBI_EXT_DBCN, 0, 0);
	dbcn_present = (ret.error == 0 && ret.value != 0) ? 1 : 0;
	return (dbcn_present);
}

/*
 * sbi_console_putchar — public single-char console output.
 *
 * R-P5 change: use LEGACY putchar (EID 0x01), which passes the character in a
 * register (a0) with NO buffer pointer. The DBCN path passes the ADDRESS of a
 * byte to OpenSBI, which reads it back through the caller's address space —
 * that worked in R-P2..R-P4 only because everything ran on the identity-mapped
 * boot stack (VA==PA in the 0x80000000 gigapage). R-P5 introduces kernel
 * threads whose stacks live in the high canonical kmem VA range
 * (0xffffffc0...); a DBCN char buffer there is a VA OpenSBI's read path faults
 * on. Legacy putchar has no such buffer, so it is correct from ANY stack —
 * boot, secondary, or thread. (DBCN with a properly pinned/identity buffer is a
 * later console-driver concern; the NS16550A PLIC console replaces this in R-P6.)
 */
void
sbi_console_putchar(int ch)
{
	sbi_legacy_putchar(ch);
}

/*
 * sbi_console_puts — write a NUL-terminated string. Translates \n to \r\n so
 * the banner renders cleanly on a raw serial console (qemu -nographic).
 */
void
sbi_console_puts(const char *s)
{
	for (; *s != '\0'; s++) {
		if (*s == '\n')
			sbi_console_putchar('\r');
		sbi_console_putchar((unsigned char)*s);
	}
}

/*
 * sbi_set_timer — SBI TIME extension (EID 0x54494D45, FID 0). Programs the
 * platform timer (mtimecmp) to the absolute `time`-CSR deadline; when the
 * counter reaches it, OpenSBI pends the S-mode timer interrupt (STIP). Calling
 * again with a new (or far-future) deadline re-arms / disarms and clears the
 * currently-pending timer interrupt, per the SBI spec. Returns the SBI error
 * (0 == success).
 */
long
sbi_set_timer(unsigned long deadline)
{
	sbiret_t ret;

	ret = sbi_ecall(SBI_EXT_TIME, SBI_TIME_SET_TIMER, deadline, 0, 0);
	return (ret.error);
}

/*
 * sbi_hart_start — SBI HSM (EID 0x48534D, FID 0). Ask OpenSBI to release the
 * hart `hartid` (which is in the STOPPED state, parked in firmware) and start
 * it executing in S-mode at `start_addr` with a0=hartid, a1=opaque, satp=0.
 * This is how the R-P4 SMP bring-up wakes the secondary harts. Returns the
 * SBI error (0 == success; SBI_ERR_INVALID_PARAM if hartid can't be started).
 */
long
sbi_hart_start(unsigned long hartid, unsigned long start_addr,
    unsigned long opaque)
{
	sbiret_t ret;

	ret = sbi_ecall(SBI_EXT_HSM, SBI_HSM_HART_START, hartid, start_addr,
	    opaque);
	return (ret.error);
}

/*
 * sbi_hart_get_status — SBI HSM (EID 0x48534D, FID 2). Query the HSM state of
 * `hartid`. On success returns the non-negative state (SBI_HSM_STARTED=0,
 * STOPPED=1, START_PENDING=2, STOP_PENDING=3); on error returns the negative
 * SBI error. Used both to probe how many harts exist (a valid hartid returns a
 * state; an out-of-range one returns SBI_ERR_INVALID_PARAM) and to confirm a
 * secondary reached STARTED.
 */
long
sbi_hart_get_status(unsigned long hartid)
{
	sbiret_t ret;

	ret = sbi_ecall(SBI_EXT_HSM, SBI_HSM_HART_GET_STATUS, hartid, 0, 0);
	if (ret.error != 0)
		return (ret.error);
	return (ret.value);
}

/*
 * sbi_send_ipi — SBI IPI (EID 0x735049, FID 0). Pend a S-mode software
 * interrupt on the harts selected by (hart_mask, hart_mask_base): hart
 * (hart_mask_base + i) is targeted for each set bit i in hart_mask. The woken
 * hart traps IRQ_S_SOFT -> ipi_intr(). Used by the R-P13 dispatcher to wake an
 * idle secondary hart when a thread becomes runnable. Returns the SBI error.
 */
long
sbi_send_ipi(unsigned long hart_mask, unsigned long hart_mask_base)
{
	sbiret_t ret;

	ret = sbi_ecall(SBI_EXT_IPI, SBI_IPI_SEND_IPI, hart_mask,
	    hart_mask_base, 0);
	return (ret.error);
}

/*
 * sbi_console_kind — for the banner/diagnostics: which console path is live.
 * Returns a static string; forces a probe if not done.
 */
const char *
sbi_console_kind(void)
{
	/* R-P5: legacy putchar is the active path (no buffer-pointer issue on
	 * high-VA thread stacks); DBCN presence is still reported for info. */
	return (sbi_probe_dbcn() ?
	    "SBI legacy putchar (DBCN present)" :
	    "SBI legacy putchar (EID 0x01)");
}
