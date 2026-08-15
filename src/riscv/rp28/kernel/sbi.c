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
#define	SBI_EXT_LEGACY_SHUTDOWN	0x08UL		/* legacy shutdown fallback */

#define	SBI_TIME_SET_TIMER	0UL
#define	SBI_SRST_SYSTEM_RESET	0UL
#define	SBI_HSM_HART_START	0UL

typedef struct sbiret {
	long error;	/* a0 */
	long value;	/* a1 */
} sbiret_t;

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
	while (*s != '\0') {
		if (*s == '\n')
			sbi_console_putchar('\r');
		sbi_console_putchar((unsigned char)*s++);
	}
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
