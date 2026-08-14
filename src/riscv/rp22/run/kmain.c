/*
 * The first EXECUTING riscv64-solaris code: a freestanding hello that runs
 * on qemu-system-riscv64 -machine virt via the OpenSBI console, built with
 * the riscv64-unknown-solaris2.11 gcc + the R-P17 binutils.  This proves the
 * EM_RISCV code our solaris-target toolchain emits actually EXECUTES on a
 * real riscv64 (emulated) machine.
 */
#include "sbi.h"

static void puts_sbi(const char *s)
{
	while (*s)
		sbi_putchar((unsigned char)*s++);
}

void kmain(unsigned long hartid, void *fdt)
{
	(void)fdt;
	puts_sbi("hello from riscv64-solaris (R-P22)\n");
	puts_sbi("first executing riscv64-solaris code\n");
	sbi_shutdown();
}
