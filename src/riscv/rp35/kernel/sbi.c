/*
 * sbi.c -- illumos riscv64 SBI (Supervisor Binary Interface) layer, R-P23
 * skeleton.  The S-mode kernel never touches M-mode hardware directly; it asks
 * OpenSBI (the M-mode firmware) via the SBI ecall ABI.  This is the
 * illumos-correct S-mode way to reach the console + reset.
 *
 * SBI ecall ABI: a7=EID, a6=FID, a0..a5=args, `ecall` traps to M-mode
 * (OpenSBI); returns a0=error, a1=value.
 *
 * R-P23 console: LEGACY console putchar (EID 0x01, char in a0, no buffer
 * pointer).  Legacy putchar is correct from ANY stack (boot/secondary/thread)
 * because it passes the char in a register, not a buffer VA OpenSBI must read
 * back -- exactly the R-P5 lesson from the full R-P16 kernel.  Clean shutdown
 * via the SRST (System Reset) extension so qemu exits instead of hanging.
 *
 * CRIB PROVENANCE: trimmed from this repo's R-P2..R-P16 uts/riscv64 sbi.c
 * (legacy-putchar console choice + the ecall register convention); the SBI
 * EIDs/FIDs (legacy putchar 0x01, TIME 0x54494D45, SRST 0x53525354) are the
 * RISC-V SBI spec; NetBSD sys/arch/riscv/riscv/sbi.c was studied for the ecall
 * inline-asm shape and reimplemented in illumos idiom.
 */

#include "sbi.h"

#define	SBI_EXT_LEGACY_PUTCHAR	0x01UL
#define	SBI_EXT_TIME		0x54494D45UL	/* "TIME" */
#define	SBI_EXT_SRST		0x53525354UL	/* "SRST" system reset */
#define	SBI_EXT_HSM		0x48534DUL	/* "HSM" hart state mgmt */
#define	SBI_EXT_IPI		0x735049UL	/* "sPI" inter-processor intr */
#define	SBI_EXT_RFENCE		0x52464E43UL	/* "RFNC" remote fence */
#define	SBI_EXT_LEGACY_SHUTDOWN	0x08UL		/* legacy shutdown fallback */

#define	SBI_TIME_SET_TIMER	0UL
#define	SBI_SRST_SYSTEM_RESET	0UL
#define	SBI_HSM_HART_START	0UL
#define	SBI_HSM_HART_STOP	1UL
#define	SBI_IPI_SEND_IPI	0UL
#define	SBI_RFENCE_REMOTE_SFENCE_VMA	1UL

typedef struct sbiret {
	long error;	/* a0 */
	long value;	/* a1 */
} sbiret_t;

static sbiret_t
sbi_ecall5(unsigned long eid, unsigned long fid,
    unsigned long a0, unsigned long a1, unsigned long a2,
    unsigned long a3, unsigned long a4)
{
	register unsigned long r_a0 asm("a0") = a0;
	register unsigned long r_a1 asm("a1") = a1;
	register unsigned long r_a2 asm("a2") = a2;
	register unsigned long r_a3 asm("a3") = a3;
	register unsigned long r_a4 asm("a4") = a4;
	register unsigned long r_a6 asm("a6") = fid;
	register unsigned long r_a7 asm("a7") = eid;
	sbiret_t ret;

	__asm__ __volatile__(
		"ecall"
		: "+r"(r_a0), "+r"(r_a1)
		: "r"(r_a2), "r"(r_a3), "r"(r_a4), "r"(r_a6), "r"(r_a7)
		: "memory");

	ret.error = (long)r_a0;
	ret.value = (long)r_a1;
	return (ret);
}

static sbiret_t
sbi_ecall(unsigned long eid, unsigned long fid,
    unsigned long a0, unsigned long a1, unsigned long a2)
{
	return (sbi_ecall5(eid, fid, a0, a1, a2, 0, 0));
}

void
sbi_console_putchar(int ch)
{
	register unsigned long r_a0 asm("a0") = (unsigned long)ch;
	register unsigned long r_a7 asm("a7") = SBI_EXT_LEGACY_PUTCHAR;

	__asm__ __volatile__(
		"ecall"
		: "+r"(r_a0)
		: "r"(r_a7)
		: "memory");
}

void
sbi_console_puts(const char *s)
{
	/*
	 * R-P32: serialize whole-string console writes across harts (both harts
	 * print concurrently once the SMP proc dispatcher runs), so a proof line
	 * from one hart is not interleaved char-by-char with the other's -- an
	 * amoswap.w test-and-set (RISC-V A extension).  putchar itself stays
	 * lock-free (used inside the lock + by single-char paths).
	 */
	static volatile int cons_lock;
	int prev;
	do {
		__asm__ __volatile__("amoswap.w.aq %0, %2, %1"
		    : "=r"(prev), "+A"(cons_lock) : "r"(1) : "memory");
	} while (prev != 0);
	while (*s != '\0') {
		if (*s == '\n')
			sbi_console_putchar('\r');
		sbi_console_putchar((unsigned char)*s++);
	}
	__asm__ __volatile__("amoswap.w.rl zero, zero, %0"
	    : "+A"(cons_lock) :: "memory");
}

