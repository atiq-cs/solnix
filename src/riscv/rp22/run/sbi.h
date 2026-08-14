/*
 * Minimal SBI (Supervisor Binary Interface) calls for the qemu-virt console.
 * Crib: RISC-V SBI spec v2 -- legacy console_putchar (EID 0x01), and the
 * SRST (System Reset) extension (EID 0x53525354 "SRST", FID 0) for a clean
 * qemu shutdown; falls back to the legacy shutdown (EID 0x08) if SRST is
 * unavailable.  These are exactly the calls OpenSBI implements on qemu-virt.
 */
#ifndef _RP22_SBI_H
#define _RP22_SBI_H

struct sbiret { long error; long value; };

static inline struct sbiret
sbi_ecall(long eid, long fid, long a0, long a1, long a2)
{
	register long r_a0 __asm__("a0") = a0;
	register long r_a1 __asm__("a1") = a1;
	register long r_a2 __asm__("a2") = a2;
	register long r_a6 __asm__("a6") = fid;
	register long r_a7 __asm__("a7") = eid;
	__asm__ __volatile__("ecall"
		: "+r"(r_a0), "+r"(r_a1)
		: "r"(r_a2), "r"(r_a6), "r"(r_a7)
		: "memory");
	struct sbiret ret;
	ret.error = r_a0;
	ret.value = r_a1;
	return ret;
}

/* legacy console putchar: EID 0x01, char in a0 */
static inline void sbi_putchar(int c)
{
	sbi_ecall(0x01, 0, c, 0, 0);
}

/* SRST shutdown: type=0 (shutdown), reason=0; fall back to legacy 0x08 */
static inline void sbi_shutdown(void)
{
	sbi_ecall(0x53525354, 0, 0, 0, 0);
	sbi_ecall(0x08, 0, 0, 0, 0);
	for (;;) __asm__ __volatile__("wfi");
}

#endif
