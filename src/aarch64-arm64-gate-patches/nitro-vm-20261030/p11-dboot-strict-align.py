#!/usr/bin/env python3
# p11-dboot-strict-align.py <gate> : aa64vm.  dboot runs with the MMU off (SCTLR.M=0 at EL1 and EL2 entry), where every
# data access is Device memory and any unaligned access takes an alignment fault.  The ACPI structs are #pragma pack(1),
# and without -mstrict-align gcc reads their fields with full-width loads.  On a Nitro VM the RSDP is at 0x...14, so
# get_acpi_xsdt's `ldr x19, [x0, #0x18]` (rsdp->XsdtPhysicalAddress) faults: esr 0x96000021, far 0x786e002c.
# Idempotent: a second run leaves the file alone.
import sys
p = sys.argv[1] + '/usr/src/uts/armv8/Makefile.rules'
a = 'DBOOT_FLAGS\t+= -_gcc=-march=armv8-a+nofp+nosimd\n'
b = a + ('# dboot runs with the MMU off, where an unaligned access faults (packed ACPI tables, e.g. a VM RSDP at 0x...14)\n'
         'DBOOT_FLAGS\t+= -_gcc=-mstrict-align\n')
s = open(p).read()
if '-mstrict-align' in s:
    print('p11 already applied'); sys.exit(0)
assert s.count(a) == 1, s.count(a)
open(p, 'w').write(s.replace(a, b)); print('p11 ok')