const char *
sbi_console_kind(void)
{
	return ("SBI legacy console (EID 0x01)");
}

long
sbi_set_timer(unsigned long deadline)
{
	sbiret_t r = sbi_ecall(SBI_EXT_TIME, SBI_TIME_SET_TIMER,
	    deadline, 0, 0);
	return (r.error);
}

/*
 * sbi_hart_start -- R-P28 SMP: ask OpenSBI (HSM extension) to start a secondary
 * hart in S-mode at physical address `addr` with `opaque` handed to it in a1
 * (a0 = the hartid).  The target hart must be in the STOPPED state (which
 * non-boot harts are on qemu-virt after OpenSBI hands the boot hart the S-mode
 * payload).  Returns the SBI error (0 = SBI_SUCCESS).
 *
 * CRIB PROVENANCE: the HSM hart_start ecall (EID "HSM"=0x48534D, FID 0, args
 * hartid/start_addr/opaque) is the RISC-V SBI spec (Hart State Management
 * extension); using it to bring up APs is the illumos mp_startup / i86pc
 * mach_cpu_start + BSD riscv cpu_hatch AP-start idiom mapped onto SBI.
 */
long
sbi_hart_start(unsigned long hartid, unsigned long addr, unsigned long opaque)
{
	sbiret_t r = sbi_ecall(SBI_EXT_HSM, SBI_HSM_HART_START,
	    hartid, addr, opaque);
	return (r.error);
}

/*
 * sbi_hart_stop -- R-P29: the CALLING hart stops itself (returns to the SBI
 * HSM STOPPED state), so it can later be re-started with sbi_hart_start.  A
 * secondary calls this after it finishes draining a runq; the boot hart may
 * then re-launch it for a fresh phase.  Does not return on success.
 *
 * CRIB PROVENANCE: the HSM hart_stop ecall (EID "HSM"=0x48534D, FID 1) is the
 * RISC-V SBI spec; a CPU parking itself back to an offline state is the illumos
 * mp_cpu_stop / cpu_offline reduced to the SBI HSM stop primitive.
 */
long
sbi_hart_stop(void)
{
	sbiret_t r = sbi_ecall(SBI_EXT_HSM, SBI_HSM_HART_STOP, 0, 0, 0);
	return (r.error);
}

/*
 * sbi_send_ipi_hart -- R-P29: post an inter-processor interrupt to a single
 * hart.  hart_mask = (1 << relative_hartid), hart_mask_base = 0 so bit i =
 * hartid i (fine for hartids 0/1 on qemu-virt).  Returns the SBI error.
 *
 * CRIB PROVENANCE: the SBI IPI extension (EID "sPI"=0x735049, FID 0, args
 * hart_mask/hart_mask_base) is the RISC-V SBI spec; using an IPI to poke a peer
 * CPU is the illumos poke_cpu / x_call cross-call primitive mapped onto SBI.
 */
long
sbi_send_ipi_hart(unsigned long hartid)
{
	sbiret_t r = sbi_ecall(SBI_EXT_IPI, SBI_IPI_SEND_IPI,
	    (1UL << hartid), 0, 0);
	return (r.error);
}

/*
 * sbi_remote_sfence_vma -- R-P29 TLB shootdown: ask OpenSBI to execute an
 * sfence.vma on a remote hart so it drops stale translations after a shared
 * kernel mapping changed.  hart_mask = (1 << hartid); start=0,size=-1 means a
 * full flush.  Returns the SBI error.
 *
 * CRIB PROVENANCE: the SBI RFENCE extension (EID "RFNC"=0x52464E43, FID 1
 * remote_sfence_vma, args hart_mask/base/start/size) is the RISC-V SBI spec;
 * driving it from a mapping change is the illumos hat_tlb_inval cross-CPU TLB
 * shootdown reduced to the SBI remote-fence primitive.
 */
long
sbi_remote_sfence_vma(unsigned long hartid)
{
	sbiret_t r = sbi_ecall5(SBI_EXT_RFENCE, SBI_RFENCE_REMOTE_SFENCE_VMA,
	    (1UL << hartid), 0, 0, ~0UL, 0);
	return (r.error);
}

void
sbi_shutdown(void)
{
	/* SRST system_reset(type=shutdown(0), reason=none(0)). */
	(void) sbi_ecall(SBI_EXT_SRST, SBI_SRST_SYSTEM_RESET, 0, 0, 0);
	/* Fall back to the legacy shutdown, then spin. */
	(void) sbi_ecall(SBI_EXT_LEGACY_SHUTDOWN, 0, 0, 0, 0);
	for (;;)
		__asm__ __volatile__("wfi");
}
