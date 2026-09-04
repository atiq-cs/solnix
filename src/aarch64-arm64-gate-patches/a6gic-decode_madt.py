#!/usr/bin/env python3
# WHAT: decode a real ACPI MADT (APIC) exactly the way dboot_synth_fdt.c's
# synth_scan_madt() walks it, to see the GICC/GICR topology Graviton presents.
import struct, sys, collections

b = open(sys.argv[1], 'rb').read()
sig, length, rev, cks, oem = struct.unpack_from('<4sIBB6s', b, 0)
print(f"sig={sig} length={length} rev={rev} oem={oem}")
off = 44  # ACPI_TABLE_MADT = header(36) + LocalApicAddress(4) + Flags(4)
counts = collections.Counter()
gicc = []
gicr = []
while off < length:
    t, l = struct.unpack_from('<BB', b, off)
    if l == 0:
        print(f"!! zero-length subtable at {off}: WALK STOPS HERE")
        break
    counts[t] += 1
    if t == 0x0b:  # GICC / GENERIC_INTERRUPT
        # ACPI_MADT_GENERIC_INTERRUPT layout after Type/Length:
        # Reserved(2) CpuInterfaceNumber(4) Uid(4) Flags(4) ParkingVersion(4)
        # PerformanceInterrupt(4) ParkedAddress(8) BaseAddress(8)
        # GicvBaseAddress(8) GichBaseAddress(8) VgicInterrupt(4)
        # GicrBaseAddress(8) ArmMpidr(8) EfficiencyClass(1) ...
        cpuif, uid, flags = struct.unpack_from('<III', b, off + 4)
        parkaddr, base, gicv, gich = struct.unpack_from('<QQQQ', b, off + 24)
        vgic, = struct.unpack_from('<I', b, off + 56)
        grbase, mpidr = struct.unpack_from('<QQ', b, off + 60)
        gicc.append((cpuif, uid, flags, base, grbase, mpidr, l))
    elif t == 0x0e:  # GICR / GENERIC_REDISTRIBUTOR
        base, ln = struct.unpack_from('<QI', b, off + 4)
        gicr.append((base, ln))
    off += l

names = {0x0b: 'GICC', 0x0c: 'GICMSI', 0x0d: 'GICD', 0x0e: 'GICR', 0x0f: 'GICITS'}
print("subtable counts:", {names.get(k, hex(k)): v for k, v in sorted(counts.items())})
print(f"\nngicc = {len(gicc)}   standalone GICR subtables = {len(gicr)}")
for base, ln in gicr:
    print(f"  GICR region base=0x{base:x} len=0x{ln:x}")

bases = sorted(set(g[4] for g in gicc))
print(f"\ndistinct GicrBaseAddress values among GICC: {len(bases)}")
print(f"  min=0x{bases[0]:x} max=0x{bases[-1]:x}")
for i, x in enumerate(bases):
    d = x - bases[i - 1] if i else 0
    print(f"  [{i:2d}] 0x{x:x}  delta=0x{d:x}")

# Are they one contiguous block at a uniform stride?
if len(bases) > 1:
    deltas = sorted(set(bases[i + 1] - bases[i] for i in range(len(bases) - 1)))
    print(f"\nunique deltas: {[hex(d) for d in deltas]}")
    span = bases[-1] - bases[0]
    print(f"span=0x{span:x}  ngicc*0x20000=0x{len(gicc)*0x20000:x} "
          f" ngicc*0x40000=0x{len(gicc)*0x40000:x}")
    print(f"contiguous-at-uniform-stride: {len(deltas) == 1}")

print("\nfirst 4 + last 2 GICC entries (cpuif, uid, flags, gicc_base, gicr_base, mpidr, len):")
for g in gicc[:4] + gicc[-2:]:
    print(f"  cpuif={g[0]:3d} uid={g[1]:3d} fl=0x{g[2]:x} "
          f"base=0x{g[3]:x} gicr=0x{g[4]:x} mpidr=0x{g[5]:x} len={g[6]}")
